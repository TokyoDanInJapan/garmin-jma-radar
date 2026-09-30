#!/usr/bin/env bash
#
# One-time setup of the Connect IQ build/run environment on Ubuntu or Omarchy.
#
# Garmin's SDK Manager and simulator link the old webkit2gtk-4.0 / libsoup2.4
# libraries that Ubuntu dropped after 22.04 and that Arch no longer ships. This
# script provisions an Ubuntu 22.04 distrobox container that has those libraries
# (plus the JDK), so build.sh and run-sim.sh work on any modern Ubuntu, and on
# Omarchy or another Arch-based host. Safe to re-run (idempotent).
#
# What it does:
#   1. installs podman + distrobox on the host                   (sudo)
#      (apt on Ubuntu/Debian, pacman on Omarchy/Arch)
#   2. creates the 'garmin' distrobox container (ubuntu:22.04)
#   3. installs the SDK / simulator dependencies inside it
#   4. launches the Connect IQ SDK Manager so you can install the SDK
#      (interactive: sign in with your Garmin account)
#   5. generates a developer signing key if you don't already have one
#
# Usage:
#   ./setup.sh
#   CIQ_BOX=mybox ./setup.sh           # use a different container name
#
set -euo pipefail

BOX="${CIQ_BOX:-garmin}"
IMAGE="${CIQ_IMAGE:-ubuntu:22.04}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ciq-lib.sh
. "$here/scripts/ciq-lib.sh"   # ciq_box_exists

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    %s\033[0m\n' "$*"; }

# Must run on the host, not inside a container.
if [ -e /run/.containerenv ] || [ -e /.dockerenv ]; then
    echo "Run this on the host, not inside a container." >&2; exit 1
fi
# Only the host packages differ between hosts. The container is the same.
# Omarchy is Arch-based, so it uses pacman.
if command -v apt-get >/dev/null 2>&1; then
    host="ubuntu"
elif command -v pacman >/dev/null 2>&1; then
    host="arch"
else
    echo "This script targets Ubuntu (apt-get) or Omarchy/Arch (pacman)." >&2; exit 1
fi

# 1. Host packages -----------------------------------------------------------
say "1/5  Host packages (podman, distrobox, newuidmap)"
if command -v podman >/dev/null 2>&1 && command -v distrobox >/dev/null 2>&1 \
   && command -v newuidmap >/dev/null 2>&1; then
    ok "already installed"
elif [ "$host" = "ubuntu" ]; then
    sudo apt-get update
    sudo apt-get install -y podman distrobox uidmap
    ok "installed"
else
    # --needed skips packages that are already current, such as Omarchy's podman.
    # No -y: Arch does not support partial upgrades, so a stale package database
    # is the user's full upgrade to run, not ours.
    if ! sudo pacman -S --needed --noconfirm podman distrobox; then
        warn "pacman failed. If it reported 'target not found' or a 404, the package"
        warn "database is out of date. Run 'omarchy-update' (or 'sudo pacman -Syu'),"
        warn "then run ./setup.sh again."
        exit 1
    fi
    ok "installed"
fi

# Rootless podman needs subuid/subgid ranges for the current user. A fixed
# 100000-165535 would overlap another user's range on a shared machine, and two
# users mapped to the same host IDs can read each other's container files. So
# take the first free range after every range already in use.
user="${USER:-$(id -un)}"
next_free_id() {
    awk -F: '{ end = $2 + $3 } end > max { max = end }
             END { print (max < 100000 ? 100000 : max) }' "$1" 2>/dev/null || echo 100000
}
for kind in uid gid; do
    file="/etc/sub$kind"
    if ! grep -q "^$user:" "$file" 2>/dev/null; then
        start="$(next_free_id "$file")"
        warn "adding sub$kind range $start-$((start + 65535)) for $user (you may need to log out and in once)"
        sudo usermod "--add-sub${kind}s" "$start-$((start + 65535))" "$user"
        added_ids=1
    fi
done
if [ -n "${added_ids:-}" ]; then
    podman system migrate 2>/dev/null || true
fi

# 2. Container ---------------------------------------------------------------
say "2/5  Container '$BOX' ($IMAGE)"
if ciq_box_exists "$BOX"; then
    ok "already exists"
else
    distrobox create --name "$BOX" --image "$IMAGE" --yes
    ok "created"
fi

# 3. In-box dependencies -----------------------------------------------------
say "3/5  SDK & simulator libraries inside '$BOX'"
# An array, so the package list reaches apt-get as separate arguments without
# relying on word splitting.
deps=(openjdk-17-jdk libwebkit2gtk-4.0-37 libjavascriptcoregtk-4.0-18
      libsoup2.4-1 libusb-1.0-0 libpng16-16 unzip)
if distrobox enter "$BOX" -- bash -c "dpkg -s ${deps[*]} >/dev/null 2>&1"; then
    ok "already installed"
else
    distrobox enter "$BOX" -- sudo apt-get update
    distrobox enter "$BOX" -- sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${deps[@]}"
    ok "installed"
fi

# 4. Connect IQ SDK ----------------------------------------------------------
say "4/5  Connect IQ SDK"
cfg="$HOME/.Garmin/ConnectIQ/current-sdk.cfg"
if [ -s "$cfg" ] && [ -d "$(tr -d '[:space:]' < "$cfg")/bin" ]; then
    ok "SDK already installed: $(tr -d '[:space:]' < "$cfg")"
else
    # Find the SDK Manager the user downloaded.
    mgr=""
    for c in \
        "$HOME/Downloads/connectiq-sdk-manager-linux/bin/sdkmanager" \
        "$HOME/connectiq-sdk-manager/bin/sdkmanager" \
        "$HOME"/Downloads/connectiq-sdk-manager*/bin/sdkmanager; do
        [ -x "$c" ] && { mgr="$c"; break; }
    done
    if [ -n "$mgr" ]; then
        warn "Launching the SDK Manager inside '$BOX'. In the window:"
        warn "  - sign in with your Garmin account,"
        warn "  - install the latest SDK,"
        warn "  - download your device profiles (edge1030plus, edge1040),"
        warn "  then close it to continue."
        distrobox enter "$BOX" -- "$mgr" || true
    else
        warn "SDK Manager not found under ~/Downloads. Download the Linux SDK Manager:"
        warn "  https://developer.garmin.com/connect-iq/sdk/"
        warn "unzip it under ~/Downloads, then run ./setup.sh again (or launch it manually:"
        warn "  distrobox enter $BOX -- <path>/bin/sdkmanager )."
    fi
fi

# 5. Developer key -----------------------------------------------------------
say "5/5  Developer signing key"
if [ -f "$here/developer_key.der" ] || [ -f "$here/developer_key" ]; then
    ok "key already present at repo root"
else
    openssl genrsa -out "$here/developer_key.pem" 4096
    openssl pkcs8 -topk8 -inform PEM -outform DER \
        -in "$here/developer_key.pem" -out "$here/developer_key.der" -nocrypt
    rm -f "$here/developer_key.pem"
    ok "generated developer_key.der (git-ignored)"
fi

say "Setup complete."
echo "Both widgets share this toolchain. build.sh / run-sim.sh auto-enter '$BOX':"
echo "    cd $here/radar-widget     && ./run-sim.sh   # build + launch the simulator"
echo "    cd $here/speedtest-widget && ./run-sim.sh   # same, for the speed-test widget"
echo "    ./build.sh                                  # deployable .iq, in either folder"
