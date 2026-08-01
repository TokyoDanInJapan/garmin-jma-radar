# JMA Rain Radar

Animated, rider-centred rain radar for Garmin Edge devices. It uses JMA's
high-resolution precipitation nowcast (高解像度降水ナウキャスト). **Japan only.**

The project has three parts:

- **`proxy/`** – a Cloudflare Worker. It reads JMA's radar times, composites JMA
  and GSI tiles into one rider-centred PNG per frame, caches the frames and
  serves them to the device.
- **`radar-widget/`** – the Connect IQ widget (Monkey C). It takes a GPS fix,
  asks the proxy for frames and animates them on screen.
- **`speedtest-widget/`** – a small diagnostic Connect IQ widget. It times the
  proxy's `/frames` (`makeWebRequest`) against the fixed-size `/speedtest` asset
  (`makeImageRequest`), so you can compare the Wi-Fi and Bluetooth transport
  paths (see [Connectivity](#connectivity-wi-fi-vs-bluetooth)). It installs
  alongside the radar.

```
garmin-jma-radar/
├── setup.sh               # one-time toolchain setup (distrobox container + SDK + key)
├── docs/                  # SDK install, troubleshooting, demo media
├── proxy/                 # Cloudflare Worker (Node / wrangler)
│   ├── src/
│   │   ├── index.js       #   routes: /frames (list), /tile (PNG), /speedtest, /health
│   │   ├── jma.js         #   JMA endpoint logic
│   │   ├── tilemath.js    #   lon/lat -> z/x/y + pixel offset
│   │   ├── basemap.js     #   GSI base-map tile URLs
│   │   └── composite.js   #   composite 3x3 neighbourhood -> rider-centred PNG
│   └── wrangler.toml
├── radar-widget/          # Connect IQ widget (Monkey C)
│   ├── manifest.xml       # app id, products, permissions
│   ├── monkey.jungle      # build config
│   ├── build.sh           # build the deployable .iq / .prg
│   ├── run-sim.sh         # build + run in the simulator
│   ├── deploy-device.sh   # dev build with .env baked in + copy to a USB device
│   ├── remove-device.sh   # uninstall the widget from a connected device
│   ├── source/            # RainRadarApp / RadarView / RadarDelegate / Util(+Test)
│   └── resources/         # all app resources
│       ├── shared/        # strings, properties, settings (every device)
│       ├── edge1030plus/  # per-device launcher icon (36x36)
│       └── edge1040/      # per-device launcher icon (40x40)
└── speedtest-widget/      # diagnostic widget (build/run-sim/deploy/remove like the
                           #   radar. Reuses radar-widget/.env for the URL + key)
```

## How it works

1. The widget gets a one-shot GPS fix.
2. It calls `GET /frames?lat&lon&z` on the proxy.
3. The proxy reads JMA `targetTimes_N1.json` (observed) and `targetTimes_N2.json`
   (forecast). It returns a **−15…+60 min** window as ordered `/tile?...` URLs:
   up to six frames, in 15-minute steps. Each URL carries its JST valid-time
   `label` and its minutes-from-now `offset`. `frameCount` (1–6) is the Wi-Fi
   maximum. Over Bluetooth the widget throttles to three frames (see
   [Connectivity](#connectivity-wi-fi-vs-bluetooth)).
4. The widget requests each tile as a `makeImageRequest`. The proxy composites a
   rider-centred PNG of 16 colours or fewer (4-bit), a 3×3 tile crop on a GSI
   base map, and caches it immutably.
5. The widget animates the frames on a timer and labels each frame with its valid
   time, for example `21:45 now` or `22:00 +15m`. The on-screen **Wide** and
   **Local** buttons switch the zoom preset.

Device traffic goes over **Wi-Fi when a network is connected, and otherwise
through the phone over Bluetooth**. The Edge has no cellular radio, so at run
time you need a paired phone running Garmin Connect, or a known Wi-Fi network,
with internet access. The loading screen shows which path is in use, for example
`Loading radar (Wi-Fi)...`.

### Connectivity (Wi-Fi vs Bluetooth)

The two paths behave very differently for the image tiles:

- The phone fetches **`/frames`** (JSON, `makeWebRequest`) directly. This is
  quick on either path.
- **`/tile`** (PNG, `makeImageRequest`) is **not** transferred directly. Garmin
  relays it through its image service. On **Wi-Fi** the relay is fast, under a
  second per tile. Over **Bluetooth** it is slow and unreliable: about 20–30 s
  per tile, the documented `BLE_HOST_TIMEOUT` behaviour. A full set can
  therefore take minutes.

Because of that, the widget adapts. On Wi-Fi it loads the full `frameCount`.
Over Bluetooth it throttles to **three frames** (`BLE_FRAME_CAP`), so the
animation appears in reasonable time.

To watch the latency of the two paths live, run the **`speedtest-widget/`** app.
Its image phase pulls the proxy's `/speedtest` asset, a deterministic PNG shaped
like a real frame (about 12 KB, byte-identical on every request), so timings are
comparable across runs and locations. To load a full set quickly, prefer Wi-Fi.
Bluetooth is best for a quick 'is rain near me' check.

---

# Setup

Do this once, in order:

1. **[Deploy the proxy](#1-deploy-the-proxy)** to Cloudflare.
2. **[Build and run the widget](#2-build--run-the-widget)**, then point it at
   your proxy URL.
3. *(optional)* Set up
   **[continuous integration and deployment](#3-continuous-integration--deployment)**
   for the proxy.

## 1. Deploy the proxy

**Prerequisites:** Node 22 or newer (wrangler v4 needs it) and a free Cloudflare
account.

```bash
cd proxy
npm install                 # wrangler, upng-js
npm test                    # optional: unit tests (should be all green)
npx wrangler login          # opens a browser to authorise Cloudflare
```

**Set the auth token.** The proxy fails closed: without `PROXY_TOKEN` it returns
`401` for every request. Generate a random token and store it as a Worker secret.
Never commit the token.

```bash
openssl rand -hex 16                 # generate a token, then copy it
npx wrangler secret put PROXY_TOKEN  # paste it when prompted
```

**Deploy.**

```bash
npx wrangler deploy
# prints your public URL, for example
# https://jma-rain-radar-proxy.<subdomain>.workers.dev
```

Note that URL. You paste it into the widget settings later.

<details>
<summary><strong>Run the proxy locally (optional)</strong></summary>

Worker secrets are not available to `wrangler dev`, so put the same token in
`proxy/.dev.vars` (git-ignored):

```bash
echo "PROXY_TOKEN=<your-token>" > .dev.vars
npx wrangler dev                     # http://localhost:8787
curl "http://localhost:8787/frames?lat=35.68&lon=139.76&z=10&n=6&key=<your-token>"
curl "http://localhost:8787/health"  # -> {"ok":true,"rateLimiter":false} (no token needed)
```
</details>

<details>
<summary><strong>Rate limiting (recommended)</strong></summary>

`/tile` is cheap to call but expensive to serve, so cap the request rate.

**This repo already ships per-IP rate limiting** (60 requests per 60 s) through
the `RATE_LIMITER` binding in `wrangler.toml`, enforced in `src/index.js`. The
limiter activates on `npx wrangler deploy`. Tune `limit` and `period` to taste.
The limiter does nothing when the binding is absent, so `wrangler dev` works
without it.

```toml
# wrangler.toml
[[ratelimits]]
name = "RATE_LIMITER"
namespace_id = "1002"                 # a fresh id (see gotcha below)
simple = { limit = 60, period = 60 } # period must be 10 or 60
```

Two gotchas:
- **Use a fresh `namespace_id`.** A namespace first registered under the older
  `[[unsafe.bindings]]` form deploys as a *no-op* limiter that never enforces.
- **Enforcement is eventually consistent.** Verify with *sequential* requests
  (`curl '…&cb=[1-120]'` → about 60 × `200`, then `429`). A concurrent burst
  races the counter and mostly slips through. That is expected.

If the Worker runs on a custom domain, you can instead add a Cloudflare dashboard
**WAF → Rate limiting** rule on `URI Path contains /tile`. That needs no code
change.
</details>

## 2. Build & run the widget

### Install the Connect IQ SDK

On Ubuntu 24.10 or newer, run this from the repo root:

```bash
./setup.sh      # idempotent: container + SDK + simulator libs + signing key
```

**[docs/connect-iq-sdk.md](docs/connect-iq-sdk.md)** covers VS Code and
plain-Ubuntu installs. It also shows how to create the developer signing key by
hand.

### Run in the simulator

```bash
cd radar-widget
./run-sim.sh                 # -d <device>, --lat/--lon to override
```

`run-sim.sh` **brings the simulator up** with the app loaded. It starts the
simulator if the simulator is not already running, injects a GPS fix (Tokyo by
default, override with `--lat` and `--lon`), side-loads the `.prg` and streams
the device console. The default device is `edge1030plus`. Use `-d <device>` to
change it.

If a simulator is already open, `run-sim.sh` reuses it. To get a fresh one, close
the simulator from its own window first. A forced restart wedges the SDK's debug
port. Then, in the simulator:

1. **Settings → App Settings** → set **Proxy URL** (your `…workers.dev` URL) and
   **Proxy key** (your `PROXY_TOKEN`). *(Or bake both values into the build with
   `radar-widget/.env`. See [Settings](#settings).)*

The widget acquires the fix, fetches frames and animates. To move the position
after launch, use **Simulation → GPS/Position** in the simulator UI.

**Fast inner loop: reload into the open simulator.** Once a simulator is running,
a plain `build.sh` loads the new build straight into it, with no restart. The
usual edit/run cycle is `run-sim.sh` once, then `build.sh` after each change:

```bash
./build.sh -d edge1030plus   # builds, then loads into the running simulator
```

If no simulator is open, `build.sh` only builds. To suppress the auto-load, set
`CIQ_NO_SIM_UPDATE=1`.

> VS Code users can instead press **F5** and pick a device.

### Build a deployable package

```bash
cd radar-widget
./build.sh                   # -> bin/RainRadar.iq   (Connect IQ Store package)
./build.sh -d edge1030plus   # -> bin/RainRadar-edge1030plus.prg  (single device)
./build.sh --help            # all options
```

`RainRadar.iq` contains release builds for every product in `manifest.xml`.
Upload that file to the Connect IQ Store. It is the CLI equivalent of *Monkey C:
Export Project*.

If a simulator is open when you build, `build.sh` also loads the result into it
(see [Run in the simulator](#run-in-the-simulator)). For a store `.iq`,
`build.sh` compiles a single-device `.prg` for the simulator's current device to
load. Set `CIQ_NO_SIM_UPDATE=1` to skip this.

### Run on a real device

Put a dev build on your own Edge with **`deploy-device.sh`**. The script bakes
your `radar-widget/.env` secrets into the build and copies the build over USB:

```bash
cd radar-widget                    # fill in radar-widget/.env first (PROXY_BASE, PROXY_KEY)
./deploy-device.sh           # build edge1030plus, copy to the mounted Edge, eject
```

The script does five things:

- finds the USB-mounted Edge
- builds the widget with `.env` baked in
- copies the `.prg` into `Garmin/Apps/`
- clears any stale on-device settings, so the baked values win
- ejects the device

Use `-d <device>` for another Edge, `--dest <dir>` to point at the Apps folder,
or `--no-eject` to leave the device mounted. The script is Linux-only, because it
uses `udisksctl`. On other platforms, build a `.prg` with
`./build.sh -d <device>`, with `radar-widget/.env` filled in so the config is
baked in, then copy the file into `Garmin/Apps/` yourself.

Then unplug the device and open **Rain Radar JP** from the **widget loop**: swipe
down from the home screen, then left or right. Rain Radar JP is a *widget*, so it
does not appear in the device's Connect IQ Apps menu. It acquires a GPS fix,
fetches frames and animates.

**On-device controls:** the on-screen **Wide** (about 140 km) and **Local**
(about 36 km) buttons switch the zoom preset. A tap elsewhere does nothing, so a
stray touch cannot flip the zoom. After a failure, a tap acts as **Retry**.
**Back** exits.

### Settings

The widget reads these app settings at run time. Set them in the simulator's App
Settings, through Garmin Connect (Connect IQ **Store** installs only, see below),
or bake them into a build with `radar-widget/.env`:

| Setting | Required | Notes |
| --- | --- | --- |
| **Proxy URL** (`proxyBase`) | yes | your `…workers.dev` URL, no trailing slash |
| **Proxy key** (`proxyKey`) | yes | the Worker's `PROXY_TOKEN`, an `openssl rand -hex 16` value. **Not** a Cloudflare API token |
| **Zoom** (`zoom`) | no | 4 (widest) to 11 (street). Default 8, which is the **Local** preset. The **Wide** button selects 6 |
| **Frame count** (`frameCount`) | no | 1 to 6. This is the **Wi-Fi maximum**. Over Bluetooth the widget throttles to three frames |

`radar-widget/.env` (git-ignored) holds `PROXY_BASE` and `PROXY_KEY`. `build.sh`,
`run-sim.sh` and `deploy-device.sh` bake those values into one build only, then
restore the committed defaults afterwards, so secrets never land in git.

**Sideloaded builds compared with Store installs.** A `.prg` that you copy across
manually (a sideload) is not tied to your Garmin account, so it **never gets a
Settings screen in Garmin Connect**. That is a Connect IQ limitation. Bake the
config in instead, which is what `deploy-device.sh` does. Only apps installed
from the Connect IQ **Store** show editable settings in **Garmin Connect →
Devices → your Edge → Connect IQ Apps → Rain Radar JP → Settings**. Either way,
at run time you need a paired phone running Garmin Connect with internet access,
because the Edge has no cellular radio.

### Run the unit tests

`(:test)` functions cover the pure helpers in `source/Util.mc`, plus `FrameCache`
and `FramePipeline`. Those functions compile only into a `--unit-test` build:

```bash
cd radar-widget
monkeyc -d edge1040 -f monkey.jungle -o bin/test.prg -y ../developer_key.der --unit-test
monkeydo bin/test.prg edge1040 -t    # prints PASS/FAIL per test
```

CI runs these tests on every PR (`.github/workflows/widgets.yml`), headless under
Xvfb: 53 tests across the two widgets. Note that `monkeydo` exits non-zero even
when every test passes. The `PASSED`/`FAILED` summary line is therefore the only
reliable signal. See `.github/scripts/run-ciq-tests.sh`.

### Secret scanning

[gitleaks](https://github.com/gitleaks/gitleaks) guards the proxy token and the
Cloudflare credentials. The configuration is in `.gitleaks.toml`. CI runs
gitleaks on every push and PR (`.github/workflows/secret-scan.yml`). Install the
local pre-commit hook as well, so a secret is caught *before* you commit it. The
main risk is `build.sh` baking the proxy token into
`resources/shared/properties.xml` during a build.

```bash
pipx install pre-commit   # or: brew install pre-commit / pip install pre-commit
pre-commit install        # one-time, per clone
pre-commit run --all-files   # optional: scan the whole repo now
```

### Troubleshooting

**[docs/troubleshooting.md](docs/troubleshooting.md)** collects the device,
simulator, proxy and CI symptoms.

## 3. Continuous integration & deployment

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `proxy.yml` | every PR; `proxy/**` pushes to `main` | Typechecks, runs the tests against the coverage thresholds, runs `npm audit` over the production dependencies and does a bundle dry-run. On `main` it deploys to Cloudflare, then smoke-tests `/health`. That smoke test asserts both that the Worker routes and that the `RATE_LIMITER` binding is live. |
| `widgets.yml` | every PR and push | Installs the Connect IQ SDK headlessly, compiles both widgets for every product in their manifests with warnings treated as errors, and runs the 53 Monkey C unit tests in the simulator under Xvfb. |
| `lint.yml` | every PR and push | Runs shellcheck over every `*.sh`, actionlint over the workflows and ESLint over the proxy. |
| `secret-scan.yml` | every PR and push | Runs gitleaks across the full commit history. |
| CodeQL | push + weekly | GitHub default setup. |

Deploys are gated behind the `production` environment, whose branch policy
permits only `main`. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run each
of these checks locally before you push.

**Required GitHub repo secrets** (Settings → Secrets and variables → Actions):

| Secret | What it is | Where to get it |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | Token CI uses to publish the Worker | see below |
| `CLOUDFLARE_ACCOUNT_ID` | Your 32-char hex account id | `npx wrangler whoami` |

**Create the API token:** go to
[dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Token → Create Custom Token**. Give the token **Account · Workers
Scripts · Edit**, and optionally **Account · Account Settings · Read**. Scope it
to your account and create it. Cloudflare shows the token once.

**Store the secrets:**

```bash
CLOUDFLARE_API_TOKEN=<paste> npx wrangler whoami   # verify token + print Account ID
gh secret set CLOUDFLARE_API_TOKEN                  # paste the token
gh secret set CLOUDFLARE_ACCOUNT_ID                 # paste the Account ID
```

`PROXY_TOKEN` is **not** a CI secret. It is a Worker secret, set once with
`wrangler secret put PROXY_TOKEN`, and it persists across deploys.

---

## Attribution & compliance

- **JMA data** is under the **Public Data License v1.0**. Commercial use is
  permitted, but you must give attribution, and processed output must say that it
  is processed. The widget shows a combined credit line,
  `JMA Weather (processed) · GSI Map`. The line is romanised, because device
  fonts lack CJK glyphs unless the device language is Japanese. Keep the credit
  line visible. Carry the full form in the store listing:
  *Source: Japan Meteorological Agency website – https://www.jma.go.jp/*
- **GSI base map** (国土地理院コンテンツ利用規約, under Public Data License v1.0)
  needs a source credit and a link to the tile-list page. It needs no prior
  approval for real-time web or app display. The device shows `GSI Map`. The
  store-listing form carries the required link:
  *Map: Geospatial Information Authority of Japan (地理院タイル) –
  https://maps.gsi.go.jp/development/ichiran.html*
- The app **redisplays JMA's own nowcast**: observed N1 plus JMA's published
  forecast N2, out to +60 min. It does **not** synthesise forecasts and it does
  **not** issue warnings (Weather Service Act, Article 17 and Article 23).

---

## Licence

The code in this repository is licensed under the [MIT License](LICENSE).

This covers the code only. The JMA precipitation data and the GSI base map served
through the app carry their own terms. See **Attribution & compliance** above and
keep the required credits intact.
