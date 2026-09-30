#!/usr/bin/env bash
#
# Build each widget's unit-test program and run it in the headless simulator.
# Used by widgets.yml on every change and by release.yml before it publishes.
#
# (:test) functions are compiled in only by --unit-test, so this is a second
# build. It is not held to the zero-warning bar of the main build: the test
# sources trip "cannot determine container type" on their fixture literals.
#
# Usage:
#   test-widgets.sh <signing key> [<device>]
#
set -euo pipefail

key="${1:?usage: test-widgets.sh <signing key> [<device>]}"
device="${2:-edge1040}"

for widget in radar-widget speedtest-widget; do
    echo "::group::$widget unit tests"
    (cd "$widget" && monkeyc -d "$device" -l 1 --unit-test \
        -f monkey.jungle -o bin/ci-test.prg -y "$key")
    "$(dirname "$0")/run-ciq-tests.sh" "$widget/bin/ci-test.prg" "$device"
    echo "::endgroup::"
done
