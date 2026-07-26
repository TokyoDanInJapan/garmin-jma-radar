#!/usr/bin/env bash
#
# Build the Proxy Speed Test widget (diagnostic companion to the radar).
#
# By default produces the store package bin/SpeedTest.iq; with -d <device> a
# single-device .prg for sideloading/the simulator. If a simulator is open the
# fresh build is loaded into it (skip with CIQ_NO_SIM_UPDATE=1).
#
# Reuses the radar's secrets: by default it bakes PROXY_BASE/PROXY_KEY from
# ../radar-widget/.env into resources/shared/properties.xml for this build, then
# restores the committed file. So the same proxy the radar uses is tested.
#
# Usage:
#   ./build.sh                       # bin/SpeedTest.iq (store package, release)
#   ./build.sh -d edge1030plus       # bin/SpeedTest-edge1030plus.prg (sideload)
#   ./build.sh -o /tmp/SpeedTest.iq  # custom output path
#   ./build.sh -k ~/keys/dev.der     # custom developer key
#   ./build.sh -e ../radar-widget/.env     # secrets file (this is the default)
#   ./build.sh --debug               # debug build (.iq only; .prg is already debug)
#
set -euo pipefail

# --- Run inside the Connect IQ container, if there is one -------------------
CIQ_BOX="${CIQ_BOX:-garmin}"
if [ -z "${CIQ_NO_BOX:-}" ] && [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ] \
   && command -v distrobox >/dev/null 2>&1 \
   && distrobox list 2>/dev/null | grep -qw "$CIQ_BOX"; then
    exec distrobox enter "$CIQ_BOX" -- "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sed_inplace() {
    if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# --- Defaults ---------------------------------------------------------------
device=""
output=""
key="$here/../developer_key.der"
[ -f "$key" ] || key="$here/../developer_key"
envfile="$here/../radar-widget/.env"          # reuse the radar's secrets by default
release=1
baked=0

usage() {
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)  device="$2"; shift 2 ;;
        -o|--output)  output="$2"; shift 2 ;;
        -k|--key)     key="$2"; shift 2 ;;
        -e|--env)     envfile="$2"; shift 2 ;;
        --release)    release=1; shift ;;
        --debug)      release=0; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- Locate the Connect IQ SDK ----------------------------------------------
if ! command -v monkeyc >/dev/null 2>&1; then
    sdk_root="$HOME/.Garmin/ConnectIQ/Sdks"
    cfg="$HOME/.Garmin/ConnectIQ/current-sdk.cfg"
    sdk=""
    [[ -f "$cfg" ]] && sdk="$(tr -d '[:space:]' < "$cfg")"
    if [[ -z "$sdk" || ! -d "$sdk" ]]; then
        sdk="$(find "$sdk_root" -maxdepth 1 -type d -name 'connectiq-sdk-*' 2>/dev/null | sort | tail -n1)"
    fi
    if [[ -z "$sdk" || ! -d "$sdk/bin" ]]; then
        echo "Connect IQ SDK not found. Install it and put its bin/ on PATH." >&2
        exit 1
    fi
    export PATH="$sdk/bin:$PATH"
    echo "SDK:    $sdk"
fi

if [[ ! -f "$key" ]]; then
    echo "Developer key not found at $key (generate one or pass -k <path>)." >&2
    exit 1
fi

jungle="$here/monkey.jungle"

if [[ -z "$output" ]]; then
    if [[ -n "$device" ]]; then output="$here/bin/SpeedTest-$device.prg"; else output="$here/bin/SpeedTest.iq"; fi
fi
mkdir -p "$(dirname "$output")"

# --- Inject secrets from .env (optional) ------------------------------------
props="$here/resources/shared/properties.xml"
props_backup=""
restore_props() { [[ -n "$props_backup" && -f "$props_backup" ]] && mv -f "$props_backup" "$props"; }
trap restore_props EXIT

