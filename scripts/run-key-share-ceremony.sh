#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEREMONY="${KEY_SHARE_CEREMONY:-${1:-}}"
OUTPUT_DIR="${KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR:-${CEREMONY_OUTPUT_DIR:-${2:-_out/key-share-ceremony}}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_ON_CHAIN_LIFECYCLE="${REQUIRE_ON_CHAIN_LIFECYCLE:-false}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"
REQUIRE_TPM_SEALING_EVIDENCE="${REQUIRE_TPM_SEALING_EVIDENCE:-false}"
REQUIRE_DKG_RESHARE_ATTESTATION="${REQUIRE_DKG_RESHARE_ATTESTATION:-false}"
REQUIRE_TPM2_CHECKQUOTE="${REQUIRE_TPM2_CHECKQUOTE:-auto}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"
VERIFY_LOCAL_FILES="${VERIFY_LOCAL_FILES:-auto}"
TPM_SEALING_EVIDENCE_FILES="${TPM_SEALING_EVIDENCE_FILES:-}"
ENROLLMENT_MANIFEST_FILES="${ENROLLMENT_MANIFEST_FILES:-}"
DKG_RESHARE_ATTESTATION_INPUT="${DKG_RESHARE_ATTESTATION_INPUT:-}"
DKG_RESHARE_ATTESTATION_OUTPUT="${DKG_RESHARE_ATTESTATION_OUTPUT:-}"
DKG_RESHARE_INTENT_ID="${DKG_RESHARE_INTENT_ID:-}"
DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX="${DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX:-}"
DKG_RESHARE_BLS_PUBLIC_KEYS_HEX="${DKG_RESHARE_BLS_PUBLIC_KEYS_HEX:-}"
DKG_RESHARE_THRESHOLD_SIG_HEX="${DKG_RESHARE_THRESHOLD_SIG_HEX:-}"
DKG_RESHARE_CREATED_AT="${DKG_RESHARE_CREATED_AT:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "key-share-ceremony-runner: $*" >&2
  exit 1
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

list_values() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0
  tr ',:' '  ' <<<"$raw" | xargs -n1 printf '%s\n'
}

validate_index() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$label must be an operator index 0 through 9: $value"
  (( value >= 0 && value <= 9 )) || fail "$label must be an operator index 0 through 9: $value"
}

enrollment_for_index() {
  local index="$1"
  local file candidate_index

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -f "$file" ]] || fail "enrollment manifest not found: $file"
    candidate_index="$(jq -r '.operator.index // ""' "$file")"
    if [[ "$candidate_index" == "$index" ]]; then
      printf '%s' "$file"
      return 0
    fi
  done < <(list_values "$ENROLLMENT_MANIFEST_FILES")
}

render_or_validate_dkg_attestation() {
  local output="$1"
  local raw_count=0
  local input="$DKG_RESHARE_ATTESTATION_INPUT"
  local intent="$DKG_RESHARE_INTENT_ID"
  local keys="${DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX:-$DKG_RESHARE_BLS_PUBLIC_KEYS_HEX}"
  local sig="$DKG_RESHARE_THRESHOLD_SIG_HEX"
  local created_at="$DKG_RESHARE_CREATED_AT"

  [[ -n "$intent" ]] && raw_count=$((raw_count + 1))
  [[ -n "$keys" ]] && raw_count=$((raw_count + 1))
  [[ -n "$sig" ]] && raw_count=$((raw_count + 1))

  if [[ -n "$input" && "$raw_count" -gt 0 ]]; then
    fail "provide either DKG_RESHARE_ATTESTATION_INPUT or raw DKG_RESHARE_* fields, not both"
  fi
  if [[ -z "$input" && "$raw_count" -gt 0 && "$raw_count" -lt 3 ]]; then
    fail "DKG_RESHARE_INTENT_ID, DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX, and DKG_RESHARE_THRESHOLD_SIG_HEX must be supplied together"
  fi
  if [[ -z "$input" && "$raw_count" -eq 0 ]]; then
    if bool_true "$REQUIRE_DKG_RESHARE_ATTESTATION"; then
      fail "DKG re-share attestation is required; provide DKG_RESHARE_ATTESTATION_INPUT or raw DKG_RESHARE_* fields"
    fi
    return 1
  fi

  if [[ -n "$input" ]]; then
    [[ -f "$input" ]] || fail "DKG_RESHARE_ATTESTATION_INPUT not found: $input"
    intent="$(jq -r '.intent_id // .intentId // ""' "$input")"
    keys="$(jq -r '.consensus_public_keys_hex // .consensusPublicKeysHex // .bls_public_keys_hex // .blsPublicKeysHex // .bls_public_keys // .blsPublicKeys // ""' "$input")"
    sig="$(jq -r '.threshold_sig_hex // .thresholdSigHex // .threshold_signature_hex // .thresholdSignatureHex // ""' "$input")"
    created_at="$(jq -r '.created_at // .createdAt // ""' "$input")"
  fi

  DKG_RESHARE_CREATED_AT="$created_at" \
    "$ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" "$intent" "$keys" "$sig" "$output"
  return 0
}

