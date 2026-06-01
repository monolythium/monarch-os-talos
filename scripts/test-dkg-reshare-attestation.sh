#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "test-dkg-reshare-attestation: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

key() {
  local byte="$1"
  printf '%096s' "" | tr ' ' "$byte"
}

need jq

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

keys="0x$(key 1)$(key 2)$(key 3)$(key 4)$(key 5)"
sig="0x$(printf '%0192s' "" | tr ' ' c)"
out="$tmp_dir/dkg-reshare-attestation.json"

DKG_RESHARE_CREATED_AT="2026-06-01T00:00:00Z" \
  "$ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" 7 "$keys" "$sig" "$out"

jq -e '
  .schema_version == "monarch-dkg-reshare-attestation/v1"
  and .intent_id == "7"
  and .signer_count == 5
  and (.bls_public_keys_hex | startswith("0x"))
  and (.threshold_sig_hex | startswith("0x"))
' "$out" >/dev/null || fail "rendered attestation artifact has wrong shape"

if "$ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" 7 "0x$(key 1)$(key 1)$(key 2)$(key 3)$(key 4)" "$sig" >/dev/null 2>&1; then
  fail "duplicate signer pubkeys must be rejected"
fi

if "$ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" 7 "0x$(key 1)$(key 2)$(key 3)$(key 4)" "$sig" >/dev/null 2>&1; then
  fail "below-threshold signer count must be rejected"
fi

if "$ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" 0 "$keys" "$sig" >/dev/null 2>&1; then
  fail "zero intent id must be rejected"
fi

echo "dkg reshare attestation renderer tests passed"