if [[ -f "$envfile" ]]; then
    proxy_base="" ; proxy_key=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *"="* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        k="$(echo "$k" | tr -d '[:space:]')"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        case "$k" in
            PROXY_BASE) proxy_base="$v" ;;
            PROXY_KEY)  proxy_key="$v" ;;
        esac
    done < "$envfile"

    injected=()
    if [[ -n "$proxy_base" || -n "$proxy_key" ]]; then
        props_backup="$(mktemp)"
        cp "$props" "$props_backup"
        xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
        sed_escape() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
        if [[ -n "$proxy_base" ]]; then
            esc="$(sed_escape "$(xml_escape "$proxy_base")")"
            sed_inplace -E "s#(<property id=\"proxyBase\"[^>]*>).*(</property>)#\1$esc\2#" "$props"
            injected+=("PROXY_BASE")
        fi
        if [[ -n "$proxy_key" ]]; then
            esc="$(sed_escape "$(xml_escape "$proxy_key")")"
            sed_inplace -E "s#(<property id=\"proxyKey\"[^>]*>).*(</property>)#\1$esc\2#" "$props"
            injected+=("PROXY_KEY")
        fi
        baked=1
        echo "Env:    injected ${injected[*]} from $envfile"
    else
        echo "Env:    $envfile has no PROXY_BASE/PROXY_KEY; using properties.xml defaults"
    fi
else
    echo "Env:    no $envfile; using properties.xml defaults"
fi

# --- Build ------------------------------------------------------------------
build_prg() { monkeyc -d "$1" -w -f "$jungle" -o "$2" -y "$key"; }

echo
if [[ -n "$device" ]]; then
    echo "Building $device .prg..."
    build_prg "$device" "$output"
else
    rel_flag=()
    [[ "$release" -eq 1 ]] && rel_flag+=("-r")
    echo "Building store package (.iq)..."
    monkeyc -e "${rel_flag[@]}" -w -f "$jungle" -o "$output" -y "$key"
fi
echo "Built $output"

# --- Load into a running simulator, if one is open --------------------------
if [[ -z "${CIQ_NO_SIM_UPDATE:-}" ]] && pgrep -x simulator >/dev/null 2>&1; then
    if ! command -v monkeydo >/dev/null 2>&1; then
        echo "Sim:    simulator running but monkeydo isn't on PATH; skipping load."
    else
        if [[ -n "$device" ]]; then
            sim_device="$device"; prg="$output"
        else
            sim_ini="$HOME/.Garmin/ConnectIQ/simulator.ini"; sim_device=""
            [[ -f "$sim_ini" ]] && sim_device="$(sed -nE 's/^LastUsedDevice=//p' "$sim_ini" | tr -d '[:space:]')"
            prg="$here/bin/SpeedTest-$sim_device.prg"
        fi
        if [[ -z "$sim_device" ]]; then
            echo "Sim:    couldn't determine the simulator's device; rebuild with -d <device> to load it."
        else
            if [[ "$prg" != "$output" || -z "$device" ]]; then
                echo "Sim:    compiling $sim_device .prg for the running simulator..."
                build_prg "$sim_device" "$prg"
            fi
            # The sim names the .SET after the uppercased .prg basename, not the
            # AppName -- see the longer note in radar-widget/build.sh. Stripping
            # the "-<device>" suffix here meant the file was never found and
            # stale settings were never actually cleared.
            if [[ "$baked" -eq 1 ]]; then
                tmpbase="${TMPDIR:-/tmp}"
                setname="$(basename "$prg")"; setname="${setname%.*}"
                setname="$(printf '%s' "$setname" | tr '[:lower:]' '[:upper:]').SET"
                setpath="$tmpbase/com.garmin.connectiq/GARMIN/APPS/SETTINGS/$setname"
                [[ -f "$setpath" ]] && { rm -f "$setpath"; echo "Sim:    cleared stored settings override $setname"; }
            fi
            echo "Sim:    loading into running simulator ($sim_device)..."
            mdlog="${TMPDIR:-/tmp}/speedtest-monkeydo.log"; : > "$mdlog"
            monkeydo "$prg" "$sim_device" >"$mdlog" 2>&1 &
            mdpid=$!; failed=0
            for _ in $(seq 1 8); do
                sleep 1
                grep -q "Unable to connect" "$mdlog" 2>/dev/null && { failed=1; break; }
                kill -0 "$mdpid" 2>/dev/null || { failed=1; break; }
            done
            if [[ "$failed" -eq 0 ]]; then
                disown "$mdpid" 2>/dev/null || true
                echo "Sim:    simulator updated (monkeydo PID $mdpid)."
            else
                echo "Sim:    couldn't attach to the simulator; build is fine." >&2
            fi
        fi
    fi
fi
