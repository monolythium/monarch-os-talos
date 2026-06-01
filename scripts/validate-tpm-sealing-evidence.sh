#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${TPM_SEALING_EVIDENCE:-${1:-}}"
KEY_SHARE_CEREMONY="${KEY_SHARE_CEREMONY:-${2:-}}"
ENROLLMENT_MANIFEST="${ENROLLMENT_MANIFEST:-${3:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"
REQUIRE_TPM2_CHECKQUOTE="${REQUIRE_TPM2_CHECKQUOTE:-auto}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"
VERIFY_LOCAL_FILES="${VERIFY_LOCAL_FILES:-auto}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "tpm-sealing-evidence: $*" >&2
  exit 1
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$MANIFEST"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 32-byte hex digest"
}

validate_bls_pubkey() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{96}$ ]] \
    || fail "$label must be a 48-byte BLS12-381 public key"
}

validate_signature() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$ ]] \
    || fail "$label must be a hex or base64 signature"
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

canonical_sealing_payload_hash() {
  jq -cS '
    def norm_hex: ascii_downcase | ltrimstr("0x");
    {
      schema_version: "monarch-protocore-tpm-sealing-payload/v1",
      chain: {
        profile: .chain.profile,
        chain_id: (.chain.chain_id | tostring)
      },
      cluster: {
        id: (.cluster.id | tostring),
        dkg_epoch: (.cluster.dkg_epoch | tostring)
      },
      operator: {
        index: .operator.index,
        address: .operator.address,
        position: .operator.position,
        tpm_mode: .operator.tpm_mode
      },
      release: {
        metadata_sha256: (.release.metadata_sha256 | norm_hex),
        protocore_digest: (.release.protocore_digest | norm_hex)
      },
      tpm: {
        mode: .tpm.mode,
        pcr_bank: .tpm.pcr_bank,
        pcrs: .tpm.pcrs,
        pcr_values: (
          .tpm.pcr_values
          | to_entries
          | map({key: .key, value: (.value | norm_hex)})
          | from_entries
        ),
        quote_sha256: (.tpm.quote_sha256 | norm_hex),
        event_log_sha256: (.tpm.event_log_sha256 | norm_hex),
        quote_nonce: (.tpm.quote_nonce | norm_hex),
        sealed_share_policy_hash: (.tpm.sealed_share_policy_hash | norm_hex)
      },
      dkg: {
        transcript_sha256: (.dkg.transcript_sha256 | norm_hex),
        encrypted_share_bundle_hash: (.dkg.encrypted_share_bundle_hash | norm_hex),
        group_public_key_hex: (.dkg.group_public_key_hex | norm_hex)
      },
      sealed_share: {
        sha256: (.sealed_share.sha256 | norm_hex),
        plaintext_share_hash: (.sealed_share.plaintext_share_hash | norm_hex),
        sealed_to_tpm: .sealed_share.sealed_to_tpm
      },
      sealing: {
        toolchain: .sealing.toolchain,
        tool_version: .sealing.tool_version,
        command_log_sha256: (.sealing.command_log_sha256 | norm_hex),
        public_blob_sha256: (.sealing.public_blob_sha256 | norm_hex),
        private_blob_sha256: (.sealing.private_blob_sha256 | norm_hex),
        context_sha256: (.sealing.context_sha256 | norm_hex),
        unseal_validation: {
          performed: .sealing.unseal_validation.performed,
          pcr_policy_digest: (.sealing.unseal_validation.pcr_policy_digest | norm_hex),
          plaintext_share_hash: (.sealing.unseal_validation.plaintext_share_hash | norm_hex)
        }
      }
    }
  ' "$MANIFEST" | sha256sum | awk '{print $1}'
}

need jq
need sha256sum

[[ -n "$MANIFEST" ]] || fail "TPM_SEALING_EVIDENCE or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$MANIFEST" >/dev/null; then
  fail "manifest contains placeholder string values"
fi

