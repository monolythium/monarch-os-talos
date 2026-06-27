#!/usr/bin/env bash
# Release-drift guard: assert that the staged genesis, the staged milestone
# config, the embedded protocore binary, the protocore release tag, and the
# chain id all agree with the chain-registry entry for this network.
# chain-registry is the single source of truth for the live chain; a Monarch OS
# image must never ship something that disagrees with it.
#
# Fail-closed: any fetch error, parse error, missing pin, or mismatch prints a
# `DRIFT:` line to stderr and exits 1. The only exit-0 path is a full match.
#
# Inputs (environment):
#   REGISTRY_NETWORK   network key in chain-registry        (default testnet-69420)
#   REGISTRY_REF       git ref / commit of chain-registry   (default master)
#   GENESIS_TOML       staged genesis to verify             (required unless MILESTONES_ONLY=1)
#   MILESTONES_TOML    staged milestone config to verify    (optional; verified when set)
#   PROTOCORE_BINARY   extracted ./protocore to verify      (required unless GENESIS_ONLY=1 / MILESTONES_ONLY=1)
#   PROTOCORE_TAG      protocore release tag baked in        (required unless GENESIS_ONLY=1 / MILESTONES_ONLY=1)
#   CHAIN_ID           chain id baked into the image        (required unless GENESIS_ONLY=1 / MILESTONES_ONLY=1)
#   RELEASE_JSON       optional generated *.release.json; if set + exists, its
#                      recorded provenance fields MUST be present and match.
#   REGISTRY_DIR       optional local chain-registry checkout. If set, the
#                      registry entry + canonical genesis/milestones are read
#                      from disk (OFFLINE mode) instead of fetched over https.
#   GENESIS_ONLY       optional `1` to run only the genesis half (no binary/tag).
#   MILESTONES_ONLY    optional `1` to run only the milestone half (no genesis/
#                      binary/tag). Used by sync-milestones-from-registry.sh.
set -euo pipefail

REGISTRY_NETWORK="${REGISTRY_NETWORK:-testnet-69420}"
REGISTRY_REF="${REGISTRY_REF:-master}"
GENESIS_TOML="${GENESIS_TOML:-}"
MILESTONES_TOML="${MILESTONES_TOML:-}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-}"
PROTOCORE_TAG="${PROTOCORE_TAG:-}"
CHAIN_ID="${CHAIN_ID:-}"
RELEASE_JSON="${RELEASE_JSON:-}"
REGISTRY_DIR="${REGISTRY_DIR:-}"
GENESIS_ONLY="${GENESIS_ONLY:-}"
MILESTONES_ONLY="${MILESTONES_ONLY:-}"

NET="$REGISTRY_NETWORK"
REF="$REGISTRY_REF"

fail() {
  # fail <field> <staged> <registry>
  echo "DRIFT: $1 staged=$2 registry=$3 (network=$NET)" >&2
  exit 1
}

die() {
  echo "verify-release-matches-registry: $1 (network=$NET)" >&2
  exit 1
}

# `do_genesis` gates the genesis/binary/tag/chain_id half. MILESTONES_ONLY=1
# (the sync-milestones path) verifies only the staged milestone config.
do_genesis=1
[ "$MILESTONES_ONLY" = "1" ] && do_genesis=0

# --- input sanity ---------------------------------------------------------
if [ "$do_genesis" = "1" ]; then
  [ -n "$GENESIS_TOML" ] || die "GENESIS_TOML is required"
  [ -f "$GENESIS_TOML" ] || die "GENESIS_TOML not found: $GENESIS_TOML"

  if [ "$GENESIS_ONLY" != "1" ]; then
    [ -n "$PROTOCORE_BINARY" ] || die "PROTOCORE_BINARY is required (or set GENESIS_ONLY=1)"
    [ -f "$PROTOCORE_BINARY" ] || die "PROTOCORE_BINARY not found: $PROTOCORE_BINARY"
    [ -n "$PROTOCORE_TAG" ] || die "PROTOCORE_TAG is required (or set GENESIS_ONLY=1)"
    [ -n "$CHAIN_ID" ] || die "CHAIN_ID is required (or set GENESIS_ONLY=1)"
  fi
