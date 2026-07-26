#!/usr/bin/env bash
#
# Run a Connect IQ unit-test .prg in the headless simulator and report the
# result as this script's exit status.
#
# The dance below exists because monkeydo is not a test runner:
#   - it needs a *running* simulator to attach to, and the simulator is a GUI
#     app, hence Xvfb;
#   - it exits 1 whether the tests passed or failed, so the only trustworthy
#     signal is the PASSED/FAILED summary line it prints on stdout.
#
# Usage:
#   run-ciq-tests.sh <unit-test.prg> <device>
#
set -euo pipefail

prg="${1:?usage: run-ciq-tests.sh <prg> <device>}"
device="${2:?usage: run-ciq-tests.sh <prg> <device>}"

if [[ ! -f "$prg" ]]; then
    echo "No such program: $prg" >&2
    exit 1
fi

export DISPLAY="${DISPLAY:-:99}"
# The simulator writes here; without it, it falls back to noisy warnings.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
mkdir -p "$XDG_RUNTIME_DIR"

log_dir="$(mktemp -d)"
sim_log="$log_dir/simulator.log"
result="$log_dir/result.txt"

cleanup() {
    pkill -x simulator 2>/dev/null || true
    pkill -f "Xvfb $DISPLAY" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Starting Xvfb on $DISPLAY"
Xvfb "$DISPLAY" -screen 0 1280x1024x24 >/dev/null 2>&1 &

echo "==> Starting simulator"
simulator >"$sim_log" 2>&1 &

# Wait for the simulator to come up rather than sleeping a fixed interval.
for _ in $(seq 1 30); do
    sleep 1
    pgrep -x simulator >/dev/null 2>&1 && break
done
if ! pgrep -x simulator >/dev/null 2>&1; then
    echo "Simulator failed to start:" >&2
    cat "$sim_log" >&2
    exit 1
fi
# It needs a moment past process start before it will accept a connection.
sleep 5

echo "==> Running tests: $(basename "$prg") on $device"
# Ignore the exit code on purpose (see header); the summary line is the signal.
monkeydo "$prg" "$device" -t >"$result" 2>&1 || true
cat "$result"

summary="$(grep -E '^(PASSED|FAILED)' "$result" | tail -1 || true)"
if [[ -z "$summary" ]]; then
    echo >&2
    echo "No PASSED/FAILED summary from monkeydo -- the simulator likely never" >&2
    echo "accepted the program. Simulator log:" >&2
    cat "$sim_log" >&2
    exit 1
fi

echo
echo "==> $summary"
[[ "$summary" == PASSED* ]]
