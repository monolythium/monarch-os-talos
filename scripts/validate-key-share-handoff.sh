#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOFF="${KEY_SHARE_HANDOFF:-${HANDOFF_MANIFEST:-${1:-}}}"
CEREMONY="${KEY_SHARE_CEREMONY:-${2:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_ON_CHAIN_LIFECYCLE="${REQUIRE_ON_CHAIN_LIFECYCLE:-false}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"
VERIFY_LOCAL_FILES="${VERIFY_LOCAL_FILES:-auto}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "key-share-handoff: $*" >&2
  exit 1
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$HANDOFF"
}

ceremony_field() {
  local path="$1"
  jq -r "$path // \"\"" "$CEREMONY"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

hash32_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local expected_norm actual_norm

  expected_norm="$(tr '[:upper:]' '[:lower:]' <<<"${expected#0x}")"
  actual_norm="$(tr '[:upper:]' '[:lower:]' <<<"${actual#0x}")"
  [[ "$expected_norm" == "$actual_norm" ]] \
    || fail "$label mismatch: expected=$expected actual=$actual"
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 32-byte hex digest"
}

validate_consensus_pubkey() {
  local label="$1"
  local value="$2"
  # ML-DSA-65 public key, 1952 bytes = 3904 hex chars. There is no threshold
  # group key under the post-quantum per-operator multisig; this field records
  # the cluster's ML-DSA-65 consensus public key.
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{3904}$ ]] \
    || fail "$label must be a 1952-byte ML-DSA-65 public key"
}

validate_file_ref() {
  local label="$1"
  local path="$2"
  local prefix="${3-/var/lib/protocore/secrets/}"

  [[ -n "$path" ]] || fail "$label is required"
  if [[ -n "$prefix" ]]; then
    [[ "$path" == "$prefix"* ]] || fail "$label must be under $prefix: $path"
  fi
  if [[ "$path" == *"@"* ]]; then
    fail "$label must be a file path, not an inline credential: $path"
  fi
  if grep -Eiq '<replace|replace-with|changeme|placeholder|example-secret' <<<"$path"; then
    fail "$label contains a placeholder path: $path"
  fi
}

local_path_for() {
  local remote_path="$1"

  if [[ -n "$LOCAL_EVIDENCE_ROOT" ]]; then
    printf '%s/%s' "${LOCAL_EVIDENCE_ROOT%/}" "${remote_path#/}"
    return
  fi
  printf '%s' "$remote_path"
}

verify_file_hash() {
  local label="$1"
  local remote_path="$2"
  local expected_sha="$3"
  local local_path actual_sha size_bytes

  [[ -n "$remote_path" ]] || fail "$label path is required"
  [[ -n "$expected_sha" ]] || fail "$label expected sha256 is required"
  local_path="$(local_path_for "$remote_path")"
  [[ -f "$local_path" ]] || fail "$label file not found: $local_path"
  actual_sha="$(sha256sum "$local_path" | awk '{print $1}')"
  size_bytes="$(wc -c <"$local_path" | tr -d '[:space:]')"
  hash32_equals "$label sha256" "$expected_sha" "$actual_sha"

  jq -n \
    --arg label "$label" \
    --arg path "$remote_path" \
    --arg local_path "$local_path" \
    --arg sha256 "$actual_sha" \
    --argjson size_bytes "$size_bytes" \
    '{label: $label, path: $path, local_path: $local_path, sha256: $sha256, size_bytes: $size_bytes}'
}

need jq
need sha256sum

[[ -n "$HANDOFF" ]] || fail "KEY_SHARE_HANDOFF, HANDOFF_MANIFEST, or first argument is required"
[[ -f "$HANDOFF" ]] || fail "handoff manifest not found: $HANDOFF"
[[ -n "$CEREMONY" ]] || fail "KEY_SHARE_CEREMONY or second argument is required"
[[ -f "$CEREMONY" ]] || fail "ceremony manifest not found: $CEREMONY"

jq -e . "$HANDOFF" >/dev/null || fail "handoff manifest is not valid JSON"
if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$HANDOFF" >/dev/null; then
  fail "handoff manifest contains placeholder string values"
fi

EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
REQUIRE_ON_CHAIN_LIFECYCLE="$REQUIRE_ON_CHAIN_LIFECYCLE" \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$CEREMONY" >/dev/null

schema="$(field '.schema_version')"
[[ "$schema" == "monarch-protocore-key-share-handoff/v1" ]] \
  || fail "unsupported schema_version: $schema"

