# shellcheck shell=bash
#
# Shared implementation of the widget scripts (build, run-sim, deploy-device,
# remove-device) for radar-widget/ and speedtest-widget/. Each widget keeps a
# thin wrapper with its own help text, sets a few CIQ_* variables and calls one
# ciq_*_main function here. The two widgets used to carry full copies of these
# scripts, and the copies drifted: one build.sh failed every build that baked no
# key, and the SDK error messages cited a README heading that no longer existed.
#
# Wrappers set, before calling a main:
#   CIQ_WIDGET_DIR   absolute path of the widget folder
#   CIQ_APP          .prg basename, for example RainRadar
#   CIQ_APP_LABEL    name shown on the device, for example "Rain Radar JP"
#   CIQ_ENV_DEFAULT  default .env to bake PROXY_BASE/PROXY_KEY from
#   CIQ_SIM_GPS      1 to accept --lat/--lon in run-sim (radar only)
#
# Sourced, never executed. Callers run under `set -euo pipefail`.

CIQ_BOX="${CIQ_BOX:-garmin}"
CIQ_HOME="$HOME/.Garmin/ConnectIQ"

ciq_die() { echo "$*" >&2; exit 1; }

# Print the calling script's header comment block as help. Derived from the file
# rather than a fixed line range, which silently truncated the examples whenever
# the header grew: drop the shebang, stop at the first non-comment line, strip
# the '# '.
ciq_usage() {
    sed -e '1d' -e '/^[^#]/,$d' -e 's/^# \{0,1\}//' "$0"
    exit "${1:-0}"
}

# --- Container --------------------------------------------------------------
# True if a distrobox named exactly $1 exists. `distrobox list | grep -w` also
# matched "garmin-old", or an IMAGE column containing the word.
ciq_box_exists() {
    command -v distrobox >/dev/null 2>&1 || return 1
    distrobox list --no-color 2>/dev/null \
        | awk -F'|' 'NR > 1 { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' \
        | grep -qxF -- "$1"
}

# The Connect IQ SDK, simulator, and their (older) shared-library dependencies
# live in the 'garmin' distrobox container, not on the host. When run on the
# host, re-exec the calling script inside that box so the toolchain resolves.
# Skip with CIQ_NO_BOX=1. Rename the target box with CIQ_BOX=<name>.
ciq_enter_box() {
    if [[ -z "${CIQ_NO_BOX:-}" && ! -e /run/.containerenv && ! -e /.dockerenv ]] \
       && ciq_box_exists "$CIQ_BOX"; then
        exec distrobox enter "$CIQ_BOX" -- "$(readlink -f "$0")" "$@"
    fi
}

# --- Toolchain --------------------------------------------------------------
# Put the SDK's bin/ on PATH unless $1 (a tool name) already resolves. Resolve
# the active SDK the way the SDK Manager records it (current-sdk.cfg), then fall
# back to the newest installed SDK folder.
ciq_find_sdk() {
    command -v "$1" >/dev/null 2>&1 && return 0
    local sdk=""
    if [[ -f "$CIQ_HOME/current-sdk.cfg" ]]; then
        sdk="$(tr -d '[:space:]' < "$CIQ_HOME/current-sdk.cfg")"
    fi
    if [[ -z "$sdk" || ! -d "$sdk" ]]; then
        sdk="$(find "$CIQ_HOME/Sdks" -maxdepth 1 -type d -name 'connectiq-sdk-*' 2>/dev/null \
               | sort | tail -n1)"
    fi
    if [[ -z "$sdk" || ! -d "$sdk/bin" ]]; then
        echo "Connect IQ SDK not found. Run ./setup.sh from the repo root, or see" >&2
        echo "docs/connect-iq-sdk.md." >&2
        exit 1
    fi
    export PATH="$sdk/bin:$PATH"
    echo "SDK:    $sdk"
}

# The repo-root developer key (git-ignored), with the extensionless name as a
# fallback.
ciq_default_key() {
    local key="$CIQ_WIDGET_DIR/../developer_key.der"
    [[ -f "$key" ]] || key="$CIQ_WIDGET_DIR/../developer_key"
    printf '%s\n' "$key"
}

