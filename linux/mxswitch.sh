#!/usr/bin/env bash
# mxswitch.sh - switch a Logitech Easy-Switch device to another channel.
# Linux only. Needs nothing but bash, coreutils and read/write access to hidraw.
#
#   ./mxswitch.sh --info      show channels and which one is active
#   ./mxswitch.sh --status    --info plus battery and firmware
#   ./mxswitch.sh 2           switch to channel 2
#   ./mxswitch.sh --all 2     switch every ChangeHost device
#   ./mxswitch.sh --toggle    switch to the other configured channel
#   ./mxswitch.sh --list      list candidate hidraw nodes
#
# Config (optional), key=value lines:
#   ${XDG_CONFIG_HOME:-$HOME/.config}/mxswitch/config
#     channel_a=1
#     channel_b=2
#     device=primary|all
#
# Exit codes: 0 ok, 1 device not found, 2 bad usage, 3 partial --all failure.
#
# hidraw nodes are root-only by default. One-time fix, as root:
#   sudo cp linux/42-logitech-hidpp.rules /etc/udev/rules.d/
#   sudo udevadm control --reload-rules && sudo udevadm trigger
# The rule covers USB/Bolt receivers and Bluetooth-connected devices.

set -uo pipefail

SW_ID=10                 # software id, any value 1..15
FEAT_CHANGE_HOST_HI=0x18
FEAT_CHANGE_HOST_LO=0x14
DEVICE_INDICES=(255 1 2 3 4 5 6)
REPORT_IDS=(0x11 0x10)   # long, short
READ_TIMEOUT=0.2

CONFIG_CHANNEL_A=1
CONFIG_CHANNEL_B=2
CONFIG_DEVICE=primary
CONFIG_NAME=""

byte() { printf '%s' "${1:$(( $2 * 2 )):2}"; }   # byte N of a hex string

# ---------------------------------------------------------------------------
# Pure protocol helpers (hardware-free; exercised by tests)
# ---------------------------------------------------------------------------

# hidpp_build_frame <report_id> <dev_idx> <feature_idx> <function> [params...]
# Echoes the full report as a hex string, zero-padded to the report length.
hidpp_build_frame() {
    local rid=$1 didx=$2 fidx=$3 func=$4; shift 4
    local len=20; [ "$(( rid ))" -eq 16 ] && len=7
    local -a frame=( "$(( rid ))" "$(( didx ))" "$(( fidx ))" \
                     "$(( (func << 4) | SW_ID ))" )
    local p; for p in "$@"; do frame+=( "$(( p ))" ); done
    [ "${#frame[@]}" -le "$len" ] || return 1
    while [ "${#frame[@]}" -lt "$len" ]; do frame+=( 0 ); done
    local out="" b
    for b in "${frame[@]}"; do out+=$(printf '%02x' "$b"); done
    printf '%s' "$out"
}

# hidpp_classify_reply <reply_hex> <dev_idx> <feature_idx>
# Echoes one of: too_short, ignore, error, match.
hidpp_classify_reply() {
    local reply=$1 didx=$2 fidx=$3 func=${4:-0}
    [ "${#reply}" -ge 10 ] || { printf 'too_short'; return 0; }
    local minimum
    case "$(byte "$reply" 0)" in 10) minimum=14 ;; 11) minimum=40 ;; *) printf ignore; return 0 ;; esac
    [ "${#reply}" -ge "$minimum" ] || { printf too_short; return 0; }
    # Compare numerically: callers may pass the device index in hex.
    local reply_idx=$(( 0x$(byte "$reply" 1) ))
    if [ "$reply_idx" -ne "$(( didx ))" ] && ! { [ "$(( didx ))" -eq 255 ] && [ "$reply_idx" -eq 0 ]; }; then
        printf ignore; return 0
    fi
    local rf=$(( 0x$(byte "$reply" 2) ))
    # 0xff / 0x8f are HID++ 2.0 / 1.0 error replies
    local header=$(( (func << 4) | SW_ID ))
    if [ "$rf" -eq 255 ] || [ "$rf" -eq 143 ]; then
        [ "${#reply}" -ge 12 ] || { printf too_short; return 0; }
        if [ "$(( 0x$(byte "$reply" 3) ))" -eq "$fidx" ] &&
           [ "$(( 0x$(byte "$reply" 4) ))" -eq "$header" ]; then printf error
        else printf ignore; fi
        return 0
    fi
    [ "$rf" -eq "$fidx" ] || { printf 'ignore'; return 0; }
    [ "$(( 0x$(byte "$reply" 3) ))" -eq "$header" ] \
        || { printf 'ignore'; return 0; }
    printf 'match'
}

