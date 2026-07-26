# Contributing

Thanks for taking a look. This is a small project with a narrow scope -- a rain
radar for Garmin Edge devices, in Japan -- so the most useful contributions are
bug reports from real rides, and fixes that keep the moving parts simple.

## Scope

**In scope:** correctness and reliability of the radar, proxy caching and cost,
Connect IQ device support, docs.

**Out of scope:** weather sources outside Japan (the JMA nowcast is the whole
point), and anything that requires the proxy to store user data. The proxy
deliberately keeps no state beyond edge cache entries keyed on tile geometry.

## Getting set up

- **Proxy only** (`proxy/`): Node 22+. `cd proxy && npm ci`. No Garmin toolchain
  needed.
- **Widgets** (`radar-widget/`, `speedtest-widget/`): see
  [docs/connect-iq-sdk.md](docs/connect-iq-sdk.md). On Ubuntu 24.10+, `./setup.sh`
  from the repo root does everything.

Install the pre-commit hooks once per clone -- they run the same gitleaks,
shellcheck and actionlint checks CI does:

```bash
pipx install pre-commit   # or brew / pip
pre-commit install
pre-commit run --all-files
```

## Running the checks locally

Everything CI enforces, you can run yourself:

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
constraint behind a decision -- why the cache key is tile geometry rather than
raw lat/lon, why `monkeydo`'s exit code can't be trusted, why the base resource
path can't point at `resources/`. Match that. Don't add comments that restate the
code.

**JMA specifics stay in `proxy/src/jma.js`.** Those endpoints are undocumented
and will change without notice; one file should absorb that.

**The device tile size is a cross-project contract.** `DEVICE_TILE_SIZE` (288) is
duplicated in `proxy/src/index.js`, `radar-widget/source/RadarView.mc` and
`speedtest-widget/source/SpeedTestView.mc`. Change all three together.

**Frame count is bounded by device memory.** `MAX_FRAMES = 6` in `jma.js` isn't
arbitrary -- a 7th 288px frame OOMs the widget mid-load.

**Never commit secrets.** `build.sh` bakes `PROXY_BASE`/`PROXY_KEY` from a
git-ignored `.env` into `resources/shared/properties.xml` for the duration of a
build and restores it afterwards. That restore is the single most dangerous thing
in the repo; gitleaks runs pre-commit and in CI because of it.

## Typecheck levels

Monkey C builds are gated at `-l 1`, which both widgets pass with zero warnings.
Levels 2 and 3 currently surface ~360 "untyped member" findings. Raising the bar
would be welcome, but it's an annotation project -- please do it as its own PR
rather than mixing it into a behaviour change.

## Pull requests

- Branch off `main`; `main` requires a PR and passing checks.
- Keep commits focused -- one concern each, with a message that says why.
- CI must be green: `proxy`, `widgets`, `lint`, `secret-scan`.
- Add a CHANGELOG entry under `## Unreleased` for anything user-visible.

## Releases

Widgets are released by tag; the proxy deploys continuously from `main`.

```bash
git tag -a v0.2.0 -m "..." && git push origin v0.2.0
```

That builds both `.iq` packages and attaches them to a GitHub Release. Store
uploads need the project's real developer key in the `GARMIN_DEVELOPER_KEY`
secret (base64-encoded DER) -- without it the workflow still builds, but the
packages are sideload-only.

## Reporting bugs

Use the issue templates. For a widget bug, `Garmin/Apps/LOGS/CIQ_LOG.YML` on the
device carries the exception and stack trace and is usually the whole answer.
Security issues go through [private vulnerability reporting](SECURITY.md), not
public issues.
