#!/usr/bin/env bash
#
# Run a Connect IQ unit-test .prg in the headless simulator and report the
# result as this script's exit status.
#
# The dance below exists because monkeydo is not a test runner:
#   - it needs a *running* simulator to attach to, and the simulator is a GUI
#     app, hence Xvfb;
#   - it attaches over a TCP debug port the simulator opens well after the
#     process itself starts, so we poll the port rather than sleeping;
#   - it exits 1 whether the tests passed or failed, so the only trustworthy
#     signal is the PASSED/FAILED summary line it prints on stdout.
#
# Safe to call repeatedly in one job: each invocation tears down any simulator
# and X server left by the previous one, and `xvfb-run -a` picks a free display
# instead of reusing a fixed one whose lock file may still exist.
#
# Usage:
#   run-ciq-tests.sh <unit-test.prg> <device>
#
set -euo pipefail

prg="${1:?usage: run-ciq-tests.sh <prg> <device>}"
device="${2:?usage: run-ciq-tests.sh <prg> <device>}"
port="${CIQ_SIM_PORT:-1234}"

if [[ ! -f "$prg" ]]; then
    echo "No such program: $prg" >&2
    exit 1
fi

# The simulator writes here; without it, it emits noisy warnings.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
mkdir -p "$XDG_RUNTIME_DIR"

log_dir="$(mktemp -d)"
sim_log="$log_dir/simulator.log"
result="$log_dir/result.txt"

port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; }

teardown() {
    pkill -x simulator 2>/dev/null || true
    pkill -x Xvfb 2>/dev/null || true
    # Wait for the debug port to be released, so a following invocation doesn't
    # attach to the simulator we just killed.
    for _ in $(seq 1 20); do
        port_listening || break
        sleep 1
    done
}
trap teardown EXIT

# Clean slate: a simulator left running by a previous invocation would still be
# holding the debug port, and monkeydo would happily attach to it and run the
# *previous* widget's tests.
teardown

echo "==> Starting simulator under Xvfb"
# -a: pick any free display. A fixed :99 breaks the second call in a job, since
# Xvfb refuses to start when /tmp/.X99-lock is still present.
xvfb-run -a --server-args="-screen 0 1280x1024x24" simulator >"$sim_log" 2>&1 &

echo "==> Waiting for the simulator debug port ($port)"
port_up=0
for _ in $(seq 1 90); do
    sleep 1
    if port_listening; then port_up=1; break; fi
done
if [[ "$port_up" -eq 0 ]]; then
    echo "Simulator never opened its debug port ($port). Simulator log:" >&2
    cat "$sim_log" >&2
    exit 1
fi
sleep 2   # the port can flap briefly right after first appearing; let it settle

echo "==> Running tests: $(basename "$prg") on $device"
# Ignore the exit code on purpose (see header); the summary line is the signal.
monkeydo "$prg" "$device" -t >"$result" 2>&1 || true
cat "$result"

summary="$(grep -E '^(PASSED|FAILED)' "$result" | tail -1 || true)"
if [[ -z "$summary" ]]; then
    echo >&2
    echo "No PASSED/FAILED summary from monkeydo -- it never got the program" >&2
    echo "running. Simulator log:" >&2
    cat "$sim_log" >&2
    exit 1
fi

echo
echo "==> $summary"
[[ "$summary" == PASSED* ]]
