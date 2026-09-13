# Installing the Connect IQ SDK

You need this setup once, to build the two Monkey C widgets. If you work only on
`proxy/`, you do not need it.

Choose **one** of these options.

## Option A: VS Code (simplest, all platforms)

1. Install the **Monkey C** extension from Garmin.
2. Run *Connect IQ: Open SDK Manager*.
3. Download a recent SDK and the profiles for your target devices
   (`edge1030plus` and `edge1040`).

You can then build and run the widgets from VS Code. Press **F5** to start.

## Option B: Ubuntu 22.04 or 24.04 (command line)

```bash
# 1. Java (the monkeyc compiler runs on Java):
sudo apt update && sudo apt install -y openjdk-17-jdk

# 2. Simulator runtime libraries:
sudo apt install -y libwebkit2gtk-4.1-0 libusb-1.0-0 libpng16-16   # 24.04
# sudo apt install -y libwebkit2gtk-4.0-37 libusb-1.0-0 libpng16-16  # 22.04

# 3. SDK Manager (GUI): download it from
#    https://developer.garmin.com/connect-iq/sdk/ , unzip it and run it.
~/Downloads/connectiq-sdk-manager-linux/bin/sdkmanager
#    Sign in, install the latest SDK and download the edge* device profiles.
#    Everything installs under ~/.Garmin/ConnectIQ/.
```

`build.sh` and `run-sim.sh` find the SDK automatically through
`~/.Garmin/ConnectIQ/current-sdk.cfg`, so you do not need to change `PATH`.

## Option C: Ubuntu 24.10, 25.x or 26.04 (container)

The Garmin tools still need the old `webkit2gtk-4.0` and `libsoup2.4` libraries.
Ubuntu removed these libraries after 22.04, so an install directly on a newer
release fails. Instead, the tools run in an Ubuntu 22.04
[distrobox](https://distrobox.it/) container. The container shares your home
directory and your display.

First, download the Linux SDK Manager from
<https://developer.garmin.com/connect-iq/sdk/> and unzip it into `~/Downloads`.
Then run the setup script from the repo root:

```bash
./setup.sh
```

`setup.sh` does all of the one-time setup, and you can safely run it again. The
script does these steps:

- installs `podman` and `distrobox` on the host
- creates the `garmin` container
- installs the libraries for the SDK and the simulator in the container
- starts the SDK Manager, so that you can sign in and install the SDK
- generates a signing key, if you do not have one

To use a different container name, run `CIQ_BOX=<name> ./setup.sh`. The two
widgets share one toolchain, so one run of the script sets up both.

After setup, run `build.sh` and `run-sim.sh` **on the host as usual**. Each
script finds that it is outside the container and runs itself again inside the
`garmin` container. The simulator window still shows on your host display. To
stop the scripts from entering the container, set `CIQ_NO_BOX=1`.

## Create a developer key

`setup.sh` creates the key for you. To create it by hand, run:

```bash
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER \
    -in developer_key.pem -out developer_key.der -nocrypt
```

Keep `developer_key.der` in the repo root. Git ignores this file. In VS Code,
register the key with *Connect IQ: Configure Monkey C*. The command-line scripts
find the key automatically.

Only uploads to the Connect IQ **Store** need a key that stays the same. CI
generates a new temporary key for each run (see
`.github/scripts/install-connectiq.sh`).

## How CI installs the SDK

`.github/workflows/widgets.yml` installs the same SDK with no display. It then
runs the Monkey C unit tests in the simulator under Xvfb.

If you debug that workflow, know where the device profiles come from. Garmin
publishes the SDK at a public URL, but it does **not** publish the device
profiles. The SDK Manager downloads the profiles from a private service that
needs a sign-in. `monkeyc` cannot build without `-d <device>`, so CI gets the
device profiles from a pinned third-party archive. The header comment in
`.github/scripts/install-connectiq.sh` gives the details.