# --- Secrets ----------------------------------------------------------------
# Read PROXY_BASE and PROXY_KEY from a .env into CIQ_PROXY_BASE/CIQ_PROXY_KEY.
# Parsed line by line, never sourced, so a .env cannot run code.
ciq_read_env() {  # <file>
    CIQ_PROXY_BASE=""; CIQ_PROXY_KEY=""
    local line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *"="* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"  # trim
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"             # unquote
        case "$k" in
            PROXY_BASE) CIQ_PROXY_BASE="$v" ;;
            PROXY_KEY)  CIQ_PROXY_KEY="$v" ;;
        esac
    done < "$1"
}

# Set one <property id="..."> default in a properties.xml. The value goes
# through ENVIRON, not sed or awk -v, so no character in it (#, /, &, \) can
# break the edit or be read as an sed command.
ciq_set_property() {  # <file> <id> <value>
    local v="$3"
    v="${v//&/&amp;}"; v="${v//</&lt;}"; v="${v//>/&gt;}"
    grep -q "<property id=\"$2\"" "$1" || ciq_die "No <property id=\"$2\"> in $1."
    CIQ_VAL="$v" awk -v id="$2" '
        index($0, "<property id=\"" id "\"") {
            open_end = index($0, ">"); close_at = index($0, "</property>")
            if (open_end && close_at > open_end)
                $0 = substr($0, 1, open_end) ENVIRON["CIQ_VAL"] substr($0, close_at)
        }
        { print }' "$1" > "$1.new"
    mv -f "$1.new" "$1"
}

# Connect IQ has no build-time substitution, so the proxy URL and key are baked
# in as property defaults. They used to be written into the tracked
# resources/shared/properties.xml and restored by an EXIT trap. Two builds at
# once could then "restore" each other's baked copy and leave the key in a
# tracked file, and a SIGKILL skipped the restore. Now the tracked tree is never
# written: the baked properties go into a copy of resources/shared in a temp
# folder, and an overlay jungle points base.resourcePath at it. monkeyc reads
# the jungle files in order, so the overlay wins, and the per-device lines that
# use $(base.resourcePath) follow it.
#
# Sets CIQ_JUNGLE (the -f argument) and CIQ_BAKED (1 if anything was baked).
ciq_prepare_build() {  # <envfile>
    CIQ_JUNGLE="$CIQ_WIDGET_DIR/monkey.jungle"
    CIQ_BAKED=0
    if [[ ! -f "$1" ]]; then
        echo "Env:    no $1; using properties.xml defaults"
        return 0
    fi
    ciq_read_env "$1"
    if [[ -z "$CIQ_PROXY_BASE" && -z "$CIQ_PROXY_KEY" ]]; then
        echo "Env:    $1 has no PROXY_BASE/PROXY_KEY; using properties.xml defaults"
        return 0
    fi

    CIQ_STAGE="$(mktemp -d)"
    trap 'rm -rf "$CIQ_STAGE"' EXIT
    cp -r "$CIQ_WIDGET_DIR/resources/shared" "$CIQ_STAGE/shared"
    local props="$CIQ_STAGE/shared/properties.xml" injected=()
    if [[ -n "$CIQ_PROXY_BASE" ]]; then
        ciq_set_property "$props" proxyBase "$CIQ_PROXY_BASE"; injected+=(PROXY_BASE)
    fi
    if [[ -n "$CIQ_PROXY_KEY" ]]; then
        ciq_set_property "$props" proxyKey "$CIQ_PROXY_KEY"; injected+=(PROXY_KEY)
    fi
    printf 'base.resourcePath = shared\n' > "$CIQ_STAGE/overlay.jungle"
    CIQ_JUNGLE="$CIQ_JUNGLE;$CIQ_STAGE/overlay.jungle"
    CIQ_BAKED=1
    echo "Env:    baked ${injected[*]} from $1"
}

