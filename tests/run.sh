#!/usr/bin/env bash
# Run every hardware-free test that this machine can run.
#
#   ./tests/run.sh
#
# Python and bash run anywhere; the C suite needs macOS (IOKit); the PowerShell
# suite needs pwsh with Pester.

set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0

run() {
    printf '\n== %s ==\n' "$1"
    shift
    "$@" || fail=1
}

skip() { printf '\n== %s ==\nskipped (%s)\n' "$1" "$2"; }

run "Python" python3 -m unittest discover -s "$here" -p 'test_python.py'
run "Bash" bash "$here/test_bash.sh"

if [ "$(uname)" = "Darwin" ]; then
    tmp=$(mktemp -d)
    python3 "$here/fixture_cases.py" c > "$tmp/frames.h" || fail=1
    run "C (macOS)" sh -c \
        "cc -O2 -Wall -Wextra -Wno-unused-function -include '$tmp/frames.h' -o '$tmp/test_c' \
           '$here/test_c.c' -framework IOKit -framework CoreFoundation \
           -framework CoreGraphics && '$tmp/test_c'"
    rm -rf "$tmp"
else
    skip "C (macOS)" "needs IOKit"
fi

if command -v pwsh >/dev/null 2>&1; then
    if pwsh -NoProfile -Command 'Get-Command Invoke-Pester' >/dev/null 2>&1; then
        run "PowerShell" pwsh -NoProfile -Command \
            "\$result = Invoke-Pester -Path '$here/test_powershell.ps1' -PassThru; if (\$result.FailedCount -gt 0 -or \$result.FailedContainersCount -gt 0) { exit 1 }"
    else
        skip "PowerShell" "Pester not installed"
    fi
else
    skip "PowerShell" "pwsh not installed"
fi

printf '\n'
[ "$fail" -eq 0 ] && echo "all available tests passed" || echo "FAILURES"
exit "$fail"
