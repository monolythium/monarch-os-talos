#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ENROLLMENT_ON_CHAIN_OUTPUT_DIR:-${1:-_out/on-chain-enrollment}}"
ENROLLMENT_MANIFEST="${ENROLLMENT_MANIFEST:-${2:-}}"
ENROLLMENT_ON_CHAIN_COMMAND="${ENROLLMENT_ON_CHAIN_COMMAND:-}"
ENROLLMENT_ON_CHAIN_COMMAND_LABEL="${ENROLLMENT_ON_CHAIN_COMMAND_LABEL:-external-on-chain-enrollment}"
ENROLLMENT_ON_CHAIN_MANIFEST="${ENROLLMENT_ON_CHAIN_MANIFEST:-$OUTPUT_DIR/enrollment.on-chain.json}"
ENROLLMENT_ON_CHAIN_SUMMARY="${ENROLLMENT_ON_CHAIN_SUMMARY:-$OUTPUT_DIR/on-chain-enrollment-run.json}"
ENROLLMENT_ON_CHAIN_STRICT="${ENROLLMENT_ON_CHAIN_STRICT:-true}"
ENROLLMENT_REGISTRY_CONTRACT="${ENROLLMENT_REGISTRY_CONTRACT:-}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_RELEASE_DIGEST="${REQUIRE_RELEASE_DIGEST:-true}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"
REQUIRE_TPM_ATTESTATION_EVIDENCE="${REQUIRE_TPM_ATTESTATION_EVIDENCE:-false}"
REQUIRE_TPM2_CHECKQUOTE="${REQUIRE_TPM2_CHECKQUOTE:-auto}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "on-chain-enrollment: $*" >&2
  exit 1
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{print $1}'
}

need jq
need sha256sum

[[ -n "$ENROLLMENT_MANIFEST" ]] \
  || fail "ENROLLMENT_MANIFEST is required"
[[ -f "$ENROLLMENT_MANIFEST" ]] \
  || fail "input enrollment manifest not found: $ENROLLMENT_MANIFEST"
[[ -n "$ENROLLMENT_ON_CHAIN_COMMAND" ]] \
  || fail "ENROLLMENT_ON_CHAIN_COMMAND is required; it must submit registration and write MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST"

if bool_true "$ENROLLMENT_ON_CHAIN_STRICT"; then
  REQUIRE_RELEASE_DIGEST=true
  REQUIRE_HARDWARE_TPM=true
  REQUIRE_TPM_ATTESTATION_EVIDENCE=true
fi

mkdir -p "$OUTPUT_DIR" "$(dirname "$ENROLLMENT_ON_CHAIN_MANIFEST")" "$(dirname "$ENROLLMENT_ON_CHAIN_SUMMARY")"
command_log="$OUTPUT_DIR/external-on-chain-enrollment-command.log"
tpm_evidence_output="$OUTPUT_DIR/tpm-attestation-evidence.json"

EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
ENROLLMENT_MANIFEST="$ENROLLMENT_MANIFEST" \
REQUIRE_RELEASE_DIGEST="$REQUIRE_RELEASE_DIGEST" \
ALLOW_PENDING_ON_CHAIN_REGISTRATION=true \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$ENROLLMENT_MANIFEST" >/dev/null

export MONARCH_ENROLLMENT_ROOT_DIR="$ROOT_DIR"
export MONARCH_ENROLLMENT_OUTPUT_DIR="$OUTPUT_DIR"
export MONARCH_ENROLLMENT_INPUT_MANIFEST="$ENROLLMENT_MANIFEST"
export MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST="$ENROLLMENT_ON_CHAIN_MANIFEST"
export MONARCH_ENROLLMENT_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT"
export MONARCH_ENROLLMENT_REGISTRY_CONTRACT="$ENROLLMENT_REGISTRY_CONTRACT"
export MONARCH_ENROLLMENT_EXPECTED_SCHEMA="monarch-protocore-enrollment/v1"
export MONARCH_ENROLLMENT_EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE"
export MONARCH_ENROLLMENT_EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID"

set +e
bash -euo pipefail -c "$ENROLLMENT_ON_CHAIN_COMMAND" >"$command_log" 2>&1
command_status=$?
set -e
if [[ "$command_status" -ne 0 ]]; then
  sed -n '1,120p' "$command_log" >&2 || true
  fail "external on-chain enrollment command failed with exit status $command_status"
fi

[[ -s "$ENROLLMENT_ON_CHAIN_MANIFEST" ]] \
  || fail "external on-chain enrollment did not write manifest: $ENROLLMENT_ON_CHAIN_MANIFEST"
jq -e . "$ENROLLMENT_ON_CHAIN_MANIFEST" >/dev/null \
  || fail "external on-chain enrollment manifest is not valid JSON: $ENROLLMENT_ON_CHAIN_MANIFEST"
