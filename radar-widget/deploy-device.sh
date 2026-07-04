#!/usr/bin/env bash
#
# Dev deploy: build the JMA Rain Radar widget for a physical Edge with your
# radar-widget/.env secrets (Proxy URL + key) baked in, then copy it onto the
# connected device. This is the reliable way to run on real hardware, because a
# SIDELOADED app can't be configured through Garmin Connect -- only apps
# installed from the Connect IQ Store can. The baked secrets live in the .prg on
# YOUR device, so don't share or publish this build.
#
# Runs on the host (it needs the USB-mounted device + udisksctl); the build step
# delegates to build.sh, which enters the Connect IQ container on its own.
#
# Usage:
#   ./deploy-device.sh                  # build edge1030plus, copy to the device
#   ./deploy-device.sh -d edge1040      # a different device id
#   ./deploy-device.sh --dest <dir>     # explicit GARMIN/.../Apps folder
#   ./deploy-device.sh --no-eject       # leave the device mounted afterward
#   ./deploy-device.sh -h
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---------------------------------------------------------------
device="edge1030plus"
dest=""
eject=1
envfile="$here/.env"
key="$here/../developer_key.der"; [ -f "$key" ] || key="$here/../developer_key"
prgname="RainRadar.PRG"

usage() { sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) device="$2"; shift 2 ;;
        --dest)      dest="$2"; shift 2 ;;
        --no-eject)  eject=0; shift ;;
        -e|--env)    envfile="$2"; shift 2 ;;
        -k|--key)    key="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- Require .env (baking its secrets in is the whole point of this script) --
if [[ ! -f "$envfile" ]]; then
    echo "No $envfile -- this script bakes the Proxy URL/key from .env into the" >&2
    echo "build (sideloaded apps can't be set up via Garmin Connect). Create it" >&2
    echo "(see .env.example), or use build.sh for a clean build." >&2
    exit 1
fi

# --- Locate the connected Garmin's Apps folder ------------------------------
# The Edge mounts as USB mass storage with a GARMIN/Garmin/Apps tree (casing
# varies by firmware). Find it under the usual auto-mount roots, or take --dest.
find_apps_dir() {
    if [[ -n "$dest" ]]; then
        [[ -d "$dest" ]] && { printf '%s\n' "$dest"; return 0; }
        return 1
    fi
    local root apps
    for root in "/media/$USER"/* "/run/media/$USER"/* /media/* /mnt/*; do
        [[ -d "$root" ]] || continue
        apps="$(find "$root" -maxdepth 2 -type d -ipath '*garmin/apps' 2>/dev/null | head -1)"
        [[ -n "$apps" ]] && { printf '%s\n' "$apps"; return 0; }
    done
    return 1
}

apps_dir="$(find_apps_dir)" || {
    echo "Couldn't find a connected Garmin device (no */GARMIN/Garmin/Apps mount)." >&2
    echo "Plug the Edge in by USB and wait for it to mount, or pass --dest <Apps dir>." >&2
    exit 1
}
echo "Device: $device"
echo "Target: $apps_dir/$prgname"

# --- Build with .env baked in (delegates to build.sh) -----------------------
out="$here/bin/$prgname"
echo
echo "Building (with .env baked in)..."
export CIQ_NO_SIM_UPDATE=1   # deploying to hardware; don't also poke a running sim
"$here/build.sh" -d "$device" -o "$out" -k "$key" -e "$envfile"

# --- Copy onto the device ---------------------------------------------------
echo
echo "Copying to device..."
cp "$out" "$apps_dir/$prgname"
sync
echo "Copied $prgname ($(du -h "$apps_dir/$prgname" | cut -f1)) -> $apps_dir"

# Clear a stale settings file so the freshly baked values win. The device writes
# a <PRG-name>.SET of defaults the first time it accepts the app; one left from
# an earlier (e.g. clean) build would shadow the new baked Proxy URL/key.
settings_dir="$apps_dir/SETTINGS"
if [[ -d "$settings_dir" ]]; then
    stale="$(find "$settings_dir" -maxdepth 1 -iname "${prgname%.*}.SET" 2>/dev/null || true)"
    if [[ -n "$stale" ]]; then
        rm -f $stale && sync && echo "Cleared stale device settings: $stale"
    fi
fi

# --- Eject so the Edge leaves USB mode and loads the app --------------------
if [[ "$eject" -eq 1 ]]; then
    devnode="$(findmnt -no SOURCE --target "$apps_dir" 2>/dev/null || true)"
    if [[ -n "$devnode" ]] && command -v udisksctl >/dev/null 2>&1; then
        if udisksctl unmount -b "$devnode" >/dev/null 2>&1; then
            echo "Ejected $devnode -- safe to unplug."
        else
            echo "Copied OK, but auto-eject failed; eject it manually before unplugging."
        fi
    else
        echo "Copied OK; eject the device manually before unplugging."
    fi
fi

echo
echo "On the Edge: unplug, then open 'Rain Radar JP' from the widget loop"
echo "(swipe down from the home screen, then swipe left/right)."