# --- Simulator --------------------------------------------------------------
# Delete the simulator's stored settings for a .prg, so the defaults compiled
# into it win. The simulator persists app settings in a .SET file that
# OVERRIDES those defaults, so a stale entry (for example, an empty proxyKey)
# would silently shadow what was just baked in.
#
# The .SET is named after the uppercased .prg BASENAME, not the AppName:
# loading RainRadar-edge1040.prg yields RAINRADAR-EDGE1040.SET. Stripping the
# "-<device>" suffix on the theory that the name came from AppName meant the
# file never matched.
ciq_clear_sim_settings() {  # <prg>
    local name
    name="$(basename "$1")"; name="${name%.*}"
    name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]').SET"
    local path="${TMPDIR:-/tmp}/com.garmin.connectiq/GARMIN/APPS/SETTINGS/$name"
    if [[ -f "$path" ]]; then
        rm -f "$path"
        echo "Sim:    cleared stored settings override $name (baked defaults win)"
    fi
}

ciq_port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

# Side-load a .prg with monkeydo, retrying up to <tries> times. A SUCCESSFUL
# monkeydo does not exit: it stays attached to stream the device console, and it
# prints nothing on connect. A failure prints "Unable to connect" and exits,
# which can take 5-6 s. So "still alive after the observation window with no
# error" means loaded. Sets CIQ_MD_PID and CIQ_MD_LOG. Returns 1 if every
# attempt failed.
ciq_monkeydo_attach() {  # <prg> <device> <tries>
    CIQ_MD_LOG="$(mktemp "${TMPDIR:-/tmp}/${CIQ_APP,,}-monkeydo.XXXXXX")"
    local attempt failed
    for attempt in $(seq 1 "$3"); do
        : > "$CIQ_MD_LOG"
        monkeydo "$1" "$2" >"$CIQ_MD_LOG" 2>&1 &
        CIQ_MD_PID=$!
        failed=0
        for _ in $(seq 1 8); do
            sleep 1
            if grep -q "Unable to connect" "$CIQ_MD_LOG" 2>/dev/null; then failed=1; break; fi
            if ! kill -0 "$CIQ_MD_PID" 2>/dev/null; then failed=1; break; fi
        done
        if [[ "$failed" -eq 0 ]]; then
            disown "$CIQ_MD_PID" 2>/dev/null || true   # let it outlive the script
            return 0
        fi
        kill "$CIQ_MD_PID" 2>/dev/null || true
        wait "$CIQ_MD_PID" 2>/dev/null || true
        if [[ "$attempt" -lt "$3" ]]; then
            echo "  attach attempt $attempt failed, retrying..."
            sleep 3
        fi
    done
    return 1
}

