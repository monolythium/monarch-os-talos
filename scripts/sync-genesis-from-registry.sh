#!/usr/bin/env bash
# Sync the staged genesis from chain-registry. This is the one operator action
# at re-genesis time: instead of hand-editing the staged
# defaults/<profile>/genesis.toml, fetch the canonical genesis the live chain is
# pinned to, verify its keccak256 against the registry's genesis_hash, and copy
# it into place. The release-drift guard then proves the staged file matches on
# every build.
#
# Inputs (environment):
#   REGISTRY_NETWORK   network key in chain-registry      (default testnet-69420)
#   REGISTRY_REF       git ref / commit of chain-registry (default master)
#   GENESIS_TOML       destination staged genesis path    (required)
#   REGISTRY_DIR       optional local chain-registry checkout (offline source)
set -euo pipefail

REGISTRY_NETWORK="${REGISTRY_NETWORK:-testnet-69420}"
REGISTRY_REF="${REGISTRY_REF:-master}"
GENESIS_TOML="${GENESIS_TOML:-}"
REGISTRY_DIR="${REGISTRY_DIR:-}"

NET="$REGISTRY_NETWORK"
REF="$REGISTRY_REF"

die() {
  echo "sync-genesis-from-registry: $1 (network=$NET)" >&2
  exit 1
}

[ -n "$GENESIS_TOML" ] || die "GENESIS_TOML is required"
command -v sha256sum >/dev/null 2>&1 || die "missing required tool: sha256sum"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FETCHED="$WORKDIR/genesis.toml"

if [ -n "$REGISTRY_DIR" ]; then
  src="$REGISTRY_DIR/chains/genesis/$NET.genesis.toml"
  [ -f "$src" ] || die "offline canonical genesis not found: $src"
  cp "$src" "$FETCHED"
else
  command -v curl >/dev/null 2>&1 || die "missing required tool: curl"
  entry_url="https://raw.githubusercontent.com/monolythium/chain-registry/$REF/chains/$NET.toml"
  entry="$WORKDIR/registry.toml"
  curl -fsSL "$entry_url" -o "$entry" || die "failed to fetch registry entry: $entry_url"
  genesis_url="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { exit }
    {
      line=$0; sub(/[[:space:]]*#.*$/, "", line)
      n=index(line, "="); if (n==0) next
      lhs=substr(line,1,n-1); rhs=substr(line,n+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs!="genesis_url") next
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs); gsub(/^"|"$/, "", rhs)
      print rhs; exit
    }' "$entry")"
  [ -n "$genesis_url" ] || die "registry entry missing genesis_url"
  curl -fsSL "$genesis_url" -o "$FETCHED" || die "failed to fetch canonical genesis: $genesis_url"
fi

# Verify keccak == genesis_hash (GENESIS_ONLY guard run against the fetched file)
# before writing anything. This re-uses the single guard so the keccak / sha256
# logic lives in exactly one place.
HERE="$(cd "$(dirname "$0")" && pwd)"
REGISTRY_NETWORK="$NET" REGISTRY_REF="$REF" REGISTRY_DIR="$REGISTRY_DIR" \
  GENESIS_TOML="$FETCHED" GENESIS_ONLY=1 \
  "$HERE/verify-release-matches-registry.sh" >/dev/null \
  || die "fetched genesis failed registry verification; not writing $GENESIS_TOML"

mkdir -p "$(dirname "$GENESIS_TOML")"
cp "$FETCHED" "$GENESIS_TOML"
echo "OK: synced $NET genesis from chain-registry ($REF) -> $GENESIS_TOML"
