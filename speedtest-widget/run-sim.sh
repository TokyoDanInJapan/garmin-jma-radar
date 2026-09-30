#!/usr/bin/env bash
#
# Build the Proxy Speed Test widget and launch it in the Connect IQ simulator.
# Linux + macOS.
#
# Mirrors radar-widget/run-sim.sh, minus the GPS handling: this widget only
# declares the Communications permission, so there is no position to simulate.
#
# Locates the installed Connect IQ SDK, builds a single-device .prg (via
# build.sh, which also bakes in PROXY_BASE/PROXY_KEY from the radar widget's
# .env), starts the simulator host (connectiq) if it isn't already running, then
# side-loads the app with monkeydo and streams the device console. If a simulator is
# already up it's reused (a forced restart wedges the SDK's debug port). To
# reload into an open simulator you can also just run build.sh.
#
# Run from anywhere. Paths are resolved relative to this script.
#
# Options:
#   -d, --device <id>   Target device id (matches a <product> in manifest.xml).
#                       Default: edge1030plus.
#   -k, --key <path>    Developer key (.der/PKCS8). Default: ../developer_key.
#   -e, --env <path>    .env with secrets to bake in.
#                       Default: ../radar-widget/.env (shared with the radar app).
#   -h, --help          Show this help.
#
# Examples:
#   ./run-sim.sh
#   ./run-sim.sh -d edge1040
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
ciq_runsim_main "$@"