ceremony_sha_expected="$(field '.ceremony_manifest.sha256')"
ceremony_sha_actual="$(sha256sum "$CEREMONY" | awk '{print $1}')"
validate_file_ref "ceremony_manifest.file" "$(field '.ceremony_manifest.file')" ""
validate_hash32 "ceremony_manifest.sha256" "$ceremony_sha_expected"
hash32_equals "ceremony_manifest.sha256" "$ceremony_sha_actual" "$ceremony_sha_expected"

chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
cluster_id="$(field '.cluster.id')"
operator_index="$(field '.operator.index')"
cluster_operator_index="$(field '.cluster.operator_index')"
operator_address="$(field '.operator.address')"
operator_position="$(field '.operator.position')"
operator_tpm_mode="$(field '.operator.tpm_mode')"
operator_quote_hash="$(field '.operator.pcr_quote_hash')"
operator_event_log_hash="$(field '.operator.pcr_event_log_hash')"
operator_policy_hash="$(field '.operator.sealed_share_policy_hash')"
next_dkg_epoch="$(field '.cluster.next_dkg_epoch')"

[[ -n "$chain_profile" ]] || fail "chain.profile is required"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "chain.chain_id must be numeric: $chain_id"
if [[ -n "$EXPECTED_CHAIN_PROFILE" ]]; then
  [[ "$chain_profile" == "$EXPECTED_CHAIN_PROFILE" ]] \
    || fail "chain profile mismatch: expected=$EXPECTED_CHAIN_PROFILE actual=$chain_profile"
fi
if [[ -n "$EXPECTED_CHAIN_ID" ]]; then
  [[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] \
    || fail "chain id mismatch: expected=$EXPECTED_CHAIN_ID actual=$chain_id"
fi

[[ "$cluster_id" == "$(ceremony_field '.cluster.id')" ]] \
  || fail "cluster.id must match ceremony cluster.id"
[[ "$next_dkg_epoch" == "$(ceremony_field '.cluster.next_dkg_epoch')" ]] \
  || fail "cluster.next_dkg_epoch must match ceremony cluster.next_dkg_epoch"
[[ "$operator_index" =~ ^[0-9]+$ ]] || fail "operator.index must be 0 through 9"
(( operator_index >= 0 && operator_index <= 9 )) || fail "operator.index must be 0 through 9"
[[ "$cluster_operator_index" == "$operator_index" ]] \
  || fail "cluster.operator_index must match operator.index"

ceremony_operator_json="$(jq -c --argjson index "$operator_index" '.operators[] | select(.index == $index)' "$CEREMONY")"
[[ -n "$ceremony_operator_json" ]] || fail "operator.index is not present in ceremony roster"
ceremony_share_json="$(jq -c --argjson index "$operator_index" '.sealed_share_outputs[] | select(.operator_index == $index)' "$CEREMONY")"
[[ -n "$ceremony_share_json" ]] || fail "sealed share output for operator.index is not present in ceremony"

[[ "$operator_address" =~ ^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$ ]] \
  || fail "operator.address must be mono1 or 0x address"
case "$operator_position" in
  active|standby) ;;
  *) fail "operator.position must be active or standby" ;;
esac
case "$operator_tpm_mode" in
  hardware-tpm2|vtpm-testnet) ;;
  *) fail "operator.tpm_mode must be hardware-tpm2 or vtpm-testnet" ;;
esac
validate_hash32 "operator.pcr_quote_hash" "$operator_quote_hash"
validate_hash32 "operator.pcr_event_log_hash" "$operator_event_log_hash"
validate_hash32 "operator.sealed_share_policy_hash" "$operator_policy_hash"

[[ "$operator_address" == "$(jq -r '.address' <<<"$ceremony_operator_json")" ]] \
  || fail "operator.address must match ceremony roster"
[[ "$operator_position" == "$(jq -r '.position' <<<"$ceremony_operator_json")" ]] \
  || fail "operator.position must match ceremony roster"
[[ "$(field '.cluster.position')" == "$operator_position" ]] \
  || fail "cluster.position must match operator.position"
[[ "$operator_tpm_mode" == "$(jq -r '.tpm_mode' <<<"$ceremony_operator_json")" ]] \
  || fail "operator.tpm_mode must match ceremony roster"
hash32_equals "operator.pcr_quote_hash" "$(jq -r '.pcr_quote_hash' <<<"$ceremony_operator_json")" "$operator_quote_hash"
hash32_equals "operator.pcr_event_log_hash" "$(jq -r '.pcr_event_log_hash' <<<"$ceremony_operator_json")" "$operator_event_log_hash"
hash32_equals "operator.sealed_share_policy_hash" "$(jq -r '.sealed_share_policy_hash' <<<"$ceremony_operator_json")" "$operator_policy_hash"

