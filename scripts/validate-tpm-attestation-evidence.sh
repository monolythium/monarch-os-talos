#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${TPM_ATTESTATION_MANIFEST:-${ENROLLMENT_MANIFEST:-${1:-}}}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"
REQUIRE_TPM2_CHECKQUOTE="${REQUIRE_TPM2_CHECKQUOTE:-auto}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_RELEASE_DIGEST="${REQUIRE_RELEASE_DIGEST:-true}"
REQUIRE_ON_CHAIN_REGISTRATION="${REQUIRE_ON_CHAIN_REGISTRATION:-false}"
ALLOW_PENDING_ON_CHAIN_REGISTRATION="${ALLOW_PENDING_ON_CHAIN_REGISTRATION:-false}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "tpm-attestation-evidence: $*" >&2
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

[[ -n "$MANIFEST" ]] || fail "TPM_ATTESTATION_MANIFEST, ENROLLMENT_MANIFEST, or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"

EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
REQUIRE_RELEASE_DIGEST="${REQUIRE_RELEASE_DIGEST:-true}" \
REQUIRE_ON_CHAIN_REGISTRATION="$REQUIRE_ON_CHAIN_REGISTRATION" \
ALLOW_PENDING_ON_CHAIN_REGISTRATION="$ALLOW_PENDING_ON_CHAIN_REGISTRATION" \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$MANIFEST" >/dev/null

role="$(field '.node.role')"
tpm_mode="$(field '.attestation.tpm.mode')"
pcr_bank="$(field '.attestation.tpm.pcr_bank')"
quote_nonce="$(field '.attestation.tpm.quote_nonce')"
quote_file="$(field '.attestation.tpm.quote_file')"
event_log_file="$(field '.attestation.tpm.event_log_file')"
key_transcript_file="$(field '.secret_files.key_transcript')"
dkg_transcript_file="$(field '.secret_files.dkg_transcript')"
lythiumseal_operator_key_file="$(field '.secret_files.lythiumseal_operator_key')"
sealed_operator_key_file="$(field '.secret_files.tpm_sealed_operator_key')"
sealed_bls_share_file="$(field '.secret_files.tpm_sealed_bls_share')"
quote_verification_present="$(jq -r '.attestation.tpm | has("quote_verification")' "$MANIFEST")"
transcript_file="${key_transcript_file:-$dkg_transcript_file}"
sealed_share_file="${lythiumseal_operator_key_file:-${sealed_operator_key_file:-$sealed_bls_share_file}}"

[[ "$role" == "operator-signing" ]] || fail "TPM attestation evidence is only defined for operator-signing manifests"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
items="$tmp_dir/file-hashes.items"
: >"$items"

verify_file_hash "tpm_quote" "$quote_file" "$(field '.attestation.tpm.quote_sha256')" >>"$items"
verify_file_hash "tpm_event_log" "$event_log_file" "$(field '.attestation.tpm.event_log_sha256')" >>"$items"
verify_file_hash "lythiumseal_operator_key" "$sealed_share_file" "$(field '.attestation.tpm.sealed_key_policy.sealed_share_sha256')" >>"$items"
verify_file_hash "key_transcript" "$transcript_file" "$(field '.attestation.tpm.sealed_key_policy.dkg_transcript_sha256')" >>"$items"

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

checkquote_status="not-required"
if [[ "$quote_verification_present" == "true" ]]; then
  ak_public_file="$(field '.attestation.tpm.quote_verification.ak_public_file')"
  quote_signature_file="$(field '.attestation.tpm.quote_verification.quote_signature_file')"
  pcr_digest_file="$(field '.attestation.tpm.quote_verification.pcr_digest_file')"
  ak_public_local="$(local_path_for "$ak_public_file")"
  quote_local="$(local_path_for "$quote_file")"
  quote_signature_local="$(local_path_for "$quote_signature_file")"
  pcr_digest_local="$(local_path_for "$pcr_digest_file")"

  verify_file_hash "tpm_ak_public" "$ak_public_file" "$(field '.attestation.tpm.quote_verification.ak_public_sha256')" >>"$items"
  verify_file_hash "tpm_quote_signature" "$quote_signature_file" "$(field '.attestation.tpm.quote_verification.quote_signature_sha256')" >>"$items"
  verify_file_hash "tpm_pcr_digest" "$pcr_digest_file" "$(field '.attestation.tpm.quote_verification.pcr_digest_sha256')" >>"$items"

  if [[ "$checkquote_required" == "true" ]]; then
    need tpm2_checkquote
    tpm2_checkquote \
      --public "$ak_public_local" \
      --message "$quote_local" \
      --signature "$quote_signature_local" \
      --pcr "$pcr_digest_local" \
      --hash-algorithm "$pcr_bank" \
      --qualification "${quote_nonce#0x}" >/dev/null
    checkquote_status="verified"
  else
    checkquote_status="hashes-only"
  fi
elif [[ "$checkquote_required" == "true" ]]; then
  fail "hardware TPM quote verification requires attestation.tpm.quote_verification"
fi

file_hashes="$(jq -s '.' "$items")"
jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg role "$role" \
  --arg tpm_mode "$tpm_mode" \
  --arg pcr_bank "$pcr_bank" \
  --arg quote_nonce "$quote_nonce" \
  --arg checkquote_status "$checkquote_status" \
  --argjson checkquote_required "$([[ "$checkquote_required" == "true" ]] && printf true || printf false)" \
  --argjson file_hashes "$file_hashes" \
  '{
    ok: true,
    manifest: $manifest,
    role: $role,
    tpm: {
      mode: $tpm_mode,
      pcr_bank: $pcr_bank,
      quote_nonce: $quote_nonce,
      tpm2_checkquote_required: $checkquote_required,
      tpm2_checkquote_status: $checkquote_status
    },
    file_hashes: $file_hashes
  }'
