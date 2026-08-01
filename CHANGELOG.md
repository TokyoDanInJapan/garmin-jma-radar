# Changelog

Notable changes to the widgets and the proxy. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The widgets are versioned by git tag (see [CONTRIBUTING.md](CONTRIBUTING.md)).
The proxy deploys continuously from `main` and is not versioned separately.

## Unreleased

### Fixed

- **The release workflow built every package and then published nothing.** The
  job runs in a bare `ubuntu:22.04` container, which has no `gh`, so the final
  `gh release create` stopped with 'command not found'. The v1.0.0 tag compiled
  both widgets, passed the credential check and staged all ten assets, then
  failed at the last step. The job is now split. `build` keeps the container and
  hands the packages to `publish` as a workflow artifact, and `publish` runs on
  the plain runner, where `gh` is on the PATH. Because no tag had been pushed
  before v1.0.0, this step had never run.

## [1.0.0] - 2026-08-01

### Added

- CI for the Connect IQ widgets (`.github/workflows/widgets.yml`): headless SDK
  install, compilation of both widgets for every product in their manifests with
  warnings treated as errors, and the 53 Monkey C unit tests run in the simulator
  under Xvfb. Previously CI checked none of the Monkey C code.
- Lint workflow: shellcheck over every shell script, actionlint over the
  workflows and ESLint over the proxy. shellcheck and actionlint also run
  pre-commit.
- Post-deploy smoke test. After a Cloudflare deploy, the workflow probes
  `/health` to confirm that the Worker routes and that the `RATE_LIMITER` binding
  actually materialised at run time.
- Coverage thresholds on the proxy test suite (lines 98%, branches 90%,
  functions 100%), enforced in CI.
- An `npm audit --omit=dev` gate on the production dependencies.
- Credential check on built widgets
  (`.github/scripts/assert-no-credentials.sh`), run before any artifact upload or
  release. A `PROXY_KEY` baked in by `build.sh` is compiled into the `.prg` and
  into the generated `-settings.json`, but it never reaches git, because the
  build restores `properties.xml`. gitleaks therefore cannot catch it, and the
  published artifact is the one place it could escape.
- Release workflow. Tagging `v*` builds both widgets and attaches these files to
  a GitHub Release: the sideloadable `.prg` files (one per product), the `.iq`
  Store bundles and the matching `.prg.debug.xml` symbol maps.
- `CONTRIBUTING.md`, issue and PR templates, and this changelog.
- `speedtest-widget/run-sim.sh`, matching the radar widget's script.

### Fixed

- **`remove-device.sh` falsely reported success.** The settings-file loop
  iterated a quoted path with no glob metacharacters, so `nullglob` and
  `nocaseglob` never applied and the loop always ran once. `rm -f` on a
  nonexistent file succeeds, so the script printed 'Removed settings' and
  suppressed the 'Nothing to remove' message even when nothing was there. The
  loop now matches with `find -iname`.
- **`build.sh` never cleared stale simulator settings.** The `.SET` file is named
  after the uppercased `.prg` basename, not after the AppName as the comment
  claimed. Stripping the `-<device>` suffix therefore meant the script looked for
  `RAINRADAR.SET` while the simulator had written `RAINRADAR-EDGE1040.SET`. Stale
  settings could silently shadow freshly baked `.env` values.
- Ten shellcheck findings across the build, deploy and setup scripts, including
  three errors where `"$k[[:space:]]"` parsed as an array subscript.
- `proxy/scripts/gen-samples.mjs` imported `pngjs` from a hardcoded
  `/tmp/imgtools` path, so it only ran on one machine. It now depends on `pngjs`
  properly and emits a `/frames`-shaped `frames.json`, so the sample pipeline
  runs from live JMA data without a deployed proxy or a token.
- `gen-device-gif.py` claimed to mirror `RadarView.mc onUpdate()`. It does not.
  It approximates an early prototype and has diverged from the real UI (title
  row, romanised attribution, zoom buttons, progress bar). The docstring is
  corrected, so its output is not mistaken for a screenshot of the app.
- **`--help` was truncated in all eight widget scripts.** Each one printed its
  header comment with a hardcoded `sed` line range. Seven ranges stopped short,
  so `build.sh --help` listed one of its five examples and `run-sim.sh --help`
  cut off inside the options list. The eighth over-ran the header entirely. The
  range is now derived from the file, so the help cannot drift again.
- The Settings table in the README gave the zoom range as 8 to 11 and called the
  default 8 the Wide preset. The widget clamps zoom to 4 to 11, and 8 is the
  Local preset (Wide is 6).
- A comment in `speedtest-widget/resources/shared/properties.xml` said the proxy
  URL and key are editable from Garmin Connect for sideloaded installs. They are
  not. Only Store installs get a settings screen, which is why `deploy-device.sh`
  bakes the values in.

### Changed

- Documentation, code comments and user-facing strings across the repository now
  follow one British English writing standard: British spelling, active voice,
  shorter sentences, no semicolons or Latin abbreviations in prose, and one term
  per thing (the simulator is no longer also 'the sim').
- Device status messages separate the cause from the advice with a colon rather
  than a hyphen: `Auth failed: check key`, `Server busy: try later` and
  `Timed out: try Wi-Fi`. The loading disclaimer now reads as full sentences.
  `docs/troubleshooting.md` lists the new strings.

- `setup.sh` moved from `radar-widget/` to the repo root. It provisions the
  toolchain that both widgets share, and nothing in it was widget-specific.
- Wrangler `compatibility_date` bumped from `2024-09-01` to `2026-07-01`.
- README split: the Connect IQ SDK install guide and the troubleshooting guide
  moved to `docs/`.
- The path filter in `proxy.yml` now applies to `push` only, not to
  `pull_request`, so the `test` check reports on every PR. The check can then be
  required without deadlocking PRs that do not touch `proxy/**`.

[1.0.0]: https://github.com/TokyoDanInJapan/garmin-jma-radar/releases/tag/v1.0.0
