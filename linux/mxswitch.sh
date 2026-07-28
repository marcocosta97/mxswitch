#!/usr/bin/env bash
# mxswitch.sh - switch a Logitech Easy-Switch device to another channel.
# Linux only. Needs nothing but bash, coreutils and read/write access to hidraw.
#
#   ./mxswitch.sh --info      show channels and which one is active
#   ./mxswitch.sh 2           switch to channel 2
#
# hidraw nodes are root-only by default. One-time fix, as root:
#   echo 'KERNEL=="hidraw*", ATTRS{idVendor}=="046d", MODE="0660", TAG+="uaccess"' \
#     > /etc/udev/rules.d/42-logitech-hidpp.rules
#   udevadm control --reload-rules && udevadm trigger

set -uo pipefail

SW_ID=10                 # software id, any value 1..15
FEAT_CHANGE_HOST_HI=0x18
FEAT_CHANGE_HOST_LO=0x14
DEVICE_INDICES=(0xff 1 2 3)
REPORT_IDS=(0x11 0x10)   # long, short
READ_TIMEOUT=0.2

byte() { printf '%s' "${1:$(( $2 * 2 )):2}"; }   # byte N of a hex string

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
        lower=$(grep -i '^HID_NAME=' "/sys/class/hidraw/$name/device/uevent" 2>/dev/null \
                | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
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
    printf '%s\n' "${mice[@]}" "${other[@]}" "${kbds[@]}"
}

# hidpp_call <fd> <report_id> <dev_idx> <feature_idx> <function> [params...]
# Echoes the matching reply as a hex string, or nothing.
hidpp_call() {
    local fd=$1 rid=$2 didx=$3 fidx=$4 func=$5; shift 5
    local len=20; [ "$(( rid ))" -eq 16 ] && len=7

    local -a frame=( "$(( rid ))" "$(( didx ))" "$(( fidx ))" \
                     "$(( (func << 4) | SW_ID ))" )
    local p; for p in "$@"; do frame+=( "$(( p ))" ); done
    while [ "${#frame[@]}" -lt "$len" ]; do frame+=( 0 ); done

    local esc="" b
    for b in "${frame[@]}"; do esc+=$(printf '\\x%02x' "$b"); done
    printf '%b' "$esc" >&"$fd" 2>/dev/null || return 1

    # Replies share the pipe with unsolicited notifications, so read a few.
    local try reply r_didx r_fidx r_sw
    for try in 1 2 3; do
        reply=$(timeout "$READ_TIMEOUT" dd bs=64 count=1 status=none <&"$fd" \
                2>/dev/null | od -An -v -tx1 | tr -d ' \n')
        [ -n "$reply" ] || return 1
        [ "${#reply}" -ge 10 ] || continue
        r_didx=$(( 0x$(byte "$reply" 1) ))
        r_fidx=$(( 0x$(byte "$reply" 2) ))
        r_sw=$(( 0x$(byte "$reply" 3) & 0x0f ))
        [ "$r_didx" -eq "$(( didx ))" ] || continue
        # 0xff / 0x8f are HID++ 2.0 / 1.0 error replies
        if [ "$r_fidx" -eq 255 ] || [ "$r_fidx" -eq 143 ]; then return 1; fi
        [ "$r_fidx" -eq "$(( fidx ))" ] || continue
        [ "$r_sw" -eq "$SW_ID" ] || continue
        printf '%s' "$reply"
        return 0
    done
    return 1
}

# Sets DEV, FD, RID, DIDX, FIDX on success.
find_device() {
    local node rid didx reply fidx
    for node in $(logitech_hidraws); do
        exec {fd}<>"$node" 2>/dev/null || continue
        for didx in "${DEVICE_INDICES[@]}"; do
            for rid in "${REPORT_IDS[@]}"; do
                reply=$(hidpp_call "$fd" "$rid" "$didx" 0 0 \
                        "$FEAT_CHANGE_HOST_HI" "$FEAT_CHANGE_HOST_LO" 0) || continue
                fidx=$(( 0x$(byte "$reply" 4) ))
                [ "$fidx" -ne 0 ] || continue      # feature not supported
                DEV=$node; FD=$fd; RID=$rid; DIDX=$didx; FIDX=$fidx
                return 0
            done
        done
        exec {fd}>&-
    done
    return 1
}

main() {
    local target=""
    case "${1:-}" in
        --info) target="info" ;;
        1|2|3)  target=$(( $1 - 1 )) ;;
        *) echo "usage: $0 {1|2|3|--info}" >&2; exit 2 ;;
    esac

    if ! find_device; then
        echo "No Logitech device supporting ChangeHost found." >&2
        echo "Click the mouse to wake it; check hidraw permissions (see header)." >&2
        exit 1
    fi

    if [ "$target" = "info" ]; then
        local reply
        echo "device     : $DEV"
        echo "transport  : index $DIDX, report $RID"
        echo "ChangeHost : feature index $FIDX"
        if reply=$(hidpp_call "$FD" "$RID" "$DIDX" "$FIDX" 0); then
            echo "channels   : $(( 0x$(byte "$reply" 4) )), currently on \
$(( 0x$(byte "$reply" 5) + 1 ))"
        fi
        exec {FD}>&-
        exit 0
    fi

    echo "Switching to channel $(( target + 1 )) ..."
    # setCurrentHost, function 1. No reply - the link is gone by then.
    hidpp_call "$FD" "$RID" "$DIDX" "$FIDX" 1 "$target" >/dev/null 2>&1 || true
    exec {FD}>&-
    exit 0
}

main "$@"
