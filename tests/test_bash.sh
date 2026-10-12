#!/usr/bin/env bash
# Hardware-free tests for linux/mxswitch.sh.
#
#   bash tests/test_bash.sh
#
# Sources the script (the exec guard keeps main from running) and exercises the
# pure frame/reply/config helpers against the same cases as the other ports.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../linux/mxswitch.sh
source "$here/../linux/mxswitch.sh"

pass=0 fail=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$(( pass + 1 ))
    else
        fail=$(( fail + 1 ))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Read the shared cases without duplicating expected protocol bytes.
cases=$(python3 "$here/fixture_cases.py" bash) || exit 1
while IFS=$'\t' read -r kind label expected a b c d params; do
    if [ "$kind" = frame ]; then
        args=(); [ "$params" = - ] || read -ra args <<< "$params"
        check "$label" "$expected" "$(hidpp_build_frame "$a" "$b" "$c" "$d" ${args[@]+"${args[@]}"})"
    else
        check "$label" "$expected" "$(hidpp_classify_reply "$a" "$b" "$c" "$d")"
    fi
done <<< "$cases"
if hidpp_build_frame 16 255 0 0 1 2 3 4 5 6 7 >/dev/null 2>&1; then
    fail=$((fail+1)); echo 'FAIL: oversize frame accepted'
else pass=$((pass+1)); fi

# --- config -----------------------------------------------------------------
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'EOF'
# a comment
channel_a = 3

junk line
channel_b=1
device = all
name = MX Keys, MX Master
EOF
CONFIG_CHANNEL_A=1 CONFIG_CHANNEL_B=2 CONFIG_DEVICE=primary CONFIG_NAME=""
config_load "$tmp"
check "config channel_a" "3" "$CONFIG_CHANNEL_A"
check "config channel_b" "1" "$CONFIG_CHANNEL_B"
check "config device" "all" "$CONFIG_DEVICE"
check "config name keeps spaces" "MX Keys, MX Master" "$CONFIG_NAME"

CONFIG_CHANNEL_A=1 CONFIG_CHANNEL_B=1 CONFIG_DEVICE=all
case "$(config_problems)" in
    *"must differ"*) pass=$(( pass + 1 )) ;;
    *) fail=$(( fail + 1 )); echo "FAIL: duplicate channels not rejected" ;;
esac
CONFIG_CHANNEL_A=1 CONFIG_CHANNEL_B=2 CONFIG_DEVICE=bogus
case "$(config_problems)" in
    *"device must be"*) pass=$(( pass + 1 )) ;;
    *) fail=$(( fail + 1 )); echo "FAIL: bad device not rejected" ;;
esac
CONFIG_CHANNEL_A=1 CONFIG_CHANNEL_B=2 CONFIG_DEVICE=primary
check "valid config has no problems" "" "$(config_problems)"

# --- name filter ------------------------------------------------------------
if name_matches "MX Master 3S"; then pass=$(( pass + 1 )); else
    fail=$(( fail + 1 )); echo "FAIL: no filter should match everything"
fi
if name_matches "MX Keys S" keys; then pass=$(( pass + 1 )); else
    fail=$(( fail + 1 )); echo "FAIL: substring should match"
fi
if name_matches "mx keys s" KEYS; then pass=$(( pass + 1 )); else
    fail=$(( fail + 1 )); echo "FAIL: match should be case-insensitive"
fi
if name_matches "MX Master 3S" nope master; then pass=$(( pass + 1 )); else
    fail=$(( fail + 1 )); echo "FAIL: any filter should match"
fi
if name_matches "MX Master 3S" keys; then
    fail=$(( fail + 1 )); echo "FAIL: non-matching filter accepted"
else
    pass=$(( pass + 1 ))
fi
if name_matches "" keys; then
    fail=$(( fail + 1 )); echo "FAIL: empty name should not match"
else
    pass=$(( pass + 1 ))
fi

# JSON escaping includes controls while preserving UTF-8.
check 'JSON controls' 'MX\u0009Keys\u000a' "$(json_escape $'MX\tKeys\n')"
check 'JSON quote and backslash' "\\\"\\\\" "$(json_escape "\"\\")"

