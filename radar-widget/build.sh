#!/usr/bin/env bash
#
# Build the JMA Rain Radar widget.
#
# By default produces the deployable Connect IQ Store package (bin/RainRadar.iq):
# a single bundle containing release builds for every <product> in manifest.xml.
# This is the CLI equivalent of VS Code's "Monkey C: Export Project" and is the
# file you upload at apps.garmin.com.
#
# With -d <device> it instead builds a single-device .prg for sideloading or the
# simulator.
#
# If a simulator is already running, the freshly built app is loaded into it (the
# fast inner loop). run-sim.sh is the one that launches a *new* simulator; this
# script only refreshes an open one. Skip the auto-load with CIQ_NO_SIM_UPDATE=1.
#
# Bakes in optional .env secrets so the proxy URL/token can be added to the build
# without committing them. The committed resources/shared/properties.xml is always
# restored afterward.
#
# Usage:
#   ./build.sh                       # bin/RainRadar.iq (store package, release)
#   ./build.sh -d edge1040           # bin/RainRadar-edge1040.prg (sideload)
#   ./build.sh -o /tmp/RainRadar.iq  # custom output path
#   ./build.sh -k ~/keys/dev.der     # custom developer key
#   ./build.sh --debug               # debug build (.iq only; .prg is already debug)
#
set -euo pipefail

# --- Run inside the Connect IQ container, if there is one -------------------
# The Connect IQ SDK and its (older) shared-library dependencies live in the
# 'garmin' distrobox container, not on the host. When invoked from the host,
# re-exec this script inside that box so the toolchain resolves. Skip with
# CIQ_NO_BOX=1; rename the target box via CIQ_BOX=<name>.
CIQ_BOX="${CIQ_BOX:-garmin}"
if [ -z "${CIQ_NO_BOX:-}" ] && [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ] \
   && command -v distrobox >/dev/null 2>&1 \
   && distrobox list 2>/dev/null | grep -qw "$CIQ_BOX"; then
    exec distrobox enter "$CIQ_BOX" -- "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Portable in-place sed (GNU sed wants `-i`; BSD/macOS sed wants `-i ''`).