schema="$(field '.schema_version')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
cluster_id="$(field '.cluster.id')"
dkg_epoch="$(field '.cluster.dkg_epoch')"
operator_index="$(field '.operator.index')"
operator_address="$(field '.operator.address')"
operator_position="$(field '.operator.position')"
operator_tpm_mode="$(field '.operator.tpm_mode')"
release_metadata_sha="$(field '.release.metadata_sha256')"
release_protocore_digest="$(field '.release.protocore_digest')"
tpm_mode="$(field '.tpm.mode')"
pcr_bank="$(field '.tpm.pcr_bank')"
quote_file="$(field '.tpm.quote_file')"
event_log_file="$(field '.tpm.event_log_file')"
quote_sha="$(field '.tpm.quote_sha256')"
event_log_sha="$(field '.tpm.event_log_sha256')"
quote_nonce="$(field '.tpm.quote_nonce')"
policy_hash="$(field '.tpm.sealed_share_policy_hash')"
dkg_transcript_file="$(field '.dkg.transcript_file')"
dkg_transcript_sha="$(field '.dkg.transcript_sha256')"
encrypted_share_bundle_hash="$(field '.dkg.encrypted_share_bundle_hash')"
group_public_key_hex="$(field '.dkg.group_public_key_hex')"
sealed_share_file="$(field '.sealed_share.file')"
sealed_share_sha="$(field '.sealed_share.sha256')"
plaintext_share_hash="$(field '.sealed_share.plaintext_share_hash')"
sealed_to_tpm="$(field '.sealed_share.sealed_to_tpm')"
toolchain="$(field '.sealing.toolchain')"
tool_version="$(field '.sealing.tool_version')"
command_log_file="$(field '.sealing.command_log_file')"
command_log_sha="$(field '.sealing.command_log_sha256')"
public_blob_file="$(field '.sealing.public_blob_file')"
public_blob_sha="$(field '.sealing.public_blob_sha256')"
private_blob_file="$(field '.sealing.private_blob_file')"
private_blob_sha="$(field '.sealing.private_blob_sha256')"
context_file="$(field '.sealing.context_file')"
context_sha="$(field '.sealing.context_sha256')"
unseal_performed="$(field '.sealing.unseal_validation.performed')"
unseal_policy_hash="$(field '.sealing.unseal_validation.pcr_policy_digest')"
unseal_plaintext_hash="$(field '.sealing.unseal_validation.plaintext_share_hash')"

[[ "$schema" == "monarch-protocore-tpm-sealing-evidence/v1" ]] \
  || fail "unsupported schema_version: $schema"
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

[[ "$cluster_id" =~ ^[0-9]+$ ]] || fail "cluster.id must be numeric"
[[ "$dkg_epoch" =~ ^[0-9]+$ ]] || fail "cluster.dkg_epoch must be numeric"
[[ "$operator_index" =~ ^[0-9]+$ ]] || fail "operator.index must be numeric"
(( operator_index >= 0 && operator_index <= 9 )) || fail "operator.index must be 0 through 9"
[[ "$operator_address" =~ ^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$ ]] \
  || fail "operator.address must be mono1... or 0x-prefixed address"
case "$operator_position" in
  active|standby) ;;
  *) fail "operator.position must be active or standby" ;;
esac
case "$operator_tpm_mode" in
  hardware-tpm2|vtpm-testnet) ;;
  *) fail "operator.tpm_mode must be hardware-tpm2 or vtpm-testnet" ;;
esac
[[ "$tpm_mode" == "$operator_tpm_mode" ]] || fail "tpm.mode must match operator.tpm_mode"
if [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_HARDWARE_TPM"; then
  [[ "$operator_tpm_mode" == "hardware-tpm2" ]] \
    || fail "mainnet or REQUIRE_HARDWARE_TPM sealing evidence must use hardware-tpm2"
fi

validate_hash32 "release.metadata_sha256" "$release_metadata_sha"
validate_hash32 "release.protocore_digest" "$release_protocore_digest"
case "$pcr_bank" in
  sha256|sha384) ;;
  *) fail "tpm.pcr_bank must be sha256 or sha384" ;;
esac
validate_file_ref "tpm.quote_file" "$quote_file" "/var/lib/protocore/attestation/"
validate_file_ref "tpm.event_log_file" "$event_log_file" "/var/lib/protocore/attestation/"
validate_hash32 "tpm.quote_sha256" "$quote_sha"
validate_hash32 "tpm.event_log_sha256" "$event_log_sha"
validate_hash32 "tpm.quote_nonce" "$quote_nonce"
validate_hash32 "tpm.sealed_share_policy_hash" "$policy_hash"
for pcr in 0 2 4 7; do
  jq -e --arg pcr "$pcr" '(.tpm.pcrs // []) | index(($pcr | tonumber))' "$MANIFEST" >/dev/null \
    || fail "tpm.pcrs must include PCR $pcr"
  pcr_value="$(jq -r --arg pcr "$pcr" '.tpm.pcr_values[$pcr] // ""' "$MANIFEST")"
  [[ "$pcr_value" =~ ^[0-9a-fA-F]{64}([0-9a-fA-F]{32})?$ ]] \
    || fail "tpm.pcr_values[$pcr] must be a sha256 or sha384 PCR digest"
