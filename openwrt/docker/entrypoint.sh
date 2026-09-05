#!/usr/bin/env bash
#
# entrypoint.sh - runs inside the Docker container to build the OpenWrt packages.
#
# Mounts expected from the host (see build-docker.sh):
#   /opt/sdk       (rw, persistent volume) -> SDK cache, reused across runs
#   /src/packages  (ro)                    -> the local package/ directory
#   /out           (rw)                    -> built *.apk/*.ipk are written here
#   SDK_URL        (env) -> URL of the OpenWrt SDK tarball (default below)
#
# Idempotent: on re-runs the downloaded/extracted SDK, installed feeds and the
# compiled build_dir/staging_dir are reused, so only changed packages rebuild.
#
# Usage (first positional arg overrides SDK_URL):
#   entrypoint.sh [SDK_URL]
set -euo pipefail

DEFAULT_SDK_URL="https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst"

SDK_URL="${1:-${SDK_URL:-$DEFAULT_SDK_URL}}"
SRC=/src/packages
OUT=/out
CACHE=/opt/sdk
STAMP="$CACHE/.feeds-installed"
JOBS="${JOBS:-$(nproc)}"

log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$SRC/rustdesk-discoveryd" ] || die "package source not mounted at $SRC"
mkdir -p "$OUT" "$CACHE"

# ---------------------------------------------------------------------------
# 1. Download + extract the SDK (only if not cached)
# ---------------------------------------------------------------------------
SDK_DIR="$(ls -d "$CACHE"/openwrt-sdk-* 2>/dev/null | head -n1 || true)"

if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/Makefile" ]; then
	log "Downloading SDK: $SDK_URL"
	curl -fSL --retry 3 -o "$CACHE/sdk.tar.zst" "$SDK_URL"

	log "Extracting SDK..."
	case "$SDK_URL" in
		*.zst) tar --zstd -xf "$CACHE/sdk.tar.zst" -C "$CACHE" ;;
		*.xz)  tar -xJf  "$CACHE/sdk.tar.zst" -C "$CACHE" ;;
		*)     die "unsupported SDK archive format: $SDK_URL" ;;
	esac
	rm -f "$CACHE/sdk.tar.zst"

	SDK_DIR="$(ls -d "$CACHE"/openwrt-sdk-* 2>/dev/null | head -n1)"
fi
[ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/Makefile" ] || die "failed to locate extracted SDK at $CACHE"
cd "$SDK_DIR"
log "SDK at: $SDK_DIR (cached)"

# ---------------------------------------------------------------------------
# 2. Feeds (luci + base + packages) - skipped once installed
# ---------------------------------------------------------------------------
if [ ! -f "$STAMP" ]; then
	log "Updating + installing feeds (first run only)..."
	./scripts/feeds update -a
	./scripts/feeds install -a
	touch "$STAMP"
else
	log "Feeds already installed - skipping"
fi

# ---------------------------------------------------------------------------
# 3. Copy our package sources into the SDK
# ---------------------------------------------------------------------------
log "Installing our packages into the SDK..."
mkdir -p package
rm -rf package/rustdesk-discoveryd package/luci-app-rustdesk-discover
cp -r "$SRC/rustdesk-discoveryd"        package/
cp -r "$SRC/luci-app-rustdesk-discover" package/

# ---------------------------------------------------------------------------
# 4. Configure: enable our packages. Disable the bootloader/ATF device
#    variants so the slow per-device U-Boot prereq/built is skipped.
# ---------------------------------------------------------------------------
log "Configuring..."
cat > .config << 'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_generic=y
CONFIG_PACKAGE_rustdesk-discoveryd=y
CONFIG_PACKAGE_luci-app-rustdesk-discover=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_libstdcpp=y
CONFIG_PACKAGE_uboot-mediatek=n
CONFIG_PACKAGE_atf-mediatek=n
EOF
make defconfig > /dev/null 2>&1 || die "defconfig failed"
# disable all per-board uboot/atf variants selected by the device defaults
sed -i -E 's/^(CONFIG_PACKAGE_(uboot-mediatek|atf-mediatek)[^=]*)=.*/\1=n/' .config

log "Building packages (jobs=$JOBS)..."
make -j"$JOBS" package/rustdesk-discoveryd/compile V=cs || die "failed to build rustdesk-discoveryd"
make -j"$JOBS" package/luci-app-rustdesk-discover/compile V=cs || die "failed to build luci-app-rustdesk-discover"

# ---------------------------------------------------------------------------
# 5. Collect artifacts
# ---------------------------------------------------------------------------
log "Collecting packages into $OUT"
rm -f "$OUT"/rustdesk-discoveryd.* "$OUT"/luci-app-rustdesk-discover.* 2>/dev/null || true

FOUND=0
while read -r f; do
	cp -v "$f" "$OUT/"
	FOUND=1
done < <(find bin -type f \( -name 'rustdesk-discoveryd*.apk' -o -name 'rustdesk-discoveryd*.ipk' \
	-o -name 'luci-app-rustdesk-discover*.apk' -o -name 'luci-app-rustdesk-discover*.ipk' \) 2>/dev/null)

if [ "$FOUND" = "1" ]; then
	log "DONE. Packages are in $OUT"
else
	log "WARNING: no packages found under bin/ - check the build log above."
fi