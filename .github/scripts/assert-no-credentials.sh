#!/usr/bin/env bash
#
# Fail if a built widget carries a proxy credential.
#
# The risk is real and specific: build.sh injects PROXY_BASE/PROXY_KEY from a
# git-ignored .env into resources/shared/properties.xml for the duration of a
# build. A key baked that way is compiled into the .prg binary AND into the
# generated <name>-settings.json -- verified by baking a sentinel token and
# finding it in both. Release assets are public, so a mistake here publishes the
# shared secret that gates /frames and /tile.
#
# CI builds by calling monkeyc directly and never has a .env, so the compiled
# default is always empty. This asserts that rather than assuming it, so the
# guarantee survives someone later switching a workflow over to build.sh.
#
# The generated settings JSON is the authoritative check: it reports the
# defaultValue the compiler actually baked, so it cannot disagree with the
# binary.
#
# Usage:
#   assert-no-credentials.sh <dir-containing-build-output> [<dir> ...]
#
set -euo pipefail

dirs=("${@:-dist}")
status=0
checked=0

# A .env anywhere in the tree means a build could have baked from it.
#
# The -e test is load-bearing: nullglob does NOT drop a word with no glob
# metacharacters, so a bare ".env" survives the expansion whether or not the
# file exists. Without the test this reports a leak on every clean tree, and a
# guard that always fails is a guard everyone learns to ignore.
shopt -s nullglob
for env_file in .env */.env; do
    [[ -e "$env_file" ]] || continue
    echo "::error::$env_file exists in the build tree; a build could bake a credential from it"
    status=1
done

for dir in "${dirs[@]}"; do
    for settings in "$dir"/*-settings.json; do
        checked=$((checked + 1))
        name="$(basename "$settings")"

        key="$(jq -r '.settings[]? | select(.key == "proxyKey") | .defaultValue' "$settings")"
        if [[ -n "$key" && "$key" != "null" ]]; then
            # Never print the value itself -- this output is a public build log.
            echo "::error::$name ships a non-empty proxyKey default (${#key} chars)"
            status=1
        else
            echo "ok: $name has an empty proxyKey"
        fi

        base="$(jq -r '.settings[]? | select(.key == "proxyBase") | .defaultValue' "$settings")"
        # Not fatal on its own -- a base URL is not a secret, and shipping a
        # real one may one day be deliberate -- but it means .env was applied,
        # so say so loudly.
        if [[ "$base" != *YOURNAME* ]]; then
            echo "::warning::$name has a non-placeholder proxyBase; was this built with .env applied?"
        fi
    done
done

if [[ "$checked" -eq 0 ]]; then
    echo "::error::no *-settings.json found under: ${dirs[*]} -- the credential check verified nothing"
    exit 1
fi

if [[ "$status" -eq 0 ]]; then
    echo "Checked $checked build(s): no proxy credential baked in."
fi
exit "$status"