else
  [ -n "$MILESTONES_TOML" ] || die "MILESTONES_TOML is required when MILESTONES_ONLY=1"
fi

if [ -n "$MILESTONES_TOML" ]; then
  [ -f "$MILESTONES_TOML" ] || die "MILESTONES_TOML not found: $MILESTONES_TOML"
fi

for tool in sha256sum cmp; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REGISTRY_TOML="$WORKDIR/registry.toml"
CANON_GENESIS="$WORKDIR/canonical.genesis.toml"
CANON_MILESTONES="$WORKDIR/canonical.milestones.toml"

# --- (a) resolve the registry entry + canonical genesis/milestones --------
if [ -n "$REGISTRY_DIR" ]; then
  # OFFLINE mode — read from a local checkout.
  src_toml="$REGISTRY_DIR/chains/$NET.toml"
  [ -f "$src_toml" ] || die "offline registry entry not found: $src_toml"
  cp "$src_toml" "$REGISTRY_TOML"
  if [ "$do_genesis" = "1" ]; then
    src_genesis="$REGISTRY_DIR/chains/genesis/$NET.genesis.toml"
    [ -f "$src_genesis" ] || die "offline canonical genesis not found: $src_genesis"
    cp "$src_genesis" "$CANON_GENESIS"
  fi
  if [ -n "$MILESTONES_TOML" ]; then
    src_milestones="$REGISTRY_DIR/chains/milestones/$NET.milestones.toml"
    [ -f "$src_milestones" ] || die "offline canonical milestones not found: $src_milestones"
    cp "$src_milestones" "$CANON_MILESTONES"
  fi
else
  command -v curl >/dev/null 2>&1 || die "missing required tool: curl (online mode)"
  base="https://raw.githubusercontent.com/monolythium/chain-registry/$REF/chains"
  entry_url="$base/$NET.toml"
  curl -fsSL "$entry_url" -o "$REGISTRY_TOML" \
    || die "failed to fetch registry entry: $entry_url"
fi

