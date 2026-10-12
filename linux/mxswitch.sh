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
FEAT_DEVICE_FW=0x0003
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
    local reply=$1 didx=$2 fidx=$3
    [ "${#reply}" -ge 10 ] || { printf 'too_short'; return 0; }
    # Compare numerically: callers may pass the device index in hex.
    [ "$(( 0x$(byte "$reply" 1) ))" -eq "$(( didx ))" ] || { printf 'ignore'; return 0; }
    local rf=$(( 0x$(byte "$reply" 2) ))
    # 0xff / 0x8f are HID++ 2.0 / 1.0 error replies
    if [ "$rf" -eq 255 ] || [ "$rf" -eq 143 ]; then printf 'error'; return 0; fi
    [ "$rf" -eq "$fidx" ] || { printf 'ignore'; return 0; }
    [ "$(( 0x$(byte "$reply" 3) & 0x0f ))" -eq "$SW_ID" ] \
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
        verdict=$(hidpp_classify_reply "$reply" "$didx" "$fidx")
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

# Sets DEV_* arrays. Returns 1 if nothing matched. Dedupes by name+index so a
# device exposing several collections is only listed once.
DEV_NODES=(); DEV_FDS=(); DEV_RIDS=(); DEV_DIDX=(); DEV_FIDX=(); DEV_NAMES=()

find_device() {
    local want_all=${1:-0}
    [ "$#" -gt 0 ] && shift
    DEV_NODES=(); DEV_FDS=(); DEV_RIDS=(); DEV_DIDX=(); DEV_FIDX=(); DEV_NAMES=()
    local seen=" " node rid didx reply fidx name fd matched key
    for node in $(logitech_hidraws); do
        name=$(hidraw_name "$node")
        name_matches "$name" "$@" || continue
        { exec {fd}<>"$node"; } 2>/dev/null || continue
        matched=0
        for didx in "${DEVICE_INDICES[@]}"; do
            for rid in "${REPORT_IDS[@]}"; do
                reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
                        "$FEAT_CHANGE_HOST_HI" "$FEAT_CHANGE_HOST_LO" 0) \
                    || continue
                fidx=$(( 0x$(byte "$reply" 4) ))
                [ "$fidx" -ne 0 ] || continue      # feature not supported
                matched=1; break
            done
            [ "$matched" -eq 1 ] && break
        done
        if [ "$matched" -eq 0 ]; then exec {fd}>&-; continue; fi

        key="$name|$didx"
        case "$seen" in *" $key "*) exec {fd}>&-; continue ;; esac
        seen+="$key "

        DEV_NODES+=("$node"); DEV_FDS+=("$fd"); DEV_RIDS+=("$rid")
        DEV_DIDX+=("$didx"); DEV_FIDX+=("$fidx"); DEV_NAMES+=("$name")
        [ "$want_all" -eq 1 ] || break
    done
    [ "${#DEV_FDS[@]}" -gt 0 ]
}

# Echoes "<percent> <charging 0|1>". Returns 1 if unsupported.
battery_status() {
    local fd=$1 rid=$2 didx=$3 feat reply fidx
    for feat in 0x1004 0x1000; do
        reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
                "$(( feat >> 8 ))" "$(( feat & 0xff ))" 0) || continue
        fidx=$(( 0x$(byte "$reply" 4) ))
        [ "$fidx" -ne 0 ] || continue
        reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" 0) || continue
        printf '%d %d' "$(( 0x$(byte "$reply" 4) ))" \
                       "$(( 0x$(byte "$reply" 5) & 1 ))"
        return 0
    done
    return 1
}

# Echoes main firmware version. Returns 1 if unsupported.
firmware_version() {
    local fd=$1 rid=$2 didx=$3 reply fidx major minor
    reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
            "$(( FEAT_DEVICE_FW >> 8 ))" "$(( FEAT_DEVICE_FW & 0xff ))" 0) \
        || return 1
    fidx=$(( 0x$(byte "$reply" 4) ))
    [ "$fidx" -ne 0 ] || return 1
    reply=$(hidpp_call "$fd" "$rid" "$didx" "$fidx" 0) || return 1
    [ "$(( 0x$(byte "$reply" 4) ))" -gt 0 ] || return 1
    major=$(( 0x$(byte "$reply" 6) )); minor=$(( 0x$(byte "$reply" 7) ))
    [ "$major" -ne 0 ] || [ "$minor" -ne 0 ] || return 1
    printf '%d.%d' "$major" "$minor"
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
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        case "$line" in *=*) ;; *) continue ;; esac
        key=${line%%=*}; key=${key//[[:space:]]/}
        value=${line#*=}
        # Trim only the ends: a name filter may contain internal spaces.
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            channel_a) CONFIG_CHANNEL_A=$value ;;
            channel_b) CONFIG_CHANNEL_B=$value ;;
            device)    CONFIG_DEVICE=$value ;;
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
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------

usage() {
    echo "usage: $0 {1|2|3|--info|--status|--toggle|--list} [--all] [--name SUBSTR] [--dry-run] [--json] [--verbose] [--config PATH]" >&2
}

main() {
    local mode="" channel="" want_all=0 dry=0 json=0 verbose=0 config=""
    local -a want_name=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --info)    mode="info" ;;
            --status)  mode="status" ;;
            --toggle)  mode="toggle" ;;
            --list)    mode="list" ;;
            --all)     want_all=1 ;;
            --name)    shift; want_name+=("${1:-}")
                       [ -n "${1:-}" ] || { usage; exit 2; } ;;
            --dry-run) dry=1 ;;
            --json)    json=1 ;;
            --verbose) verbose=1 ;;
            --config)  shift; config=${1:-}
                       [ -n "$config" ] || { usage; exit 2; } ;;
            -h|--help) usage; exit 0 ;;
            1|2|3)     channel=$1 ;;
            *) usage; exit 2 ;;
        esac
        shift
    done

    config=${config:-$(config_file)}
    config_load "$config"
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

    if [ "$mode" = "list" ]; then
        local node
        for node in $(logitech_hidraws); do
            printf '%s  %s\n' "$node" "$(hidraw_name "$node")"
        done
        exit 0
    fi

    [ "$verbose" -eq 1 ] && echo "config     : $config" >&2

    if [ "$mode" = "toggle" ]; then
        local problems; problems=$(config_problems)
        if [ -n "$problems" ]; then
            echo "Cannot toggle: $problems" >&2
            exit 2
        fi
    elif [ -z "$mode" ] && [ -z "$channel" ]; then
        usage; exit 2
    fi

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
        for (( i=0; i<n; i++ )); do
            local f=${DEV_FDS[$i]}
            exec {f}>&- 2>/dev/null || true
        done
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

    for (( i=0; i<n; i++ )); do
        local f=${DEV_FDS[$i]}
        exec {f}>&- 2>/dev/null || true
    done

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