# Run discovery itself against a receiver transport, using regular files for FDs.
# Request responses depend on feature/function/slot, not a preselected device list.
receiver="$tmp-receiver"
receiver_copy="$tmp-receiver-copy"
mouse="$tmp-mouse"
touch "$receiver" "$receiver_copy" "$mouse"
trap 'rm -f "$tmp" "$receiver" "$receiver_copy" "$mouse"' EXIT
logitech_hidraws() { printf '%s\n' "$receiver" "$receiver_copy" "$mouse"; }
hidraw_name() { echo 'USB Receiver'; }
hidraw_identity() {
    if [ "$1" = "$mouse" ]; then echo mouse; else echo receiver; fi
}
hidpp_call() {
    local fd=$1 rid=$2 didx=$3 fidx=$4 func=$5; shift 5
    local idx=0 name
    if [ "$didx" -eq 255 ]; then return 1; fi
    [ "$didx" -eq 1 ] || [ "$didx" -eq 2 ] || return 1
    if [ "$fidx" -eq 0 ]; then
        case "$(( $1 )):$(( $2 ))" in 24:20) idx=10 ;; 0:5) idx=5 ;; 0:3) idx=3 ;; esac
        printf '11%02x000a%02x000000000000000000000000000000' "$didx" "$idx"
    elif [ "$fidx" -eq 5 ]; then
        name='MX Keys S'; [ "$didx" -eq 2 ] && name='MX Master 3S'
        if [ "$func" -eq 0 ]; then printf '11%02x050a%02x000000000000000000000000000000' "$didx" "${#name}"
        else local data; data=$(printf '%s' "${name:$1}" | od -An -v -tx1 | tr -d ' \n');
             printf '11%02x051a%-32s' "$didx" "$data" | tr ' ' 0; fi
    elif [ "$fidx" -eq 3 ]; then
        # No unit ID: exercise grouping by physical transport and slot.
        printf '11%02x030a02000000000000000000000000000000' "$didx"
    elif [ "$fidx" -eq 10 ]; then printf '11%02x0a0a03000000000000000000000000000000' "$didx"
    else return 1; fi
}
find_device 1
check 'all receiver slots and second receiver retained' '4' "${#DEV_FDS[@]}"
check 'mouse ranked before keyboard' 'MX Master 3S' "${DEV_NAMES[0]}"
close_devices
find_device 1 Keys
check 'receiver name filter matches actual keyboards' '2' "${#DEV_FDS[@]}"
check 'keyboard name resolved' 'MX Keys S' "${DEV_NAMES[0]}"
close_devices
find_device 0
check 'primary is mouse from receiver slot 2' '2' "${DEV_DIDX[0]}"
close_devices

# Conflicting modes fail before any transport is opened.
config_file() { echo /nonexistent/mxswitch/config; }
check 'conflicting modes exit 2' '2' "$( (main --info --toggle --dry-run >/dev/null 2>&1); echo $?)"

# Battery charging comes from the status byte, not the next discharge level.
hidpp_call() {
    if [ "$4" -eq 0 ]; then printf '11ff000a06000000000000000000000000000000'
    elif [ "$5" -eq 1 ]; then printf '11ff061a58500100000000000000000000000000'
    else printf '11ff060a02080000000000000000000000000000'; fi
}
check 'unified battery queries function 1' '88 1' "$(battery_status 0 17 255)"
hidpp_call() {
    if [ "$4" -eq 0 ]; then
        if [ "$6" -eq 16 ] && [ "$7" -eq 4 ]; then return 1; fi
        printf '11ff000a07000000000000000000000000000000'
    else printf '11ff070a58500000000000000000000000000000'; fi
}
check 'legacy battery status ignores next level' '88 0' "$(battery_status 0 17 255)"
hidpp_call() {
    if [ "$4" -eq 0 ]; then printf '11ff000a03000000000000000000000000000000'
    elif [ "$5" -eq 0 ]; then printf '11ff030a02000000000000000000000000000000'
    elif [ "$6" -eq 0 ]; then printf '11ff031a01524d501234abcd0000000000000000'
    else printf '11ff031a00524d501234abcd0000000000000000'; fi
}
check 'firmware queries main entity after bootloader' '12.34.BABCD' "$(firmware_version 0 17 255)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
