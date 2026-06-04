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
CHAIN_PROFILE="${CHAIN_PROFILE:-testnet}"
CHAIN_ID="${CHAIN_ID:-69420}"
GENESIS_TOML="${GENESIS_TOML:-"$ROOT_DIR/defaults/$CHAIN_PROFILE/genesis.toml"}"
NAME_REGISTRY_RESERVE_TOML="${NAME_REGISTRY_RESERVE_TOML:-"$ROOT_DIR/defaults/$CHAIN_PROFILE/name-registry-reserve-$CHAIN_PROFILE.toml"}"
PROTOCORE_P2P_LISTEN="${PROTOCORE_P2P_LISTEN:-/ip4/0.0.0.0/tcp/29898}"
PROTOCORE_RPC_LISTEN="${PROTOCORE_RPC_LISTEN:-0.0.0.0:8545}"
PROTOCORE_DISCOVERY="${PROTOCORE_DISCOVERY:-hybrid}"
PROTOCORE_NODE_MODE="${PROTOCORE_NODE_MODE:-operator}"
PROTOCORE_REQUIRE_ENROLLMENT="${PROTOCORE_REQUIRE_ENROLLMENT:-false}"
PROTOCORE_ENROLLMENT_FILE="${PROTOCORE_ENROLLMENT_FILE:-/var/lib/protocore/enrollment/enrollment.json}"
PROTOCORE_EXPECTED_DIGEST_FILE="${PROTOCORE_EXPECTED_DIGEST_FILE:-}"
PROTOCORE_REQUIRE_TPM_BINDING="${PROTOCORE_REQUIRE_TPM_BINDING:-false}"
PROTOCORE_TPM_QUOTE_FILE="${PROTOCORE_TPM_QUOTE_FILE:-}"
PROTOCORE_TPM_EVENT_LOG_FILE="${PROTOCORE_TPM_EVENT_LOG_FILE:-}"
PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="${PROTOCORE_TPM_SEALED_BLS_SHARE_FILE:-}"
PROTOCORE_DKG_TRANSCRIPT_FILE="${PROTOCORE_DKG_TRANSCRIPT_FILE:-}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-}"
PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY="${PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY:-}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX="${PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX:-}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH="${PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH:-}"
if [[ "$PROTOCORE_REQUIRE_TPM_BINDING" == "true" ]]; then
  PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc}"
  PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="${PROTOCORE_TPM_SEALED_BLS_SHARE_FILE:-$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE}"
