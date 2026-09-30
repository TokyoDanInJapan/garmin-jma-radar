# Changelog

Notable changes to the widgets and the proxy. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The widgets are versioned by git tag (see [CONTRIBUTING.md](CONTRIBUTING.md)).
The proxy deploys continuously from `main` and is not versioned separately.

## Unreleased

### Added

- `setup.sh` now runs on Omarchy and other Arch-based systems. On these hosts,
  the script installs `podman` and `distrobox` with `pacman`. The container is
  the same Ubuntu 22.04 container as on Ubuntu.

### Changed

- The radar widget fetches a new frame list every 10 minutes while it stays
  open, instead of playing the first list for as long as it is open. The current
  frame stays on screen until the first new frame arrives.
- Both widgets send the proxy key for `/frames` in the `X-Proxy-Key` header, so
  it stays out of request URLs. They also round the position to 3 decimal places
  before they send it.
- Both widgets check the settings before they send anything. The `YOURNAME`
  placeholder URL, an empty key or an `http://` URL (other than `localhost`)
  now shows what to fix, instead of failing a request.
- Error messages name the problem: `Phone not connected`, `Timed out`,
  `Image too large`, `Proxy URL must be https` and `Outside Japan?`. Before, every
  transport error showed `No phone connection`, even on Wi-Fi.
- The radar widget stops redrawing when it shows a single frame, instead of
  redrawing it twice a second for as long as it is open. The speed-test widget
  stops its timer when a run is done or the settings are unusable.
- `RadarView.mc` is split into `FrameListClient` (the `/frames` request),
  `RadarRenderer` (drawing and button geometry) and the view itself. Playback,
  settings and response checks are now pure helpers with unit tests.
- The proxy keeps recent frames, frame lists and decoded base-map tiles in
  memory. The Cache API does nothing on `*.workers.dev`, so before this every
  `/tile` request there rendered the frame again. A frame whose base tiles are
  in memory renders in about 30% less CPU time. The README now explains caching
  and the free plan's 10 ms CPU limit.
- `/frames` rounds the rider's position to 3 decimal places (about 110 m)
  instead of 4. The tile URLs pass through Garmin's image relay and are stored
  on the device, so they no longer carry the exact position.
- `/tile` rejects a `basetime`/`validtime` pair that JMA could not have
  published: off the 5-minute grid, a lead outside 0–60 minutes, a `basetime`
  more than 3 hours old or in the future, or an impossible date.
- The `/tile` cache key includes a render version, so a change to the rendering
  is not hidden behind a day of cached frames.
- The frame lists are at most about a minute old, down from about two.
- The widget scripts (`build.sh`, `run-sim.sh`, `deploy-device.sh` and
  `remove-device.sh`) now share one implementation in `scripts/ciq-lib.sh`. Each
  widget keeps a short wrapper with its own help text.
- `build.sh` no longer edits the tracked `resources/shared/properties.xml`. It
  bakes the proxy URL and key into a temporary copy, so two builds at once, or a
  build that is killed, can no longer leave the key in a tracked file.
- The VS Code tasks ask which widget to act on, and there is a new
  "Garmin: Remove from device" task.

### Fixed

- `deploy-device.sh` and `remove-device.sh` only accept a mount that has
  `Garmin/GarminDevice.xml`, and stop with a list when more than one Garmin is
  mounted. Before, they took the first `garmin/apps` folder they found, even on
  a backup drive, and then ejected that drive.
- The scripts eject a device only when it is removable, so `--dest` on a fixed
  disk no longer unmounts that disk.
- When the Edge is connected over MTP, the scripts now say so, instead of
  reporting that no device is connected.
- A proxy URL or key that contains `#` no longer breaks the build.
- `remove-device.sh` now shows the size of each file it removes.
- The scripts and `setup.sh` no longer mistake a container such as
  `garmin-old` for the `garmin` container.
