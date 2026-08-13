#!/usr/bin/env bash
#
# build-deb.sh — Build four Debian packages from the decompressed LunarG
# Vulkan SDK:
#   * libvulkan1      runtime Vulkan loader
#   * libvulkan-dev   loader development files
#   * vulkan-headers  Vulkan headers + API registry
#   * vulkan-sdk      remaining SDK tools, layers, libraries, and extras
#
# The SDK is a self-contained tree (x86_64/{bin,include,lib,share}). Shipped
# tool binaries embed RUNPATH "$ORIGIN/../lib" and layer manifests use
# relative library paths that resolve correctly when the SDK payload is rooted
# at /usr. This builder preserves that layout while splitting core package
# identities away from the rest of the SDK.

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/SDK_VERSION"
DEFAULT_SDK_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

SDK_VERSION="${SDK_VERSION:-$DEFAULT_SDK_VERSION}"
SDKROOT="${SDKROOT:-${SCRIPT_DIR}/${SDK_VERSION}}"
X86="$SDKROOT/x86_64"

REVISION="${REVISION:-${SDK_VERSION}-1local}"
ARCH="${ARCH:-amd64}"
OUT="${OUT:-$PWD}"
STAGE_BASE="${STAGE_BASE:-${PWD}/stage}"
MAINTAINER="${MAINTAINER:-Local Maintainer <root@localhost>}"

PACKAGES=(libvulkan1 libvulkan-dev vulkan-headers vulkan-sdk)
CONTROL_DIR="$SCRIPT_DIR/control.d"

LOADER_REAL=""
LOADER_REAL_BASENAME=""
LOADER_API_VERSION=""

say() { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m WARNING: %s\n' "$*"; }
die()  { printf '\033[1;31m[build]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

pkg_root() { printf '%s/%s' "$STAGE_BASE" "$1"; }
pkg_arch() {
    case "$1" in
        vulkan-headers) printf 'all' ;;
        *) printf '%s' "$ARCH" ;;
    esac
}

check_prereqs() {
    command -v dpkg-deb >/dev/null || die "dpkg-deb not found"
    command -v python3  >/dev/null || die "python3 not found"
    command -v fakeroot >/dev/null || die "fakeroot not found"
    [ -f "$VERSION_FILE" ] || die "SDK version file not found at $VERSION_FILE"
    [ -n "$DEFAULT_SDK_VERSION" ] || die "SDK version file $VERSION_FILE is empty"
    [ -d "$X86/bin" ]     || die "SDK x86_64/bin not found at $X86"
    [ -d "$X86/include" ] || die "SDK x86_64/include not found at $X86"
    [ -d "$X86/lib" ]     || die "SDK x86_64/lib not found at $X86"
    [ -d "$X86/share" ]   || die "SDK x86_64/share not found at $X86"
    [ -d "$CONTROL_DIR" ] || die "control template directory not found at $CONTROL_DIR"
    for pkg in "${PACKAGES[@]}"; do
        [ -f "$CONTROL_DIR/$pkg" ] || die "missing control template: $CONTROL_DIR/$pkg"
    done
}

stage_tree() {
    local src="$1" dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    cp -a --reflink=auto "$src/." "$dest/"
}

stage_file() {
    local src="$1" dest="$2"
    install -Dm644 "$src" "$dest"
}

stage_exec() {
    local src="$1" dest="$2"
    install -Dm755 "$src" "$dest"
}

link_compat_entries() {
    local src_dir="$1" compat_dir="$2"
    [ -d "$src_dir" ] || return 0
    mkdir -p "$compat_dir"
    find "$src_dir" -maxdepth 1 \( -type f -o -type l \) -print0 |
        while IFS= read -r -d '' path; do
            ln -srf "$path" "$compat_dir/$(basename "$path")"
        done
}

link_compat_dir_entries() {
    local src_dir="$1" compat_dir="$2"
    [ -d "$src_dir" ] || return 0
    mkdir -p "$compat_dir"
    find "$src_dir" -maxdepth 1 \( -type f -o -type l \) -print0 |
        while IFS= read -r -d '' path; do
            ln -srf "$path" "$compat_dir/$(basename "$path")"
        done
}

