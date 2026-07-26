# Changelog

Notable changes to the widgets and the proxy. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The widgets are versioned by git tag (see [CONTRIBUTING.md](CONTRIBUTING.md));
the proxy deploys continuously from `main` and is not separately versioned.

## Unreleased

### Added

- CI for the Connect IQ widgets (`.github/workflows/widgets.yml`): headless SDK
  install, compilation of both widgets for every product in their manifests with
  warnings treated as errors, and the 53 Monkey C unit tests run in the simulator
  under Xvfb. Previously none of the Monkey C code was checked by CI.
- Lint workflow: shellcheck over every shell script, actionlint over the
  workflows, ESLint over the proxy. shellcheck and actionlint also run
  pre-commit.
- Post-deploy smoke test: after a Cloudflare deploy, `/health` is probed to
  confirm the Worker routes and that the `RATE_LIMITER` binding actually
  materialised at runtime.
- Coverage thresholds on the proxy test suite (lines 98%, branches 90%,
  functions 100%), enforced in CI.
- `npm audit --omit=dev` gate on production dependencies.
- Release workflow: tagging `v*` builds both widgets and attaches sideloadable
  `.prg` files (one per product), the `.iq` Store bundles, and the matching
  `.prg.debug.xml` symbol maps to a GitHub Release.
- `CONTRIBUTING.md`, issue and PR templates, this changelog.
- `speedtest-widget/run-sim.sh`, matching the radar widget's.

### Fixed

- **`remove-device.sh` falsely reported success.** The settings-file loop
  iterated a quoted path with no glob metacharacters, so `nullglob`/`nocaseglob`
  never applied and the loop always ran once. `rm -f` on a nonexistent file
  succeeds, so it printed "Removed settings" and suppressed the "Nothing to
  remove" message even when nothing was there. Now matched with `find -iname`.
- **`build.sh` never cleared stale simulator settings.** The `.SET` file is named
  after the uppercased `.prg` basename, not the AppName as the comment claimed,
  so stripping the `-<device>` suffix meant it looked for `RAINRADAR.SET` while
  the simulator had written `RAINRADAR-EDGE1040.SET`. Stale settings could
  silently shadow freshly baked `.env` values.
- Ten shellcheck findings across the build/deploy/setup scripts, including three
  errors where `"$k[[:space:]]"` parsed as an array subscript.
- `proxy/scripts/gen-samples.mjs` imported `pngjs` from a hardcoded
  `/tmp/imgtools` path, so it only ran on one machine. It now depends on `pngjs`
  properly and emits a `/frames`-shaped `frames.json`, so the sample pipeline
  runs from live JMA data without a deployed proxy or a token.
- `gen-device-gif.py` claimed to mirror `RadarView.mc onUpdate()`. It does not:
  it approximates an early prototype and has diverged from the real UI (title
  row, romanized attribution, zoom buttons, progress bar). Docstring corrected
  so its output isn't mistaken for a screenshot of the app.

### Changed

- `setup.sh` moved from `radar-widget/` to the repo root: it provisions the
  toolchain both widgets share, and nothing in it was widget-specific.
- Wrangler `compatibility_date` bumped from `2024-09-01` to `2026-07-01`.
- README split: the Connect IQ SDK install guide and troubleshooting moved to
  `docs/`.
- `proxy.yml`'s path filter now applies to `push` only, not `pull_request`, so
  the `test` check reports on every PR and can be required without deadlocking
  PRs that don't touch `proxy/**`.
