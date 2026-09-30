# Contributing

Thanks for taking a look. This is a small project with a narrow scope: a rain
radar for Garmin Edge devices, in Japan. The most useful contributions are bug
reports from real rides, and fixes that keep the moving parts simple.

## Scope

**In scope:** correctness and reliability of the radar, proxy caching and cost,
Connect IQ device support, and the docs.

**Out of scope:** weather sources outside Japan, because the JMA nowcast is the
whole point, and anything that requires the proxy to store user data. The proxy
deliberately keeps no state beyond edge cache entries keyed on tile geometry.

## Getting set up

- **Proxy only** (`proxy/`): Node 22 or newer. Run `cd proxy && npm ci`. You need
  no Garmin toolchain.
- **Widgets** (`radar-widget/`, `speedtest-widget/`): see
  [docs/connect-iq-sdk.md](docs/connect-iq-sdk.md). On Ubuntu 24.10 or newer, or
  on Omarchy, `./setup.sh` from the repo root does everything.

Install the pre-commit hooks once per clone. They run the same gitleaks,
shellcheck and actionlint checks that CI runs:

```bash
pipx install pre-commit   # or brew / pip
pre-commit install
pre-commit run --all-files
```

## Running the checks locally

You can run everything CI enforces:

```bash
# proxy
cd proxy
npm run lint          # eslint
npm run typecheck     # tsc --noEmit over JSDoc-typed JS
npm run coverage      # tests + coverage thresholds
npx wrangler deploy --dry-run --outdir dist

# whole repo
shellcheck $(git ls-files '*.sh')
actionlint

# widgets (needs the Connect IQ SDK)
cd radar-widget
monkeyc -d edge1040 -w -l 1 -f monkey.jungle -o bin/x.prg -y ../developer_key.der
monkeyc -d edge1040 -l 1 --unit-test -f monkey.jungle -o bin/test.prg -y ../developer_key.der
monkeydo bin/test.prg edge1040 -t
```

## Conventions that matter here

**Comments explain *why*.** The existing code documents the non-obvious
constraint behind a decision: why the cache key is tile geometry rather than raw
lat/lon, why `monkeydo`'s exit code cannot be trusted, and why the base resource
path cannot point at `resources/`. Match that. Do not add comments that restate
the code.

**JMA specifics stay in `proxy/src/jma.js`.** Those endpoints are undocumented
and will change without notice. One file should absorb that.

**The device tile size is a cross-project contract.** `DEVICE_TILE_SIZE` (288) is
duplicated in `proxy/src/index.js`, `radar-widget/source/FramePipeline.mc` and
`speedtest-widget/source/SpeedTestView.mc`. Change all three together.

**Frame count is bounded by device memory.** `MAX_FRAMES = 6` in `jma.js` is not
arbitrary. A seventh 288px frame makes the widget run out of memory mid-load.

**Never commit secrets.** `build.sh` bakes `PROXY_BASE` and `PROXY_KEY` from a
git-ignored `.env` into a temporary copy of `resources/shared`, and points the
build at it with an overlay jungle. The tracked `properties.xml` is never
written. gitleaks still runs pre-commit and in CI, in case a key is pasted into
a tracked file by hand.

**The widget scripts share one implementation.** `scripts/ciq-lib.sh` holds the
logic for `build.sh`, `run-sim.sh`, `deploy-device.sh` and `remove-device.sh`.
The copies in each widget folder only set the app name and defaults, and keep
their own `--help` text. Change the library, not a wrapper.

**Never publish those secrets either.** gitleaks only sees what reaches git, and
a baked key never does. But the key *is* compiled
into the `.prg` and into the generated `<name>-settings.json`, and CI uploads
both of those files while releases publish them.
`.github/scripts/assert-no-credentials.sh` runs in both workflows. The script
fails the build if the compiled `proxyKey` default is non-empty, or if a `.env`
is present in the build tree at all. Keep that check ahead of any step that
uploads an artifact.

## Typecheck levels

Monkey C builds are gated at `-l 1`, which both widgets pass with zero warnings.
Levels 2 and 3 currently surface about 360 'untyped member' findings. Raising the
bar would be welcome, but it is an annotation project. Please do it as its own
PR, rather than mixing it into a behaviour change.

## Pull requests

- Branch off `main`. `main` requires a PR and passing checks.
- Keep commits focused: one concern each, with a message that says why.
- CI must be green: `proxy`, `widgets`, `lint` and `secret-scan`.
- Add a CHANGELOG entry under `## Unreleased` for anything user-visible.

## Releases

Widgets are released by tag. The proxy deploys continuously from `main`.

1. Move the `## Unreleased` entries in CHANGELOG.md under a `## [0.2.0] - <date>`
   heading, and merge that to `main`.
2. Tag the merge commit on `main` and push the tag:

   ```bash
   git tag -a v0.2.0 -m "..." && git push origin v0.2.0
   ```

`release.yml` refuses a tag that is not on `main` or has no CHANGELOG section.
It runs the unit tests, builds the packages, checks that no proxy credential is
baked in, and publishes the release with a `SHA256SUMS` file and a build
provenance attestation. To check a download:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify radar-widget-edge1040.prg -R <owner>/garmin-jma-radar
```

**The signing key.** Store `GARMIN_DEVELOPER_KEY` (the base64-encoded DER) in
the `release` environment, never as a repository secret, and give that
environment a deployment rule that allows only `v*` tags. A workflow edited on
a branch can then never read the key.

```bash
base64 -w0 developer_key.der | gh secret set GARMIN_DEVELOPER_KEY --env release
```

In **Settings → Environments → release**, choose **Deployment branches and
tags → Selected branches and tags**, and add the tag rule `v*`.

A tag attaches these files, per widget and per product in its manifest:

- `<widget>-<device>.prg` – sideloadable. Copy it to `GARMIN/APPS` over USB. It
  works with any signing key, so the ephemeral key CI generates is fine.
- `<widget>.iq` – the Store bundle. You can upload it only when it is signed with
  the key that published the listing. Set `GARMIN_DEVELOPER_KEY` (base64-encoded
  DER) to get a bundle you can actually ship.
- `<widget>-<device>.prg.debug.xml` – the symbol map for that build. A release
  build strips debug info, so a `CIQ_LOG.YML` stack trace cannot be decoded
  without the symbol map, and the map cannot be regenerated after the fact.

None of these files have proxy credentials baked in. CI has no `.env`, so users
set the proxy URL and key in the widget's settings.

**Updating pinned downloads.** CI checks every download against a pinned
SHA-256 or digest. When you bump one, update its pin in the same commit:

- the SDK version and `SDK_SHA256` in `.github/scripts/install-connectiq.sh`
- `ACTIONLINT_SHA256` in `lint.yml` and `GITLEAKS_SHA256` in
  `secret-scan.yml`, from each release's checksums file
- the `ubuntu:22.04@sha256:` digest in `widgets.yml` and `release.yml`, from
  `docker buildx imagetools inspect ubuntu:22.04`

## Reporting bugs

Use the issue templates. For a widget bug, `Garmin/Apps/LOGS/CIQ_LOG.YML` on the
device carries the exception and the stack trace, and is usually the whole
answer. Security issues go through
[private vulnerability reporting](SECURITY.md), not public issues.