# --- Device -----------------------------------------------------------------
# Find the Apps folder of the connected Garmin (USB mass storage). Only a mount
# with Garmin/GarminDevice.xml counts, so a backup drive that happens to hold a
# garmin/apps folder is not picked. With more than one device, stop and list
# them rather than copy to (and then eject) whichever was found first.
ciq_find_apps_dir() {  # [<explicit dest>]
    if [[ -n "${1:-}" ]]; then
        [[ -d "$1" ]] || ciq_die "--dest $1 is not a folder."
        printf '%s\n' "$1"; return 0
    fi
    local user="${USER:-$(id -un)}" root xml apps found=()
    for root in "/media/$user"/* "/run/media/$user"/* /media/* /mnt/*; do
        [[ -d "$root" ]] || continue
        while IFS= read -r xml; do
            apps="$(find "$(dirname "$xml")" -mindepth 1 -maxdepth 1 -type d -iname apps 2>/dev/null | head -1)"
            [[ -n "$apps" ]] && found+=("$(readlink -f "$apps")")
        done < <(find "$root" -maxdepth 2 -ipath '*/garmin/garmindevice.xml' 2>/dev/null)
    done
    # /media/* also matches /media/$USER, so the same device can appear twice.
    mapfile -t found < <(printf '%s\n' "${found[@]}" | sed '/^$/d' | sort -u)

    if [[ ${#found[@]} -eq 1 ]]; then
        printf '%s\n' "${found[0]}"; return 0
    fi
    if [[ ${#found[@]} -gt 1 ]]; then
        echo "More than one Garmin device is mounted:" >&2
        printf '  %s\n' "${found[@]}" >&2
        ciq_die "Unplug the others, or pass --dest <Apps folder>."
    fi
    echo "Couldn't find a connected Garmin device (no Garmin/GarminDevice.xml on a mount)." >&2
    if compgen -G "/run/user/$(id -u)/gvfs/mtp:*" >/dev/null; then
        echo "A device is connected over MTP, which these scripts cannot write to." >&2
        echo "Copy the .prg to Garmin/Apps with your file manager instead." >&2
    else
        echo "Plug the Edge in by USB and wait for it to mount, or pass --dest <Apps folder>." >&2
    fi
    exit 1
}

# Unmount the filesystem that holds <apps dir>, so the Edge leaves USB mode. Only
# when it is removable or hot-plugged: --dest can point anywhere, and ejecting a
# fixed disk under /mnt is never what was meant.
ciq_eject() {  # <apps dir>
    local devnode flags
    devnode="$(findmnt -no SOURCE --target "$1" 2>/dev/null || true)"
    if [[ -z "$devnode" ]] || ! command -v udisksctl >/dev/null 2>&1; then
        echo "Eject the device by hand before you unplug it."; return 0
    fi
    flags="$(lsblk -dno RM,HOTPLUG "$devnode" 2>/dev/null | tr -d ' ')"
    if [[ "$flags" != *1* ]]; then
        echo "Not ejecting $devnode: it is not a removable device."; return 0
    fi
    if udisksctl unmount -b "$devnode" >/dev/null 2>&1; then
        echo "Ejected $devnode. Safe to unplug."
    else
        echo "Auto-eject failed. Eject the device by hand before you unplug it."
    fi
}

# --- build.sh ---------------------------------------------------------------
ciq_build_main() {
    local device="" output="" key envfile="$CIQ_ENV_DEFAULT" release=1
    key="$(ciq_default_key)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--device)  device="$2"; shift 2 ;;
            -o|--output)  output="$2"; shift 2 ;;
            -k|--key)     key="$2"; shift 2 ;;
            -e|--env)     envfile="$2"; shift 2 ;;
            --release)    release=1; shift ;;
            --debug)      release=0; shift ;;
            -h|--help)    ciq_usage 0 ;;
            *) echo "Unknown argument: $1" >&2; ciq_usage 1 ;;
        esac
    done

    ciq_find_sdk monkeyc
    [[ -f "$key" ]] || ciq_die "Developer key not found at $key. Run ./setup.sh from the repo root, or pass -k <path>."

    if [[ -z "$output" ]]; then
        if [[ -n "$device" ]]; then output="$CIQ_WIDGET_DIR/bin/$CIQ_APP-$device.prg"
        else output="$CIQ_WIDGET_DIR/bin/$CIQ_APP.iq"; fi
    fi
    mkdir -p "$(dirname "$output")"

    ciq_prepare_build "$envfile"
    build_prg() { monkeyc -d "$1" -w -f "$CIQ_JUNGLE" -o "$2" -y "$key"; }

    echo
    if [[ -n "$device" ]]; then
        echo "Building $device .prg..."
        build_prg "$device" "$output"
    else
        # -e exports the multi-device store package (.iq) for all manifest products.
        local rel_flag=()
        [[ "$release" -eq 1 ]] && rel_flag+=("-r")
        echo "Building store package (.iq)..."
        monkeyc -e "${rel_flag[@]}" -w -f "$CIQ_JUNGLE" -o "$output" -y "$key"
    fi
    echo "Built $output"

    # Load into a running simulator, if one is open: the fast inner loop.
    # run-sim.sh launches a *new* simulator, and sets CIQ_NO_SIM_UPDATE=1 so it
    # can manage loading itself. monkeydo only side-loads a single-device .prg,
    # so for a store .iq, compile one for the simulator's current device
    # (LastUsedDevice in simulator.ini). Best effort: the build has succeeded,
    # so a simulator hiccup never fails the script.
    [[ -z "${CIQ_NO_SIM_UPDATE:-}" ]] && pgrep -x simulator >/dev/null 2>&1 || return 0
    if ! command -v monkeydo >/dev/null 2>&1; then
        echo "Sim:    simulator running but monkeydo isn't on PATH; skipping load."
        return 0
    fi
    local sim_device="$device" prg="$output"
    if [[ -z "$device" ]]; then
        local sim_ini="$CIQ_HOME/simulator.ini"
        sim_device=""
        [[ -f "$sim_ini" ]] && sim_device="$(sed -nE 's/^LastUsedDevice=//p' "$sim_ini" | tr -d '[:space:]')"
        if [[ -z "$sim_device" ]]; then
            echo "Sim:    couldn't determine the simulator's device; rebuild with -d <device> to load it."
            return 0
        fi
        prg="$CIQ_WIDGET_DIR/bin/$CIQ_APP-$sim_device.prg"
        echo "Sim:    compiling $sim_device .prg for the running simulator..."
        build_prg "$sim_device" "$prg"
    fi
    # Only clear stored settings when .env was baked in (so it wins). Otherwise
    # keep what was set in the running simulator across rebuilds.
    [[ "$CIQ_BAKED" -eq 1 ]] && ciq_clear_sim_settings "$prg"
    echo "Sim:    loading into running simulator ($sim_device)..."
    if ciq_monkeydo_attach "$prg" "$sim_device" 1; then
        echo "Sim:    simulator updated (monkeydo PID $CIQ_MD_PID)."
    else
        echo "Sim:    couldn't attach to the simulator; build is fine, left it as-is." >&2
    fi
}