done

validate_file_ref "dkg.transcript_file" "$dkg_transcript_file" "/var/lib/protocore/secrets/"
validate_hash32 "dkg.transcript_sha256" "$dkg_transcript_sha"
validate_hash32 "dkg.encrypted_share_bundle_hash" "$encrypted_share_bundle_hash"
validate_bls_pubkey "dkg.group_public_key_hex" "$group_public_key_hex"
validate_file_ref "sealed_share.file" "$sealed_share_file" "/var/lib/protocore/secrets/"
validate_hash32 "sealed_share.sha256" "$sealed_share_sha"
validate_hash32 "sealed_share.plaintext_share_hash" "$plaintext_share_hash"
[[ "$sealed_to_tpm" == "true" ]] || fail "sealed_share.sealed_to_tpm must be true"

[[ "$toolchain" == "tpm2-tools" ]] || fail "sealing.toolchain must be tpm2-tools"
[[ -n "$tool_version" ]] || fail "sealing.tool_version is required"
validate_file_ref "sealing.command_log_file" "$command_log_file" "/var/lib/protocore/attestation/"
validate_hash32 "sealing.command_log_sha256" "$command_log_sha"
validate_file_ref "sealing.public_blob_file" "$public_blob_file" "/var/lib/protocore/secrets/"
validate_hash32 "sealing.public_blob_sha256" "$public_blob_sha"
validate_file_ref "sealing.private_blob_file" "$private_blob_file" "/var/lib/protocore/secrets/"
validate_hash32 "sealing.private_blob_sha256" "$private_blob_sha"
validate_file_ref "sealing.context_file" "$context_file" "/var/lib/protocore/secrets/"
validate_hash32 "sealing.context_sha256" "$context_sha"
[[ "$unseal_performed" == "true" ]] || fail "sealing.unseal_validation.performed must be true"
validate_hash32 "sealing.unseal_validation.pcr_policy_digest" "$unseal_policy_hash"
validate_hash32 "sealing.unseal_validation.plaintext_share_hash" "$unseal_plaintext_hash"
hash32_equals "sealing.unseal_validation.pcr_policy_digest" "$policy_hash" "$unseal_policy_hash"
hash32_equals "sealing.unseal_validation.plaintext_share_hash" "$plaintext_share_hash" "$unseal_plaintext_hash"

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
  verify_file_hash "tpm_quote" "$quote_file" "$quote_sha" >>"$items"
  verify_file_hash "tpm_event_log" "$event_log_file" "$event_log_sha" >>"$items"
  verify_file_hash "dkg_transcript" "$dkg_transcript_file" "$dkg_transcript_sha" >>"$items"
  verify_file_hash "tpm_sealed_share" "$sealed_share_file" "$sealed_share_sha" >>"$items"
  verify_file_hash "tpm_seal_command_log" "$command_log_file" "$command_log_sha" >>"$items"
  verify_file_hash "tpm_public_blob" "$public_blob_file" "$public_blob_sha" >>"$items"
  verify_file_hash "tpm_private_blob" "$private_blob_file" "$private_blob_sha" >>"$items"
  verify_file_hash "tpm_loaded_context" "$context_file" "$context_sha" >>"$items"
fi

checkquote_required=false
case "$REQUIRE_TPM2_CHECKQUOTE" in
  auto|AUTO)
    [[ "$tpm_mode" == "hardware-tpm2" ]] && checkquote_required=true
    ;;
  true|TRUE|1|yes|YES|on|ON)
    checkquote_required=true
    ;;
  false|FALSE|0|no|NO|off|OFF)
    checkquote_required=false
    ;;
  *)
    fail "REQUIRE_TPM2_CHECKQUOTE must be auto, true, or false"
    ;;
esac