# --- minimal TOML key reader ----------------------------------------------
# Reads a top-level `key = "value"` or `key = value` pair (string or bare),
# ignoring `#` comments and surrounding whitespace. Top-level only (stops at the
# first table header), which is all the provenance keys we need.
registry_key() {
  local key="$1" file="$2"
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { exit }
    {
      line=$0
      sub(/[[:space:]]*#.*$/, "", line)
      n=index(line, "=")
      if (n==0) next
      lhs=substr(line,1,n-1)
      rhs=substr(line,n+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs!=k) next
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
      gsub(/^"|"$/, "", rhs)
      print rhs
      exit
    }
  ' "$file"
}

GENESIS_URL="$(registry_key genesis_url "$REGISTRY_TOML")"
GENESIS_SHA256_REG="$(registry_key genesis_sha256 "$REGISTRY_TOML")"
GENESIS_HASH_REG="$(registry_key genesis_hash "$REGISTRY_TOML")"
CHAIN_ID_REG="$(registry_key chain_id "$REGISTRY_TOML")"
RELEASE_TAG_REG="$(registry_key release_tag "$REGISTRY_TOML")"
BINARY_SHA256_REG="$(registry_key binary_release_sha256 "$REGISTRY_TOML")"
MILESTONES_URL="$(registry_key milestones_url "$REGISTRY_TOML")"
MILESTONES_SHA256_REG="$(registry_key milestones_sha256 "$REGISTRY_TOML")"

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

keccak256_of() {
  # Best-effort keccak256 over the file. Prints `0x<hex>` on success; prints
  # nothing and returns non-zero if no keccak implementation is available.
  local f="$1"
  python3 - "$f" <<'PY' 2>/dev/null
import sys
path = sys.argv[1]
data = open(path, "rb").read()
try:
    from Crypto.Hash import keccak
    h = keccak.new(digest_bits=256)
    h.update(data)
    print("0x" + h.hexdigest())
    sys.exit(0)
except Exception:
    pass
try:
    import sha3  # pysha3
    print("0x" + sha3.keccak_256(data).hexdigest())
    sys.exit(0)
except Exception:
    pass
sys.exit(3)
PY
}

if [ "$do_genesis" = "1" ]; then
  # --- (b) require the genesis pins we depend on ---------------------------
  [ -n "$GENESIS_SHA256_REG" ] || die "registry entry missing genesis_sha256"
  [ -n "$GENESIS_HASH_REG" ]   || die "registry entry missing genesis_hash"
  [ -n "$CHAIN_ID_REG" ]       || die "registry entry missing chain_id"
  if [ "$GENESIS_ONLY" != "1" ]; then
    [ -n "$RELEASE_TAG_REG" ]    || die "registry entry missing release_tag"
    [ -n "$BINARY_SHA256_REG" ]  || die "registry entry missing binary_release_sha256"
  fi

  # Fetch the canonical genesis (online: follow genesis_url; offline: already copied).
  if [ -z "$REGISTRY_DIR" ]; then
    [ -n "$GENESIS_URL" ] || die "registry entry missing genesis_url"
    curl -fsSL "$GENESIS_URL" -o "$CANON_GENESIS" \
      || die "failed to fetch canonical genesis: $GENESIS_URL"
  fi

  # --- (c) GENESIS checks (always) ----------------------------------------
  # Byte-identity against the registry's canonical genesis is the primary check:
  # the registry's genesis_hash (keccak) was computed over exactly these bytes, so
  # byte-identity transitively inherits that keccak verification.
  if ! cmp -s "$GENESIS_TOML" "$CANON_GENESIS"; then
    staged_sha="$(sha256_of "$GENESIS_TOML")"
    canon_sha="$(sha256_of "$CANON_GENESIS")"
    fail "genesis_bytes" "$staged_sha" "$canon_sha"
  fi

  GENESIS_SHA256_STAGED="$(sha256_of "$GENESIS_TOML")"
  [ "$GENESIS_SHA256_STAGED" = "$GENESIS_SHA256_REG" ] \
    || fail "genesis_sha256" "$GENESIS_SHA256_STAGED" "$GENESIS_SHA256_REG"

  # keccak is BEST-EFFORT. If a keccak tool is present we require a match; if it
  # is absent we skip it, because byte-identity to the keccak-verified canonical
  # bytes already proves the hash transitively.
  if GENESIS_KECCAK_STAGED="$(keccak256_of "$GENESIS_TOML")"; then
    reg_hash_lc="$(printf '%s' "$GENESIS_HASH_REG" | tr '[:upper:]' '[:lower:]')"
    staged_hash_lc="$(printf '%s' "$GENESIS_KECCAK_STAGED" | tr '[:upper:]' '[:lower:]')"
    [ "$staged_hash_lc" = "$reg_hash_lc" ] \
      || fail "genesis_hash" "$GENESIS_KECCAK_STAGED" "$GENESIS_HASH_REG"
  else
    echo "note: keccak skipped (byte-identity to keccak-verified canonical already proven)" >&2
  fi

  # --- (e) CHAIN_ID check -------------------------------------------------
  if [ -n "$CHAIN_ID" ]; then
    [ "$CHAIN_ID" = "$CHAIN_ID_REG" ] \
      || fail "chain_id" "$CHAIN_ID" "$CHAIN_ID_REG"
  fi

  # --- (d) BINARY + TAG checks (skip if GENESIS_ONLY=1) -------------------
  if [ "$GENESIS_ONLY" != "1" ]; then
    BIN_SHA256_STAGED="$(sha256_of "$PROTOCORE_BINARY")"
    [ "$BIN_SHA256_STAGED" = "$BINARY_SHA256_REG" ] \
      || fail "binary_release_sha256" "$BIN_SHA256_STAGED" "$BINARY_SHA256_REG"

    [ "$PROTOCORE_TAG" = "$RELEASE_TAG_REG" ] \
      || fail "release_tag" "$PROTOCORE_TAG" "$RELEASE_TAG_REG"
  fi
fi

# --- (m) MILESTONES checks (whenever a staged milestone config is given) --
# The genesis.toml embeds none of the chain's height-keyed effective-params; a
# node booting without the canonical milestone config falls back to compiled
# defaults and FORKS at height 1. So the staged milestone config the image bakes
# must byte-match the registry's canonical milestones, exactly like the genesis.
# Authenticity rests on milestones_sha256 (mirrors genesis_sha256); there is no
# keccak pin for milestones.
if [ -n "$MILESTONES_TOML" ]; then
  [ -n "$MILESTONES_SHA256_REG" ] || die "registry entry missing milestones_sha256"

  if [ -z "$REGISTRY_DIR" ]; then
    [ -n "$MILESTONES_URL" ] || die "registry entry missing milestones_url"
    curl -fsSL "$MILESTONES_URL" -o "$CANON_MILESTONES" \
      || die "failed to fetch canonical milestones: $MILESTONES_URL"
  fi

  if ! cmp -s "$MILESTONES_TOML" "$CANON_MILESTONES"; then
    staged_sha="$(sha256_of "$MILESTONES_TOML")"
    canon_sha="$(sha256_of "$CANON_MILESTONES")"
    fail "milestones_bytes" "$staged_sha" "$canon_sha"
  fi

  MILESTONES_SHA256_STAGED="$(sha256_of "$MILESTONES_TOML")"
  [ "$MILESTONES_SHA256_STAGED" = "$MILESTONES_SHA256_REG" ] \
    || fail "milestones_sha256" "$MILESTONES_SHA256_STAGED" "$MILESTONES_SHA256_REG"
fi

# --- (f) METADATA cross-check (only if RELEASE_JSON set AND exists) --------
# A release.json that is provided but lacks the provenance fields is itself a
# failure — never silently skip a present-but-incomplete metadata file.
if [ -n "$RELEASE_JSON" ] && [ -f "$RELEASE_JSON" ]; then
  command -v jq >/dev/null 2>&1 || die "RELEASE_JSON set but jq is unavailable"

  if [ "$do_genesis" = "1" ]; then
    rj_genesis_sha="$(jq -r '.channel.chain.genesis.sha256 // empty' "$RELEASE_JSON")"
    rj_chain_id="$(jq -r '.channel.chain.chain_id // empty' "$RELEASE_JSON")"
    rj_binary_sha="$(jq -r '.sources.protocore_binary.sha256 // empty' "$RELEASE_JSON")"

    [ -n "$rj_genesis_sha" ] || die "RELEASE_JSON missing .channel.chain.genesis.sha256"
    [ -n "$rj_chain_id" ]    || die "RELEASE_JSON missing .channel.chain.chain_id"
    [ -n "$rj_binary_sha" ]  || die "RELEASE_JSON missing .sources.protocore_binary.sha256"

    [ "$rj_genesis_sha" = "$GENESIS_SHA256_REG" ] \
      || fail "release_json.genesis_sha256" "$rj_genesis_sha" "$GENESIS_SHA256_REG"
    [ "$rj_chain_id" = "$CHAIN_ID_REG" ] \
      || fail "release_json.chain_id" "$rj_chain_id" "$CHAIN_ID_REG"
    if [ "$GENESIS_ONLY" != "1" ]; then
      [ "$rj_binary_sha" = "$BINARY_SHA256_REG" ] \
        || fail "release_json.protocore_binary_sha256" "$rj_binary_sha" "$BINARY_SHA256_REG"
    fi
  fi

  if [ -n "$MILESTONES_TOML" ]; then
    rj_milestones_sha="$(jq -r '.channel.chain.milestones.sha256 // empty' "$RELEASE_JSON")"
    [ -n "$rj_milestones_sha" ] || die "RELEASE_JSON missing .channel.chain.milestones.sha256"
    [ "$rj_milestones_sha" = "$MILESTONES_SHA256_REG" ] \
      || fail "release_json.milestones_sha256" "$rj_milestones_sha" "$MILESTONES_SHA256_REG"
  fi
fi

# --- (g) success ----------------------------------------------------------
if [ "$do_genesis" = "0" ]; then
  echo "OK: $NET milestones match chain-registry ($REF)"
elif [ "$GENESIS_ONLY" = "1" ]; then
  if [ -n "$MILESTONES_TOML" ]; then
    echo "OK: $NET genesis+milestones match chain-registry ($REF)"
  else
    echo "OK: $NET genesis matches chain-registry ($REF)"
  fi
else
  if [ -n "$MILESTONES_TOML" ]; then
    echo "OK: $NET genesis+milestones+binary+tag+chain_id match chain-registry ($REF)"
  else
    echo "OK: $NET genesis+binary+tag+chain_id match chain-registry ($REF)"
  fi
fi
