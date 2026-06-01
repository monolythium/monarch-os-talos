#!/usr/bin/env bash
set -euo pipefail

INTENT_ID="${DKG_RESHARE_INTENT_ID:-${1:-}}"
BLS_PUBLIC_KEYS_HEX="${DKG_RESHARE_BLS_PUBLIC_KEYS_HEX:-${2:-}}"
THRESHOLD_SIG_HEX="${DKG_RESHARE_THRESHOLD_SIG_HEX:-${3:-}}"
OUTPUT="${DKG_RESHARE_ATTESTATION:-${ATTESTATION_OUTPUT:-${4:-}}}"
CREATED_AT="${DKG_RESHARE_CREATED_AT:-}"

fail() {
  echo "dkg-reshare-attestation-render: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

normalize_hex() {
  local label="$1"
  local value="$2"
  local body

  body="${value#0x}"
  body="${body#0X}"
  [[ -n "$body" ]] || fail "$label is required"
  [[ "$body" =~ ^[0-9a-fA-F]+$ ]] || fail "$label must be hex"
  (( ${#body} % 2 == 0 )) || fail "$label must have even hex length"
  printf '0x%s' "$(tr '[:upper:]' '[:lower:]' <<<"$body")"
}

need jq

[[ "$INTENT_ID" =~ ^[0-9]+$ ]] || fail "DKG_RESHARE_INTENT_ID must be a decimal integer"
[[ -n "$BLS_PUBLIC_KEYS_HEX" ]] || fail "DKG_RESHARE_BLS_PUBLIC_KEYS_HEX is required"
[[ -n "$THRESHOLD_SIG_HEX" ]] || fail "DKG_RESHARE_THRESHOLD_SIG_HEX is required"

pubkeys="$(normalize_hex "DKG_RESHARE_BLS_PUBLIC_KEYS_HEX" "$BLS_PUBLIC_KEYS_HEX")"
sig="$(normalize_hex "DKG_RESHARE_THRESHOLD_SIG_HEX" "$THRESHOLD_SIG_HEX")"

INTENT_ID="${INTENT_ID#"${INTENT_ID%%[!0]*}"}"
[[ -n "$INTENT_ID" ]] || fail "DKG_RESHARE_INTENT_ID must be 1..2^56-1"
max_intent_id="72057594037927935"
if (( ${#INTENT_ID} > ${#max_intent_id} )) \
  || { (( ${#INTENT_ID} == ${#max_intent_id} )) && [[ "$INTENT_ID" > "$max_intent_id" ]]; }; then
  fail "DKG_RESHARE_INTENT_ID must be 1..2^56-1"
fi

pubkey_body="${pubkeys#0x}"
sig_body="${sig#0x}"
(( ${#sig_body} == 96 * 2 )) || fail "DKG_RESHARE_THRESHOLD_SIG_HEX must be 96 bytes"
(( ${#pubkey_body} % (48 * 2) == 0 )) \
  || fail "DKG_RESHARE_BLS_PUBLIC_KEYS_HEX must be concatenated 48-byte pubkeys"
signer_count=$(( ${#pubkey_body} / (48 * 2) ))
(( signer_count >= 5 && signer_count <= 7 )) \
  || fail "DKG_RESHARE_BLS_PUBLIC_KEYS_HEX must contain 5..7 signer pubkeys"

tmp_keys="$(mktemp)"
trap 'rm -f "$tmp_keys"' EXIT
for ((offset = 0; offset < ${#pubkey_body}; offset += 96)); do
  printf '%s\n' "${pubkey_body:$offset:96}" >>"$tmp_keys"
done
unique_count="$(sort -u "$tmp_keys" | wc -l | tr -d '[:space:]')"
[[ "$unique_count" == "$signer_count" ]] \
  || fail "DKG_RESHARE_BLS_PUBLIC_KEYS_HEX contains duplicate signer pubkeys"

if [[ -z "$CREATED_AT" ]]; then
  CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi

render() {
  jq -S -n \
    --arg created_at "$CREATED_AT" \
    --arg intent_id "$INTENT_ID" \
    --arg bls_public_keys_hex "$pubkeys" \
    --arg threshold_sig_hex "$sig" \
    --argjson signer_count "$signer_count" \
    '{
      schema_version: "monarch-dkg-reshare-attestation/v1",
      created_at: $created_at,
      intent_id: $intent_id,
      bls_public_keys_hex: $bls_public_keys_hex,
      threshold_sig_hex: $threshold_sig_hex,
      signer_count: $signer_count
    }'
}

if [[ -n "$OUTPUT" ]]; then
  tmp_output="${OUTPUT}.tmp"
  render >"$tmp_output"
  mv "$tmp_output" "$OUTPUT"
else
  render
fi