quote_verification_present="$(jq -r '.tpm | has("quote_verification")' "$MANIFEST")"
checkquote_status="not-required"
if [[ "$quote_verification_present" == "true" ]]; then
  ak_public_file="$(field '.tpm.quote_verification.ak_public_file')"
  quote_signature_file="$(field '.tpm.quote_verification.quote_signature_file')"
  pcr_digest_file="$(field '.tpm.quote_verification.pcr_digest_file')"

  [[ "$(field '.tpm.quote_verification.tool')" == "tpm2_checkquote" ]] \
    || fail "tpm.quote_verification.tool must be tpm2_checkquote"
  validate_file_ref "tpm.quote_verification.ak_public_file" "$ak_public_file" "/var/lib/protocore/attestation/"
  validate_file_ref "tpm.quote_verification.quote_signature_file" "$quote_signature_file" "/var/lib/protocore/attestation/"
  validate_file_ref "tpm.quote_verification.pcr_digest_file" "$pcr_digest_file" "/var/lib/protocore/attestation/"
  validate_hash32 "tpm.quote_verification.ak_public_sha256" "$(field '.tpm.quote_verification.ak_public_sha256')"
  validate_hash32 "tpm.quote_verification.quote_signature_sha256" "$(field '.tpm.quote_verification.quote_signature_sha256')"
  validate_hash32 "tpm.quote_verification.pcr_digest_sha256" "$(field '.tpm.quote_verification.pcr_digest_sha256')"

  if [[ "$local_files_checked" == "true" ]]; then
    verify_file_hash "tpm_ak_public" "$ak_public_file" "$(field '.tpm.quote_verification.ak_public_sha256')" >>"$items"
    verify_file_hash "tpm_quote_signature" "$quote_signature_file" "$(field '.tpm.quote_verification.quote_signature_sha256')" >>"$items"
    verify_file_hash "tpm_pcr_digest" "$pcr_digest_file" "$(field '.tpm.quote_verification.pcr_digest_sha256')" >>"$items"
  fi

  if [[ "$checkquote_required" == "true" ]]; then
    need tpm2_checkquote
    tpm2_checkquote \
      --public "$(local_path_for "$ak_public_file")" \
      --message "$(local_path_for "$quote_file")" \
      --signature "$(local_path_for "$quote_signature_file")" \
      --pcr "$(local_path_for "$pcr_digest_file")" \
      --hash-algorithm "$pcr_bank" \
      --qualification "${quote_nonce#0x}" >/dev/null
    checkquote_status="verified"
  else
    checkquote_status="hashes-only"
  fi
elif [[ "$checkquote_required" == "true" ]]; then
  fail "hardware TPM sealing evidence requires tpm.quote_verification"
fi

approval_count="$(jq -r '[.approvals[]?.operator_index] | length' "$MANIFEST")"
(( approval_count >= 1 )) || fail "approvals must include at least one operator approval"
jq -e '
  all(.approvals[]?;
    (.operator_index | type == "number")
    and (.address | test("^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$"))
    and (.signature_scheme == "ML-DSA-65" or .signature_scheme == "SLH-DSA")
    and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$"))
  )
' "$MANIFEST" >/dev/null || fail "approvals must include operator index, address, signature scheme, payload hash, and signature"
jq -e --argjson index "$operator_index" --arg address "$operator_address" '
  any(.approvals[]?; .operator_index == $index and .address == $address)
' "$MANIFEST" >/dev/null || fail "approvals must include the sealing operator"

canonical_payload_hash="$(canonical_sealing_payload_hash)"
while IFS=$'\t' read -r approval_index approval_hash approval_signature; do
  [[ -n "$approval_index" ]] || continue
  validate_hash32 "approvals[$approval_index].signed_payload_hash" "$approval_hash"
  validate_signature "approvals[$approval_index].signature" "$approval_signature"
  hash32_equals "approvals[$approval_index].signed_payload_hash" "$canonical_payload_hash" "$approval_hash"
done < <(jq -r '.approvals | to_entries[] | [.key, .value.signed_payload_hash, .value.signature] | @tsv' "$MANIFEST")