handoff_source_ceremony_id="$(field '.handoff.source_ceremony_id')"
handoff_source_ceremony_type="$(field '.handoff.source_ceremony_type')"
handoff_runbook_id="$(field '.handoff.runbook_id')"
[[ -n "$(field '.handoff.id')" ]] || fail "handoff.id is required"
[[ "$(field '.handoff.created_at')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "handoff.created_at must be UTC timestamp"
[[ "$handoff_source_ceremony_id" == "$(ceremony_field '.ceremony.id')" ]] \
  || fail "handoff.source_ceremony_id must match ceremony.id"
[[ "$handoff_source_ceremony_type" == "$(ceremony_field '.ceremony.type')" ]] \
  || fail "handoff.source_ceremony_type must match ceremony.type"
[[ "$handoff_runbook_id" == "$(ceremony_field '.ceremony.runbook_id')" ]] \
  || fail "handoff.runbook_id must match ceremony.runbook_id"

dkg_scheme="$(field '.dkg.threshold_scheme')"
dkg_source_file="$(field '.dkg.transcript_source_file')"
dkg_import_file="$(field '.dkg.transcript_import_file')"
dkg_sha="$(field '.dkg.transcript_sha256')"
dkg_commitment_hash="$(field '.dkg.transcript_commitment_hash')"
dkg_participant_hash="$(field '.dkg.participant_commitments_hash')"
dkg_share_bundle_hash="$(field '.dkg.encrypted_share_bundle_hash')"
dkg_group_public_key="$(field '.dkg.group_public_key_hex')"
[[ "$dkg_scheme" == "ML-DSA-65-bitmap-multisig" ]] || fail "dkg.threshold_scheme must be ML-DSA-65-bitmap-multisig"
validate_file_ref "dkg.transcript_source_file" "$dkg_source_file"
validate_file_ref "dkg.transcript_import_file" "$dkg_import_file"
validate_hash32 "dkg.transcript_sha256" "$dkg_sha"
validate_hash32 "dkg.transcript_commitment_hash" "$dkg_commitment_hash"
validate_hash32 "dkg.participant_commitments_hash" "$dkg_participant_hash"
validate_hash32 "dkg.encrypted_share_bundle_hash" "$dkg_share_bundle_hash"
validate_consensus_pubkey "dkg.group_public_key_hex" "$dkg_group_public_key"
[[ "$dkg_source_file" == "$(ceremony_field '.dkg.next_transcript_file')" ]] \
  || fail "dkg.transcript_source_file must match ceremony dkg.next_transcript_file"
hash32_equals "dkg.transcript_sha256" "$(ceremony_field '.dkg.next_transcript_hash')" "$dkg_sha"
hash32_equals "dkg.transcript_commitment_hash" "$(ceremony_field '.dkg.transcript_commitment_hash')" "$dkg_commitment_hash"
hash32_equals "dkg.participant_commitments_hash" "$(ceremony_field '.dkg.participant_commitments_hash')" "$dkg_participant_hash"
hash32_equals "dkg.encrypted_share_bundle_hash" "$(ceremony_field '.dkg.encrypted_share_bundle_hash')" "$dkg_share_bundle_hash"
hash32_equals "dkg.group_public_key_hex" "$(ceremony_field '.dkg.group_public_key_hex')" "$dkg_group_public_key"

sealed_source_file="$(field '.sealed_share.source_file')"
sealed_import_file="$(field '.sealed_share.import_file')"
sealed_sha="$(field '.sealed_share.sha256')"
sealed_to_tpm="$(field '.sealed_share.sealed_to_tpm')"
sealed_tpm_mode="$(field '.sealed_share.tpm_mode')"
sealed_quote_hash="$(field '.sealed_share.pcr_quote_hash')"
sealed_event_log_hash="$(field '.sealed_share.pcr_event_log_hash')"
sealed_policy_hash="$(field '.sealed_share.sealed_share_policy_hash')"
sealed_dkg_hash="$(field '.sealed_share.dkg_transcript_hash')"
sealed_dkg_epoch="$(field '.sealed_share.dkg_epoch')"
validate_file_ref "sealed_share.source_file" "$sealed_source_file"
validate_file_ref "sealed_share.import_file" "$sealed_import_file"
validate_hash32 "sealed_share.sha256" "$sealed_sha"
[[ "$sealed_to_tpm" == "true" ]] || fail "sealed_share.sealed_to_tpm must be true"
[[ "$sealed_tpm_mode" == "$operator_tpm_mode" ]] || fail "sealed_share.tpm_mode must match operator.tpm_mode"
validate_hash32 "sealed_share.pcr_quote_hash" "$sealed_quote_hash"
validate_hash32 "sealed_share.pcr_event_log_hash" "$sealed_event_log_hash"
validate_hash32 "sealed_share.sealed_share_policy_hash" "$sealed_policy_hash"
validate_hash32 "sealed_share.dkg_transcript_hash" "$sealed_dkg_hash"
[[ "$sealed_dkg_epoch" == "$next_dkg_epoch" ]] \
  || fail "sealed_share.dkg_epoch must match cluster.next_dkg_epoch"
[[ "$sealed_source_file" == "$(jq -r '.share_file' <<<"$ceremony_share_json")" ]] \
  || fail "sealed_share.source_file must match ceremony sealed_share_outputs"
hash32_equals "sealed_share.sha256" "$(jq -r '.sha256' <<<"$ceremony_share_json")" "$sealed_sha"
hash32_equals "sealed_share.pcr_quote_hash" "$(jq -r '.pcr_quote_hash' <<<"$ceremony_share_json")" "$sealed_quote_hash"
hash32_equals "sealed_share.pcr_event_log_hash" "$(jq -r '.pcr_event_log_hash' <<<"$ceremony_share_json")" "$sealed_event_log_hash"
hash32_equals "sealed_share.sealed_share_policy_hash" "$(jq -r '.sealed_share_policy_hash' <<<"$ceremony_share_json")" "$sealed_policy_hash"
hash32_equals "sealed_share.dkg_transcript_hash" "$dkg_sha" "$sealed_dkg_hash"

release_metadata_sha="$(field '.release.metadata_sha256')"
release_protocore_digest="$(field '.release.protocore_digest')"
validate_hash32 "release.metadata_sha256" "$release_metadata_sha"
validate_hash32 "release.protocore_digest" "$release_protocore_digest"
hash32_equals "release.metadata_sha256" "$(ceremony_field '.release.metadata_sha256')" "$release_metadata_sha"
hash32_equals "release.protocore_digest" "$(ceremony_field '.release.protocore_digest')" "$release_protocore_digest"

import_service="$(field '.import_contract.service')"
import_file_mode="$(field '.import_contract.file_mode')"
env_tpm_binding="$(field '.import_contract.required_env.PROTOCORE_REQUIRE_TPM_BINDING')"
env_sealed_file="$(field '.import_contract.required_env.PROTOCORE_TPM_SEALED_BLS_SHARE_FILE')"
env_dkg_file="$(field '.import_contract.required_env.PROTOCORE_DKG_TRANSCRIPT_FILE')"
[[ "$import_service" == "ext-protocore" ]] || fail "import_contract.service must be ext-protocore"
[[ "$import_file_mode" =~ ^0?[0-7]{3}$ ]] || fail "import_contract.file_mode must be an octal file mode"
[[ "$env_tpm_binding" == "true" ]] || fail "PROTOCORE_REQUIRE_TPM_BINDING must be true"
[[ "$env_sealed_file" == "$sealed_import_file" ]] \
  || fail "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE must match sealed_share.import_file"
[[ "$env_dkg_file" == "$dkg_import_file" ]] \
  || fail "PROTOCORE_DKG_TRANSCRIPT_FILE must match dkg.transcript_import_file"

local_files_checked=false
case "$VERIFY_LOCAL_FILES" in
  auto|AUTO)
    [[ -n "$LOCAL_EVIDENCE_ROOT" ]] && local_files_checked=true
    ;;
  true|TRUE|1|yes|YES|on|ON)
    local_files_checked=true
    ;;
  false|FALSE|0|no|NO|off|OFF)
    local_files_checked=false
    ;;
  *)
    fail "VERIFY_LOCAL_FILES must be auto, true, or false"
    ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
items="$tmp_dir/file-hashes.items"
: >"$items"

if [[ "$local_files_checked" == "true" ]]; then
  verify_file_hash "tpm_sealed_bls_share_import" "$sealed_import_file" "$sealed_sha" >>"$items"
  verify_file_hash "dkg_transcript_import" "$dkg_import_file" "$dkg_sha" >>"$items"
fi

file_hashes="$(jq -s '.' "$items")"
jq -n \
  --arg manifest "$(basename "$HANDOFF")" \
  --arg ceremony "$(basename "$CEREMONY")" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg cluster_id "$cluster_id" \
  --argjson operator_index "$operator_index" \
  --arg operator_address "$operator_address" \
  --argjson dkg_epoch "$next_dkg_epoch" \
  --argjson local_files_checked "$([[ "$local_files_checked" == "true" ]] && printf true || printf false)" \
  --argjson file_hashes "$file_hashes" \
  '{
    ok: true,
    manifest: $manifest,
    ceremony: $ceremony,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    cluster: {id: $cluster_id, next_dkg_epoch: $dkg_epoch},
    operator: {index: $operator_index, address: $operator_address},
    local_files_checked: $local_files_checked,
    file_hashes: $file_hashes
  }'
