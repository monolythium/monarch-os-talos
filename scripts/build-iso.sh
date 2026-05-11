#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/_build"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:$TALOS_VERSION}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$BUILD_DIR" = /* ]] || BUILD_DIR="$ROOT_DIR/$BUILD_DIR"

mkdir -p "$OUT_DIR" "$BUILD_DIR"

EXTENSION_TARBALL="$("$ROOT_DIR/scripts/build-protocore-extension.sh")"
PROFILE="$BUILD_DIR/profile-iso.yaml"

cat > "$PROFILE" <<EOF_PROFILE
arch: $ARCH
platform: metal
secureboot: false
version: $TALOS_VERSION
input:
  kernel:
    path: /usr/install/$ARCH/vmlinuz
  initramfs:
    path: /usr/install/$ARCH/initramfs.xz
  systemExtensions:
    - tarballPath: /extensions/$(basename "$EXTENSION_TARBALL")
output:
  kind: iso
  outFormat: raw
EOF_PROFILE

docker run --rm -i \
  -v "$OUT_DIR:/out" \
  -v "$EXTENSION_TARBALL:/extensions/$(basename "$EXTENSION_TARBALL"):ro" \
  "$IMAGER_IMAGE" - < "$PROFILE"

ISO_SRC="$OUT_DIR/metal-$ARCH.iso"
ISO_DST="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.iso"

if [[ ! -f "$ISO_SRC" ]]; then
  echo "expected imager output not found: $ISO_SRC" >&2
  exit 1
fi

mv "$ISO_SRC" "$ISO_DST"
sha256sum "$ISO_DST" > "$ISO_DST.sha256"

echo "$ISO_DST"