jq -e 'has("on_chain_registration")' "$ENROLLMENT_ON_CHAIN_MANIFEST" >/dev/null \
  || fail "external on-chain enrollment did not write on_chain_registration proof"

EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
ENROLLMENT_MANIFEST="$ENROLLMENT_ON_CHAIN_MANIFEST" \
REQUIRE_RELEASE_DIGEST="$REQUIRE_RELEASE_DIGEST" \
REQUIRE_ON_CHAIN_REGISTRATION=true \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$ENROLLMENT_ON_CHAIN_MANIFEST" >/dev/null

tpm_attestation_evidence_json="null"
if bool_true "$REQUIRE_TPM_ATTESTATION_EVIDENCE"; then
  [[ -n "$LOCAL_EVIDENCE_ROOT" ]] \
    || fail "LOCAL_EVIDENCE_ROOT is required when REQUIRE_TPM_ATTESTATION_EVIDENCE=true"
  [[ -d "$LOCAL_EVIDENCE_ROOT" ]] \
    || fail "LOCAL_EVIDENCE_ROOT not found: $LOCAL_EVIDENCE_ROOT"
  LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
  EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
  TPM_ATTESTATION_MANIFEST="$ENROLLMENT_ON_CHAIN_MANIFEST" \
  ENROLLMENT_MANIFEST="$ENROLLMENT_ON_CHAIN_MANIFEST" \
  REQUIRE_RELEASE_DIGEST="$REQUIRE_RELEASE_DIGEST" \
  REQUIRE_ON_CHAIN_REGISTRATION=true \
  REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
  REQUIRE_TPM2_CHECKQUOTE="$REQUIRE_TPM2_CHECKQUOTE" \
    "$ROOT_DIR/scripts/validate-tpm-attestation-evidence.sh" "$ENROLLMENT_ON_CHAIN_MANIFEST" \
      >"$tpm_evidence_output"
  tpm_attestation_evidence_json="$(jq -c . "$tpm_evidence_output")"
fi

registration_json="$(jq -c '.on_chain_registration' "$ENROLLMENT_ON_CHAIN_MANIFEST")"

jq -S -n \
  --arg command_label "$ENROLLMENT_ON_CHAIN_COMMAND_LABEL" \
  --arg command_log "$command_log" \
  --arg command_log_sha256 "$(sha256_file "$command_log")" \
  --arg input_manifest "$ENROLLMENT_MANIFEST" \
  --arg input_manifest_sha256 "$(sha256_file "$ENROLLMENT_MANIFEST")" \
  --arg on_chain_manifest "$ENROLLMENT_ON_CHAIN_MANIFEST" \
  --arg on_chain_manifest_sha256 "$(sha256_file "$ENROLLMENT_ON_CHAIN_MANIFEST")" \
  --arg output_dir "$OUTPUT_DIR" \
  --arg expected_chain_profile "$EXPECTED_CHAIN_PROFILE" \
  --arg expected_chain_id "$EXPECTED_CHAIN_ID" \
  --arg local_evidence_root "$LOCAL_EVIDENCE_ROOT" \
  --argjson enrollment_strict "$(bool_true "$ENROLLMENT_ON_CHAIN_STRICT" && printf true || printf false)" \
  --argjson require_release_digest "$(bool_true "$REQUIRE_RELEASE_DIGEST" && printf true || printf false)" \
  --argjson require_hardware_tpm "$(bool_true "$REQUIRE_HARDWARE_TPM" && printf true || printf false)" \
  --argjson require_tpm_attestation_evidence "$(bool_true "$REQUIRE_TPM_ATTESTATION_EVIDENCE" && printf true || printf false)" \
  --argjson registration "$registration_json" \
  --argjson tpm_attestation_evidence "$tpm_attestation_evidence_json" \
  '{
    schema_version: "monarch-on-chain-enrollment-run/v1",
    ok: true,
    output_dir: $output_dir,
    external_command: {
      label: $command_label,
      log_file: $command_log,
      log_sha256: $command_log_sha256
    },
    policy: {
      expected_chain_profile: $expected_chain_profile,
      expected_chain_id: $expected_chain_id,
      enrollment_strict: $enrollment_strict,
      require_release_digest: $require_release_digest,
      require_hardware_tpm: $require_hardware_tpm,
      require_on_chain_registration: true,
      require_tpm_attestation_evidence: $require_tpm_attestation_evidence,
      local_evidence_root: $local_evidence_root
    },
    artifacts: {
      input_manifest: {
        file: $input_manifest,
        sha256: $input_manifest_sha256
      },
      on_chain_manifest: {
        file: $on_chain_manifest,
        sha256: $on_chain_manifest_sha256
      },
      tpm_attestation_evidence: $tpm_attestation_evidence
    },
    registration: $registration
  }' >"$ENROLLMENT_ON_CHAIN_SUMMARY"

cat "$ENROLLMENT_ON_CHAIN_SUMMARY"
