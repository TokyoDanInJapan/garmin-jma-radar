#!/usr/bin/env bash
#
# Install the Connect IQ toolchain for CI: the SDK, the device profiles the
# widgets target, and a throwaway signing key. Not used by local development –
# setup.sh provisions that via the SDK Manager GUI.
#
# Why this exists instead of a marketplace action:
#
#   Garmin publishes the SDK on a public endpoint (sdks.json, below), but NOT
#   the per-device profiles. The GUI SDK Manager pulls those from an
#   authenticated, non-public service (monkeynet.garmin.com), so CI has no way
#   to fetch them from Garmin at all – and monkeyc cannot build without them,
#   since every build needs -d <device>. CI therefore has to get device bits
#   from somewhere else. See CIQ_DEVICES_URL.
#
# Usage:
#   install-connectiq.sh <device> [<device> ...]
#
# Environment:
#   CIQ_DEVICES_URL     Zip of device profiles, each in a <device>/ folder at
#                       the zip root. Defaults to the pinned community archive
#                       below. Point this at your own mirror to drop that
#                       dependency, and set CIQ_DEVICES_SHA256 to match it.
#   CIQ_DEVICES_SHA256  SHA-256 of that zip. Required with CIQ_DEVICES_URL.
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
# The one place the CI SDK version is set. The workflows' cache keys hash this
# file, so a bump here also invalidates the cached toolchain. Keep it in step
# with the SDK developers install locally (docs/connect-iq-sdk.md).
SDK_VERSION="9.2.0"
# Garmin publishes no checksum, so this hash was taken from the first download
# of this version (trust on first use). It still stops a changed or corrupted
# zip from being unpacked and run in a job that can hold the signing key.
SDK_SHA256="4907d8455b651c5a00a865e364cc4f1921c055b9279c7c8634c7a7a6773b5593"
CIQ_HOME="${CIQ_HOME:-$HOME/.Garmin/ConnectIQ}"

# Device profiles are Garmin assets with no public download (see above). This
# archive is the one the community ConnectIQ CI image uses, pinned to a commit
# so the contents can't shift under us. It is the weakest link in this workflow:
# if it disappears, set CIQ_DEVICES_URL to a mirror you control.
DEVICES_PIN="de516a7b50defc1df0eeb5fe8ad116b301358781"
if [[ -n "${CIQ_DEVICES_URL:-}" ]]; then
    DEVICES_URL="$CIQ_DEVICES_URL"
    DEVICES_SHA256="${CIQ_DEVICES_SHA256:?set CIQ_DEVICES_SHA256 to the SHA-256 of $CIQ_DEVICES_URL}"
else
    DEVICES_URL="https://raw.githubusercontent.com/matco/connectiq-tester/${DEVICES_PIN}/devices.zip"
    DEVICES_SHA256="f5c40592470f5c9681d3bd6fd8062fc1a9b8f584c99554a601a45ba186a40df7"
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <device> [<device> ...]" >&2
    exit 1
fi
devices=("$@")

say() { printf '\n==> %s\n' "$*"; }

# Downloads go to a private temp folder, removed on exit.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

verify() {  # <file> <sha256>
    if ! echo "$2  $1" | sha256sum -c --quiet -; then
        echo "Checksum mismatch for $(basename "$1"). Refusing to unpack it." >&2
        exit 1
    fi
}

# --- SDK --------------------------------------------------------------------
# sdks.json maps a version to its per-platform filenames. Resolve ours rather
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
    curl -fsSL --retry 3 -o "$tmp/sdk.zip" "$SDK_BASE/$sdk_file"
    verify "$tmp/sdk.zip" "$SDK_SHA256"
    unzip -q "$tmp/sdk.zip" -d "$sdk_dir"
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
    curl -fsSL --retry 3 -o "$tmp/devices.zip" "$DEVICES_URL"
    verify "$tmp/devices.zip" "$DEVICES_SHA256"
    # Extract only what we build for. The archive carries every device Garmin
    # has ever shipped and we need two of them.
    patterns=()
    for d in "${missing[@]}"; do patterns+=("$d/*"); done
    unzip -qo "$tmp/devices.zip" "${patterns[@]}" -d "$CIQ_HOME/Devices"

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
    (umask 077
     openssl genrsa -out "$tmp/ci-key.pem" 4096 2>/dev/null
     openssl pkcs8 -topk8 -inform PEM -outform DER -in "$tmp/ci-key.pem" -out "$key" -nocrypt)
fi

# --- Sanity: will the compiler look where we installed? ---------------------
# monkeyc is a Java program and resolves its SDK/device root from the passwd
# entry for the current uid, not from $HOME. When those disagree – which they
# do by default in a GitHub container job, where HOME=/github/home while uid 0's
# passwd home is /root – every build fails with "Invalid device id: <device>",
# which says nothing about paths. Catch it here instead.
passwd_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
if [[ -n "$passwd_home" && "$passwd_home" != "$HOME" ]]; then
    echo >&2
    echo "ERROR: \$HOME ($HOME) differs from the passwd home for uid $(id -u)" >&2
    echo "       ($passwd_home). The toolchain is installed under \$HOME, but" >&2
    echo "       monkeyc will look under $passwd_home and report every device as" >&2
    echo "       an invalid device id." >&2
    echo "       Set HOME=$passwd_home for the job (see .github/workflows/widgets.yml)." >&2
    exit 1
fi

say "Connect IQ $SDK_VERSION ready"
echo "HOME:    $HOME"
echo "SDK:     $sdk_dir"
echo "Devices: ${devices[*]}"
echo "Key:     $key"
