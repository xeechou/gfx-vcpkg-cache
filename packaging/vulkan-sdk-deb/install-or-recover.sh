#!/usr/bin/env bash
#
# install-or-recover.sh — Install the split LunarG Vulkan SDK packages or roll
# back to the distro Vulkan packages.
#
# Usage:
#   sudo ./install-or-recover.sh install
#   sudo ./install-or-recover.sh recover
#   sudo ./install-or-recover.sh status
#
# The local build now produces four packages:
#   * libvulkan1
#   * libvulkan-dev
#   * vulkan-headers
#   * vulkan-sdk
#
# `install` snapshots the current apt state, installs the locally-built split
# packages, and lets APT resolve the remaining runtime dependencies.
# `recover` removes the local packages and restores the previously-installed
# distro Vulkan package set from the saved snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/apt-state"
INSTALL_LOG="$SCRIPT_DIR/install.log"
VERSION_FILE="$SCRIPT_DIR/SDK_VERSION"
DEFAULT_SDK_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

SDK_VERSION="${SDK_VERSION:-$DEFAULT_SDK_VERSION}"
ARCH="${ARCH:-amd64}"
REVISION="${REVISION:-${SDK_VERSION}-1local}"

LOCAL_PKGS=(libvulkan1 libvulkan-dev vulkan-headers vulkan-sdk)
DISTRO_PKGS=(libvulkan1 libvulkan-dev vulkan-headers vulkan-validationlayers vulkan-tools
  vulkan-utility-libraries vulkan-utility-libraries-dev vulkan-profiles
  vulkan-extensionlayer lunarg-vkconfig lunarg-vulkan-layers lunarg-via vma volk
  vulkancapsviewer glslang-tools glslang-dev shaderc dxc slang spirv-tools
  spirv-headers spirv-cross spirv-cross-dev spirv-reflect lunarg-gfxreconstruct)

say() { printf '\033[1;32m[%s]\033[0m %s\n' "$ACTION" "$*"; }
die() { printf '\033[1;31m[%s]\033[0m ERROR: %s\n' "$ACTION" "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $ACTION"; }
require_version_file() {
    [ -f "$VERSION_FILE" ] || die "SDK version file not found at $VERSION_FILE"
    [ -n "$DEFAULT_SDK_VERSION" ] || die "SDK version file $VERSION_FILE is empty"
}

deb_path() {
    local pkg="$1"
    local pkg_arch="$ARCH"
    [ "$pkg" = "vulkan-headers" ] && pkg_arch="all"
    printf '%s/%s_%s_%s.deb' "$SCRIPT_DIR" "$pkg" "$REVISION" "$pkg_arch"
}

snapshot_installed() {
    mkdir -p "$STATE_DIR"
    dpkg --get-selections > "$STATE_DIR/selections.before"
    dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null > "$STATE_DIR/packages.before"

    local re
    re="$(printf '%s|' "${DISTRO_PKGS[@]}" | sed 's/|$//')"
    dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null \
        | grep -E "^(${re}) " > "$STATE_DIR/distro-version.txt" || true

    (cd /etc/apt && cp sources.list "$STATE_DIR/sources.list" 2>/dev/null || true
     mkdir -p "$STATE_DIR/sources.list.d"
     cp sources.list.d/* "$STATE_DIR/sources.list.d/" 2>/dev/null || true)
    say "Saved apt state to $STATE_DIR"
}

assert_local_debs_exist() {
    local pkg path
    for pkg in "${LOCAL_PKGS[@]}"; do
        path="$(deb_path "$pkg")"
        [ -f "$path" ] || die "Package not found: $path (run build-deb.sh first)"
    done
}

do_install() {
    assert_local_debs_exist
    say "Snapshotting current apt state for recovery"
    snapshot_installed

    say "Installing split Vulkan packages"
    apt-get install -y \
        "$(deb_path libvulkan1)" \
        "$(deb_path libvulkan-dev)" \
        "$(deb_path vulkan-headers)" \
        "$(deb_path vulkan-sdk)"

    say "Install complete. Verifying..."
    vulkaninfo --summary || say "vulkaninfo not on PATH yet (may need a new shell)"
}

do_recover() {
    say "Restoring original distro Vulkan packages"
    [ -f "$STATE_DIR/selections.before" ] || die "No saved state found in $STATE_DIR — run install first"

    say "Removing locally-built Vulkan packages"
    apt-get purge -y "${LOCAL_PKGS[@]}" || true
    dpkg --remove --force-remove-reinstreq --force-depends "${LOCAL_PKGS[@]}" 2>/dev/null || true

    say "Cleaning stray files from the local install"
    rm -f \
      /usr/lib/libvulkan.so* /usr/lib/x86_64-linux-gnu/libvulkan.so* \
      /usr/bin/vulkaninfo /usr/bin/vkcube /usr/bin/vkcubepp \
      /usr/bin/vkconfig /usr/bin/vkconfig-gui \
      /usr/bin/glslangValidator /usr/bin/glslang /usr/bin/glslc \
      /usr/bin/slangc /usr/bin/slangd /usr/bin/slangi /usr/bin/slang \
      /usr/bin/dxc /usr/bin/spirv-as /usr/bin/spirv-val \
      /usr/share/vulkan/explicit_layer.d/*.json
    dpkg --configure -a || true

    say "Refreshing package indices"
    apt-get update

    if [ -s "$STATE_DIR/distro-version.txt" ]; then
        mapfile -t restore_specs < <(awk '{print $1"="$2}' "$STATE_DIR/distro-version.txt")
        say "Reinstalling prior distro Vulkan package set"
        apt-get install -y --fix-broken "${restore_specs[@]}" || apt-get install -y --fix-broken "${DISTRO_PKGS[@]}" || true
    else
        say "No prior distro Vulkan package set recorded; skipping targeted reinstall"
    fi

    say "Restoring exact dpkg selections from before install"
    dpkg --set-selections < "$STATE_DIR/selections.before"
    apt-get dselect-upgrade -y || true
    apt-get -f install -y

    say "Recovery complete."
}

do_status() {
    echo "=== installed Vulkan-related packages ==="
    dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null \
        | grep -iE 'vulkan|glslang|lunarg|spirv|shaderc|slang|^vma|^volk|^dxc' \
        | grep -iE 'installed' || true
    echo
    echo "=== locally-built packages present? ==="
    for pkg in "${LOCAL_PKGS[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "$pkg: INSTALLED"
        else
            echo "$pkg: not installed"
        fi
    done
    echo
    echo "=== saved recovery state ==="
    ls -la "$STATE_DIR" 2>/dev/null || echo "(none — run 'install' first to enable 'recover')"
}

ACTION="${1:-status}"
require_root
require_version_file
case "$ACTION" in
  install) do_install | tee -a "$INSTALL_LOG" ;;
  recover) do_recover | tee -a "$INSTALL_LOG" ;;
  status)  do_status ;;
  *) die "Unknown action '$ACTION'. Use: install | recover | status" ;;
esac