- **The radar widget kept working after it was hidden.** It stopped its timers
  but not the load, so the next image callback requested another image and
  restarted the timer. A settings change in Garmin Connect also started GPS
  and network requests for a hidden widget. Both now wait until the widget is
  shown again.
- **A late `/frames` response could replace a newer one.** After a zoom change
  or a reload, the old request's answer could still be accepted, so frames for
  the old zoom showed, or an old `401` flagged a key that had been fixed. Each
  request now has a sequence number.
- The radar widget checks the `/frames` response before it uses it. A body of
  the wrong shape shows `Bad server response` instead of crashing, and a proxy
  that returns more frames than asked for can no longer run the device out of
  memory.
- Responses that are too large (`-402`, `-403`) or need https (`-1001`) are no
  longer retried. Over Bluetooth, each retry could take 90 seconds.
- A GPS fix that arrives after `No GPS fix` now clears the failure, and a
  last-known position with no accuracy is no longer used.
- **The speed-test widget could record a result against the wrong request.**
  After a tap or a timeout, an old request's late callback was counted as the
  new one. Callbacks now carry a sequence number, and an abandoned request is
  cancelled. A settings change now starts a fresh run.
- **"Now" could go missing from `/frames`.** The proxy anchored on the forecast
  list but looked up "now" in the observed list. The two are cached separately,
  so when the observed list was a step behind, "now" was dropped, and a request
  for one frame failed with a 502. The anchor is now the newest time both lists
  have reached.
- When a frame offset is missing, `/frames` now moves on to the next offset in
  priority order, so it still returns the number of frames asked for.
- A 200 response that is not a 256×256 PNG (for example, an HTML maintenance
  page) no longer fails the whole frame. The proxy treats it as a failed tile.
- **A slow radar tile could show "no rain" for 24 hours.** When JMA timed out or
  returned a server error for a tile, the proxy drew that tile as background and
  cached the frame as immutable for a day. It now serves such a frame with
  `no-store` and does not cache it. A 404 still counts as "no rain" and is
  cached as before.
- **The gitleaks CI job could print the proxy token in the public log.** The two
  custom rules did not set `secretGroup`, so gitleaks redacted the keyword and
  printed the value. Both rules now report the value as the secret.
- **CI uploaded widget builds even when the credential check failed.** The
  upload ran with `if: always()`. The check now runs last, also covers the
  unit-test build, and the upload runs only when the check passes.
- `speedtest-widget/build.sh` exited with status 1 after every build that did
  not bake a key, so `run-sim.sh` stopped before it started the simulator.

## [1.0.1] - 2026-09-13

### Changed

- The README and the guides in `docs/` now use plain British English. Sentences
  are shorter, the steps are in lists, and the text defines terms such as JMA and
  GSI on first use. Some README anchors changed, for example
  `#2-build-and-run-the-widget` and `#wi-fi-and-bluetooth`.
- The troubleshooting entry for blank frames no longer blames a zoom above
  `z=11`. The Worker limits the zoom to 4–11, so a request cannot go past `z=11`.

### Fixed

- **The release workflow built every package and then published nothing.** The
  job runs in a bare `ubuntu:22.04` container, which has no `gh`, so the final
  `gh release create` stopped with 'command not found'. The v1.0.0 tag compiled
  both widgets, passed the credential check and staged all ten assets, then
  failed at the last step. The job is now split. `build` keeps the container and
  hands the packages to `publish` as a workflow artifact, and `publish` runs on
  the plain runner, where `gh` is on the PATH. `publish` takes only the
  artifact and does no checkout, so it also sets `GH_REPO`. Without it, `gh`
  asks git which repository it is in and stops with 'not a git repository'.
  Because no tag had been pushed before v1.0.0, this step had never run.

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

[1.0.1]: https://github.com/TokyoDanInJapan/garmin-jma-radar/releases/tag/v1.0.1
[1.0.0]: https://github.com/TokyoDanInJapan/garmin-jma-radar/releases/tag/v1.0.0
