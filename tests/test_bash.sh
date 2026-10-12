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

# --- frame encoding ---------------------------------------------------------
check "root getFeature long" \
    "11ff000a18140000000000000000000000000000" \
    "$(hidpp_build_frame 17 255 0 0 24 20 0)"
check "root getFeature short" \
    "10ff000a181400" \
    "$(hidpp_build_frame 16 255 0 0 24 20 0)"
check "getHostInfo long" \
    "11ff0a0a00000000000000000000000000000000" \
    "$(hidpp_build_frame 17 255 10 0)"
check "getHostInfo short" \
    "10ff0a0a000000" \
    "$(hidpp_build_frame 16 255 10 0)"
check "setCurrentHost(1) long" \
    "11ff0a1a01000000000000000000000000000000" \
    "$(hidpp_build_frame 17 255 10 1 1)"
check "setCurrentHost(1) short" \
    "10ff0a1a010000" \
    "$(hidpp_build_frame 16 255 10 1 1)"
check "receiver slot 2" \
    "11020a1a00000000000000000000000000000000" \
    "$(hidpp_build_frame 17 2 10 1 0)"

if hidpp_build_frame 16 255 0 0 1 2 3 4 5 6 7 >/dev/null 2>&1; then
    fail=$(( fail + 1 )); echo "FAIL: oversize short frame accepted"
else
    pass=$(( pass + 1 ))
fi

# --- reply classification ---------------------------------------------------
check "match getHostInfo" "match" \
    "$(hidpp_classify_reply 11ff0a0a03010000000000000000000000000000 255 10)"
check "match root getFeature" "match" \
    "$(hidpp_classify_reply 11ff000a0a000400000000000000000000000000 255 0)"
check "match battery" "match" \
    "$(hidpp_classify_reply 11ff050a58010000000000000000000000000000 255 5)"
check "notification ignored" "ignore" \
    "$(hidpp_classify_reply 11ff050a00000000000000000000000000000000 255 10)"
check "other device ignored" "ignore" \
    "$(hidpp_classify_reply 11010a0a03010000000000000000000000000000 255 10)"
check "hex device index matches" "match" \
    "$(hidpp_classify_reply 11ff0a0a03010000000000000000000000000000 0xff 10)"
check "other sw id ignored" "ignore" \
    "$(hidpp_classify_reply 11ff0a1b03010000000000000000000000000000 255 10)"
check "HID++ 2.0 error" "error" \
    "$(hidpp_classify_reply 11ffff0a00000000000000000000000000000000 255 10)"
check "HID++ 1.0 error" "error" \
    "$(hidpp_classify_reply 11ff8f0a00000000000000000000000000000000 255 10)"
check "too short" "too_short" \
    "$(hidpp_classify_reply 11ff0a 255 10)"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