# name_matches <name> [<substr>...]
# True (0) when no substring is given, or the name contains any of them,
# case-insensitively. Empty substrings are ignored.
name_matches() {
    local name=$1; shift
    [ "$#" -gt 0 ] || return 0
    local lower f
    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    for f in "$@"; do
        [ -n "$f" ] || continue
        case "$lower" in
            *"$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"*) return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

hidraw_name() {
    local node=$1
    grep -i '^HID_NAME=' "/sys/class/hidraw/$(basename "$node")/device/uevent" \
        2>/dev/null | cut -d= -f2-
}

logitech_hidraws() {
    # Mice first, then unknowns, keyboards last — based on HID_NAME.
    local node name lower rank
    local -a mice=() other=() kbds=()
    for node in /dev/hidraw*; do
        [ -e "$node" ] || continue
        name=$(basename "$node")
        # HID_ID looks like 0003:0000046D:0000C548
        if ! grep -qi '^HID_ID=[^:]*:0*46[dD]:' "/sys/class/hidraw/$name/device/uevent" \
               2>/dev/null; then
            continue
        fi
        lower=$(hidraw_name "$node" | tr '[:upper:]' '[:lower:]')
        rank=1
        case "$lower" in *master*|*anywhere*|*mouse*|*ergo*) rank=0 ;; esac
        case "$lower" in *keys*|*keyboard*)
            [ "$rank" -eq 0 ] || rank=2
            ;;
        esac
        case "$rank" in
            0) mice+=("$node") ;;
            2) kbds+=("$node") ;;
            *) other+=("$node") ;;
        esac
    done
    printf '%s\n' ${mice[@]+"${mice[@]}"} ${other[@]+"${other[@]}"} \
                  ${kbds[@]+"${kbds[@]}"}
}

