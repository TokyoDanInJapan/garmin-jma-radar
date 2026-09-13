# JMA Rain Radar

An animated rain radar for Garmin Edge bike computers, centred on the rider. It
uses the high-resolution precipitation nowcast (高解像度降水ナウキャスト) from the
Japan Meteorological Agency (JMA). **It works in Japan only.**

The project has three parts:

- **`proxy/`** is a Cloudflare Worker. It reads the radar times from JMA and
  combines JMA radar tiles with map tiles from the Geospatial Information
  Authority of Japan (GSI). For each frame, it makes one PNG image centred on the
  rider. It caches the frames and serves them to the device.
- **`radar-widget/`** is the Connect IQ widget, written in Monkey C. It gets a
  GPS fix, asks the proxy for frames and animates them on the screen.
- **`speedtest-widget/`** is a small Connect IQ widget for diagnostics. It times
  the proxy's `/frames` list (through `makeWebRequest`) against the fixed-size
  `/speedtest` image (through `makeImageRequest`). Use it to compare the Wi-Fi
  and Bluetooth paths (see [Wi-Fi and Bluetooth](#wi-fi-and-bluetooth)). It
  installs alongside the radar widget.

```
garmin-jma-radar/
├── setup.sh               # one-time toolchain setup (distrobox container + SDK + key)
├── docs/                  # SDK install, troubleshooting
├── proxy/                 # Cloudflare Worker (Node / wrangler)
│   ├── src/
│   │   ├── index.js       #   routes: /frames (list), /tile (PNG), /speedtest, /health
│   │   ├── jma.js         #   JMA endpoint logic
│   │   ├── tilemath.js    #   lon/lat -> z/x/y + pixel offset
│   │   ├── basemap.js     #   GSI base map tile URLs
│   │   └── composite.js   #   combine a 3x3 block of tiles -> rider-centred PNG
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
│       ├── edge1030plus/  # launcher icon for this device (36x36)
│       └── edge1040/      # launcher icon for this device (40x40)
└── speedtest-widget/      # diagnostic widget (same scripts as the radar widget.
                           #   Uses radar-widget/.env for the URL and key)
```

## How it works

1. The widget gets a single GPS fix.
2. It calls `GET /frames?lat&lon&z` on the proxy.
3. The proxy reads the JMA observed times (`targetTimes_N1.json`) and forecast
   times (`targetTimes_N2.json`). It returns up to six `/tile?...` URLs in order,
   one for each 15-minute step from **−15 min to +60 min**. Each URL carries its
   valid time in JST (`label`) and its minutes from now (`offset`).
4. The widget requests each tile with `makeImageRequest`. The proxy combines a
   3×3 block of tiles on a GSI base map into one rider-centred PNG. The PNG has
   16 colours or fewer (4-bit). The proxy caches each PNG as immutable, because
   the image for a given valid time never changes.
5. The widget animates the frames on a timer. It labels each frame with its valid
   time, for example `21:45 now` or `22:00 +15m`. The **Wide** and **Local**
   buttons on the screen change the zoom preset.

`frameCount` (1–6) sets the maximum number of frames on Wi-Fi. Over Bluetooth,
the widget loads three frames at most (see
[Wi-Fi and Bluetooth](#wi-fi-and-bluetooth)).

The device uses **Wi-Fi when it is connected to a network. Otherwise, it goes
through the phone over Bluetooth**. The Edge has no cellular radio. At run time,
it needs internet access through a known Wi-Fi network or a paired phone that
runs Garmin Connect. The loading screen shows which path is in use, for example
`Loading radar (Wi-Fi)...`.

### Wi-Fi and Bluetooth

The two paths give very different speeds for image tiles:

- **`/frames`** (JSON, through `makeWebRequest`) goes directly to the proxy. It
  is fast on both paths.
- **`/tile`** (PNG, through `makeImageRequest`) goes through Garmin's image
  service, which relays each image. On **Wi-Fi**, the relay is fast, at under one
  second for each tile. Over **Bluetooth**, it is slow and unreliable, at about
  20–30 s for each tile. This matches the documented `BLE_HOST_TIMEOUT`
  behaviour. A full set of frames can take minutes.

The widget adapts to the path. On Wi-Fi, it loads the full `frameCount`. Over
Bluetooth, it loads three frames at most (`BLE_FRAME_CAP`), so that the animation
appears in a reasonable time.

To see the delay on each path live, run the **`speedtest-widget/`** app. Its
image test downloads the proxy's `/speedtest` image. This image is a fixed PNG
the same size as a real frame (about 12 KB). The proxy returns the same bytes on
every request, so you can compare timings across runs and places.

Use Wi-Fi to load a full set of frames quickly. Bluetooth is good enough for a
quick check of whether rain is near you.

---

# Setup

Do these steps once, in this order:

1. **[Deploy the proxy](#1-deploy-the-proxy)** to Cloudflare.
2. **[Build and run the widget](#2-build-and-run-the-widget)**, then give it
   your proxy URL.
3. Optionally, set up
   **[continuous integration and deployment](#3-continuous-integration-and-deployment)**
   for the proxy.

## 1. Deploy the proxy

**You need** Node 22 or newer (wrangler v4 needs it) and a free Cloudflare
account.

```bash
cd proxy
npm install                 # wrangler, upng-js
npm test                    # optional: run the unit tests (all must pass)
npx wrangler login          # opens a browser to authorise Cloudflare
```

**Set the auth token.** If `PROXY_TOKEN` is not set, the proxy returns `401` for
every request. Generate a random token and store it as a Worker secret. Never
commit the token.

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

Keep a copy of that URL. You need it for the widget settings later.

<details>
<summary><strong>Run the proxy locally (optional)</strong></summary>

`wrangler dev` cannot read Worker secrets. Put the same token in
`proxy/.dev.vars`, which git ignores:

```bash
echo "PROXY_TOKEN=<your-token>" > .dev.vars
npx wrangler dev                     # http://localhost:8787
curl "http://localhost:8787/frames?lat=35.68&lon=139.76&z=10&n=6&key=<your-token>"
curl "http://localhost:8787/health"  # -> {"ok":true,"rateLimiter":false} (no token needed)
```
</details>

<details>
<summary><strong>Rate limiting (recommended)</strong></summary>

`/tile` is cheap to call but expensive to serve, so limit the request rate.

**This repo already limits requests for each IP address** to 60 requests in
60 s. The `RATE_LIMITER` binding in `wrangler.toml` sets the limit, and
`src/index.js` applies it. The limiter starts to work when you run
`npx wrangler deploy`. Change `limit` and `period` to suit your needs. When the
binding is absent, the limiter does nothing, so `wrangler dev` works without it.

```toml
# wrangler.toml
[[ratelimits]]
name = "RATE_LIMITER"
namespace_id = "1002"                 # a new id (see the notes below)
simple = { limit = 60, period = 60 } # period must be 10 or 60
```

Two points need care:

- **Use a new `namespace_id`.** If a namespace was first registered in the older
  `[[unsafe.bindings]]` form, it deploys as a limiter that never blocks a
  request.
- **The counter is eventually consistent**, so it can fall behind the requests.
  Test with requests *in sequence*. `curl '…&cb=[1-120]'` gives about 60 ×
  `200`, then `429`. Most of a concurrent burst gets through before the counter
  catches up. This is expected.

If the Worker runs on a custom domain, you can use a rule in the Cloudflare
dashboard instead. Add a **WAF → Rate limiting** rule on
`URI Path contains /tile`. This needs no change to the code.
</details>

## 2. Build and run the widget

### Install the Connect IQ SDK

On Ubuntu 24.10 or newer, run this from the repo root:

```bash
./setup.sh      # safe to run again: container + SDK + simulator libs + signing key
```

**[docs/connect-iq-sdk.md](docs/connect-iq-sdk.md)** covers installs with
VS Code and on Ubuntu 22.04 or 24.04. It also shows how to create the developer
signing key by hand.

### Run in the simulator

```bash
cd radar-widget
./run-sim.sh                 # -d <device>, --lat/--lon to override
```

`run-sim.sh` **starts the simulator with the app loaded**. The script does these
steps:

- starts the simulator, if it is not already running
- sets a GPS fix (Tokyo by default, or use `--lat` and `--lon`)
- copies the `.prg` into the simulator (a sideload)
- streams the device console

The default device is `edge1030plus`. To use a different device, add
`-d <device>`.

If a simulator is already open, `run-sim.sh` uses it. To start with a new
simulator, close the open one from its own window. Do not force the simulator to
close, because a forced close blocks the SDK's debug port.

When the simulator runs, go to **Settings → App Settings**. Set **Proxy URL** to
your `…workers.dev` URL, and set **Proxy key** to your `PROXY_TOKEN`. You can
also bake both values into the build with `radar-widget/.env` (see
[Settings](#settings)).

The widget then gets a GPS fix, fetches the frames and animates them. To move the
position after launch, use **Simulation → GPS/Position** in the simulator.

**Load new builds into the open simulator.** When a simulator is running,
`build.sh` loads each new build straight into it, with no restart. For the usual
cycle of edit and run, run `run-sim.sh` once. Then run `build.sh` after each
change:

```bash
./build.sh -d edge1030plus   # builds, then loads into the running simulator
```

If no simulator is open, `build.sh` only builds. To stop the automatic load, set
`CIQ_NO_SIM_UPDATE=1`.

> In VS Code, you can press **F5** and select a device instead.

### Build a deployable package

```bash
cd radar-widget
./build.sh                   # -> bin/RainRadar.iq   (Connect IQ Store package)
./build.sh -d edge1030plus   # -> bin/RainRadar-edge1030plus.prg  (single device)
./build.sh --help            # all options
```

`RainRadar.iq` contains release builds for every product in `manifest.xml`.
Upload this file to the Connect IQ Store. `./build.sh` with no options does the
same as *Monkey C: Export Project* in VS Code.

If a simulator is open when you build, `build.sh` also loads the result into it
(see [Run in the simulator](#run-in-the-simulator)). For a Store `.iq` build,
`build.sh` also compiles a `.prg` for the device that the simulator shows, and
loads that `.prg`. To skip this step, set `CIQ_NO_SIM_UPDATE=1`.

### Run on a real device

To put a development build on your own Edge, use **`deploy-device.sh`**. First,
fill in `PROXY_BASE` and `PROXY_KEY` in `radar-widget/.env`. Then run the
script:

```bash
cd radar-widget
./deploy-device.sh           # build edge1030plus, copy to the mounted Edge, eject
```

The script does these steps:

- finds the Edge that is mounted over USB
- builds the widget with the `.env` values baked in
- copies the `.prg` into `Garmin/Apps/`
- deletes old settings on the device, so that the baked-in values apply
- ejects the device

The script has these options:

- `-d <device>` builds for a different Edge model.
- `--dest <dir>` sets the path to the Apps folder.
- `--no-eject` leaves the device mounted.

The script works on Linux only, because it uses `udisksctl`. On other platforms,
fill in `radar-widget/.env` and build a `.prg` with `./build.sh -d <device>`.
Then copy the file into `Garmin/Apps/` yourself.

Unplug the device. Open **Rain Radar JP** from the **widget loop**. To get
there, swipe down from the home screen, then swipe left or right. Rain Radar JP
is a *widget*, so it is not in the Connect IQ Apps menu on the device. The widget
gets a GPS fix, fetches the frames and animates them.

**Controls on the device:**

- **Wide** (about 140 km) and **Local** (about 36 km) change the zoom preset.
- A tap anywhere else does nothing, so an accidental touch cannot change the
  zoom.
- After a failure, tap the screen to try again.
- **Back** closes the widget.

### Settings

The widget reads these settings at run time. You can set them in three ways:

- in the simulator, under **App Settings**
- in Garmin Connect, for Store installs only (see below)
- in a build, baked in from `radar-widget/.env`

| Setting | Required | Notes |
| --- | --- | --- |
| **Proxy URL** (`proxyBase`) | yes | Your `…workers.dev` URL, with no slash at the end. |
| **Proxy key** (`proxyKey`) | yes | The Worker's `PROXY_TOKEN` (the `openssl rand -hex 16` value). This is not your Cloudflare API token. |
| **Zoom** (`zoom`) | no | From 4 (widest) to 11 (street level). The default is 8, which is the **Local** preset. **Wide** selects 6. |
| **Frame count** (`frameCount`) | no | From 1 to 6. This is the maximum on Wi-Fi. Over Bluetooth, the widget loads three frames at most. |

`radar-widget/.env` holds `PROXY_BASE` and `PROXY_KEY`, and git ignores it.
`build.sh`, `run-sim.sh` and `deploy-device.sh` bake those values into one build
only. The scripts then restore the committed defaults, so the secrets never go
into git.

**Sideloaded builds and Store installs.** A `.prg` that you copy to the device by
hand (a sideload) is not linked to your Garmin account. As a result, a sideloaded
widget **never gets a Settings screen in Garmin Connect**. This is a limit of
Connect IQ. Bake the settings into the build instead, as `deploy-device.sh` does.
Only apps from the Connect IQ **Store** show settings that you can change, in
**Garmin Connect → Devices → your Edge → Connect IQ Apps → Rain Radar JP →
Settings**.

### Run the unit tests

The unit tests are `(:test)` functions. They cover the pure helper functions in
`source/Util.mc`, and also `FrameCache` and `FramePipeline`. The tests compile
only into a `--unit-test` build:

```bash
cd radar-widget
monkeyc -d edge1040 -f monkey.jungle -o bin/test.prg -y ../developer_key.der --unit-test
monkeydo bin/test.prg edge1040 -t    # prints PASS/FAIL per test
```

CI runs the 53 tests for the two widgets on every pull request (PR). The tests
run under Xvfb, with no physical display (`.github/workflows/widgets.yml`).
`monkeydo` exits with a non-zero code even when all the tests pass. Only the
`PASSED` or `FAILED` summary line tells you the result. See
`.github/scripts/run-ciq-tests.sh`.

### Secret scanning

[gitleaks](https://github.com/gitleaks/gitleaks) looks for the proxy token and
the Cloudflare credentials in commits. Its configuration is in `.gitleaks.toml`.
CI runs gitleaks on every push and PR (`.github/workflows/secret-scan.yml`).
Also install the local pre-commit hook, so that gitleaks finds a secret *before*
you commit it. The main risk is that `build.sh` writes the proxy token into
`resources/shared/properties.xml` during a build.

```bash
pipx install pre-commit   # or: brew install pre-commit / pip install pre-commit
pre-commit install        # once for each clone
pre-commit run --all-files   # optional: scan the whole repo now
```

### Troubleshooting

**[docs/troubleshooting.md](docs/troubleshooting.md)** lists symptoms and fixes
for the device, the simulator, the proxy and CI.

## 3. Continuous integration and deployment

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `proxy.yml` | Every PR, and every push to `main` that changes `proxy/**` | Checks the types and runs the tests against the coverage thresholds. Runs `npm audit` on the production dependencies and does a dry run of the bundle. On `main`, it then deploys to Cloudflare and smoke-tests `/health`. The smoke test checks that the Worker routes requests and that the `RATE_LIMITER` binding is live. |
| `widgets.yml` | Every PR and push | Installs the Connect IQ SDK with no display. Compiles both widgets for every product in their manifests, and treats warnings as errors. Runs the 53 Monkey C unit tests in the simulator under Xvfb. |
| `lint.yml` | Every PR and push | Runs shellcheck on every `*.sh` file, actionlint on the workflows and ESLint on the proxy. |
| `secret-scan.yml` | Every PR and push | Runs gitleaks on the full commit history. |
| CodeQL | Every push, and weekly | Runs GitHub's default code scanning setup. |

A deploy needs the `production` environment, and the branch policy for that
environment allows only `main`. [CONTRIBUTING.md](CONTRIBUTING.md) shows how to
run each of these checks locally before you push.

**Add these GitHub repository secrets** in **Settings → Secrets and variables →
Actions**:

| Secret | What it is | Where to get it |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | The token that CI uses to deploy the Worker | See below |
| `CLOUDFLARE_ACCOUNT_ID` | Your account ID (32 hexadecimal characters) | `npx wrangler whoami` |

**Create the API token:**

1. Go to
   [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens).
2. Select **Create Token → Create Custom Token**.
3. Give the token the **Account · Workers Scripts · Edit** permission. You can
   also add **Account · Account Settings · Read**.
4. Limit the token to your account, then create it.
5. Copy the token. Cloudflare shows it only once.

**Store the secrets:**

```bash
CLOUDFLARE_API_TOKEN=<paste> npx wrangler whoami   # verify token + print Account ID
gh secret set CLOUDFLARE_API_TOKEN                  # paste the token
gh secret set CLOUDFLARE_ACCOUNT_ID                 # paste the Account ID
```

`PROXY_TOKEN` is a Worker secret, not a CI secret. You set it once with
`wrangler secret put PROXY_TOKEN`, and it stays in place across deploys.

---

## Attribution and compliance

- **JMA data** is under the **Public Data License v1.0**. You can use it
  commercially, but you must credit the source and label processed output as
  processed. The widget shows the combined credit line
  `JMA Weather (processed) · GSI Map`. The line uses Latin letters, because
  device fonts have no Japanese characters unless the device language is
  Japanese. Keep the credit line visible. Put the full credit in the store
  listing:
  *Source: Japan Meteorological Agency website – https://www.jma.go.jp/*
- The **GSI base map** is under the GSI terms of use (国土地理院コンテンツ利用規約),
  which use the Public Data License v1.0. The terms need a source credit and a
  link to the tile list page. Real-time display in a website or app needs no
  approval in advance. The device shows `GSI Map`. The store listing carries the
  required link:
  *Map: Geospatial Information Authority of Japan (地理院タイル) –
  https://maps.gsi.go.jp/development/ichiran.html*
- The app **only shows JMA's own nowcast again**. This is the observed data (N1)
  and JMA's published forecast (N2), up to +60 min. The app makes no forecasts of
  its own and issues no warnings (see the Weather Service Act, Articles 17
  and 23).

---

## Licence

The code in this repository is licensed under the [MIT License](LICENSE).

The licence covers the code only. The JMA precipitation data and the GSI base map
in the app have their own terms. See **Attribution and compliance** above, and
keep the required credits in place.
