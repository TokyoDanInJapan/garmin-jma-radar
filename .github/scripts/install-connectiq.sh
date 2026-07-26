#!/usr/bin/env bash
#
# Install the Connect IQ toolchain for CI: the SDK, the device profiles the
# widgets target, and a throwaway signing key. Not used by local development --
# setup.sh provisions that via the SDK Manager GUI.
#
# Why this exists instead of a marketplace action:
#
#   Garmin publishes the SDK on a public endpoint (sdks.json, below), but NOT
#   the per-device profiles. The GUI SDK Manager pulls those from an
#   authenticated, non-public service (monkeynet.garmin.com), so CI has no way
#   to fetch them from Garmin at all -- and monkeyc cannot build without them,
#   since every build needs -d <device>. CI therefore has to get device bits
#   from somewhere else; see CIQ_DEVICES_URL.
#
# Usage:
#   install-connectiq.sh <device> [<device> ...]
#
# Environment:
#   CIQ_SDK_VERSION  SDK version to install, as listed in sdks.json.
#   CIQ_DEVICES_URL  Zip of device profiles, each in a <device>/ folder at the
#                    zip root. Defaults to the pinned community archive below.
#                    Point this at your own mirror to drop that dependency.
#   CIQ_HOME         Install root. Must stay ~/.Garmin/ConnectIQ: the path is
#                    hardcoded in both the compiler and the simulator.
#
# Writes:
#   $CIQ_HOME/Sdks/<sdk>/bin   toolchain (add to PATH)
#   $CIQ_HOME/Devices/<device> device profiles
#   $CIQ_HOME/ci-key.der       ephemeral signing key
#
set -euo pipefail

SDK_BASE="https://developer.garmin.com/downloads/connect-iq/sdks"
SDK_VERSION="${CIQ_SDK_VERSION:-9.2.0}"
CIQ_HOME="${CIQ_HOME:-$HOME/.Garmin/ConnectIQ}"

# Device profiles are Garmin assets with no public download (see above). This
# archive is the one the community ConnectIQ CI image uses, pinned to a commit
# so the contents can't shift under us. It is the weakest link in this workflow:
# if it disappears, set CIQ_DEVICES_URL to a mirror you control.
DEVICES_PIN="de516a7b50defc1df0eeb5fe8ad116b301358781"
DEVICES_URL="${CIQ_DEVICES_URL:-https://raw.githubusercontent.com/matco/connectiq-tester/${DEVICES_PIN}/devices.zip}"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <device> [<device> ...]" >&2
    exit 1
fi
devices=("$@")

say() { printf '\n==> %s\n' "$*"; }

# --- SDK --------------------------------------------------------------------
# sdks.json maps a version to its per-platform filenames; resolve ours rather
# than hardcoding the dated, hash-suffixed zip name.
say "Resolving Connect IQ SDK $SDK_VERSION"
sdk_file="$(curl -fsSL --retry 3 "$SDK_BASE/sdks.json" \
    | jq -r --arg v "$SDK_VERSION" '.[] | select(.version == $v) | .linux')"
if [[ -z "$sdk_file" || "$sdk_file" == "null" ]]; then
    echo "SDK version $SDK_VERSION not found in sdks.json. Available:" >&2
    curl -fsSL "$SDK_BASE/sdks.json" | jq -r '.[].version' >&2
    exit 1
fi

sdk_dir="$CIQ_HOME/Sdks/${sdk_file%.zip}"
if [[ -x "$sdk_dir/bin/monkeyc" ]]; then
    say "SDK already present (cache hit): $sdk_dir"
else
    say "Downloading $sdk_file (~210 MB)"
    mkdir -p "$sdk_dir"
    curl -fsSL --retry 3 -o /tmp/connectiq-sdk.zip "$SDK_BASE/$sdk_file"
    unzip -q /tmp/connectiq-sdk.zip -d "$sdk_dir"
    rm -f /tmp/connectiq-sdk.zip
    chmod +x "$sdk_dir/bin/"*
fi
# build.sh and the SDK Manager both read this to locate the active SDK.
printf '%s' "$sdk_dir" > "$CIQ_HOME/current-sdk.cfg"

# --- Device profiles --------------------------------------------------------
missing=()
for d in "${devices[@]}"; do
    [[ -f "$CIQ_HOME/Devices/$d/compiler.json" ]] || missing+=("$d")
done

if [[ ${#missing[@]} -eq 0 ]]; then
    say "Device profiles already present (cache hit): ${devices[*]}"
else
    say "Fetching device profiles: ${missing[*]}"
    mkdir -p "$CIQ_HOME/Devices"
    curl -fsSL --retry 3 -o /tmp/devices.zip "$DEVICES_URL"
    # Extract only what we build for; the archive carries every device Garmin
    # has ever shipped and we need two of them.
    patterns=()
    for d in "${missing[@]}"; do patterns+=("$d/*"); done
    unzip -qo /tmp/devices.zip "${patterns[@]}" -d "$CIQ_HOME/Devices"
    rm -f /tmp/devices.zip

    for d in "${missing[@]}"; do
        if [[ ! -f "$CIQ_HOME/Devices/$d/compiler.json" ]]; then
            echo "Device profile '$d' not found in $DEVICES_URL" >&2
            exit 1
        fi
    done
fi

# --- Signing key ------------------------------------------------------------
# Every monkeyc build must be signed. Only Store uploads need the real developer
# key, so CI generates a throwaway one per run rather than holding a secret.
key="$CIQ_HOME/ci-key.der"
if [[ ! -f "$key" ]]; then
    say "Generating ephemeral signing key"
    openssl genrsa -out /tmp/ci-key.pem 4096 2>/dev/null
    openssl pkcs8 -topk8 -inform PEM -outform DER -in /tmp/ci-key.pem -out "$key" -nocrypt
    rm -f /tmp/ci-key.pem
fi

say "Connect IQ $SDK_VERSION ready"
echo "SDK:     $sdk_dir"
echo "Devices: ${devices[*]}"
echo "Key:     $key"