sed_inplace() {
    if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# --- Defaults ---------------------------------------------------------------
device=""                              # empty => store .iq; set => single .prg
output=""                              # derived from mode if empty
key="$here/../developer_key.der"       # repo-root key (gitignored; see README §2)
[ -f "$key" ] || key="$here/../developer_key"   # fall back to the extensionless name
envfile="$here/.env"
release=1                              # store packages should be release builds
baked=0                                # set to 1 once .env secrets are injected

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- Parse args -------------------------------------------------------------
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
# Prefer monkeyc already on PATH; otherwise resolve the active SDK the way the
# SDK Manager records it (~/.Garmin/ConnectIQ/current-sdk.cfg), then fall back
# to the newest installed SDK folder.
if ! command -v monkeyc >/dev/null 2>&1; then
    sdk_root="$HOME/.Garmin/ConnectIQ/Sdks"
    cfg="$HOME/.Garmin/ConnectIQ/current-sdk.cfg"
    sdk=""
    if [[ -f "$cfg" ]]; then
        sdk="$(tr -d '[:space:]' < "$cfg")"
    fi
    if [[ -z "$sdk" || ! -d "$sdk" ]]; then
        sdk="$(find "$sdk_root" -maxdepth 1 -type d -name 'connectiq-sdk-*' 2>/dev/null \
               | sort | tail -n1)"
    fi
    if [[ -z "$sdk" || ! -d "$sdk/bin" ]]; then
        echo "Connect IQ SDK not found. Install it via the SDK Manager and put its" >&2
        echo "bin/ on PATH (see README, 'Installing the Connect IQ SDK on Ubuntu')." >&2
        exit 1
    fi
    export PATH="$sdk/bin:$PATH"
    echo "SDK:    $sdk"
fi

# --- Resolve developer key --------------------------------------------------
if [[ ! -f "$key" ]]; then
    echo "Developer key not found at $key." >&2
    echo "Generate one (see README, section 2) or pass -k <path>." >&2
    exit 1
fi

jungle="$here/monkey.jungle"

# --- Default output path ----------------------------------------------------
if [[ -z "$output" ]]; then
    if [[ -n "$device" ]]; then
        output="$here/bin/RainRadar-$device.prg"
    else
        output="$here/bin/RainRadar.iq"
    fi
fi
mkdir -p "$(dirname "$output")"

# --- Inject secrets from .env (optional) ------------------------------------
# Connect IQ has no build-time env substitution, so bake the proxy URL/token into
# the app by overwriting the matching defaults in resources/shared/properties.xml just
# for this build, then restore on exit (even on error/interrupt). Keeps secrets
# out of git (.env is gitignored).
props="$here/resources/shared/properties.xml"
props_backup=""

restore_props() {
    if [[ -n "$props_backup" && -f "$props_backup" ]]; then
        mv -f "$props_backup" "$props"
    fi
}
trap restore_props EXIT

if [[ -f "$envfile" ]]; then
    # shellcheck disable=SC1090
    proxy_base="" ; proxy_key=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *"="* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        k="$(echo "$k" | tr -d '[:space:]')"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"  # trim
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"             # unquote
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
# Compile a single-device .prg (used for the main build when -d is given, and
# again below to make a loadable artifact for a running simulator).
build_prg() {  # <device> <output>
    monkeyc -d "$1" -w -f "$jungle" -o "$2" -y "$key"
}

echo
if [[ -n "$device" ]]; then
    echo "Building $device .prg..."
    build_prg "$device" "$output"
else
    # -e exports the multi-device store package (.iq) for all manifest products.
    rel_flag=()
    [[ "$release" -eq 1 ]] && rel_flag+=("-r")
    echo "Building store package (.iq)..."
    monkeyc -e "${rel_flag[@]}" -w -f "$jungle" -o "$output" -y "$key"
fi

echo "Built $output"

# --- Load into a running simulator, if one is open --------------------------
# A plain build refreshes whatever the simulator is currently showing (the fast
# inner loop; run-sim.sh is the one that launches a *new* sim). monkeydo can
# only side-load a single-device .prg, so: if this build already produced one we
# load it directly; for a store .iq we compile a .prg for the sim's current
# device (LastUsedDevice in simulator.ini) and load that. Opt out with
# CIQ_NO_SIM_UPDATE=1 (run-sim.sh sets this so it can manage loading itself).
if [[ -z "${CIQ_NO_SIM_UPDATE:-}" ]] && pgrep -x simulator >/dev/null 2>&1; then
    if ! command -v monkeydo >/dev/null 2>&1; then
        echo "Sim:    simulator running but monkeydo isn't on PATH; skipping load."
    else
        if [[ -n "$device" ]]; then
            sim_device="$device"
            prg="$output"
        else
            # No device built; target the device the sim already has loaded.
            sim_ini="$HOME/.Garmin/ConnectIQ/simulator.ini"
            sim_device=""
            [[ -f "$sim_ini" ]] && sim_device="$(sed -nE 's/^LastUsedDevice=//p' "$sim_ini" | tr -d '[:space:]')"
            prg="$here/bin/RainRadar-$sim_device.prg"
        fi

        if [[ -z "$sim_device" ]]; then
            echo "Sim:    simulator running but couldn't determine its device; skipping."
            echo "        Rebuild with -d <device> to load it."
        else
            # Need a .prg for sim_device. If the main build wasn't it, compile one.
            if [[ "$prg" != "$output" || -z "$device" ]]; then
                echo "Sim:    compiling $sim_device .prg for the running simulator..."
                build_prg "$sim_device" "$prg"
            fi

            # Only wipe the sim's stored app settings when we actually baked in
            # .env secrets (so they win); otherwise keep what the user set in the
            # running sim across rebuilds. The sim names the .SET after the app
            # (uppercased AppName -> RAINRADAR.SET), NOT the .prg file -- so strip
            # the "-<device>" suffix the single-device build adds to the output.
            if [[ "$baked" -eq 1 ]]; then
                tmpbase="${TMPDIR:-/tmp}"
                setname="$(basename "$prg")"; setname="${setname%.*}"  # RainRadar-edge1030plus
                setname="${setname%-$sim_device}"                      # RainRadar
                setname="$(printf '%s' "$setname" | tr '[:lower:]' '[:upper:]').SET"
                setpath="$tmpbase/com.garmin.connectiq/GARMIN/APPS/SETTINGS/$setname"
                if [[ -f "$setpath" ]]; then
                    rm -f "$setpath"
                    echo "Sim:    cleared stored settings override $setname (baked .env wins)"
                fi
            fi

            # A successful monkeydo stays attached (no exit, no output); a failure
            # prints "Unable to connect" and exits. So: alive after a short window
            # with no error == loaded. Keep the load best-effort -- the build has
            # already succeeded, so never fail the script on a sim hiccup.
            echo "Sim:    loading into running simulator ($sim_device)..."
            mdlog="${TMPDIR:-/tmp}/rainradar-monkeydo.log"; : > "$mdlog"
            monkeydo "$prg" "$sim_device" >"$mdlog" 2>&1 &
            mdpid=$!
            failed=0
            for _ in $(seq 1 8); do
                sleep 1
                if grep -q "Unable to connect" "$mdlog" 2>/dev/null; then failed=1; break; fi
                if ! kill -0 "$mdpid" 2>/dev/null; then failed=1; break; fi
            done
            if [[ "$failed" -eq 0 ]]; then
                disown "$mdpid" 2>/dev/null || true
                echo "Sim:    simulator updated (monkeydo PID $mdpid)."
            else
                echo "Sim:    couldn't attach to the simulator; build is fine, left it as-is." >&2
            fi
        fi
    fi
fi
