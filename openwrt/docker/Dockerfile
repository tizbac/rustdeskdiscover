# RustDesk Discovery - OpenWrt SDK build environment (Arch Linux based)
#
# Builds the rustdesk-discoveryd and luci-app-rustdesk-discover packages for
# OpenWrt using the official SDK. An Arch Linux base is used because its build
# tooling matches what the OpenWrt SDK needs, and it is fully reproducible
# inside a container (independently of the host OS).
#
# Build the image:
#   docker build -t rustdesk-openwrt-build -f Dockerfile .
#
# The actual SDK download/build happens at container run time via entrypoint.sh,
# so this image can be reused for any SDK version without rebuilding.

FROM archlinux:latest

# Keep unprivileged-execution-friendly and non-interactive.
ENV LANG=C.UTF-8

# Host build-tool prerequisites required by the OpenWrt build system
# (the "prereq" / host-toolcheck pass). On Arch, pacman provides these.
RUN pacman -Syu --noconfirm \
        base-devel \
        git unzip zip \
        gcc make gcc-libs \
        perl \
        rsync wget curl \
        tar xz gzip bzip2 zstd \
        python python-setuptools python-jinja python-yaml \
        swig file which \
        patch sed gawk diffutils findutils \
        gettext libtool automake autoconf \
        bc openssl pkgconf time \
    && pacman -Scc --noconfirm

# Scripts + sources are mounted at run time, but keep a copy of the entrypoint.
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /work

ENTRYPOINT ["/entrypoint.sh"]
