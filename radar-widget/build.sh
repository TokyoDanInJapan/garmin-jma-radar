#!/usr/bin/env bash
#
# Build the JMA Rain Radar widget.
#
# By default produces the deployable Connect IQ Store package (bin/RainRadar.iq):
# a single bundle containing release builds for every <product> in manifest.xml.
# This is the CLI equivalent of VS Code's "Monkey C: Export Project" and is the
# file you upload at apps.garmin.com.
#
# With -d <device> it instead builds a single-device .prg for sideloading or the
# simulator.
#
# If a simulator is already running, the freshly built app is loaded into it (the
# fast inner loop). run-sim.sh is the one that launches a *new* simulator. This
# script only refreshes an open one. Skip the auto-load with CIQ_NO_SIM_UPDATE=1.
#
# Bakes in optional .env secrets so the proxy URL/token can be added to the build
# without committing them. The secrets go into a temporary copy of the resources,
# so the tracked resources/shared/properties.xml is never changed.
#
# Usage:
#   ./build.sh                       # bin/RainRadar.iq (store package, release)
#   ./build.sh -d edge1040           # bin/RainRadar-edge1040.prg (sideload)
#   ./build.sh -o /tmp/RainRadar.iq  # custom output path
#   ./build.sh -k ~/keys/dev.der     # custom developer key
#   ./build.sh --debug               # debug build (.iq only, as .prg already is)
#

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/ciq-lib.sh
. "$here/../scripts/ciq-lib.sh"
ciq_enter_box "$@"
CIQ_WIDGET_DIR="$here"
CIQ_APP=RainRadar
CIQ_APP_LABEL="Rain Radar JP"
CIQ_ENV_DEFAULT="$here/.env"
ciq_build_main "$@"