# --- run-sim.sh -------------------------------------------------------------
ciq_runsim_main() {
    local device="edge1030plus" key envfile="$CIQ_ENV_DEFAULT" port=1234
    local lat="35.681236" lon="139.767125"
    key="$(ciq_default_key)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--device) device="$2"; shift 2 ;;
            -k|--key)    key="$2"; shift 2 ;;
            -e|--env)    envfile="$2"; shift 2 ;;
            --lat|--lon)
                [[ "${CIQ_SIM_GPS:-0}" -eq 1 ]] || { echo "Unknown argument: $1" >&2; ciq_usage 1; }
                if [[ "$1" == --lat ]]; then lat="$2"; else lon="$2"; fi
                shift 2 ;;
            -h|--help)   ciq_usage 0 ;;
            *) echo "Unknown argument: $1" >&2; ciq_usage 1 ;;
        esac
    done

    # build.sh finds the SDK itself. connectiq and monkeydo need it here too.
    ciq_find_sdk monkeydo
    echo "Device: $device"
    echo "Key:    $key"

    local out="$CIQ_WIDGET_DIR/bin/$CIQ_APP.prg"
    echo
    echo "Building..."
    CIQ_NO_SIM_UPDATE=1 "$CIQ_WIDGET_DIR/build.sh" -d "$device" -o "$out" -k "$key" -e "$envfile"
    ciq_clear_sim_settings "$out"

    # If a simulator is already running, reuse it rather than kill it: a hard
    # kill leaves the Connect IQ host in an "unclean shutdown" state that wedges
    # the debug port on the next launch. To get a fresh simulator (for example,
    # to apply GPS), close it from its own window first.
    local sim_was_running=0
    pgrep -x simulator >/dev/null 2>&1 && sim_was_running=1

    if [[ "${CIQ_SIM_GPS:-0}" -eq 1 ]]; then
        if [[ "$sim_was_running" -eq 0 ]]; then
            ciq_set_sim_gps "$lat" "$lon"
        else
            echo "GPS:    not set (simulator already running; use Simulation > GPS/Position)"
        fi
    fi

    echo
    if [[ "$sim_was_running" -eq 0 ]]; then
        echo "Starting simulator..."
        ( connectiq >/dev/null 2>&1 & )   # detached, so it survives this script
    else
        echo "Simulator already running; loading the new build into it."
    fi

    # monkeydo attaches over a local TCP port the simulator opens. On a cold
    # start that can take 30-90 s, long after the window appears, so poll it.
    echo "Waiting for simulator debug port $port (can take up to ~90s on a cold start)..."
    local s port_up=0
    for s in $(seq 1 90); do
        if ciq_port_listening "$port"; then
            port_up=1; echo "  port $port listening after ${s}s."; break
        fi
        sleep 1
    done
    if [[ "$port_up" -eq 0 ]]; then
        echo "Simulator never opened its debug port ($port) within 90s. Close the" >&2
        ciq_die "simulator completely (reboot if needed) and run this again."
    fi
    sleep 2   # the port can flap right after it first appears, so let it settle

    echo "Loading app into simulator..."
    if ! ciq_monkeydo_attach "$out" "$device" 8; then
        echo "Simulator port was up but monkeydo could not attach after several tries." >&2
        ciq_die "Close the simulator completely and run this again."
    fi
    echo "App loaded (monkeydo PID $CIQ_MD_PID)."
    echo
    if [[ "${CIQ_SIM_GPS:-0}" -eq 1 ]]; then
        echo "In the simulator set App Settings (Proxy URL + key) and a Japan GPS fix"
        echo "(Simulation > GPS/Position, for example lat 35.68 lon 139.76)."
    else
        echo "In the simulator set App Settings (Proxy URL + key), then run a test."
    fi

    # monkeydo keeps appending the device console to its log. Tail it live.
    # Ctrl+C stops the tail. The simulator and app stay loaded.
    echo
    echo "Streaming device console (Ctrl+C to stop; simulator stays open)..."
    echo "----------------------------------------------------------------------"
    trap 'echo; echo "----------------------------------------------------------------------"; echo "Stopped tailing. monkeydo PID '"$CIQ_MD_PID"' is still running; full log at '"$CIQ_MD_LOG"'"; exit 0' INT
    tail -n +1 -f "$CIQ_MD_LOG"
}