rewrite_layer_libpath() {
    local json="$1"
    python3 - "$json" <<'PY'
import json, os, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data = json.load(f)
layer = data.get('layer', {})
library_path = layer.get('library_path')
if library_path:
    layer['library_path'] = f"/usr/lib/{os.path.basename(library_path)}"
with open(p, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
PY
}

copy_package_docs() {
    local pkg="$1" synopsis="$2"
    local root="$(pkg_root "$pkg")"
    local docdir="$root/usr/share/doc/$pkg"
    mkdir -p "$docdir"

    if [ -f "$SCRIPT_DIR/copyright" ]; then
        cp "$SCRIPT_DIR/copyright" "$docdir/copyright"
    elif [ -f "$SDKROOT/LICENSE.txt" ]; then
        cp "$SDKROOT/LICENSE.txt" "$docdir/copyright"
    fi

    if [ -f "$SDKROOT/README.txt" ]; then
        cp "$SDKROOT/README.txt" "$docdir/README.sdk"
    fi

    cat > "$docdir/changelog.Debian" <<EOF
${pkg} (${REVISION}) local; urgency=medium

  * Package produced from the decompressed LunarG Vulkan SDK ${SDK_VERSION}.
  * Payload class: ${synopsis}.

 -- ${MAINTAINER}  $(date -R)
EOF
    gzip -9 -n "$docdir/changelog.Debian"
}

write_vulkan_pc() {
    local dest="$1"
    cat > "$dest" <<EOF
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: Vulkan-Loader
Description: Vulkan Loader
Version: ${LOADER_API_VERSION}
Libs: -L\${libdir} -lvulkan
Cflags: -I\${includedir}
EOF
}

resolve_loader() {
    local candidates=("$X86/lib/VulkanLoader/lib/libvulkan.so.1."*)
    [ ${#candidates[@]} -gt 0 ] || die "no libvulkan.so.1.* found under $X86/lib/VulkanLoader/lib"
    LOADER_REAL="${candidates[0]}"
    LOADER_REAL_BASENAME="$(basename "$LOADER_REAL")"
    LOADER_API_VERSION="${LOADER_REAL_BASENAME#libvulkan.so.1.}"
    say "Resolved Vulkan loader: $LOADER_REAL_BASENAME"
}

reset_stage() {
    rm -rf "$STAGE_BASE"
    mkdir -p "$STAGE_BASE"
    for pkg in "${PACKAGES[@]}"; do
        mkdir -p "$(pkg_root "$pkg")"
    done
}

stage_libvulkan1() {
    local pkg=libvulkan1 root
    root="$(pkg_root "$pkg")"
    say "Staging $pkg"

    stage_exec "$LOADER_REAL" "$root/usr/lib/$LOADER_REAL_BASENAME"
    ln -sf "$LOADER_REAL_BASENAME" "$root/usr/lib/libvulkan.so.1"

    mkdir -p "$root/usr/lib/x86_64-linux-gnu"
    ln -sf "../$LOADER_REAL_BASENAME" "$root/usr/lib/x86_64-linux-gnu/$LOADER_REAL_BASENAME"
    ln -sf "../$LOADER_REAL_BASENAME" "$root/usr/lib/x86_64-linux-gnu/libvulkan.so.1"

    copy_package_docs "$pkg" "runtime Vulkan loader"
}

stage_libvulkan_dev() {
    local pkg=libvulkan-dev root
    root="$(pkg_root "$pkg")"
    say "Staging $pkg"

    mkdir -p "$root/usr/lib" "$root/usr/lib/x86_64-linux-gnu"
    ln -sf "libvulkan.so.1" "$root/usr/lib/libvulkan.so"
    ln -sf "../libvulkan.so" "$root/usr/lib/x86_64-linux-gnu/libvulkan.so"

    mkdir -p "$root/usr/lib/pkgconfig"
    write_vulkan_pc "$root/usr/lib/pkgconfig/vulkan.pc"
    mkdir -p "$root/usr/lib/x86_64-linux-gnu/pkgconfig"
    ln -srf "$root/usr/lib/pkgconfig/vulkan.pc" "$root/usr/lib/x86_64-linux-gnu/pkgconfig/vulkan.pc"

    if [ -d "$X86/lib/VulkanLoader/lib/cmake/VulkanLoader" ]; then
        stage_tree "$X86/lib/VulkanLoader/lib/cmake/VulkanLoader" "$root/usr/lib/cmake/VulkanLoader"
        link_compat_dir_entries "$root/usr/lib/cmake/VulkanLoader" "$root/usr/lib/x86_64-linux-gnu/cmake/VulkanLoader"
    fi

    copy_package_docs "$pkg" "Vulkan loader development files"
}

stage_vulkan_headers() {
    local pkg=vulkan-headers root
    root="$(pkg_root "$pkg")"
    say "Staging $pkg"

    if [ -d "$X86/include/vulkan" ]; then
        stage_tree "$X86/include/vulkan" "$root/usr/include/vulkan"
    fi
    if [ -d "$X86/include/vk_video" ]; then
        stage_tree "$X86/include/vk_video" "$root/usr/include/vk_video"
    fi
    if [ -d "$X86/share/cmake/VulkanHeaders" ]; then
        stage_tree "$X86/share/cmake/VulkanHeaders" "$root/usr/share/cmake/VulkanHeaders"
    fi
    if [ -d "$X86/share/vulkan/registry" ]; then
        stage_tree "$X86/share/vulkan/registry" "$root/usr/share/vulkan/registry"
    fi

    copy_package_docs "$pkg" "Vulkan headers and API registry"
}

stage_vulkan_sdk() {
    local pkg=vulkan-sdk root
    root="$(pkg_root "$pkg")"
    say "Staging $pkg"

    stage_tree "$X86/bin" "$root/usr/bin"
    stage_tree "$X86/include" "$root/usr/include"
    stage_tree "$X86/lib" "$root/usr/lib"
    stage_tree "$X86/share" "$root/usr/share"

    rm -rf "$root/usr/include/vulkan" "$root/usr/include/vk_video"
    rm -rf "$root/usr/share/cmake/VulkanHeaders" "$root/usr/share/vulkan/registry"
    rm -rf "$root/usr/lib/VulkanLoader"

    link_compat_entries "$root/usr/lib" "$root/usr/lib/x86_64-linux-gnu"
    if [ -d "$root/usr/lib/pkgconfig" ]; then
        link_compat_entries "$root/usr/lib/pkgconfig" "$root/usr/lib/x86_64-linux-gnu/pkgconfig"
    fi

    if [ -d "$root/usr/share/vulkan/explicit_layer.d" ]; then
        for json in "$root"/usr/share/vulkan/explicit_layer.d/*.json; do
            [ -f "$json" ] || continue
            rewrite_layer_libpath "$json"
        done
    fi

    copy_package_docs "$pkg" "SDK tools, layers, libraries, and extras"
}

render_control() {
    local pkg="$1" root debian arch template rendered
    root="$(pkg_root "$pkg")"
    debian="$root/DEBIAN"
    arch="$(pkg_arch "$pkg")"
    template="$CONTROL_DIR/$pkg"
    rendered="$debian/control"
    mkdir -p "$debian"

    sed \
        -e "s|@VERSION@|$REVISION|g" \
        -e "s|@ARCH@|$arch|g" \
        -e "s|@MAINTAINER@|$MAINTAINER|g" \
        -e "s|@SDK_VERSION@|$SDK_VERSION|g" \
        "$template" > "$rendered"

    ( cd "$root" && find usr -type f -exec md5sum {} + ) > "$debian/md5sums"
}

build_staging() {
    reset_stage
    stage_libvulkan1
    stage_libvulkan_dev
    stage_vulkan_headers
    stage_vulkan_sdk
    for pkg in "${PACKAGES[@]}"; do
        render_control "$pkg"
    done
}

bake() {
    mkdir -p "$OUT"
    for pkg in "${PACKAGES[@]}"; do
        local arch full root
        arch="$(pkg_arch "$pkg")"
        root="$(pkg_root "$pkg")"
        full="$OUT/${pkg}_${REVISION}_${arch}.deb"
        say "Building $full"
        fakeroot dpkg-deb --build --root-owner-group "$root" "$full"
        ls -lh "$full"
    done
}

check_prereqs
resolve_loader
build_staging
bake

say "Done. Inspect with: dpkg-deb -c $OUT/<package>_${REVISION}_<arch>.deb"
