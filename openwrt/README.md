# RustDesk Discovery for OpenWrt + LuCI

A companion to the Go `rustdeskdiscover` tool, specifically for OpenWrt routers.
It consists of two OpenWrt packages:

- **`rustdesk-discoveryd`** — a dependency-free **C++ daemon** that performs
  RustDesk LAN peer discovery and stores results in `/tmp/rustdesk_peers.json`.
- **`luci-app-rustdesk-discover`** — a **LuCI** web UI (JSON **menu.d** entry +
  **rpcd ucode** backend) that shows the discovered RustDesk peers and lets
  you rescan. The page appears under **Services → RustDesk Discovery**.

## How discovery works

Both packages share the same protocol used by the RustDesk desktop client:

1. The daemon broadcasts a protobuf-encoded `ping` (`PeerDiscovery { cmd: "ping" }`)
   on UDP port **21119** to every active IPv4 subnet (including the VPN tunnel).
2. Any RustDesk client with LAN discovery enabled replies with a unicast `pong`
   carrying its RustDesk **ID**, **hostname**, **MAC**, **username** and **platform**.
3. The daemon deduplicates by client ID/MAC, tracks last-seen, and writes JSON to
   `/tmp/rustdesk_peers.json` (peers not seen for 60s are dropped).

The LuCI controller exposes this file over an authenticated JSON endpoint and the
client-side JS view renders it as a table with live auto-refresh.

## Building with the OpenWrt SDK

### One-command Docker build (recommended)

`build-docker.sh` runs the whole SDK build inside an **Arch Linux** container,
so it never depends on the host OS/toolchain (Debian/Ubuntu hosts commonly fail
the OpenWrt host-prereq checks because of `git`/`unzip`/`python3-dev` etc.):

```sh
./build-docker.sh [SDK_URL]
```

- Defaults to the SDK URL baked into the script
  (`25.12.5` / `mediatek/filogic`), or pass any SDK tarball URL as the first arg.
- Builds the image once (first run), then runs the build and writes the resulting
  `.apk`/`.ipk` into `./bin/`.
- The SDK lives in a **persistent Docker volume** (`rustdesk-openwrt-sdk`), so:
  - the *first* run is slow: it downloads the SDK (~240 MB), clones all OpenWrt
    feeds, stamps the one-time U-Boot device prereq pass, and compiles the whole
    cross-toolchain + luci-base dependency tree (≈1–2 h). Build with `JOBS=N` to
    speed it up;
  - *subsequent* runs are fast — only the changed packages are rebuilt.
- The controller/uboot/atf device variants are force-disabled in `.config`, so no
  extra per-device bootloader builds happen after the one-time prereq stamping.

### Docker build — manual commands (what `build-docker.sh` runs)

```sh
# 1. Build the build-environment image (only once)
docker build -t rustdesk-openwrt-build -f docker/Dockerfile .

# 2. Run the build. The SDK is cached in the persistent volume so re-runs are fast.
mkdir -p bin
docker run --rm \
    -v rustdesk-openwrt-sdk:/opt/sdk \
    -v "$PWD/package":/src/packages:ro \
    -v "$PWD/bin":/out \
    -e SDK_URL="https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst" \
    rustdesk-openwrt-build

# 3. The build outputs land in ./bin/. Install them on the router:
opkg install bin/rustdesk-discoveryd_*.apk
opkg install bin/luci-app-rustdesk-discover_*.apk
/etc/init.d/rustdesk-discoveryd enable && /etc/init.d/rustdesk-discoveryd start
```

Pre-requisite on the host: only **Docker** (the container provides gcc/make/python/
swig/git/unzip — everything the OpenWrt build needs).

### One-command build script (old, host-dependent)

`build.sh` downloads the SDK, sets up feeds, configures, builds both packages and
collects the resulting files into `./bin`:

```sh
./build.sh [SDK_URL] [WORKDIR]
```

Examples:

```sh
# default SDK (mediatek/filogic 25.12.5)
./build.sh

# a specific SDK URL
./build.sh \
  https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/openwrt-sdk-24.10.5-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.xz

# specify a work directory (defaults to ./sdk-work)
./build.sh "https://..." ./my-workdir
```

The script is idempotent — an already-extracted SDK in `WORKDIR` is reused, so
subsequent runs are fast (only the package sources are re-copied and rebuilt).

Notes:
- **This script only works if the host already has a correct OpenWrt build
  environment.** On Debian/Ubuntu (and/or with a broken `python3-dev`), the SDK's
  host-prereq pass fails — use the Docker build above instead.
- The first run installs the LuCI/base/packages feeds and runs a **one-time**
  prereq pass (U-Boot device checks), which can take several minutes. Later runs
  skip this.
- On OpenWrt ≥ 24.10 the default package manager is **apk** and the output files
  are `.apk`; on older releases they are `.ipk`. `build.sh` copies whichever it finds.

### Manual build inside an existing SDK

```sh
# in your OpenWrt checkout / SDK
cp -r package/rustdesk-discoveryd        package/
cp -r package/luci-app-rustdesk-discover package/
./scripts/feeds update -a && ./scripts/feeds install -a
make package/rustdesk-discoveryd/compile
make package/luci-app-rustdesk-discover/compile
```

Or enable in `make menuconfig`:

- `Network -> RustDesk -> rustdesk-discoveryd` (or `Network -> rustdesk-discoveryd`)
- `LuCI -> Applications -> luci-app-rustdesk-discover`

Build the firmware or just the resulting packages and install them.

## Installing manually (`.apk`/`.ipk`)

```sh
opkg install rustdesk-discoveryd_*.apk      # or .ipk on older releases
opkg install luci-app-rustdesk-discover_*.apk
/etc/init.d/rustdesk-discoveryd enable
/etc/init.d/rustdesk-discoveryd start
```

## Usage

Open LuCI → **Services → RustDesk Discovery**. The page shows the daemon status,
the date of the last update, a **Rescan Now** button, and a table of discovered peers
with live auto-refresh.

## Running the daemon on a plain host (no OpenWrt)

For testing on a Linux desktop/laptop without OpenWrt:

```sh
g++ -O2 -Wall -o rustdesk-discoveryd rustdesk-discoveryd.cpp
./rustdesk-discoveryd --once --out ./peers.json
cat peers.json
```

`--once` runs a single scan then exits; `--out FILE` overrides the output path.

## Files

```
build.sh                                # one-command SDK build script (host-dependent)
build-docker.sh                         # Docker build wrapper (recommended)
docker/Dockerfile                       # Arch-based build-environment image
docker/entrypoint.sh                    # runs the SDK build inside the container
package/rustdesk-discoveryd/            # C++ daemon package
  src/rustdesk-discoveryd.cpp           # the daemon (std-only, no deps)
  files/rustdesk-discoveryd.init        # procd init script
package/luci-app-rustdesk-discover/     # LuCI package
  root/usr/share/luci/menu.d/           # JSON menu entry (Services -> RustDesk Discovery)
  root/usr/share/rpcd/ucode/rustdesk.uc # rpcd ucode backend (luci.rustdesk: peers/restart)
  root/usr/share/rpcd/acl.d/            # ACL granting read + rescan rights
  htdocs/.../view/rustdesk/peers.js     # client-side peers table view
```

