#!/usr/bin/env bash
#
# Dev deploy: build the JMA Rain Radar widget for a physical Edge with your
# radar-widget/.env secrets (Proxy URL + key) baked in, then copy it onto the
# connected device. This is the reliable way to run on real hardware, because a
# SIDELOADED app can't be configured through Garmin Connect – only apps
# installed from the Connect IQ Store can. The baked secrets live in the .prg on
# YOUR device, so don't share or publish this build.
#
# Runs on the host (it needs the USB-mounted device + udisksctl). The build step
# delegates to build.sh, which enters the Connect IQ container on its own.
#
# Usage:
#   ./deploy-device.sh                  # build edge1030plus, copy to the device
#   ./deploy-device.sh -d edge1040      # a different device id
#   ./deploy-device.sh --dest <dir>     # explicit GARMIN/.../Apps folder
#   ./deploy-device.sh --no-eject       # leave the device mounted afterwards
#   ./deploy-device.sh -h
#

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/ciq-lib.sh
. "$here/../scripts/ciq-lib.sh"
CIQ_WIDGET_DIR="$here"
CIQ_APP=RainRadar
CIQ_APP_LABEL="Rain Radar JP"
CIQ_ENV_DEFAULT="$here/.env"
ciq_deploy_main "$@"