ceremony_checked=false
if [[ -n "$KEY_SHARE_CEREMONY" ]]; then
  [[ -f "$KEY_SHARE_CEREMONY" ]] || fail "key-share ceremony not found: $KEY_SHARE_CEREMONY"
  EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
  REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
  VERIFY_LOCAL_FILES="$VERIFY_LOCAL_FILES" \
    "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$KEY_SHARE_CEREMONY" >/dev/null

  ceremony_operator="$(jq -c --argjson index "$operator_index" '.operators[] | select(.index == $index)' "$KEY_SHARE_CEREMONY")"
  ceremony_share="$(jq -c --argjson index "$operator_index" '.sealed_share_outputs[] | select(.operator_index == $index)' "$KEY_SHARE_CEREMONY")"
  [[ -n "$ceremony_operator" ]] || fail "operator.index is not present in key-share ceremony"
  [[ -n "$ceremony_share" ]] || fail "sealed share output is not present in key-share ceremony"
  [[ "$chain_profile" == "$(jq -r '.chain.profile' "$KEY_SHARE_CEREMONY")" ]] || fail "chain.profile must match key-share ceremony"
  [[ "$chain_id" == "$(jq -r '.chain.chain_id' "$KEY_SHARE_CEREMONY")" ]] || fail "chain.chain_id must match key-share ceremony"
  [[ "$cluster_id" == "$(jq -r '.cluster.id' "$KEY_SHARE_CEREMONY")" ]] || fail "cluster.id must match key-share ceremony"
  [[ "$dkg_epoch" == "$(jq -r '.cluster.next_dkg_epoch' "$KEY_SHARE_CEREMONY")" ]] || fail "cluster.dkg_epoch must match ceremony next_dkg_epoch"
  [[ "$operator_address" == "$(jq -r '.address' <<<"$ceremony_operator")" ]] || fail "operator.address must match key-share ceremony"
  [[ "$operator_position" == "$(jq -r '.position' <<<"$ceremony_operator")" ]] || fail "operator.position must match key-share ceremony"
  [[ "$operator_tpm_mode" == "$(jq -r '.tpm_mode' <<<"$ceremony_operator")" ]] || fail "operator.tpm_mode must match key-share ceremony"
  hash32_equals "operator.pcr_quote_hash" "$(jq -r '.pcr_quote_hash' <<<"$ceremony_operator")" "$quote_sha"
  hash32_equals "operator.pcr_event_log_hash" "$(jq -r '.pcr_event_log_hash' <<<"$ceremony_operator")" "$event_log_sha"
  hash32_equals "operator.sealed_share_policy_hash" "$(jq -r '.sealed_share_policy_hash' <<<"$ceremony_operator")" "$policy_hash"
  [[ "$dkg_transcript_file" == "$(jq -r '.dkg.next_transcript_file' "$KEY_SHARE_CEREMONY")" ]] || fail "dkg.transcript_file must match key-share ceremony"
  hash32_equals "dkg.transcript_sha256" "$(jq -r '.dkg.next_transcript_hash' "$KEY_SHARE_CEREMONY")" "$dkg_transcript_sha"
  hash32_equals "dkg.encrypted_share_bundle_hash" "$(jq -r '.dkg.encrypted_share_bundle_hash' "$KEY_SHARE_CEREMONY")" "$encrypted_share_bundle_hash"
  hash32_equals "dkg.group_public_key_hex" "$(jq -r '.dkg.group_public_key_hex' "$KEY_SHARE_CEREMONY")" "$group_public_key_hex"
  hash32_equals "release.metadata_sha256" "$(jq -r '.release.metadata_sha256' "$KEY_SHARE_CEREMONY")" "$release_metadata_sha"
  hash32_equals "release.protocore_digest" "$(jq -r '.release.protocore_digest' "$KEY_SHARE_CEREMONY")" "$release_protocore_digest"
  [[ "$sealed_share_file" == "$(jq -r '.share_file' <<<"$ceremony_share")" ]] || fail "sealed_share.file must match ceremony sealed_share_outputs"
  hash32_equals "sealed_share.sha256" "$(jq -r '.sha256' <<<"$ceremony_share")" "$sealed_share_sha"
  hash32_equals "sealed_share.pcr_quote_hash" "$(jq -r '.pcr_quote_hash' <<<"$ceremony_share")" "$quote_sha"
  hash32_equals "sealed_share.pcr_event_log_hash" "$(jq -r '.pcr_event_log_hash' <<<"$ceremony_share")" "$event_log_sha"
  hash32_equals "sealed_share.sealed_share_policy_hash" "$(jq -r '.sealed_share_policy_hash' <<<"$ceremony_share")" "$policy_hash"
  hash32_equals "sealed_share.dkg_transcript_hash" "$(jq -r '.dkg_transcript_hash' <<<"$ceremony_share")" "$dkg_transcript_sha"
  ceremony_checked=true
fi