fi

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$BUILD_DIR" = /* ]] || BUILD_DIR="$ROOT_DIR/$BUILD_DIR"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
[[ "$PROTOCORE_BINARY" = /* ]] || PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"
if [[ -n "$GENESIS_TOML" && "$GENESIS_TOML" != /* ]]; then
  GENESIS_TOML="$ROOT_DIR/$GENESIS_TOML"
fi
if [[ -n "$NAME_REGISTRY_RESERVE_TOML" && "$NAME_REGISTRY_RESERVE_TOML" != /* ]]; then
  NAME_REGISTRY_RESERVE_TOML="$ROOT_DIR/$NAME_REGISTRY_RESERVE_TOML"
fi

mkdir -p "$OUT_DIR" "$BUILD_DIR"

if [[ ! -x "$PROTOCORE_BINARY" ]]; then
  if [[ ! -f "$MONO_CORE_DIR/Cargo.toml" ]]; then
    echo "PROTOCORE_BINARY is not executable and MONO_CORE_DIR does not contain Cargo.toml: $MONO_CORE_DIR" >&2
    exit 1
  fi
  cargo build --release --features "$PROTOCORE_CARGO_FEATURES" --bin protocore --manifest-path "$MONO_CORE_DIR/Cargo.toml"
fi

PROTOCORE_VERSION="$("$PROTOCORE_BINARY" version --output json | jq -r '.version')"
if MONO_CORE_COMMIT="$(git -C "$MONO_CORE_DIR" rev-parse --short=12 HEAD 2>/dev/null)"; then
  :
else
  MONO_CORE_COMMIT="bin$(sha256sum "$PROTOCORE_BINARY" | awk '{print substr($1,1,12)}')"
fi
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
  mkdir -p "$SERVICE_ROOT/defaults/$CHAIN_PROFILE"
  cp "$GENESIS_TOML" "$SERVICE_ROOT/defaults/$CHAIN_PROFILE/genesis.toml"
fi

# Bake the name-registry reserve manifest. On a public-profile chain the node
# refuses to boot (RuntimeError::Boot) unless
# <home>/<network>/name-registry-reserve-<network>.toml exists, so the manifest
# must travel with the image exactly like the baked genesis. The entrypoint
# seeds it into the per-network state subdir on first boot.
RESERVE_BASENAME="name-registry-reserve-$CHAIN_PROFILE.toml"
if [[ -n "$NAME_REGISTRY_RESERVE_TOML" && -f "$NAME_REGISTRY_RESERVE_TOML" ]]; then
  mkdir -p "$SERVICE_ROOT/defaults/$CHAIN_PROFILE"
  cp "$NAME_REGISTRY_RESERVE_TOML" "$SERVICE_ROOT/defaults/$CHAIN_PROFILE/$RESERVE_BASENAME"
else
  echo "name-registry reserve manifest not found at $NAME_REGISTRY_RESERVE_TOML; public-profile nodes will refuse to boot without it" >&2
  exit 1
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

cat > "$SERVICE_CONFIG_DIR/protocore.yaml" <<EOF_SERVICE
name: protocore
container:
  entrypoint: ./protocore-entrypoint
  environment:
    - PROTOCORE_HOME=/var/lib/protocore
    - PROTOCORE_NETWORK=$CHAIN_PROFILE
    - PROTOCORE_CHAIN_ID=$CHAIN_ID
    - PROTOCORE_P2P_LISTEN=$PROTOCORE_P2P_LISTEN
    - PROTOCORE_RPC_LISTEN=$PROTOCORE_RPC_LISTEN
    - PROTOCORE_DISCOVERY=$PROTOCORE_DISCOVERY
    - PROTOCORE_NODE_MODE=$PROTOCORE_NODE_MODE
    - PROTOCORE_REQUIRE_ENROLLMENT=$PROTOCORE_REQUIRE_ENROLLMENT
    - PROTOCORE_ENROLLMENT_FILE=$PROTOCORE_ENROLLMENT_FILE
$(if [[ -n "$PROTOCORE_EXPECTED_DIGEST_FILE" ]]; then printf '    - PROTOCORE_EXPECTED_DIGEST_FILE=%s\n' "$PROTOCORE_EXPECTED_DIGEST_FILE"; fi)
    - PROTOCORE_REQUIRE_TPM_BINDING=$PROTOCORE_REQUIRE_TPM_BINDING
$(if [[ -n "$PROTOCORE_TPM_QUOTE_FILE" ]]; then printf '    - PROTOCORE_TPM_QUOTE_FILE=%s\n' "$PROTOCORE_TPM_QUOTE_FILE"; fi)
$(if [[ -n "$PROTOCORE_TPM_EVENT_LOG_FILE" ]]; then printf '    - PROTOCORE_TPM_EVENT_LOG_FILE=%s\n' "$PROTOCORE_TPM_EVENT_LOG_FILE"; fi)
$(if [[ -n "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" ]]; then printf '    - PROTOCORE_TPM_SEALED_BLS_SHARE_FILE=%s\n' "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE"; fi)
$(if [[ -n "$PROTOCORE_DKG_TRANSCRIPT_FILE" ]]; then printf '    - PROTOCORE_DKG_TRANSCRIPT_FILE=%s\n' "$PROTOCORE_DKG_TRANSCRIPT_FILE"; fi)
$(if [[ -n "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" ]]; then printf '    - PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE=%s\n' "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE"; fi)
$(if [[ -n "$PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY" ]]; then printf '    - PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY=%s\n' "$PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY"; fi)
$(if [[ -n "$PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX" ]]; then printf '    - PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX=%s\n' "$PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX"; fi)
$(if [[ -n "$PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH" ]]; then printf '    - PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH=%s\n' "$PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH"; fi)
    - PROTOCORE_KEYCHAIN_BACKEND=file
    - PROTOCORE_LOG_FORMAT=json
    - PROTOCORE_LOG_LEVEL=info
    - PROTOCORE_OUTPUT=json
    - PROTOCORE_YES=true
    - PROTOCORE_GENESIS_TOML=./defaults/$CHAIN_PROFILE/genesis.toml
    - PROTOCORE_NAME_REGISTRY_RESERVE_TOML=./defaults/$CHAIN_PROFILE/$RESERVE_BASENAME
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
(cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")

ln -sfn "$(basename "$TARBALL")" "$OUT_DIR/${EXTENSION_NAME}-${ARCH}.tar"
ln -sfn "$(basename "$TARBALL.sha256")" "$OUT_DIR/${EXTENSION_NAME}-${ARCH}.tar.sha256"
"$ROOT_DIR/scripts/write-release-metadata.sh" >/dev/null

printf '%s\n' "$TARBALL"