need jq
need sha256sum

[[ -n "$CEREMONY" ]] || fail "KEY_SHARE_CEREMONY or first argument is required"
[[ -f "$CEREMONY" ]] || fail "ceremony manifest not found: $CEREMONY"
jq -e . "$CEREMONY" >/dev/null || fail "ceremony manifest is not valid JSON"

mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/handoffs" "$OUTPUT_DIR/handoff-validations" "$OUTPUT_DIR/tpm-sealing-validations"

ceremony_validation="$OUTPUT_DIR/ceremony.validation.json"
EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
REQUIRE_ON_CHAIN_LIFECYCLE="$REQUIRE_ON_CHAIN_LIFECYCLE" \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
VERIFY_LOCAL_FILES="$VERIFY_LOCAL_FILES" \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$CEREMONY" >"$ceremony_validation"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
tpm_items="$tmp_dir/tpm.items"
handoff_items="$tmp_dir/handoff.items"
seen_tpm_indexes="$tmp_dir/tpm.indexes"
: >"$tpm_items"
: >"$handoff_items"
: >"$seen_tpm_indexes"

while IFS= read -r evidence; do
  [[ -n "$evidence" ]] || continue
  [[ -f "$evidence" ]] || fail "TPM sealing evidence not found: $evidence"
  index="$(jq -r '.operator.index // ""' "$evidence")"
  validate_index "TPM sealing evidence operator.index" "$index"
  validation="$OUTPUT_DIR/tpm-sealing-validations/operator-${index}.validation.json"
  enrollment="$(enrollment_for_index "$index")"
  EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
  REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  REQUIRE_TPM2_CHECKQUOTE="$REQUIRE_TPM2_CHECKQUOTE" \
  LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
  VERIFY_LOCAL_FILES="$VERIFY_LOCAL_FILES" \
  KEY_SHARE_CEREMONY="$CEREMONY" \
  ENROLLMENT_MANIFEST="$enrollment" \
    "$ROOT_DIR/scripts/validate-tpm-sealing-evidence.sh" "$evidence" >"$validation"
  printf '%s\n' "$index" >>"$seen_tpm_indexes"
  jq -n \
    --arg file "$evidence" \
    --arg validation "$validation" \
    --argjson operator_index "$index" \
    '{operator_index: $operator_index, evidence_file: $file, validation: $validation}' >>"$tpm_items"
done < <(list_values "$TPM_SEALING_EVIDENCE_FILES")

if bool_true "$REQUIRE_TPM_SEALING_EVIDENCE"; then
  for index in $(seq 0 9); do
    grep -Fx "$index" "$seen_tpm_indexes" >/dev/null \
      || fail "production ceremony requires TPM sealing evidence for operator index $index"
  done
fi

transcript_import_file="$(jq -r '.dkg.next_transcript_file // ""' "$CEREMONY")"
[[ -n "$transcript_import_file" ]] || fail "ceremony dkg.next_transcript_file is required"

