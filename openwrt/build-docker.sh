#!/usr/bin/env bash
#
# build-docker.sh - Build the RustDesk Discovery OpenWrt packages with Docker
#                   using an Arch Linux based SDK build environment.
#
# Usage:
#   ./build-docker.sh [SDK_URL]
#
#   SDK_URL  (optional) OpenWrt SDK tarball URL. Defaults to the
#            mediatek/filogic 25.12.5 SDK.
#
# Output:
#   The built .apk (or .ipk on older releases) files are written to ./bin/.
#
# The build runs entirely inside a container, so it works regardless of the
# host OS/toolchain. Only Docker is required on the host.

set -euo pipefail

IMAGE="rustdesk-openwrt-build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_SDK_URL="https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_URL="${1:-$DEFAULT_SDK_URL}"

OUTDIR="$SCRIPT_DIR/bin"

command -v docker >/dev/null 2>&1 || { echo "docker is required"; exit 1; }

mkdir -p "$OUTDIR"

# ---------------------------------------------------------------------------
# Build the image (only when the Dockerfile changes)
# ---------------------------------------------------------------------------
if [ -z "$(docker images -q "$IMAGE")" ]; then
    echo "[*] Building image $IMAGE (first time only)"
    docker build -t "$IMAGE" -f "$SCRIPT_DIR/docker/Dockerfile" "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Run the build. Mount the package sources and the output directory.
# The SDK itself lives in a persistent named volume so that re-runs reuse the
# downloaded SDK, installed feeds and compiled build_dir/staging_dir.
# ---------------------------------------------------------------------------
SDK_VOLUME="rustdesk-openwrt-sdk"
echo "[*] Building packages in container (SDK: $SDK_URL)"
echo "[*] SDK cache volume: $SDK_VOLUME"
echo "[*] Output: $OUTDIR"

docker run --rm \
    -v "$SDK_VOLUME":/opt/sdk \
    -v "$SCRIPT_DIR/package":/src/packages:ro \
    -v "$OUTDIR":/out \
    -e SDK_URL="$SDK_URL" \
    -e JOBS="${JOBS:-}" \
    "$IMAGE" "$SDK_URL"

echo
echo "[*] Done. Packages are in: $OUTDIR"
echo "    opkg install $OUTDIR/rustdesk-discoveryd* "
echo "    opkg install $OUTDIR/luci-app-rustdesk-discover*"
echo "    /etc/init.d/rustdesk-discoveryd enable && /etc/init.d/rustdesk-discoveryd start"