enrollment_checked=false
if [[ -n "$ENROLLMENT_MANIFEST" ]]; then
  [[ -f "$ENROLLMENT_MANIFEST" ]] || fail "enrollment manifest not found: $ENROLLMENT_MANIFEST"
  EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
  REQUIRE_RELEASE_DIGEST=true \
    "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$ENROLLMENT_MANIFEST" >/dev/null

  [[ "$(jq -r '.node.role' "$ENROLLMENT_MANIFEST")" == "operator-signing" ]] \
    || fail "enrollment manifest must be for operator-signing"
  [[ "$chain_profile" == "$(jq -r '.node.chain_profile' "$ENROLLMENT_MANIFEST")" ]] || fail "chain.profile must match enrollment"
  [[ "$chain_id" == "$(jq -r '.node.chain_id' "$ENROLLMENT_MANIFEST")" ]] || fail "chain.chain_id must match enrollment"
  [[ "$cluster_id" == "$(jq -r '.cluster.id' "$ENROLLMENT_MANIFEST")" ]] || fail "cluster.id must match enrollment"
  [[ "$dkg_epoch" == "$(jq -r '.cluster.dkg_epoch' "$ENROLLMENT_MANIFEST")" ]] || fail "cluster.dkg_epoch must match enrollment"
  [[ "$operator_index" == "$(jq -r '.operator.index' "$ENROLLMENT_MANIFEST")" ]] || fail "operator.index must match enrollment"
  [[ "$operator_address" == "$(jq -r '.operator.address' "$ENROLLMENT_MANIFEST")" ]] || fail "operator.address must match enrollment"
  [[ "$operator_position" == "$(jq -r '.operator.position' "$ENROLLMENT_MANIFEST")" ]] || fail "operator.position must match enrollment"
  hash32_equals "release.protocore_digest" "$(jq -r '.release.expected_digest' "$ENROLLMENT_MANIFEST")" "$release_protocore_digest"
  [[ "$tpm_mode" == "$(jq -r '.attestation.tpm.mode' "$ENROLLMENT_MANIFEST")" ]] || fail "tpm.mode must match enrollment"
  hash32_equals "tpm.quote_sha256" "$(jq -r '.attestation.tpm.quote_sha256' "$ENROLLMENT_MANIFEST")" "$quote_sha"
  hash32_equals "tpm.event_log_sha256" "$(jq -r '.attestation.tpm.event_log_sha256' "$ENROLLMENT_MANIFEST")" "$event_log_sha"
  hash32_equals "tpm.sealed_share_policy_hash" "$(jq -r '.attestation.tpm.sealed_key_policy.policy_digest' "$ENROLLMENT_MANIFEST")" "$policy_hash"
  hash32_equals "dkg.transcript_sha256" "$(jq -r '.attestation.tpm.sealed_key_policy.dkg_transcript_sha256' "$ENROLLMENT_MANIFEST")" "$dkg_transcript_sha"
  hash32_equals "sealed_share.sha256" "$(jq -r '.attestation.tpm.sealed_key_policy.sealed_share_sha256' "$ENROLLMENT_MANIFEST")" "$sealed_share_sha"
  [[ "$dkg_transcript_file" == "$(jq -r '.secret_files.dkg_transcript' "$ENROLLMENT_MANIFEST")" ]] || fail "dkg.transcript_file must match enrollment"
  [[ "$sealed_share_file" == "$(jq -r '.secret_files.tpm_sealed_bls_share' "$ENROLLMENT_MANIFEST")" ]] || fail "sealed_share.file must match enrollment"
  enrollment_checked=true
fi

file_hashes="$(jq -s '.' "$items")"
jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg cluster_id "$cluster_id" \
  --argjson dkg_epoch "$dkg_epoch" \
  --argjson operator_index "$operator_index" \
  --arg operator_address "$operator_address" \
  --arg tpm_mode "$tpm_mode" \
  --arg payload_hash "$canonical_payload_hash" \
  --arg checkquote_status "$checkquote_status" \
  --argjson local_files_checked "$([[ "$local_files_checked" == "true" ]] && printf true || printf false)" \
  --argjson ceremony_checked "$([[ "$ceremony_checked" == "true" ]] && printf true || printf false)" \
  --argjson enrollment_checked "$([[ "$enrollment_checked" == "true" ]] && printf true || printf false)" \
  --argjson file_hashes "$file_hashes" \
  '{
    ok: true,
    manifest: $manifest,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    cluster: {id: $cluster_id, dkg_epoch: $dkg_epoch},
    operator: {index: $operator_index, address: $operator_address, tpm_mode: $tpm_mode},
    signed_payload_hash: $payload_hash,
    tpm2_checkquote_status: $checkquote_status,
    local_files_checked: $local_files_checked,
    key_share_ceremony_checked: $ceremony_checked,
    enrollment_checked: $enrollment_checked,
    file_hashes: $file_hashes
  }'
