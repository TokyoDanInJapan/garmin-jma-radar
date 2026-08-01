#!/usr/bin/env bash
#
# Build the Proxy Speed Test widget and launch it in the Connect IQ simulator.
# Linux + macOS.
#
# Mirrors radar-widget/run-sim.sh, minus the GPS handling: this widget only
# declares the Communications permission, so there is no position to simulate.
#
# Locates the installed Connect IQ SDK, builds a single-device .prg (via
# build.sh, which also bakes in PROXY_BASE/PROXY_KEY from the radar widget's
# .env), starts the simulator host (connectiq) if it isn't already running, then
# side-loads the app with monkeydo and streams the device console. If a simulator is
# already up it's reused (a forced restart wedges the SDK's debug port). To
# reload into an open simulator you can also just run build.sh.
#
# Run from anywhere. Paths are resolved relative to this script.
#
# Options:
#   -d, --device <id>   Target device id (matches a <product> in manifest.xml).
#                       Default: edge1030plus.
#   -k, --key <path>    Developer key (.der/PKCS8). Default: ../developer_key.
#   -e, --env <path>    .env with secrets to bake in.
#                       Default: ../radar-widget/.env (shared with the radar app).
#   -h, --help          Show this help.
#
# Examples:
#   ./run-sim.sh
#   ./run-sim.sh -d edge1040
#
set -euo pipefail

# --- Run inside the Connect IQ container, if there is one -------------------
# The Connect IQ SDK, simulator, and their (older) shared-library dependencies
# live in the 'garmin' distrobox container, not on the host. When invoked from
# the host, re-exec this script inside that box. Skip with CIQ_NO_BOX=1. Rename
# the target box via CIQ_BOX=<name>.
CIQ_BOX="${CIQ_BOX:-garmin}"
if [ -z "${CIQ_NO_BOX:-}" ] && [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ] \
   && command -v distrobox >/dev/null 2>&1 \
   && distrobox list 2>/dev/null | grep -qw "$CIQ_BOX"; then
    exec distrobox enter "$CIQ_BOX" -- "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---------------------------------------------------------------
device="edge1030plus"
key="$here/../developer_key.der"; [ -f "$key" ] || key="$here/../developer_key"
envfile="$here/../radar-widget/.env"
port=1234

# Print the header comment block as help. Derived from the file rather than a
# fixed line range, which silently truncated the examples whenever the header
# grew: drop the shebang, stop at the first non-comment line, strip the '# '.
usage() { sed -e '1d' -e '/^[^#]/,$d' -e 's/^# \{0,1\}//' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) device="$2"; shift 2 ;;
        -k|--key)    key="$2"; shift 2 ;;
        -e|--env)    envfile="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- Locate the Connect IQ SDK and put its bin/ on PATH ---------------------
# Needed so connectiq/monkeydo resolve here (build.sh does its own discovery,
# but it finds the same monkeyc once it's on PATH). Mirrors build.sh.
if ! command -v monkeydo >/dev/null 2>&1; then
    sdk_root="$HOME/.Garmin/ConnectIQ/Sdks"
    cfg="$HOME/.Garmin/ConnectIQ/current-sdk.cfg"
    sdk=""
    [[ -f "$cfg" ]] && sdk="$(tr -d '[:space:]' < "$cfg")"
    if [[ -z "$sdk" || ! -d "$sdk" ]]; then
        sdk="$(find "$sdk_root" -maxdepth 1 -type d -name 'connectiq-sdk-*' 2>/dev/null | sort | tail -n1)"
    fi
    if [[ -z "$sdk" || ! -d "$sdk/bin" ]]; then
        echo "Connect IQ SDK not found. Install it via the SDK Manager and put its" >&2
        echo "bin/ on PATH (see docs/connect-iq-sdk.md)." >&2
        exit 1
    fi
    export PATH="$sdk/bin:$PATH"
    echo "SDK:    $sdk"
fi

echo "Device: $device"
echo "Key:    $key"

# --- Build (delegates to build.sh: SDK + .env injection + restore) ----------
# CIQ_NO_SIM_UPDATE=1: build.sh auto-loads into an already-open simulator, but run-sim
# launches its own fresh simulator and loads below, so suppress build.sh's load here.
out="$here/bin/SpeedTest.prg"
echo
echo "Building..."
CIQ_NO_SIM_UPDATE=1 "$here/build.sh" -d "$device" -o "$out" -k "$key" -e "$envfile"

