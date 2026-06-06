#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${KEY_SHARE_CEREMONY:-${1:-}}"
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
  echo "key-share-ceremony: $*" >&2
  exit 1
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$MANIFEST"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 32-byte hex digest"
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

validate_selector() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "$label must be a 0x-prefixed 4-byte function selector"
}

validate_tx_hash() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 0x-prefixed 32-byte transaction hash"
}

canonical_lifecycle_payload_hash() {
  jq -cS '
    def norm_hex: ascii_downcase | ltrimstr("0x");
    def maybe_norm_hash($v): if ($v // "") == "" then null else ($v | norm_hex) end;
    {
      schema_version: "monarch-protocore-key-share-lifecycle-payload/v1",
      chain: {
        profile: .chain.profile,
        chain_id: (.chain.chain_id | tostring)
      },
      registry: {
        contract: .on_chain_lifecycle.registry_contract,
        ceremony_method: .on_chain_lifecycle.ceremony_method,
        ceremony_function_selector: .on_chain_lifecycle.ceremony_function_selector,
        attestation_method: .on_chain_lifecycle.attestation_method,
        attestation_function_selector: .on_chain_lifecycle.attestation_function_selector
      },
      ceremony: {
        type: .ceremony.type,
        id: .ceremony.id,
        runbook_id: .ceremony.runbook_id,
        created_at: .ceremony.created_at,
        reason: .ceremony.reason
      },
      cluster: {
        id: (.cluster.id | tostring),
        size: .cluster.size,
        threshold: .cluster.threshold,
        active_members: .cluster.active_members,
        standby_members: .cluster.standby_members,
        previous_dkg_epoch: .cluster.previous_dkg_epoch,
        next_dkg_epoch: .cluster.next_dkg_epoch
      },
      dkg: {
        threshold_scheme: .dkg.threshold_scheme,
        previous_transcript_hash: maybe_norm_hash(.dkg.previous_transcript_hash),
        next_transcript_hash: (.dkg.next_transcript_hash | norm_hex),
        transcript_commitment_hash: (.dkg.transcript_commitment_hash | norm_hex),
        participant_commitments_hash: (.dkg.participant_commitments_hash | norm_hex),
        encrypted_share_bundle_hash: (.dkg.encrypted_share_bundle_hash | norm_hex),
        group_public_key_hex: (.dkg.group_public_key_hex | norm_hex)
      },
      release: {
        metadata_sha256: (.release.metadata_sha256 | norm_hex),
        protocore_digest: (.release.protocore_digest | norm_hex)
      },
      operators: (
        .operators
        | sort_by(.index)
        | map({
            index,
            address,
            position,
            tpm_mode,
            pcr_quote_hash: (.pcr_quote_hash | norm_hex),
            pcr_event_log_hash: (.pcr_event_log_hash | norm_hex),
            sealed_share_policy_hash: (.sealed_share_policy_hash | norm_hex)
          })
      ),
      sealed_share_outputs: (
        .sealed_share_outputs
        | sort_by(.operator_index)
        | map({
            operator_index,
            sha256: (.sha256 | norm_hex),
            sealed_to_tpm,
            tpm_mode,
            pcr_quote_hash: (.pcr_quote_hash | norm_hex),
            pcr_event_log_hash: (.pcr_event_log_hash | norm_hex),
            sealed_share_policy_hash: (.sealed_share_policy_hash | norm_hex),
            dkg_transcript_hash: (.dkg_transcript_hash | norm_hex),
            dkg_epoch
          })
      ),
      approvals: (
        .approvals
        | sort_by(.operator_index, .address)
        | map({
            operator_index,
            address,
            signature_scheme,
            signed_payload_hash: (.signed_payload_hash | norm_hex),
            signature
          })
      )
    }
  ' "$MANIFEST" | sha256sum | awk '{print $1}'
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
  local prefix="${3:-/var/lib/protocore/}"

  [[ -n "$path" ]] || fail "$label is required"
  [[ "$path" == "$prefix"* ]] || fail "$label must be under $prefix: $path"
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

[[ -n "$MANIFEST" ]] || fail "KEY_SHARE_CEREMONY or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

schema="$(field '.schema_version')"
ceremony_type="$(field '.ceremony.type')"
ceremony_id="$(field '.ceremony.id')"
runbook_id="$(field '.ceremony.runbook_id')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
cluster_id="$(field '.cluster.id')"
cluster_size="$(field '.cluster.size')"
cluster_threshold="$(field '.cluster.threshold')"
cluster_active="$(field '.cluster.active_members')"
cluster_standby="$(field '.cluster.standby_members')"
previous_epoch="$(field '.cluster.previous_dkg_epoch')"
next_epoch="$(field '.cluster.next_dkg_epoch')"
threshold_scheme="$(field '.dkg.threshold_scheme')"
previous_transcript_hash="$(field '.dkg.previous_transcript_hash')"
next_transcript_file="$(field '.dkg.next_transcript_file')"
next_transcript_hash="$(field '.dkg.next_transcript_hash')"
transcript_commitment_hash="$(field '.dkg.transcript_commitment_hash')"
participant_commitments_hash="$(field '.dkg.participant_commitments_hash')"
encrypted_share_bundle_hash="$(field '.dkg.encrypted_share_bundle_hash')"
group_public_key_hex="$(field '.dkg.group_public_key_hex')"
release_metadata_sha="$(field '.release.metadata_sha256')"
protocore_digest="$(field '.release.protocore_digest')"

[[ "$schema" == "monarch-protocore-key-share-ceremony/v1" ]] \
  || fail "unsupported schema_version: $schema"
case "$ceremony_type" in
  initial-dkg|operator-rotation|share-reseal|recovery|emergency-revocation) ;;
  *) fail "ceremony.type must be initial-dkg, operator-rotation, share-reseal, recovery, or emergency-revocation: $ceremony_type" ;;