# The simulator stores its last position in simulator.ini as Garmin semicircles
# (degrees * 2^31 / 180). It reads the file on launch and overwrites it on exit,
# so this only sticks on a cold start.
ciq_set_sim_gps() {  # <lat> <lon>
    local ini="$CIQ_HOME/simulator.ini" lat_semi lon_semi
    lat_semi="$(awk -v v="$1" 'BEGIN{printf "%.0f", v*2147483648/180}')"
    lon_semi="$(awk -v v="$2" 'BEGIN{printf "%.0f", v*2147483648/180}')"
    mkdir -p "$(dirname "$ini")"; touch "$ini"
    local k v
    for k in PositionLatitude PositionLongitude; do
        if [[ "$k" == PositionLatitude ]]; then v="$lat_semi"; else v="$lon_semi"; fi
        # ${k} rather than $k: "$k[" reads as an array subscript, both to bash's
        # parser and to anyone skimming the regex.
        if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$ini"; then
            K="$k" V="$v" awk '{ if ($0 ~ "^[[:space:]]*" ENVIRON["K"] "[[:space:]]*=") print ENVIRON["K"] "=" ENVIRON["V"]; else print }' \
                "$ini" > "$ini.new" && mv -f "$ini.new" "$ini"
        else
            printf '%s=%s\n' "$k" "$v" >> "$ini"
        fi
    done
    echo "GPS:    lat $1 lon $2 (simulator.ini)"
}

