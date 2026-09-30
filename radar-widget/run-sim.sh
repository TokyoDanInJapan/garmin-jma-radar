#!/usr/bin/env bash
#
# Build the JMA Rain Radar widget and launch it in the Connect IQ simulator.
# Linux + macOS.
#
# Locates the installed Connect IQ SDK, builds a single-device .prg (via
# build.sh, which also bakes in PROXY_BASE/PROXY_KEY from .env), starts the
# simulator host (connectiq) if it isn't already running, then side-loads the
# app with monkeydo and streams the device console. If a simulator is already up it's
# reused (a forced restart wedges the SDK's debug port). To reload into an open
# simulator you can also just run build.sh.
#
# Run from anywhere. Paths are resolved relative to this script.
#
# Options:
#   -d, --device <id>   Target device id (matches a <product> in manifest.xml).
#                       Default: edge1030plus.
#   -k, --key <path>    Developer key (.der/PKCS8). Default: ../developer_key.
#       --lat <deg>     Simulated GPS latitude.  Default: 35.681236 (Tokyo).
#       --lon <deg>     Simulated GPS longitude. Default: 139.767125 (Tokyo).
#                       GPS only applies on a COLD start (the simulator rewrites its
#                       config on exit). If already running, use Simulation >
#                       GPS/Position in the UI.
#   -e, --env <path>    .env with secrets to bake in. Default: ./.env.
#   -h, --help          Show this help.
#
# Examples:
#   ./run-sim.sh
#   ./run-sim.sh -d edge1040
#   ./run-sim.sh --lat 34.6937 --lon 135.5023   # Osaka
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
CIQ_SIM_GPS=1
ciq_runsim_main "$@"
