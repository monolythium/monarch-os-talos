#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/_build"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-"$MONO_CORE_DIR/target/release/protocore"}"
PROTOCORE_CARGO_FEATURES="${PROTOCORE_CARGO_FEATURES:-mdbx,indexer-postgres}"
GENESIS_TOML="${GENESIS_TOML:-}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$BUILD_DIR" = /* ]] || BUILD_DIR="$ROOT_DIR/$BUILD_DIR"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
[[ "$PROTOCORE_BINARY" = /* ]] || PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"
if [[ -n "$GENESIS_TOML" && "$GENESIS_TOML" != /* ]]; then
  GENESIS_TOML="$ROOT_DIR/$GENESIS_TOML"
fi

mkdir -p "$OUT_DIR" "$BUILD_DIR"

if [[ ! -x "$PROTOCORE_BINARY" ]]; then
  cargo build --release --features "$PROTOCORE_CARGO_FEATURES" --bin protocore --manifest-path "$MONO_CORE_DIR/Cargo.toml"
fi

PROTOCORE_VERSION="$("$PROTOCORE_BINARY" version --output json | jq -r '.version')"
MONO_CORE_COMMIT="$(git -C "$MONO_CORE_DIR" rev-parse --short=12 HEAD)"
EXTENSION_NAME="monarch-protocore"
EXTENSION_VERSION="${PROTOCORE_VERSION}-${MONO_CORE_COMMIT}-${TALOS_VERSION}"
STAGE_DIR="$BUILD_DIR/$EXTENSION_NAME"
SERVICE_ROOT="$STAGE_DIR/rootfs/usr/local/lib/containers/protocore"
SERVICE_CONFIG_DIR="$STAGE_DIR/rootfs/usr/local/etc/containers"
TARBALL="$OUT_DIR/${EXTENSION_NAME}-${ARCH}-${EXTENSION_VERSION}.tar"

rm -rf "$STAGE_DIR"
mkdir -p "$SERVICE_ROOT" "$SERVICE_CONFIG_DIR"

cat > "$STAGE_DIR/manifest.yaml" <<EOF_MANIFEST
version: v1alpha1
metadata:
  name: $EXTENSION_NAME
  version: $EXTENSION_VERSION
  author: Monolythium Vision
  description: |
    Monarch OS system extension that ships the protocore node binary.
  compatibility:
    talos:
      version: ">= $TALOS_VERSION"
EOF_MANIFEST

cp "$PROTOCORE_BINARY" "$SERVICE_ROOT/protocore"
gcc -static -Os -s -o "$SERVICE_ROOT/protocore-entrypoint" "$ROOT_DIR/extensions/protocore/src/protocore-entrypoint.c"

if [[ -n "$GENESIS_TOML" && -f "$GENESIS_TOML" ]]; then
  mkdir -p "$SERVICE_ROOT/defaults/testnet"
  cp "$GENESIS_TOML" "$SERVICE_ROOT/defaults/testnet/genesis.toml"
fi

while read -r lib; do
  [[ -z "$lib" ]] && continue
  target="$SERVICE_ROOT$lib"
  mkdir -p "$(dirname "$target")"
  cp -L "$lib" "$target"
done < <(
  {
    ldd "$PROTOCORE_BINARY" \
      | awk '/=> \// {print $3} /^[[:space:]]*\/.*ld-linux/ {print $1}'
    readelf -l "$PROTOCORE_BINARY" \
      | sed -n 's/.*interpreter: \(.*\)]/\1/p'
  } \
    | sort -u
)

cat > "$SERVICE_CONFIG_DIR/protocore.yaml" <<'EOF_SERVICE'
name: protocore
container:
  entrypoint: ./protocore-entrypoint
  environment:
    - PROTOCORE_HOME=/var/lib/protocore
    - PROTOCORE_NETWORK=testnet
    - PROTOCORE_KEYCHAIN_BACKEND=file
    - PROTOCORE_LOG_FORMAT=json
    - PROTOCORE_LOG_LEVEL=info
    - PROTOCORE_OUTPUT=json
    - PROTOCORE_YES=true
    - PROTOCORE_GENESIS_TOML=./defaults/testnet/genesis.toml
  mounts:
    - source: /var/lib/protocore
      destination: /var/lib/protocore
      type: bind
      options:
        - rbind
        - rw
depends:
  - configuration: true
  - service: cri
  - network:
    - addresses
    - connectivity
    - hostname
    - etcfiles
  - time: true
restart: always
logToConsole: true
EOF_SERVICE

chmod 0755 "$SERVICE_ROOT/protocore" "$SERVICE_ROOT/protocore-entrypoint"
find "$SERVICE_ROOT" -path '*ld-linux*.so*' -exec chmod 0755 {} +
find "$STAGE_DIR" -type d -exec chmod 0755 {} +
find "$STAGE_DIR" -type f ! -name protocore ! -name protocore-entrypoint -exec chmod 0644 {} +
find "$SERVICE_ROOT" -path '*ld-linux*.so*' -exec chmod 0755 {} +

tar -C "$STAGE_DIR" --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2026-01-01' -cf "$TARBALL" manifest.yaml rootfs
sha256sum "$TARBALL" > "$TARBALL.sha256"

ln -sfn "$(basename "$TARBALL")" "$OUT_DIR/${EXTENSION_NAME}-${ARCH}.tar"
ln -sfn "$(basename "$TARBALL.sha256")" "$OUT_DIR/${EXTENSION_NAME}-${ARCH}.tar.sha256"
"$ROOT_DIR/scripts/write-release-metadata.sh" >/dev/null

printf '%s\n' "$TARBALL"