# --- Clear the simulator's stored app settings (so baked .env values win) ---
# The simulator persists app settings in a .SET file that OVERRIDES the property
# defaults compiled into the .prg. A stale entry (for example, an empty proxyKey) would
# silently shadow what we just baked in, causing auth failures. The file is named
# after the uppercased .prg basename (SpeedTest.prg -> SPEEDTEST.SET).
tmpbase="${TMPDIR:-/tmp}"
setname="$(basename "$out")"; setname="${setname%.*}"
setname="$(printf '%s' "$setname" | tr '[:lower:]' '[:upper:]').SET"
setpath="$tmpbase/com.garmin.connectiq/GARMIN/APPS/SETTINGS/$setname"
if [[ -f "$setpath" ]]; then
    rm -f "$setpath"
    echo "Settings: cleared stored override $setname (baked defaults win)"
fi

# --- Launch the simulator (if it isn't already up) --------------------------
# run-sim.sh's job is to bring the simulator up with the app loaded. The job of
# build.sh is
# the one that loads into an already-open simulator. If a simulator is already running we
# reuse it rather than killing it: a hard kill leaves the Connect IQ host in an
# "unclean shutdown" state that wedges the debug port on the next launch.
if pgrep -x simulator >/dev/null 2>&1; then
    echo
    echo "Simulator already running; loading the new build into it."
else
    echo
    echo "Starting simulator..."
    ( connectiq >/dev/null 2>&1 & )   # detached, so it survives this script
fi

# --- Wait for the simulator's debug port to be LISTENING --------------------
# monkeydo attaches over a local TCP port (1234) the simulator opens. On a cold start
# that can take 30-90s – long after the window appears. Poll the port directly.
port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
echo "Waiting for simulator debug port $port (can take up to ~90s on a cold start)..."
port_up=0
for s in $(seq 1 90); do
    if port_listening "$port"; then
        port_up=1
        echo "  port $port listening after ${s}s."
        break
    fi
    sleep 1
done
if [[ "$port_up" -eq 0 ]]; then
    echo "Simulator never opened its debug port ($port) within 90s. Close the" >&2
    echo "simulator completely (reboot if needed) and re-run." >&2
    exit 1
fi
sleep 2   # the port can flap right after first appearing, so let it settle

# --- Load the app into the simulator ----------------------------------------
# A SUCCESSFUL monkeydo does NOT exit – it stays attached to stream the device
# console. It prints nothing on connect, so success = "still alive after the
# observation window with no 'Unable to connect'". Failure prints that and exits
# (can take ~5-6s), so observe a bit longer before trusting an "alive" reading.
echo "Loading app into simulator..."
mdlog="$tmpbase/speedtest-monkeydo.log"
mderr="$mdlog.err"
loaded=0
mdpid=""
for attempt in $(seq 1 8); do
    : > "$mdlog"; : > "$mderr"
    monkeydo "$out" "$device" >"$mdlog" 2>"$mderr" &
    mdpid=$!
    failed=0
    for _ in $(seq 1 8); do
        sleep 1
        if grep -q "Unable to connect" "$mdlog" "$mderr" 2>/dev/null; then failed=1; break; fi
        if ! kill -0 "$mdpid" 2>/dev/null; then failed=1; break; fi
    done
    if [[ "$failed" -eq 0 ]]; then loaded=1; break; fi
    kill "$mdpid" 2>/dev/null || true
    wait "$mdpid" 2>/dev/null || true
    echo "  attach attempt $attempt failed, retrying..."
    sleep 3
done
if [[ "$loaded" -eq 0 ]]; then
    echo "Simulator port was up but monkeydo could not attach after several tries." >&2
    echo "Close the simulator completely and re-run." >&2
    exit 1
fi
disown "$mdpid" 2>/dev/null || true   # let it survive the script exit
echo "App loaded (monkeydo PID $mdpid)."

echo
echo "In the simulator set App Settings (Proxy URL + key), then run a test."

# --- Stream the device console to this terminal -----------------------------
# monkeydo keeps running in the background, appending the device console to
# $mdlog. Tail it live. Ctrl+C stops the tail. The simulator and app stay loaded.
echo
echo "Streaming device console (Ctrl+C to stop; simulator stays open)..."
echo "----------------------------------------------------------------------"
trap 'echo; echo "----------------------------------------------------------------------"; echo "Stopped tailing. monkeydo PID '"$mdpid"' is still running; full log at '"$mdlog"'"; exit 0' INT
tail -n +1 -f "$mdlog"
