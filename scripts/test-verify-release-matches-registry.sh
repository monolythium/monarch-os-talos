#!/usr/bin/env bash
# Hermetic self-test for scripts/verify-release-matches-registry.sh. Drives the
# guard against scripts/fixtures/registry/ (OFFLINE mode) and asserts the exit
# code of five cases: one PASS and four DRIFT. No network, no real registry.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/verify-release-matches-registry.sh"
FIXTURES="$HERE/fixtures/registry"

GENESIS_GOOD="$FIXTURES/chains/genesis/testnet-69420.genesis.toml"
BINARY_GOOD="$FIXTURES/bin/protocore"
STALE_JSON="$FIXTURES/stale.release.json"

[ -x "$GUARD" ] || { echo "guard not executable: $GUARD" >&2; exit 1; }
[ -f "$GENESIS_GOOD" ] || { echo "missing fixture genesis: $GENESIS_GOOD" >&2; exit 1; }
[ -f "$BINARY_GOOD" ] || { echo "missing fixture binary: $BINARY_GOOD" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0

# run_case <label> <expected-exit> <env-assignments...> -- runs the guard with
# the common offline settings plus the per-case env, comparing the exit code.
run_case() {
  local label="$1" expected="$2"
  shift 2
  local rc=0
  (
    REGISTRY_DIR="$FIXTURES" \
    REGISTRY_NETWORK="testnet-69420" \
    "$@" \
    "$GUARD"
  ) >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    echo "ok   - $label (exit $rc)"
  else
    echo "FAIL - $label (got exit $rc, expected $expected)" >&2
    fails=$((fails + 1))
  fi
}

# Case 1 (PASS): synced genesis + matching binary/tag/chain_id -> exit 0.
run_case "synced genesis + binary + tag + chain_id" 0 \
  env \
  GENESIS_TOML="$GENESIS_GOOD" \
  PROTOCORE_BINARY="$BINARY_GOOD" \
  PROTOCORE_TAG="v0.1.51-testnet" \
  CHAIN_ID="69420"

# Case 2 (FAIL): one flipped byte in the staged genesis -> exit 1.
GENESIS_FLIPPED="$TMP/genesis-flipped.toml"
cp "$GENESIS_GOOD" "$GENESIS_FLIPPED"
# Append a byte so the content differs from the canonical fixture genesis.
printf '#' >> "$GENESIS_FLIPPED"
run_case "flipped byte in staged genesis" 1 \
  env \
  GENESIS_TOML="$GENESIS_FLIPPED" \
  PROTOCORE_BINARY="$BINARY_GOOD" \
  PROTOCORE_TAG="v0.1.51-testnet" \
  CHAIN_ID="69420"

# Case 3 (FAIL): protocore binary with the wrong sha -> exit 1.
BINARY_WRONG="$TMP/protocore-wrong"
cp "$BINARY_GOOD" "$BINARY_WRONG"
printf 'tampered' >> "$BINARY_WRONG"
run_case "binary with wrong sha256" 1 \
  env \
  GENESIS_TOML="$GENESIS_GOOD" \
  PROTOCORE_BINARY="$BINARY_WRONG" \
  PROTOCORE_TAG="v0.1.51-testnet" \
  CHAIN_ID="69420"

# Case 4 (FAIL): wrong protocore tag vs fixture v0.1.51-testnet -> exit 1.
run_case "wrong protocore tag" 1 \
  env \
  GENESIS_TOML="$GENESIS_GOOD" \
  PROTOCORE_BINARY="$BINARY_GOOD" \
  PROTOCORE_TAG="v0.1.49-testnet" \
  CHAIN_ID="69420"

# Case 5 (FAIL): release.json carrying stale provenance fields -> exit 1.
run_case "stale release.json provenance" 1 \
  env \
  GENESIS_TOML="$GENESIS_GOOD" \
  PROTOCORE_BINARY="$BINARY_GOOD" \
  PROTOCORE_TAG="v0.1.51-testnet" \
  CHAIN_ID="69420" \
  RELEASE_JSON="$STALE_JSON"

if [ "$fails" -ne 0 ]; then
  echo "SELF-TEST FAILED ($fails case(s))" >&2
  exit 1
fi
echo "SELF-TEST OK (5 cases)"
