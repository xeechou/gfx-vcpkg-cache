#!/usr/bin/env bash
#
# fetch-sdk.sh — Download and decompress the LunarG Vulkan SDK tarball into
# the exact layout build-deb.sh expects:  $SCRIPT_DIR/<version>/x86_64 ...
#
# The LunarG SDK tarball self-extracts into a leading directory named
# "<version>/" (e.g. "1.4.357.1/") whose children are x86_64/, LICENSE.txt,
# README.txt, config, ...  So extracting inside this repo root produces
# ./<version>/, which matches the default $SDKROOT that build-deb.sh resolves.
#
# URL format (see https://vulkan.lunarg.com/sdk/home):
#   https://sdk.lunarg.com/sdk/download/{version}/linux/vulkansdk-linux-x86_64-{version}.tar.xz
#
# Usage:
#   ./scripts/fetch-sdk.sh                     # fetch default SDK_VERSION
#   SDK_VERSION=1.3.290.0 ./scripts/fetch-sdk.sh
#   SDK_URL=https://... ./scripts/fetch-sdk.sh # explicit URL overrides version
#   SDK_SKIP_DOWNLOAD=1 SDKROOT=/existing/tree \
#       ./scripts/fetch-sdk.sh                 # reuse an already-extracted tree
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$SCRIPT_DIR/SDK_VERSION"
DEFAULT_SDK_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

SDK_VERSION="${SDK_VERSION:-$DEFAULT_SDK_VERSION}"
DEFAULT_URL="https://sdk.lunarg.com/sdk/download/${SDK_VERSION}/linux/vulkansdk-linux-x86_64-${SDK_VERSION}.tar.xz"
SDK_URL="${SDK_URL:-$DEFAULT_URL}"
ARCHIVE="$(basename "$SDK_URL")"
DEST_DIR="${DEST_DIR:-$SCRIPT_DIR}"
SDKROOT="${DEST_DIR}/${SDK_VERSION}"

say() { printf '\033[1;32m[fetch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fetch]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

check_prereqs() {
    command -v curl   >/dev/null || command -v wget >/dev/null || die "curl or wget required"
    command -v tar    >/dev/null || die "tar required"
    command -v xz     >/dev/null || die "xz required (to decompress .tar.xz)"
    command -v sha256sum >/dev/null || command -v shasum >/dev/null || die "sha256sum/shasum required"
    [ -f "$VERSION_FILE" ] || die "SDK version file not found at $VERSION_FILE"
    [ -n "$DEFAULT_SDK_VERSION" ] || die "SDK version file $VERSION_FILE is empty"
}

sha256_of() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Try to fetch a sidecar SHA256SUMS file from the same base URL.  LunarG hosts
# an optional "<archive>.sha256" next to the tarball; use it when present so CI
# can fail fast on a corrupted/incomplete download.  Silently skip if absent.
verify_checksum() {
    local tarball="$1"
    local sumfile="${SDK_URL}.sha256"
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL --max-time 60 "$sumfile" -o "$tmp" 2>/dev/null \
       || wget -q --timeout=60 -O "$tmp" "$sumfile" 2>/dev/null; then
        local expected actual
        expected="$(awk '{print $1}' "$tmp" | head -n1)"
        actual="$(sha256_of "$tarball")"
        rm -f "$tmp"
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            say "Checksum verified ($actual)"
        else
            die "Checksum mismatch: expected=$expected actual=$actual"
        fi
    else
        rm -f "$tmp"
        say "No ${ARCHIVE}.sha256 sidecar; skipping checksum verification"
    fi
}

# If the caller already points at an extracted SDK tree, just reuse it.
if [ "${SDK_SKIP_DOWNLOAD:-0}" = "1" ]; then
    [ -d "$SDKROOT/x86_64" ] || die "SDK_SKIP_DOWNLOAD=1 but $SDKROOT/x86_64 not found"
    say "Reusing pre-extracted SDK at $SDKROOT"
    exit 0
fi

check_prereqs

say "Fetching SDK ${SDK_VERSION}"
say "URL: $SDK_URL"

# Download (resume-friendly) the tarball into the destination dir.
TMP_EXT="$(mktemp -d "${DEST_DIR}/.fetch.XXXXXX")"
TARBALL="${TMP_EXT}/${ARCHIVE}"
if command -v curl >/dev/null; then
    curl -fL --retry 3 --retry-delay 5 -C - "$SDK_URL" -o "$TARBALL"
else
    wget -q --tries=3 --timeout=120 -c -O "$TARBALL" "$SDK_URL"
fi
[ -s "$TARBALL" ] || die "Download failed: empty file"

verify_checksum "$TARBALL"

say "Decompressing into $DEST_DIR (leading '$SDK_VERSION/' dir)"
# --strip-components=0 keeps the leading <version>/ dir so the tree lands at
# $DEST_DIR/<version> exactly as build-deb.sh expects.
tar -xJf "$TARBALL" -C "$DEST_DIR"

[ -d "$SDKROOT/x86_64" ] || die "Expected $SDKROOT/x86_64 after extraction (missing)"
say "SDK ready at $SDKROOT"

rm -rf "$TMP_EXT"
say "Done."
