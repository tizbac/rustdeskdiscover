# rustdeskdiscover

RustDesk **LAN peer discovery** — find RustDesk clients on your local network
without a remote/relay server. It speaks the same UDP broadcast protocol used by
the RustDesk desktop client (UDP port **21119**): it broadcasts a protobuf
`ping`, and every RustDesk client with **LAN discovery** enabled replies with a
unicast `pong` carrying its RustDesk ID, hostname, MAC, username and platform.

Two implementations live in this repository:

| Component | Where | What it does |
|-----------|-------|--------------|
| Go CLI    | repo root (`main.go`) | One-shot scan for a Linux/macOS desktop: prints the found peers and exits. |
| OpenWrt package set | [`openwrt/`](openwrt/) | Always-on **C++ daemon** + **LuCI web UI** for OpenWrt routers. |

## How discovery works

1. The discoverer sends a protobuf-encoded `ping` (`PeerDiscovery { cmd: "ping" }`)
   on UDP port **21119** to the broadcast address of every active IPv4 subnet
   (plus the multicast group `224.0.0.251`).
2. Each RustDesk client with LAN discovery enabled responds with a unicast
   `pong` (protobuf field 22 → `PeerDiscovery`) containing its ID, hostname, MAC,
   username and platform.
3. Responses are collected for ~3 seconds, deduplicated (by ID, then MAC, then
   source IP), and displayed.

## Go CLI

```sh
go build -o rustdeskdiscover .
./rustdeskdiscover
```

Prints a table like:

```
Found 2 RustDesk client(s):

ID           HOSTNAME                        MAC               IP              PLATFORM
1772049193   desktop-i9hfa5g                 5c:9a:d8:df:ca:7b  192.168.255.180  Windows
239302464    tiziano-ms7e06                  d8:43:ae:43:77:40  192.168.255.10   Linux
```

## OpenWrt

For routers (tested on OpenWrt 25.12.5, mediatek/filogic), two packages:

- **`rustdesk-discoveryd`** — a dependency-free C++ daemon that runs the scan in
  a loop and writes the results to `/tmp/rustdesk_peers.json` (peers not seen for
  ~60 s are dropped).
- **`luci-app-rustdesk-discover`** — a modern LuCI app:
  - JSON `menu.d` entry (*Services → RustDesk Discovery*),
  - an **rpcd ucode** backend (`luci.rustdesk`: `peers`/`restart`),
  - a client-side JS view (auto-refreshing table + *Rescan Now* button).

**Build** (recommended, Docker-based — no host toolchain needed):

```sh
cd openwrt
./build-docker.sh        # writes .apk files into openwrt/bin/
```

**Install** on the router:

```sh
opkg install rustdesk-discoveryd-*.apk luci-app-rustdesk-discover-*.apk
/etc/init.d/rustdesk-discoveryd enable && /etc/init.d/rustdesk-discoveryd start
/etc/init.d/rpcd reload
```

Then open **LuCI → Services → RustDesk Discovery**.

Full build/install/debug documentation, package sources and the manual
(non-Docker) SDK build are in **[`openwrt/README.md`](openwrt/README.md)**.

## Repository layout

```
main.go, decoder_test.go, go.mod    Go CLI (one-shot scan)
openwrt/
  build.sh / build-docker.sh        SDK build scripts (host / Docker)
  docker/                           Arch-based build-environment image + entrypoint
  package/rustdesk-discoveryd/      C++ daemon package (src/, procd init script)
  package/luci-app-rustdesk-discover/  LuCI app (menu.d, acl.d, rpcd ucode backend, JS view)
  README.md                         OpenWrt build + usage docs
```