for index in $(seq 0 9); do
  share_import_file="$(jq -r --argjson index "$index" '.sealed_share_outputs[] | select(.operator_index == $index) | .share_file // ""' "$CEREMONY")"
  [[ -n "$share_import_file" ]] || fail "ceremony sealed_share_outputs missing operator index $index"
  handoff="$OUTPUT_DIR/handoffs/operator-${index}.handoff.json"
  validation="$OUTPUT_DIR/handoff-validations/operator-${index}.validation.json"
  HANDOFF_SEALED_SHARE_FILE="$share_import_file" \
  HANDOFF_DKG_TRANSCRIPT_FILE="$transcript_import_file" \
  HANDOFF_CEREMONY_FILE="$CEREMONY" \
    "$ROOT_DIR/scripts/render-key-share-handoff.sh" "$CEREMONY" "$index" "$handoff"
  EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
  REQUIRE_ON_CHAIN_LIFECYCLE="$REQUIRE_ON_CHAIN_LIFECYCLE" \
  REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
  VERIFY_LOCAL_FILES="$VERIFY_LOCAL_FILES" \
    "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$handoff" "$CEREMONY" >"$validation"
  jq -n \
    --arg file "$handoff" \
    --arg validation "$validation" \
    --arg share_import_file "$share_import_file" \
    --arg transcript_import_file "$transcript_import_file" \
    --argjson operator_index "$index" \
    '{
      operator_index: $operator_index,
      handoff_file: $file,
      validation: $validation,
      import_files: {
        tpm_sealed_bls_share: $share_import_file,
        dkg_transcript: $transcript_import_file
      }
    }' >>"$handoff_items"
done

dkg_attestation_path="${DKG_RESHARE_ATTESTATION_OUTPUT:-$OUTPUT_DIR/dkg-reshare-attestation.json}"
dkg_attestation_json="null"
if render_or_validate_dkg_attestation "$dkg_attestation_path"; then
  dkg_attestation_sha="$(sha256sum "$dkg_attestation_path" | awk '{print $1}')"
  dkg_attestation_json="$(jq -n \
    --arg file "$dkg_attestation_path" \
    --arg sha256 "$dkg_attestation_sha" \
    --arg signer_count "$(jq -r '.signer_count' "$dkg_attestation_path")" \
    --arg intent_id "$(jq -r '.intent_id' "$dkg_attestation_path")" \
    '{
      file: $file,
      sha256: $sha256,
      intent_id: $intent_id,
      signer_count: ($signer_count | tonumber)
    }')"
fi

summary="$OUTPUT_DIR/key-share-ceremony-run.json"
ceremony_sha="$(sha256sum "$CEREMONY" | awk '{print $1}')"
jq -S -n \
  --arg ceremony "$CEREMONY" \
  --arg ceremony_sha "$ceremony_sha" \
  --arg ceremony_validation "$ceremony_validation" \
  --arg output_dir "$OUTPUT_DIR" \
  --arg expected_chain_profile "$EXPECTED_CHAIN_PROFILE" \
  --arg expected_chain_id "$EXPECTED_CHAIN_ID" \
  --argjson require_on_chain_lifecycle "$(bool_true "$REQUIRE_ON_CHAIN_LIFECYCLE" && printf true || printf false)" \
  --argjson require_hardware_tpm "$(bool_true "$REQUIRE_HARDWARE_TPM" && printf true || printf false)" \
  --argjson require_tpm_sealing_evidence "$(bool_true "$REQUIRE_TPM_SEALING_EVIDENCE" && printf true || printf false)" \
  --argjson require_dkg_reshare_attestation "$(bool_true "$REQUIRE_DKG_RESHARE_ATTESTATION" && printf true || printf false)" \
  --argjson tpm_sealing "$(jq -s '.' "$tpm_items")" \
  --argjson handoffs "$(jq -s '.' "$handoff_items")" \
  --argjson dkg_reshare_attestation "$dkg_attestation_json" \
  '{
    schema_version: "monarch-key-share-ceremony-run/v1",
    ok: true,
    ceremony: {
      file: $ceremony,
      sha256: $ceremony_sha,
      validation: $ceremony_validation
    },
    output_dir: $output_dir,
    policy: {
      expected_chain_profile: $expected_chain_profile,
      expected_chain_id: $expected_chain_id,
      require_on_chain_lifecycle: $require_on_chain_lifecycle,
      require_hardware_tpm: $require_hardware_tpm,
      require_tpm_sealing_evidence: $require_tpm_sealing_evidence,
      require_dkg_reshare_attestation: $require_dkg_reshare_attestation
    },
    tpm_sealing_evidence: $tpm_sealing,
    handoffs: $handoffs,
    dkg_reshare_attestation: $dkg_reshare_attestation
  }' >"$summary"

cat "$summary"
