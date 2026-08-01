# Installing the Connect IQ SDK

Everything here is one-time setup for building the two Monkey C widgets. If you
only touch `proxy/`, you need none of it.

Pick **one** of these options.

## Option A – VS Code (simplest, all platforms)

Install the **Monkey C** extension (Garmin). Then run *Connect IQ: Open SDK
Manager* and download a recent SDK, plus the device profiles you target
(`edge1030plus`, `edge1040`). You can build and run entirely from VS Code: press
**F5**.

## Option B – Ubuntu 22.04 / 24.04 CLI

```bash
# 1. Java (the monkeyc compiler runs on Java):
sudo apt update && sudo apt install -y openjdk-17-jdk

# 2. Simulator runtime libraries:
sudo apt install -y libwebkit2gtk-4.1-0 libusb-1.0-0 libpng16-16   # 24.04
# sudo apt install -y libwebkit2gtk-4.0-37 libusb-1.0-0 libpng16-16  # 22.04

# 3. SDK Manager (GUI): download from
#    https://developer.garmin.com/connect-iq/sdk/ , unzip, and run it.
~/Downloads/connectiq-sdk-manager-linux/bin/sdkmanager
#    Sign in, install the latest SDK, download the edge* device profiles.
#    Everything installs under ~/.Garmin/ConnectIQ/.
```

The `build.sh` and `run-sim.sh` scripts discover the SDK automatically from
`~/.Garmin/ConnectIQ/current-sdk.cfg`, so you need no `PATH` setup.

## Option C – Ubuntu 24.10 / 25.x / 26.04 CLI (container)

Garmin still links the old `webkit2gtk-4.0` and `libsoup2.4` libraries that
Ubuntu removed after 22.04, so a host install fails on newer releases. The
toolchain runs in an Ubuntu 22.04 [distrobox](https://distrobox.it/) container
instead, which shares your home directory and your display.

First download the Linux SDK Manager from
<https://developer.garmin.com/connect-iq/sdk/> and unzip it under `~/Downloads`.
Then run the bootstrap script from the repo root:

```bash
./setup.sh
```

`setup.sh` is idempotent and does the whole one-time setup. It installs `podman`
and `distrobox` on the host, creates the `garmin` container, installs the SDK and
the simulator libraries inside the container, launches the SDK Manager for you to
sign in and install the SDK, and generates a signing key if you do not have one.
To override the container name, run `CIQ_BOX=<name> ./setup.sh`. The script
serves both widgets, because they share one toolchain.

After that, run `build.sh` and `run-sim.sh` **from the host as usual**. They
detect that they are outside the container and re-enter the `garmin` container
automatically. The simulator GUI still renders on your host display. To bypass
the automatic re-entry, set `CIQ_NO_BOX=1`.

## Create a developer key (one-time)

`setup.sh` does this for you. To do it by hand:

```bash
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER \
    -in developer_key.pem -out developer_key.der -nocrypt
```

Keep `developer_key.der` at the repo root. The file is git-ignored. In VS Code,
register the key through *Connect IQ: Configure Monkey C*. The CLI scripts use it
automatically.

Only Connect IQ **Store** uploads need a stable key. CI generates a throwaway key
per run (see `.github/scripts/install-connectiq.sh`).

## How CI does it

`.github/workflows/widgets.yml` installs the same SDK headlessly and runs the
Monkey C unit tests in the simulator under Xvfb. One point is worth knowing if
you ever debug that workflow. Garmin publishes the SDK itself at a public URL,
but **not** the per-device profiles. The SDK Manager pulls those profiles from an
authenticated, non-public service. Because `monkeyc` cannot build without
`-d <device>`, CI sources the device profiles from a pinned third-party archive.
See the header comment in `.github/scripts/install-connectiq.sh`.
