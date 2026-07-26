#!/usr/bin/env bash
#
# Remove the sideloaded Proxy Speed Test widget from a connected Edge, then eject.
# It disappears from the widget loop on the next connect/boot. (To remove the
# radar instead, use radar-widget/remove-device.sh.)
#
# What it deletes: the app binary in BOTH places the device keeps it -- the
# staging copy in GARMIN/Garmin/Apps/ (present until the device imports it) and
# the installed copy in Apps/Media/ -- plus its settings file (best effort; the
# device sometimes renames the .SET to an internal id we can't match).
#
# Usage:
#   ./remove-device.sh              # find the device, remove, eject
#   ./remove-device.sh --dest <dir> # explicit GARMIN/.../Apps folder
#   ./remove-device.sh --no-eject   # leave the device mounted afterward
#   ./remove-device.sh -h
#
set -euo pipefail

dest=""
eject=1
prgname="SpeedTest.PRG"
appname="Proxy Speed Test"

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)     dest="$2"; shift 2 ;;
        --no-eject) eject=0; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- Locate the connected Garmin's Apps folder (same as deploy-device.sh) ----
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
echo "Device: $apps_dir"

# --- Delete the app binary (both locations) + its settings -------------------
removed=0
for f in "$apps_dir/$prgname" "$apps_dir/Media/$prgname"; do
    if [[ -f "$f" ]]; then rm -f "$f" && echo "Removed $(du -h "$f" 2>/dev/null | cut -f1 || echo)  $f" && removed=1; fi
done
# Settings file is named after the app, but the case varies by device, hence
# -iname. The device may instead store it under an internal id we can't match --
# harmless to leave (it's ignored once the app is gone, cleared on reinstall).
#
# find, not a glob: the path we're matching contains no glob metacharacters, so
# nullglob/nocaseglob had no effect on it and the loop ran once regardless. That
# made `rm -f` on a nonexistent file "succeed", printing "Removed settings" and
# suppressing the "Nothing to remove" message below.
mapfile -t settings < <(find "$apps_dir/SETTINGS" -maxdepth 1 -iname "${prgname%.*}.SET" 2>/dev/null || true)
for s in "${settings[@]}"; do
    rm -f "$s" && echo "Removed settings $s" && removed=1
done
sync

if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to remove: $prgname not found (already removed, or never installed)."
fi

# --- Eject so the Edge leaves USB mode --------------------------------------
if [[ "$eject" -eq 1 ]]; then
    devnode="$(findmnt -no SOURCE --target "$apps_dir" 2>/dev/null || true)"
    if [[ -n "$devnode" ]] && command -v udisksctl >/dev/null 2>&1; then
        udisksctl unmount -b "$devnode" >/dev/null 2>&1 && echo "Ejected $devnode -- safe to unplug." \
            || echo "Done, but auto-eject failed; eject manually before unplugging."
    else
        echo "Done; eject the device manually before unplugging."
    fi
fi

echo
echo "On the Edge: unplug; '$appname' will be gone from the widget loop."