# hidpp_send <fd> <report_id> <dev_idx> <feature_idx> <function> [params...]
# Fire-and-forget; used for setCurrentHost, which never replies.
hidpp_send() {
    local fd=$1 rid=$2 didx=$3 fidx=$4 func=$5; shift 5
    local hex; hex=$(hidpp_build_frame "$rid" "$didx" "$fidx" "$func" "$@") \
        || return 1
    local esc="" i
    for (( i=0; i<${#hex}; i+=2 )); do esc+="\\x${hex:i:2}"; done
    printf '%b' "$esc" >&"$fd"
}

# hidpp_call <fd> <report_id> <dev_idx> <feature_idx> <function> [params...]
# Echoes the matching reply as a hex string, or nothing.
hidpp_call() {
    local fd=$1 rid=$2 didx=$3 fidx=$4 func=$5; shift 5
    # Clear queued notifications/replies before issuing a new request.
    timeout 0.01 dd bs=64 count=16 status=none <&"$fd" >/dev/null 2>&1 || true
    local hex; hex=$(hidpp_build_frame "$rid" "$didx" "$fidx" "$func" "$@") \
        || return 1
    local esc="" i
    for (( i=0; i<${#hex}; i+=2 )); do esc+="\\x${hex:i:2}"; done
    printf '%b' "$esc" >&"$fd" || return 1

    # Replies share the pipe with unsolicited notifications, so read a few.
    local try reply verdict
    for (( try=0; try<3; try++ )); do
        reply=$(timeout "$READ_TIMEOUT" dd bs=64 count=1 status=none <&"$fd" \
                2>/dev/null | od -An -v -tx1 | tr -d ' \n')
        [ -n "$reply" ] || return 1
        verdict=$(hidpp_classify_reply "$reply" "$didx" "$fidx" "$func")
        case "$verdict" in
            match) printf '%s' "$reply"; return 0 ;;
            error) return 1 ;;
            *) continue ;;                # too short or a notification
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# Group USB collections by their common device ancestor; BT has one HID parent.
hidraw_identity() {
    local path parent
    path=$(readlink -f "/sys/class/hidraw/$(basename "$1")/device")
    parent=$path
    while [ -n "$parent" ] && [ "$parent" != / ]; do
        if [ -e "$parent/idVendor" ]; then printf '%s' "$parent"; return; fi
        parent=${parent%/*}
    done
    printf '%s' "${path:-$1}"
}

# Sets META_NAME and META_KEY from the peripheral, not the receiver collection.
device_metadata() {
    local fd=$1 rid=$2 didx=$3 fallback=$4 identity=$5 reply idx length offset fragment hex="" part
    META_NAME=$fallback
    META_KEY="$identity:$didx"
    if [ "$didx" -ne 255 ]; then
        META_NAME="${fallback:-receiver} (slot $didx)"
        if reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 0 5 0); then
            idx=$(( 0x$(byte "$reply" 4) ))
            if [ "$idx" -gt 0 ] && reply=$(hidpp_call "$fd" "$rid" "$didx" "$idx" 0); then
                length=$(( 0x$(byte "$reply" 4) )); offset=0
                while [ "$offset" -lt "$length" ]; do
                    fragment=$(hidpp_call "$fd" "$rid" "$didx" "$idx" 1 "$offset") || break
                    part=${fragment:8:$(( (length-offset)*2 ))}
                    [ -n "$part" ] || break
                    hex+=$part; offset=$(( ${#hex}/2 ))
                done
                if [ "$length" -gt 0 ] && [ "$offset" -eq "$length" ]; then
                    local esc="" i
                    for (( i=0; i<${#hex}; i+=2 )); do esc+="\\x${hex:i:2}"; done
                    META_NAME=$(printf '%b' "$esc")
                fi
            fi
        fi
    fi
    if reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 0 3 0); then
        idx=$(( 0x$(byte "$reply" 4) ))
        if [ "$idx" -gt 0 ] && reply=$(hidpp_call "$fd" "$rid" "$didx" "$idx" 0) &&
           [ "${#reply}" -ge 18 ] && [ "${reply:10:8}" != 00000000 ]; then
            META_KEY="unit:${reply:10:8}"
        fi
    fi
}

DEV_NODES=(); DEV_FDS=(); DEV_RIDS=(); DEV_DIDX=(); DEV_FIDX=(); DEV_NAMES=()
META_NAME="" META_KEY=""

# Close each shared transport once. With keep set, retain the primary transport.
close_devices() {
    local keep=${1:-} fd seen=" "
    for fd in ${DEV_FDS[@]+"${DEV_FDS[@]}"}; do
        [ "$fd" = "$keep" ] && continue
        case "$seen" in *" $fd "*) continue ;; esac
        seen+="$fd "
        { exec {fd}>&-; } 2>/dev/null || true
    done
}

device_name_rank() {
    local lower; lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$lower" in *master*|*anywhere*|*mouse*|*ergo*) echo 0 ;;
        *keys*|*keyboard*) echo 2 ;; *) echo 1 ;; esac
}

find_device() {
    local want_all=${1:-0}
    [ "$#" -gt 0 ] && shift
    DEV_NODES=(); DEV_FDS=(); DEV_RIDS=(); DEV_DIDX=(); DEV_FIDX=(); DEV_NAMES=()
    local node rid didx reply fidx name fd matched retained identity key duplicate preferred rank
    local -a seen=() ranks=()
    for node in $(logitech_hidraws); do
        name=$(hidraw_name "$node")
        identity=$(hidraw_identity "$node")
        { exec {fd}<>"$node"; } 2>/dev/null || continue
        retained=0; preferred=0
        for didx in "${DEVICE_INDICES[@]}"; do
            matched=0
            for rid in "${REPORT_IDS[@]}"; do
                [ "${VERBOSE:-0}" -eq 1 ] && printf 'probing %s index=%s report=%s\n' "$name" "$didx" "$rid" >&2
                reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
                        "$FEAT_CHANGE_HOST_HI" "$FEAT_CHANGE_HOST_LO" 0) || continue
                fidx=$(( 0x$(byte "$reply" 4) ))
                [ "$fidx" -ne 0 ] || continue
                matched=1; break
            done
            [ "$matched" -eq 1 ] || continue
            device_metadata "$fd" "$rid" "$didx" "$name" "$identity"
            duplicate=0
            for key in ${seen[@]+"${seen[@]}"}; do [ "$key" = "$META_KEY" ] && duplicate=1; done
            if [ "$duplicate" -eq 0 ] && name_matches "$META_NAME" "$@"; then
                seen+=("$META_KEY"); retained=1
                DEV_NODES+=("$node"); DEV_FDS+=("$fd"); DEV_RIDS+=("$rid")
                DEV_DIDX+=("$didx"); DEV_FIDX+=("$fidx"); DEV_NAMES+=("$META_NAME")
                rank=$(device_name_rank "$META_NAME"); ranks+=("$rank")
                if [ "$want_all" -eq 0 ] && [ "$rank" -eq 0 ]; then preferred=1; break; fi
            fi
            [ "$didx" -eq 255 ] && break
        done
        if [ "$retained" -eq 0 ]; then exec {fd}>&-; fi
        [ "$preferred" -eq 1 ] && break
    done
    local i j tmp
    for (( i=1; i<${#DEV_FDS[@]}; i++ )); do
        for (( j=i; j>0 && ranks[j]<ranks[j-1]; j-- )); do
            tmp=${ranks[j]}; ranks[j]=${ranks[j-1]}; ranks[j-1]=$tmp
            tmp=${DEV_NODES[j]}; DEV_NODES[j]=${DEV_NODES[j-1]}; DEV_NODES[j-1]=$tmp
            tmp=${DEV_FDS[j]}; DEV_FDS[j]=${DEV_FDS[j-1]}; DEV_FDS[j-1]=$tmp
            tmp=${DEV_RIDS[j]}; DEV_RIDS[j]=${DEV_RIDS[j-1]}; DEV_RIDS[j-1]=$tmp
            tmp=${DEV_DIDX[j]}; DEV_DIDX[j]=${DEV_DIDX[j-1]}; DEV_DIDX[j-1]=$tmp
            tmp=${DEV_FIDX[j]}; DEV_FIDX[j]=${DEV_FIDX[j-1]}; DEV_FIDX[j-1]=$tmp
            tmp=${DEV_NAMES[j]}; DEV_NAMES[j]=${DEV_NAMES[j-1]}; DEV_NAMES[j-1]=$tmp
        done
    done
    [ "${#DEV_FDS[@]}" -gt 0 ] || return 1
    if [ "$want_all" -eq 0 ]; then
        close_devices "${DEV_FDS[0]}"
        DEV_NODES=("${DEV_NODES[0]}"); DEV_FDS=("${DEV_FDS[0]}"); DEV_RIDS=("${DEV_RIDS[0]}")
        DEV_DIDX=("${DEV_DIDX[0]}"); DEV_FIDX=("${DEV_FIDX[0]}"); DEV_NAMES=("${DEV_NAMES[0]}")
    fi
}

# Echoes "<percent> <charging 0|1>". Returns 1 if unsupported.
battery_status() {
    local fd=$1 rid=$2 didx=$3 feat reply fidx function status percent
    for feat in 0x1004 0x1000; do
        reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
                "$(( feat >> 8 ))" "$(( feat & 0xff ))" 0) || continue
        fidx=$(( 0x$(byte "$reply" 4) ))
        [ "$fidx" -ne 0 ] || continue
        function=0; [ "$feat" = 0x1004 ] && function=1
        reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" "$function") || continue
        [ "${#reply}" -ge 14 ] || continue
        percent=$(( 0x$(byte "$reply" 4) )); status=$(( 0x$(byte "$reply" 6) ))
        [ "$percent" -gt 0 ] && [ "$percent" -le 100 ] || continue
        local charging=0
        [ "$status" -eq 1 ] || [ "$status" -eq 2 ] && charging=1
        printf '%d %d' "$percent" "$charging"
        return 0
    done
    return 1
}

# Echoes main firmware version. Returns 1 if unsupported.
firmware_version() {
    local fd=$1 rid=$2 didx=$3 reply fidx count entity build
    reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 0 3 0) || return 1
    fidx=$(( 0x$(byte "$reply" 4) ))
    [ "$fidx" -ne 0 ] || return 1
    reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" 0) || return 1
    count=$(( 0x$(byte "$reply" 4) ))
    for (( entity=0; entity<count; entity++ )); do
        reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" 1 "$entity") || continue
        [ "${#reply}" -ge 24 ] && [ "$(( 0x$(byte "$reply" 4) & 15 ))" -eq 0 ] || continue
        printf '%02X.%02X' "$(( 0x$(byte "$reply" 8) ))" "$(( 0x$(byte "$reply" 9) ))"
        build=$(( 0x${reply:20:4} ))
        [ "$build" -ne 0 ] && printf '.B%04X' "$build"
        return 0
    done
    return 1
}

host_info() {
    # Echoes "hosts current0" from getHostInfo.
    local fd=$1 rid=$2 didx=$3 fidx=$4 reply
    reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" 0) || return 1
    printf '%d %d' "$(( 0x$(byte "$reply" 4) ))" "$(( 0x$(byte "$reply" 5) ))"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

config_file() {
    printf '%s' "${MXSWITCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/mxswitch/config}"
}

config_load() {
    local file=$1 line key value
    if [ -e "$file" ] && [ ! -r "$file" ]; then echo "Cannot read config: $file" >&2; return 1; fi
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        case "$line" in *=*) ;; *) continue ;; esac
        key=${line%%=*}
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value=${line#*=}
        # Trim only the ends: a name filter may contain internal spaces.
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
        case "$key" in
            channel_a) CONFIG_CHANNEL_A=$value ;;
            channel_b) CONFIG_CHANNEL_B=$value ;;
            device)    CONFIG_DEVICE=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]') ;;
            name)      CONFIG_NAME=$value ;;
        esac
    done <"$file"
}

config_problems() {
    local problems=""
    case "$CONFIG_CHANNEL_A" in 1|2|3) ;; *) problems+="channel_a must be 1, 2 or 3; " ;; esac
    case "$CONFIG_CHANNEL_B" in 1|2|3) ;; *) problems+="channel_b must be 1, 2 or 3; " ;; esac
    [ "$CONFIG_CHANNEL_A" != "$CONFIG_CHANNEL_B" ] || problems+="channel_a and channel_b must differ; "
    case "$CONFIG_DEVICE" in primary|all) ;; *) problems+="device must be primary or all; " ;; esac
    printf '%s' "$problems"
}

json_escape() {
    local s=$1 c code i
    local LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
        c=${s:i:1}
        case "$c" in
            \\) printf '%s' "\\\\" ;;
            '"') printf '\\"' ;;
            *) printf -v code '%d' "'$c"
               if [ "$code" -lt 32 ]; then printf '\\u%04x' "$code"
               else printf '%s' "$c"; fi ;;
        esac
    done
}

# ---------------------------------------------------------------------------

usage() {
    echo "usage: $0 {1|2|3|--info|--status|--toggle|--list} [--all] [--name SUBSTR] [--dry-run] [--json] [--verbose] [--config PATH]" >&2
}

main() {
    local mode="" channel="" mode_count=0 want_all=0 dry=0 json=0 verbose=0 config=""
    local -a want_name=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --info)    mode="info"; mode_count=$((mode_count+1)) ;;
            --status)  mode="status"; mode_count=$((mode_count+1)) ;;
            --toggle)  mode="toggle"; mode_count=$((mode_count+1)) ;;
            --list)    mode="list"; mode_count=$((mode_count+1)) ;;
            --all)     want_all=1 ;;
            --name)    shift; want_name+=("${1:-}")
                       [ -n "${1:-}" ] || { usage; exit 2; } ;;
            --dry-run) dry=1 ;;
            --json)    json=1 ;;
            --verbose) verbose=1 ;;
            --config)  shift; config=${1:-}
                       [ -n "$config" ] || { usage; exit 2; } ;;
            -h|--help) usage; exit 0 ;;
            1|2|3)     [ -z "$channel" ] || { usage; exit 2; }; channel=$1 ;;
            *) usage; exit 2 ;;
        esac
        shift
    done

    if [ "$mode_count" -gt 1 ] || { [ "$mode_count" -gt 0 ] && [ -n "$channel" ]; }; then
        echo 'Give exactly one channel or mode (--info, --status, --toggle, --list).' >&2; exit 2
    fi
    if [ "$mode" = "list" ]; then
        local node
        for node in $(logitech_hidraws); do
            printf '%s  %s\n' "$node" "$(hidraw_name "$node")"
        done
        exit 0
    fi

    if [ -n "$config" ] && [ ! -r "$config" ]; then
        echo "Cannot read config: $config" >&2; exit 2
    fi
    config=${config:-$(config_file)}
    config_load "$config" || exit 2
    local problems; problems=$(config_problems)
    if [ -n "$problems" ]; then echo "Invalid config $config: $problems" >&2; exit 2; fi
    VERBOSE=$verbose
    [ "$CONFIG_DEVICE" = "all" ] && want_all=1

    if [ -n "$CONFIG_NAME" ]; then
        local -a cfg_names cn
        IFS=',' read -ra cfg_names <<< "$CONFIG_NAME"
        for cn in ${cfg_names[@]+"${cfg_names[@]}"}; do
            cn="${cn#"${cn%%[![:space:]]*}"}"
            cn="${cn%"${cn##*[![:space:]]}"}"
            [ -n "$cn" ] && want_name+=("$cn")
        done
    fi

    [ "$verbose" -eq 1 ] && echo "config     : $config" >&2

    if [ -z "$mode" ] && [ -z "$channel" ]; then usage; exit 2; fi

    if ! find_device "$want_all" ${want_name[@]+"${want_name[@]}"}; then
        echo "No Logitech device supporting ChangeHost found." >&2
        echo "Click the mouse to wake it; check hidraw permissions (see header)." >&2
        exit 1
    fi

    local n=${#DEV_FDS[@]}

    if [ "$mode" = "info" ] || [ "$mode" = "status" ]; then
        local i first=1
        [ "$json" -eq 1 ] && printf '['
        for (( i=0; i<n; i++ )); do
            local transport hosts battery="" charging="" fw=""
            transport="receiver"; [ "$(( DEV_DIDX[i] ))" -eq 255 ] \
                && transport="direct (BT/USB)"
            if [ "$mode" = "status" ]; then
                local battery_pair=""
                if battery_pair=$(battery_status "${DEV_FDS[$i]}" \
                        "${DEV_RIDS[$i]}" "${DEV_DIDX[$i]}"); then
                    battery=${battery_pair% *}
                    charging=${battery_pair#* }
                fi
                fw=$(firmware_version "${DEV_FDS[$i]}" "${DEV_RIDS[$i]}" \
                     "${DEV_DIDX[$i]}" || true)
            fi
            if [ "$json" -eq 1 ]; then
                [ "$first" -eq 0 ] && printf ','
                first=0
                printf '{"product":"%s","transport":"%s","device_index":%d,' \
                    "$(json_escape "${DEV_NAMES[$i]}")" "$transport" "${DEV_DIDX[$i]}"
                printf '"report_id":%d,"feature_index":%d' \
                    "$(( DEV_RIDS[i] ))" "${DEV_FIDX[$i]}"
                if hosts=$(host_info "${DEV_FDS[$i]}" "${DEV_RIDS[$i]}" \
                           "${DEV_DIDX[$i]}" "${DEV_FIDX[$i]}") || true; then
                    [ -n "${hosts:-}" ] && printf ',"hosts":%d,"channel":%d' \
                        "${hosts% *}" "$(( ${hosts#* } + 1 ))"
                fi
                [ -n "$battery" ] && printf ',"battery_percent":%d,"charging":%s' \
                    "$battery" "$([ "$charging" -eq 1 ] && echo true || echo false)"
                [ -n "$fw" ] && printf ',"firmware":"%s"' "$fw"
                printf '}'
                continue
            fi
            [ "$first" -eq 0 ] && echo
            first=0
            echo "device     : ${DEV_NAMES[$i]}"
            echo "transport  : $transport  index=0x$(printf '%02x' "${DEV_DIDX[$i]}")  report=0x$(printf '%02x' "$(( DEV_RIDS[i] ))")"
            echo "ChangeHost : feature index 0x$(printf '%02x' "${DEV_FIDX[$i]}")"
            if hosts=$(host_info "${DEV_FDS[$i]}" "${DEV_RIDS[$i]}" \
                       "${DEV_DIDX[$i]}" "${DEV_FIDX[$i]}") && [ -n "$hosts" ]; then
                echo "channels   : ${hosts% *}, currently on $(( ${hosts#* } + 1 ))"
            fi
            if [ -n "$battery" ]; then
                local state="discharging"; [ "$charging" -eq 1 ] && state="charging"
                echo "battery    : ${battery}% ($state)"
            fi
            [ -n "$fw" ] && echo "firmware   : $fw"
        done
        [ "$json" -eq 1 ] && printf ']\n'
        close_devices
        exit 0
    fi

    local current target
    if [ "$mode" = "toggle" ]; then
        local hosts
        hosts=$(host_info "${DEV_FDS[0]}" "${DEV_RIDS[0]}" \
                "${DEV_DIDX[0]}" "${DEV_FIDX[0]}") || {
            echo "Could not read the current channel." >&2; exit 1; }
        current=$(( ${hosts#* } + 1 ))
        if [ "$current" -eq "$CONFIG_CHANNEL_A" ]; then
            channel=$CONFIG_CHANNEL_B
        elif [ "$current" -eq "$CONFIG_CHANNEL_B" ]; then
            channel=$CONFIG_CHANNEL_A
        else
            echo "Current channel $current is not in the configured pair" \
                 "$CONFIG_CHANNEL_A,$CONFIG_CHANNEL_B. Refusing to guess." >&2
            exit 1
        fi
    fi

    target=$(( channel - 1 ))
    local i failures=0
    for (( i=0; i<n; i++ )); do
        if [ "$dry" -eq 1 ]; then
            local frame; frame=$(hidpp_build_frame "${DEV_RIDS[$i]}" \
                "${DEV_DIDX[$i]}" "${DEV_FIDX[$i]}" 1 "$target")
            echo "${DEV_NAMES[$i]}: switch to channel $channel -> $frame"
        elif hidpp_send "${DEV_FDS[$i]}" "${DEV_RIDS[$i]}" \
                        "${DEV_DIDX[$i]}" "${DEV_FIDX[$i]}" 1 "$target"; then
            echo "  ${DEV_NAMES[$i]}: command sent"
        else
            echo "  ${DEV_NAMES[$i]}: failed" >&2
            failures=$(( failures + 1 ))
        fi
    done

    close_devices

    [ "$dry" -eq 1 ] && exit 0
    [ "$failures" -eq 0 ] && exit 0
    [ "$failures" -eq "$n" ] && exit 1
    echo "$failures of $n devices failed." >&2
    exit 3
}

# Run only when executed, not when sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