esac
[[ -n "$ceremony_id" ]] || fail "ceremony.id is required"
[[ -n "$runbook_id" ]] || fail "ceremony.runbook_id is required"
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

if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$MANIFEST" >/dev/null; then
  fail "manifest contains placeholder string values"
fi

[[ "$cluster_id" =~ ^[0-9]+$ ]] || fail "cluster.id is required and must be numeric"
[[ "$cluster_size" == "10" ]] || fail "cluster.size must be 10"
[[ "$cluster_threshold" == "7" ]] || fail "cluster.threshold must be 7"
[[ "$cluster_active" == "7" ]] || fail "cluster.active_members must be 7"
[[ "$cluster_standby" == "3" ]] || fail "cluster.standby_members must be 3"
[[ "$previous_epoch" =~ ^[0-9]+$ ]] || fail "cluster.previous_dkg_epoch must be numeric"
[[ "$next_epoch" =~ ^[0-9]+$ ]] || fail "cluster.next_dkg_epoch must be numeric"
(( next_epoch > previous_epoch )) \
  || fail "cluster.next_dkg_epoch must be greater than previous_dkg_epoch"

[[ "$threshold_scheme" == "ML-DSA-65-bitmap-multisig" ]] \
  || fail "dkg.threshold_scheme must be ML-DSA-65-bitmap-multisig"
validate_hash32 "dkg.next_transcript_hash" "$next_transcript_hash"
validate_hash32 "dkg.transcript_commitment_hash" "$transcript_commitment_hash"
validate_hash32 "dkg.participant_commitments_hash" "$participant_commitments_hash"
validate_hash32 "dkg.encrypted_share_bundle_hash" "$encrypted_share_bundle_hash"
validate_consensus_pubkey "dkg.group_public_key_hex" "$group_public_key_hex"
validate_file_ref "dkg.next_transcript_file" "$next_transcript_file" "/var/lib/protocore/secrets/"
if [[ "$ceremony_type" != "initial-dkg" ]]; then
  validate_hash32 "dkg.previous_transcript_hash" "$previous_transcript_hash"
fi
validate_hash32 "release.metadata_sha256" "$release_metadata_sha"
validate_hash32 "release.protocore_digest" "$protocore_digest"

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
file_hash_items="$tmp_dir/file-hashes.items"
: >"$file_hash_items"

if [[ "$local_files_checked" == "true" ]]; then
  verify_file_hash "dkg.next_transcript_file" "$next_transcript_file" "$next_transcript_hash" >>"$file_hash_items"
fi

jq -e '[.operators[]?.index] | sort == [range(0; 10)]' "$MANIFEST" >/dev/null \
  || fail "operators must contain exactly one index 0 through 9"
jq -e '[.operators[]? | select(.position == "active")] | length == 7' "$MANIFEST" >/dev/null \
  || fail "operators must contain exactly 7 active members"
jq -e '[.operators[]? | select(.position == "standby")] | length == 3' "$MANIFEST" >/dev/null \
  || fail "operators must contain exactly 3 standby members"
