#!/usr/bin/env bash
#
# Build the Proxy Speed Test widget (diagnostic companion to the radar).
#
# By default produces the store package bin/SpeedTest.iq. With -d <device> a
# single-device .prg for sideloading/the simulator. If a simulator is open the
# fresh build is loaded into it (skip with CIQ_NO_SIM_UPDATE=1).
#
# Reuses the radar's secrets: by default it bakes PROXY_BASE/PROXY_KEY from
# ../radar-widget/.env into a temporary copy of the resources, so the same proxy
# the radar uses is tested. The tracked properties.xml is never changed.
#
# Usage:
#   ./build.sh                       # bin/SpeedTest.iq (store package, release)
#   ./build.sh -d edge1030plus       # bin/SpeedTest-edge1030plus.prg (sideload)
#   ./build.sh -o /tmp/SpeedTest.iq  # custom output path
#   ./build.sh -k ~/keys/dev.der     # custom developer key
#   ./build.sh -e ../radar-widget/.env     # secrets file (this is the default)
#   ./build.sh --debug               # debug build (.iq only, as .prg already is)
#

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/ciq-lib.sh
. "$here/../scripts/ciq-lib.sh"
ciq_enter_box "$@"
CIQ_WIDGET_DIR="$here"
CIQ_APP=SpeedTest
CIQ_APP_LABEL="Proxy Speed Test"
CIQ_ENV_DEFAULT="$here/../radar-widget/.env"
ciq_build_main "$@"
