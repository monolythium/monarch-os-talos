#!/usr/bin/env bash
# Sync the staged milestone config from chain-registry. The genesis.toml embeds
# none of the chain's height-keyed effective-params (binary_state_tree_active_height,
# epoch_seed_*, delegation_settle_fix_height, fee splits, precompile gates) — those
# live ONLY in the milestone config. A node booting without the canonical milestones
# falls back to compiled defaults and FORKS at height 1, so the image must stage the
# milestones exactly like the genesis + the name-registry reserve.
#
# This is the milestones counterpart of sync-genesis-from-registry.sh: instead of
# hand-editing the staged defaults/<profile>/milestones.toml, fetch the canonical
# milestones the live chain is pinned to, verify its sha256 against the registry's
# milestones_sha256, and copy it into place. The release-drift guard then proves the
# staged file matches on every build.
#
# Inputs (environment):
#   REGISTRY_NETWORK   network key in chain-registry      (default testnet-69420)
#   REGISTRY_REF       git ref / commit of chain-registry (default master)
#   MILESTONES_TOML    destination staged milestones path (required)
#   REGISTRY_DIR       optional local chain-registry checkout (offline source)
set -euo pipefail

REGISTRY_NETWORK="${REGISTRY_NETWORK:-testnet-69420}"
REGISTRY_REF="${REGISTRY_REF:-master}"
MILESTONES_TOML="${MILESTONES_TOML:-}"
REGISTRY_DIR="${REGISTRY_DIR:-}"

NET="$REGISTRY_NETWORK"
REF="$REGISTRY_REF"

die() {
  echo "sync-milestones-from-registry: $1 (network=$NET)" >&2
  exit 1
}

[ -n "$MILESTONES_TOML" ] || die "MILESTONES_TOML is required"
command -v sha256sum >/dev/null 2>&1 || die "missing required tool: sha256sum"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FETCHED="$WORKDIR/milestones.toml"

if [ -n "$REGISTRY_DIR" ]; then
  src="$REGISTRY_DIR/chains/milestones/$NET.milestones.toml"
  [ -f "$src" ] || die "offline canonical milestones not found: $src"
  cp "$src" "$FETCHED"
else
  command -v curl >/dev/null 2>&1 || die "missing required tool: curl"
  entry_url="https://raw.githubusercontent.com/monolythium/chain-registry/$REF/chains/$NET.toml"
  entry="$WORKDIR/registry.toml"
  curl -fsSL "$entry_url" -o "$entry" || die "failed to fetch registry entry: $entry_url"
  milestones_url="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { exit }
    {
      line=$0; sub(/[[:space:]]*#.*$/, "", line)
      n=index(line, "="); if (n==0) next
      lhs=substr(line,1,n-1); rhs=substr(line,n+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs!="milestones_url") next
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs); gsub(/^"|"$/, "", rhs)
      print rhs; exit
    }' "$entry")"
  [ -n "$milestones_url" ] || die "registry entry missing milestones_url"
  curl -fsSL "$milestones_url" -o "$FETCHED" || die "failed to fetch canonical milestones: $milestones_url"
fi

# Verify sha256 == milestones_sha256 (the MILESTONES_ONLY guard run against the
# fetched file) before writing anything. This re-uses the single guard so the
# sha256 logic lives in exactly one place — mirrors the GENESIS_ONLY check that
# sync-genesis-from-registry.sh performs.
HERE="$(cd "$(dirname "$0")" && pwd)"
REGISTRY_NETWORK="$NET" REGISTRY_REF="$REF" REGISTRY_DIR="$REGISTRY_DIR" \
  MILESTONES_TOML="$FETCHED" MILESTONES_ONLY=1 \
  "$HERE/verify-release-matches-registry.sh" >/dev/null \
  || die "fetched milestones failed registry verification; not writing $MILESTONES_TOML"

mkdir -p "$(dirname "$MILESTONES_TOML")"
cp "$FETCHED" "$MILESTONES_TOML"
echo "OK: synced $NET milestones from chain-registry ($REF) -> $MILESTONES_TOML"