jq -e '
  all(.operators[]?;
    (.address | test("^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$"))
    and (.tpm_mode == "hardware-tpm2" or .tpm_mode == "vtpm-testnet")
    and (.pcr_quote_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.pcr_event_log_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.sealed_share_policy_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
  )
' "$MANIFEST" >/dev/null || fail "operator roster entries must include address, TPM mode, PCR quote hash, event-log hash, and sealed-share policy hash"

if [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_HARDWARE_TPM"; then
  jq -e 'all(.operators[]?; .tpm_mode == "hardware-tpm2")' "$MANIFEST" >/dev/null \
    || fail "mainnet or REQUIRE_HARDWARE_TPM ceremonies must use hardware-tpm2 for every operator"
fi

jq -e '[.sealed_share_outputs[]?.operator_index] | sort == [range(0; 10)]' "$MANIFEST" >/dev/null \
  || fail "sealed_share_outputs must contain exactly one share output for each operator index 0 through 9"
while IFS=$'\t' read -r index path sha sealed output_tpm output_quote_hash output_event_log_hash output_policy_hash output_dkg_hash output_epoch; do
  [[ -n "$index" ]] || continue
  validate_file_ref "sealed_share_outputs[$index].share_file" "$path" "/var/lib/protocore/secrets/"
  validate_hash32 "sealed_share_outputs[$index].sha256" "$sha"
  [[ "$sealed" == "true" ]] || fail "sealed_share_outputs[$index].sealed_to_tpm must be true"
  case "$output_tpm" in
    hardware-tpm2|vtpm-testnet) ;;
    *) fail "sealed_share_outputs[$index].tpm_mode must be hardware-tpm2 or vtpm-testnet" ;;
  esac
  validate_hash32 "sealed_share_outputs[$index].pcr_quote_hash" "$output_quote_hash"
  validate_hash32 "sealed_share_outputs[$index].pcr_event_log_hash" "$output_event_log_hash"
  validate_hash32 "sealed_share_outputs[$index].sealed_share_policy_hash" "$output_policy_hash"
  validate_hash32 "sealed_share_outputs[$index].dkg_transcript_hash" "$output_dkg_hash"
  [[ "$output_epoch" == "$next_epoch" ]] \
    || fail "sealed_share_outputs[$index].dkg_epoch must match cluster.next_dkg_epoch"

  operator_tpm="$(jq -r --argjson index "$index" '.operators[] | select(.index == $index) | .tpm_mode' "$MANIFEST")"
  operator_quote_hash="$(jq -r --argjson index "$index" '.operators[] | select(.index == $index) | .pcr_quote_hash' "$MANIFEST")"
  operator_event_log_hash="$(jq -r --argjson index "$index" '.operators[] | select(.index == $index) | .pcr_event_log_hash' "$MANIFEST")"
  operator_policy_hash="$(jq -r --argjson index "$index" '.operators[] | select(.index == $index) | .sealed_share_policy_hash' "$MANIFEST")"

  [[ "$output_tpm" == "$operator_tpm" ]] \
    || fail "sealed_share_outputs[$index].tpm_mode must match operators[$index].tpm_mode"
  hash32_equals "sealed_share_outputs[$index].pcr_quote_hash" "$operator_quote_hash" "$output_quote_hash"
  hash32_equals "sealed_share_outputs[$index].pcr_event_log_hash" "$operator_event_log_hash" "$output_event_log_hash"
  hash32_equals "sealed_share_outputs[$index].sealed_share_policy_hash" "$operator_policy_hash" "$output_policy_hash"
  hash32_equals "sealed_share_outputs[$index].dkg_transcript_hash" "$next_transcript_hash" "$output_dkg_hash"
  if [[ "$local_files_checked" == "true" ]]; then
    verify_file_hash "sealed_share_outputs[$index].share_file" "$path" "$sha" >>"$file_hash_items"
  fi
