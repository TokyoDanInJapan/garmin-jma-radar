#!/usr/bin/env bash
#
# Dev deploy: build the Proxy Speed Test widget with the proxy secrets baked in
# (from ../radar-widget/.env, the same the radar uses), then copy it onto the connected
# Edge. Sideloaded apps can't be configured via Garmin Connect, so the Proxy
# URL/key are baked into the .prg – don't share this build.
#
# Runs on the host (needs the USB-mounted device + udisksctl). The build step
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
CIQ_APP=SpeedTest
CIQ_APP_LABEL="Proxy Speed Test"
CIQ_ENV_DEFAULT="$here/../radar-widget/.env"
ciq_deploy_main "$@"
