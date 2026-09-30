#!/usr/bin/env bash
#
# Remove the sideloaded Proxy Speed Test widget from a connected Edge, then eject.
# It disappears from the widget loop on the next connect/boot. (To remove the
# radar instead, use radar-widget/remove-device.sh.)
#
# What it deletes: the app binary in BOTH places the device keeps it – the
# staging copy in GARMIN/Garmin/Apps/ (present until the device imports it) and
# the installed copy in Apps/Media/ – plus its settings file (best effort,
# because the
# device sometimes renames the .SET to an internal id we can't match).
#
# Usage:
#   ./remove-device.sh              # find the device, remove, eject
#   ./remove-device.sh --dest <dir> # explicit GARMIN/.../Apps folder
#   ./remove-device.sh --no-eject   # leave the device mounted afterwards
#   ./remove-device.sh -h
#

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/ciq-lib.sh
. "$here/../scripts/ciq-lib.sh"
CIQ_WIDGET_DIR="$here"
CIQ_APP=SpeedTest
CIQ_APP_LABEL="Proxy Speed Test"
ciq_remove_main "$@"
