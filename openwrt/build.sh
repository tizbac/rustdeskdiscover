#!/usr/bin/env bash
#
# build.sh - Build the RustDesk Discovery OpenWrt packages with a single command.
#
# Usage:
#   ./build.sh [SDK_URL] [WORKDIR]
#
# Arguments:
#   SDK_URL   (optional) URL of the OpenWrt SDK tarball (.tar.zst/.tar.xz) to build with.
#             Defaults to the mediatek/filogic 25.12.5 SDK.
#   WORKDIR   (optional) directory in which to download/extract/build.
#             Defaults to ./sdk-work.
#
# Output:
#   The resulting .apk (OpenWrt >= 24.10, apk package manager) or .ipk (older)
#   packages are copied to ./bin/, ready to install with `opkg`/`apk`.
#
# The script is designed to be idempotent: it reuses an already-extracted SDK in
# WORKDIR and only re-copies the package sources and re-builds them.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults and argument parsing
# ---------------------------------------------------------------------------
DEFAULT_SDK_URL="https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst"

SDK_URL="${1:-$DEFAULT_SDK_URL}"
WORKDIR="${2:-$(pwd)/sdk-work}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="$SCRIPT_DIR/package"

OUTDIR="$SCRIPT_DIR/bin"

PKGS=(
    "rustdesk-discoveryd"
    "luci-app-rustdesk-discover"
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_cmd curl
require_cmd tar
require_cmd make
require_cmd gawk
command -v zstd >/dev/null 2>&1 || warn "zstd not found; .tar.zst SDKs will not extract"

[ -d "$PACKAGES_DIR" ] || die "package source directory not found: $PACKAGES_DIR"

mkdir -p "$WORKDIR" "$OUTDIR"

# ---------------------------------------------------------------------------
# 1. Download + extract the SDK (skipped if already present)
# ---------------------------------------------------------------------------
SDK_TARBALL="$WORKDIR/$(basename "$SDK_URL")"

SDK_DIR="$(find "$WORKDIR" -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n1 || true)"
[ -n "$SDK_DIR" ] || SDK_DIR=""

if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/Makefile" ]; then
    if [ ! -f "$SDK_TARBALL" ]; then
        log "Downloading SDK: $SDK_URL"
        curl -fSL --retry 3 -o "$SDK_TARBALL" "$SDK_URL"
    fi

    log "Extracting SDK..."
    case "$SDK_TARBALL" in
        *.zst) tar --zstd -xf "$SDK_TARBALL" -C "$WORKDIR" ;;
        *.xz)  tar -xJf  "$SDK_TARBALL" -C "$WORKDIR" ;;
        *.gz)  tar -xzf  "$SDK_TARBALL" -C "$WORKDIR" ;;
        *)     die "unsupported SDK archive format: $SDK_TARBALL" ;;
    esac

    SDK_DIR="$(find "$WORKDIR" -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n1)"
    [ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/Makefile" ] || die "failed to locate extracted SDK"
else
    log "Reusing existing SDK at: $SDK_DIR"
fi

# ---------------------------------------------------------------------------
# 2. Install feeds (luci + packages + base) — needed for luci.mk and luci-base
# ---------------------------------------------------------------------------
cd "$SDK_DIR"

log "Updating feeds (first run may take a while)..."

# Already-updated feeds leave index files; skip if present.
if [ ! -f "feeds/luci/luci.mk" ] || [ ! -f "feeds/packages.index" ]; then
    ./scripts/feeds update -a > /dev/null
fi

./scripts/feeds install -a
# Re-install our own package symlinks after feed install (in case the base feed
# re-synced package/). This is safe and idempotent:
mkdir -p package
cp -r "$PACKAGES_DIR/rustdesk-discoveryd"        package/
cp -r "$PACKAGES_DIR/luci-app-rustdesk-discover" package/

# ---------------------------------------------------------------------------
# 3. Configure: enable our packages + their immediate deps, disable the
#    heavy bootloader packages so the (slow, one-time) prereq pass does not
#    iterate over dozens of U-Boot variants.
# ---------------------------------------------------------------------------
log "Writing .config and running defconfig..."
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

# Disable all per-board uboot/atf variants selected by the device defaults, so
# the build does not iterate over every U-Boot/ATF device target.
log "Disabling bootloader/ATF device variants in .config..."
sed -i -E 's/^(CONFIG_PACKAGE_(uboot-mediatek|atf-mediatek)[^=]*)=.*/\1=n/' .config

# ---------------------------------------------------------------------------
# 4. Build the packages
# ---------------------------------------------------------------------------
log "Building packages (first build runs a one-time prereq pass; be patient)..."
for pkg in "${PKGS[@]}"; do
    log "Building $pkg ..."
    make "package/$pkg/compile" V=cs -j8 || die "failed to build $pkg"
done

# ---------------------------------------------------------------------------
# 5. Collect the resulting packages
# ---------------------------------------------------------------------------
log "Collecting packages into $OUTDIR"
rm -f "$OUTDIR"/rustdesk-discoveryd*.{apk,ipk} "$OUTDIR"/luci-app-rustdesk-discover*.{apk,ipk}

FOUND=0
while read -r f; do
    log "  -> $f"
    cp -v "$f" "$OUTDIR/"
    FOUND=1
done < <(find bin -type f \( -name 'rustdesk-discoveryd*.apk' -o -name 'rustdesk-discoveryd*.ipk' \
    -o -name 'luci-app-rustdesk-discover*.apk' -o -name 'luci-app-rustdesk-discover*.ipk' \) 2>/dev/null)

[ "$FOUND" = "1" ] || warn "No built packages were found in the SDK bin/ directory."

echo
log "Done. Packages are in: $OUTDIR"
echo "  Install on the router with:"
echo "    opkg install $OUTDIR/rustdesk-discoveryd*.apk"
echo "    opkg install $OUTDIR/luci-app-rustdesk-discover*.apk"
echo "  then:"
echo "    /etc/init.d/rustdesk-discoveryd enable && /etc/init.d/rustdesk-discoveryd start"