done < <(jq -r '.sealed_share_outputs[]? | [
  .operator_index,
  .share_file,
  .sha256,
  (.sealed_to_tpm // false),
  (.tpm_mode // ""),
  (.pcr_quote_hash // ""),
  (.pcr_event_log_hash // ""),
  (.sealed_share_policy_hash // ""),
  (.dkg_transcript_hash // ""),
  (.dkg_epoch // "")
] | @tsv' "$MANIFEST")

approval_count="$(jq -r '[.approvals[]?.operator_index] | unique | length' "$MANIFEST")"
(( approval_count >= 7 )) || fail "approvals must include at least 7 unique operators"
jq -e '
  (.operators // []) as $operators
  | all(.approvals[]?;
      . as $approval
      | any($operators[]; .index == $approval.operator_index and .address == $approval.address)
    )
' "$MANIFEST" >/dev/null || fail "approval operators must match roster entries"
jq -e '
  all(.approvals[]?;
    .signature_scheme == "ML-DSA-65"
    and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$"))
  )
' "$MANIFEST" >/dev/null || fail "approvals must use ML-DSA-65 signatures and signed payload hashes"

on_chain_present="$(jq -r 'has("on_chain_lifecycle")' "$MANIFEST")"
if [[ "$on_chain_present" == "true" ]]; then
  registry_contract="$(field '.on_chain_lifecycle.registry_contract')"
  lifecycle_cluster_id="$(field '.on_chain_lifecycle.cluster_id')"
  lifecycle_epoch="$(field '.on_chain_lifecycle.next_dkg_epoch')"
  ceremony_tx="$(field '.on_chain_lifecycle.ceremony_tx_hash')"
  attestation_tx="$(field '.on_chain_lifecycle.attestation_tx_hash')"
  dag_round="$(field '.on_chain_lifecycle.dag_round')"
  quorum_hash="$(field '.on_chain_lifecycle.quorum_certificate_hash')"
  ceremony_method="$(field '.on_chain_lifecycle.ceremony_method')"
  ceremony_selector="$(field '.on_chain_lifecycle.ceremony_function_selector')"
  ceremony_calldata_hash="$(field '.on_chain_lifecycle.ceremony_calldata_hash')"
  attestation_method="$(field '.on_chain_lifecycle.attestation_method')"
  attestation_selector="$(field '.on_chain_lifecycle.attestation_function_selector')"
  attestation_calldata_hash="$(field '.on_chain_lifecycle.attestation_calldata_hash')"
  lifecycle_payload_hash="$(field '.on_chain_lifecycle.lifecycle_payload_hash')"

  [[ "$registry_contract" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "on_chain_lifecycle.registry_contract must be a 0x-prefixed 20-byte address"
  [[ "$lifecycle_cluster_id" == "$cluster_id" ]] \
    || fail "on_chain_lifecycle.cluster_id must match cluster.id"
  [[ "$lifecycle_epoch" == "$next_epoch" ]] \
    || fail "on_chain_lifecycle.next_dkg_epoch must match cluster.next_dkg_epoch"
  validate_tx_hash "on_chain_lifecycle.ceremony_tx_hash" "$ceremony_tx"
  validate_tx_hash "on_chain_lifecycle.attestation_tx_hash" "$attestation_tx"
  [[ "$dag_round" =~ ^[0-9]+$ ]] \
    || fail "on_chain_lifecycle.dag_round must be numeric"
  validate_hash32 "on_chain_lifecycle.quorum_certificate_hash" "$quorum_hash"
  [[ "$ceremony_method" == "submitPendingChange" ]] \
    || fail "on_chain_lifecycle.ceremony_method must be submitPendingChange"
  [[ "$ceremony_selector" == "0x7d09426c" || "$ceremony_selector" == "0x7D09426C" ]] \
    || fail "on_chain_lifecycle.ceremony_function_selector must be node-registry submitPendingChange selector 0x7d09426c"
  validate_selector "on_chain_lifecycle.ceremony_function_selector" "$ceremony_selector"
  validate_hash32 "on_chain_lifecycle.ceremony_calldata_hash" "$ceremony_calldata_hash"
  [[ "$attestation_method" == "attestDkgReshare" ]] \
    || fail "on_chain_lifecycle.attestation_method must be attestDkgReshare"
  [[ "$attestation_selector" == "0x36e34030" || "$attestation_selector" == "0x36E34030" ]] \
    || fail "on_chain_lifecycle.attestation_function_selector must be node-registry attestDkgReshare selector 0x36e34030"
  validate_selector "on_chain_lifecycle.attestation_function_selector" "$attestation_selector"
  validate_hash32 "on_chain_lifecycle.attestation_calldata_hash" "$attestation_calldata_hash"
  validate_hash32 "on_chain_lifecycle.lifecycle_payload_hash" "$lifecycle_payload_hash"
  hash32_equals "on_chain_lifecycle.lifecycle_payload_hash" \
    "$(canonical_lifecycle_payload_hash)" \
    "$lifecycle_payload_hash"
elif [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_ON_CHAIN_LIFECYCLE"; then
  fail "mainnet or REQUIRE_ON_CHAIN_LIFECYCLE ceremonies must include on_chain_lifecycle"
fi

jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg ceremony_type "$ceremony_type" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg cluster_id "$cluster_id" \
  --argjson previous_dkg_epoch "$previous_epoch" \
  --argjson next_dkg_epoch "$next_epoch" \
  --argjson approval_count "$approval_count" \
  --argjson sealed_share_count "$(jq -r '.sealed_share_outputs | length' "$MANIFEST")" \
  --argjson on_chain_checked "$([[ "$on_chain_present" == "true" ]] && printf true || printf false)" \
  --argjson local_files_checked "$([[ "$local_files_checked" == "true" ]] && printf true || printf false)" \
  --argjson file_hashes "$(jq -s '.' "$file_hash_items")" \
  '{
    ok: true,
    manifest: $manifest,
    ceremony_type: $ceremony_type,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    cluster: {
      id: $cluster_id,
      previous_dkg_epoch: $previous_dkg_epoch,
      next_dkg_epoch: $next_dkg_epoch
    },
    approval_count: $approval_count,
    sealed_share_count: $sealed_share_count,
    on_chain_lifecycle_checked: $on_chain_checked,
    local_files_checked: $local_files_checked,
    file_hashes: $file_hashes
  }'