# --- deploy-device.sh -------------------------------------------------------
ciq_deploy_main() {
    local device="edge1030plus" dest="" eject=1 envfile="$CIQ_ENV_DEFAULT" key
    local prgname="$CIQ_APP.PRG"
    key="$(ciq_default_key)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--device) device="$2"; shift 2 ;;
            --dest)      dest="$2"; shift 2 ;;
            --no-eject)  eject=0; shift ;;
            -e|--env)    envfile="$2"; shift 2 ;;
            -k|--key)    key="$2"; shift 2 ;;
            -h|--help)   ciq_usage 0 ;;
            *) echo "Unknown argument: $1" >&2; ciq_usage 1 ;;
        esac
    done

    # Baking the secrets in is the whole point: a sideloaded app can't be set up
    # through Garmin Connect.
    if [[ ! -f "$envfile" ]]; then
        echo "No $envfile. This script bakes the Proxy URL and key from it into the build." >&2
        ciq_die "Create it (see radar-widget/.env.example), pass -e <file>, or use build.sh for a clean build."
    fi

    local apps_dir
    apps_dir="$(ciq_find_apps_dir "$dest")"
    echo "Device: $device"
    echo "Target: $apps_dir/$prgname"

    local out="$CIQ_WIDGET_DIR/bin/$prgname"
    echo
    echo "Building (with .env baked in)..."
    # Deploying to hardware: do not touch a running simulator.
    CIQ_NO_SIM_UPDATE=1 "$CIQ_WIDGET_DIR/build.sh" -d "$device" -o "$out" -k "$key" -e "$envfile"

    echo
    echo "Copying to device..."
    cp "$out" "$apps_dir/$prgname"
    sync
    echo "Copied $prgname ($(du -h "$apps_dir/$prgname" | cut -f1)) -> $apps_dir"

    # The device writes a <PRG-name>.SET of defaults the first time it accepts
    # the app. One left from an earlier (for example, clean) build would shadow
    # the newly baked Proxy URL and key. Read into an array, so a device path
    # with a space in it can't split into two rm arguments.
    local stale=()
    mapfile -t stale < <(find "$apps_dir/SETTINGS" -maxdepth 1 -iname "${prgname%.*}.SET" 2>/dev/null || true)
    if [[ ${#stale[@]} -gt 0 ]]; then
        rm -f "${stale[@]}" && sync && echo "Cleared stale device settings: ${stale[*]}"
    fi

    [[ "$eject" -eq 1 ]] && ciq_eject "$apps_dir"
    echo
    echo "On the Edge: unplug, then open '$CIQ_APP_LABEL' from the widget loop"
    echo "(swipe down from the home screen, then swipe left/right)."
}

# --- remove-device.sh -------------------------------------------------------
ciq_remove_main() {
    local dest="" eject=1 prgname="$CIQ_APP.PRG"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest)     dest="$2"; shift 2 ;;
            --no-eject) eject=0; shift ;;
            -h|--help)  ciq_usage 0 ;;
            *) echo "Unknown argument: $1" >&2; ciq_usage 1 ;;
        esac
    done

    local apps_dir
    apps_dir="$(ciq_find_apps_dir "$dest")"
    echo "Device: $apps_dir"

    # The device keeps the binary in two places: the staging copy in Apps/
    # (until the device imports it) and the installed copy in Apps/Media/.
    local removed=0 f size
    for f in "$apps_dir/$prgname" "$apps_dir/Media/$prgname"; do
        [[ -f "$f" ]] || continue
        size="$(du -h "$f" | cut -f1)"   # before rm, or there is nothing to measure
        rm -f "$f" && echo "Removed $size  $f" && removed=1
    done
    # The settings file is named after the app, but the case varies by device,
    # hence -iname. The device may instead store it under an internal id we can't
    # match, which is harmless: it is ignored once the app is gone.
    local settings=() s
    mapfile -t settings < <(find "$apps_dir/SETTINGS" -maxdepth 1 -iname "${prgname%.*}.SET" 2>/dev/null || true)
    for s in "${settings[@]}"; do
        rm -f "$s" && echo "Removed settings $s" && removed=1
    done
    sync

    if [[ "$removed" -eq 0 ]]; then
        echo "Nothing to remove: $prgname not found (already removed, or never installed)."
    fi
    [[ "$eject" -eq 1 ]] && ciq_eject "$apps_dir"
    echo
    echo "On the Edge: unplug; '$CIQ_APP_LABEL' will be gone from the widget loop."
}
