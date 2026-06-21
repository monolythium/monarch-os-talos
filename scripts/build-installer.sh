#!/usr/bin/env bash
# Build a CUSTOM Talos installer image that bakes the protocore system
# extension, and (optionally) push it to a registry.
#
# WHY THIS EXISTS: `machine.install.image` on a fresh Monarch OS install must
# point at an installer that CONTAINS the protocore extension. The plain
# `ghcr.io/siderolabs/installer` does not, so a maintenance-mode install would
# produce a vanilla Talos node with no `ext-protocore` (RPC never serves). The
# ISO/raw bake the extension for BOOT, but the on-disk install pulls this
# installer image — so it must carry the extension too.
#
# Inputs (env):
#   TALOS_VERSION   (default v1.13.0)
#   ARCH            (default amd64)
#   OUT_DIR         (default <repo>/_out) — must already contain the built
#                   `monarch-protocore-<arch>-*-<talos>.tar` extension tarball
#   IMAGER_IMAGE    (default ghcr.io/siderolabs/imager:$TALOS_VERSION)
#   BASE_INSTALLER  (default ghcr.io/siderolabs/installer:$TALOS_VERSION)
#   INSTALLER_IMAGE (required) target ref, e.g.
#                   ghcr.io/monolythium/monarch-os-installer:v0.1.72-testnet
#   PUSH_INSTALLER  (default false) — `true` to `crane push` the result
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_out}"
# docker -v requires an absolute path (a relative one becomes a named volume).
[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
ARCH="${ARCH:-amd64}"
IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:$TALOS_VERSION}"
BASE_INSTALLER="${BASE_INSTALLER:-ghcr.io/siderolabs/installer:$TALOS_VERSION}"
: "${INSTALLER_IMAGE:?set INSTALLER_IMAGE=ghcr.io/monolythium/monarch-os-installer:<tag>}"
PUSH_INSTALLER="${PUSH_INSTALLER:-false}"

EXTENSION_TARBALL="$(ls "$OUT_DIR"/monarch-protocore-"$ARCH"-*-"$TALOS_VERSION".tar 2>/dev/null | sort | tail -n 1 || true)"
if [[ -z "$EXTENSION_TARBALL" || ! -f "$EXTENSION_TARBALL" ]]; then
  echo "no protocore extension tarball in $OUT_DIR (run build-protocore-extension.sh first)" >&2
  exit 1
fi
echo "extension: $EXTENSION_TARBALL"

# NOTE: do NOT set `baseInstaller` here. With a baseInstaller the imager reuses
# its pre-built UKI and SKIPS the initramfs rebuild — the protocore extension is
# silently dropped (the installed node ends up with no ext-protocore). Feeding
# kernel+initramfs (the imager image ships them under /usr/install) makes the
# imager "rebuild initramfs with system extensions", baking protocore in. This
# mirrors build-metal.sh exactly, only the output kind differs.
PROFILE="$OUT_DIR/profile-installer.yaml"
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
  kind: installer
  outFormat: raw
EOF_PROFILE

docker run --rm -i \
  -v "$OUT_DIR:/out" \
  -v "$EXTENSION_TARBALL:/extensions/$(basename "$EXTENSION_TARBALL"):ro" \
  "$IMAGER_IMAGE" - < "$PROFILE"

INSTALLER_TAR="$OUT_DIR/installer-$ARCH.tar"
if [[ ! -f "$INSTALLER_TAR" ]]; then
  echo "imager did not produce $INSTALLER_TAR" >&2
  exit 1
fi
echo "installer image tarball: $INSTALLER_TAR ($(du -h "$INSTALLER_TAR" | cut -f1))"

if [[ "$PUSH_INSTALLER" == "true" ]]; then
  command -v crane >/dev/null 2>&1 || { echo "crane required to push" >&2; exit 1; }
  crane push "$INSTALLER_TAR" "$INSTALLER_IMAGE"
  echo "pushed: $INSTALLER_IMAGE"
  crane digest "$INSTALLER_IMAGE" 2>/dev/null || true
fi
