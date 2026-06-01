#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${PRODUCTION_DKG_OUTPUT_DIR:-${1:-_out/production-dkg-ceremony}}"
DKG_CEREMONY_COMMAND="${DKG_CEREMONY_COMMAND:-}"
DKG_CEREMONY_COMMAND_LABEL="${DKG_CEREMONY_COMMAND_LABEL:-external-dkg-ceremony}"
KEY_SHARE_CEREMONY="${KEY_SHARE_CEREMONY:-$OUTPUT_DIR/key-share-ceremony.json}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-$OUTPUT_DIR/evidence}"
KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR="${KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR:-$OUTPUT_DIR/key-share-run}"
DKG_RESHARE_ATTESTATION_INPUT="${DKG_RESHARE_ATTESTATION_INPUT:-$OUTPUT_DIR/dkg-reshare-attestation.json}"
DKG_RESHARE_ATTESTATION_OUTPUT="${DKG_RESHARE_ATTESTATION_OUTPUT:-$KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR/dkg-reshare-attestation.json}"
TPM_SEALING_EVIDENCE_FILES="${TPM_SEALING_EVIDENCE_FILES:-}"
ENROLLMENT_MANIFEST_FILES="${ENROLLMENT_MANIFEST_FILES:-}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
PRODUCTION_DKG_STRICT="${PRODUCTION_DKG_STRICT:-true}"
VERIFY_LOCAL_FILES="${VERIFY_LOCAL_FILES:-true}"
REQUIRE_TPM_SEALING_EVIDENCE="${REQUIRE_TPM_SEALING_EVIDENCE:-true}"
REQUIRE_DKG_RESHARE_ATTESTATION="${REQUIRE_DKG_RESHARE_ATTESTATION:-true}"
REQUIRE_EXTERNAL_DKG_ATTESTATION_FILE="${REQUIRE_EXTERNAL_DKG_ATTESTATION_FILE:-true}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-true}"
REQUIRE_ON_CHAIN_LIFECYCLE="${REQUIRE_ON_CHAIN_LIFECYCLE:-true}"
REQUIRE_TPM2_CHECKQUOTE="${REQUIRE_TPM2_CHECKQUOTE:-auto}"
SUMMARY_OUTPUT="${PRODUCTION_DKG_SUMMARY:-$OUTPUT_DIR/production-dkg-ceremony-run.json}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "production-dkg-ceremony: $*" >&2
  exit 1
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

join_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.json' | sort | paste -sd' ' -
}

sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{print $1}'
}

need jq
need sha256sum
need find
need paste

[[ -n "$DKG_CEREMONY_COMMAND" ]] \
  || fail "DKG_CEREMONY_COMMAND is required; use run-key-share-ceremony for already materialized manifests"

if bool_true "$PRODUCTION_DKG_STRICT"; then
  VERIFY_LOCAL_FILES=true
  REQUIRE_TPM_SEALING_EVIDENCE=true
  REQUIRE_DKG_RESHARE_ATTESTATION=true
  REQUIRE_EXTERNAL_DKG_ATTESTATION_FILE=true
  REQUIRE_HARDWARE_TPM=true
  REQUIRE_ON_CHAIN_LIFECYCLE=true
fi

mkdir -p "$OUTPUT_DIR" "$LOCAL_EVIDENCE_ROOT" "$KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR"

command_log="$OUTPUT_DIR/external-dkg-command.log"

export MONARCH_DKG_ROOT_DIR="$ROOT_DIR"
export MONARCH_DKG_OUTPUT_DIR="$OUTPUT_DIR"
export MONARCH_DKG_CEREMONY_MANIFEST="$KEY_SHARE_CEREMONY"
export MONARCH_DKG_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT"
export MONARCH_DKG_DKG_RESHARE_ATTESTATION="$DKG_RESHARE_ATTESTATION_INPUT"
export MONARCH_DKG_EXPECTED_SCHEMA="monarch-protocore-key-share-ceremony/v1"
export MONARCH_DKG_EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE"
export MONARCH_DKG_EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID"

set +e
bash -euo pipefail -c "$DKG_CEREMONY_COMMAND" >"$command_log" 2>&1
command_status=$?
set -e
if [[ "$command_status" -ne 0 ]]; then
  sed -n '1,120p' "$command_log" >&2 || true
  fail "external DKG ceremony command failed with exit status $command_status"
fi

[[ -s "$KEY_SHARE_CEREMONY" ]] \
  || fail "external DKG ceremony did not write key-share manifest: $KEY_SHARE_CEREMONY"
jq -e . "$KEY_SHARE_CEREMONY" >/dev/null \
  || fail "external DKG ceremony manifest is not valid JSON: $KEY_SHARE_CEREMONY"
[[ -d "$LOCAL_EVIDENCE_ROOT" ]] \
  || fail "external DKG ceremony evidence root not found: $LOCAL_EVIDENCE_ROOT"

if bool_true "$REQUIRE_EXTERNAL_DKG_ATTESTATION_FILE"; then
  [[ -s "$DKG_RESHARE_ATTESTATION_INPUT" ]] \
    || fail "external DKG ceremony did not write DKG re-share attestation: $DKG_RESHARE_ATTESTATION_INPUT"
  jq -e . "$DKG_RESHARE_ATTESTATION_INPUT" >/dev/null \
    || fail "external DKG re-share attestation is not valid JSON: $DKG_RESHARE_ATTESTATION_INPUT"
fi

if [[ -z "$TPM_SEALING_EVIDENCE_FILES" ]]; then
  TPM_SEALING_EVIDENCE_FILES="$(join_files "$OUTPUT_DIR/tpm-sealing")"
fi
if [[ -z "$ENROLLMENT_MANIFEST_FILES" ]]; then
  ENROLLMENT_MANIFEST_FILES="$(join_files "$OUTPUT_DIR/enrollment")"
fi

run_summary="$KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR/key-share-ceremony-run.json"
EXPECTED_CHAIN_PROFILE="$EXPECTED_CHAIN_PROFILE" \
EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID" \
REQUIRE_ON_CHAIN_LIFECYCLE="$REQUIRE_ON_CHAIN_LIFECYCLE" \
REQUIRE_HARDWARE_TPM="$REQUIRE_HARDWARE_TPM" \
REQUIRE_TPM_SEALING_EVIDENCE="$REQUIRE_TPM_SEALING_EVIDENCE" \
REQUIRE_DKG_RESHARE_ATTESTATION="$REQUIRE_DKG_RESHARE_ATTESTATION" \
REQUIRE_TPM2_CHECKQUOTE="$REQUIRE_TPM2_CHECKQUOTE" \
LOCAL_EVIDENCE_ROOT="$LOCAL_EVIDENCE_ROOT" \
VERIFY_LOCAL_FILES="$VERIFY_LOCAL_FILES" \
TPM_SEALING_EVIDENCE_FILES="$TPM_SEALING_EVIDENCE_FILES" \
ENROLLMENT_MANIFEST_FILES="$ENROLLMENT_MANIFEST_FILES" \
DKG_RESHARE_ATTESTATION_INPUT="$DKG_RESHARE_ATTESTATION_INPUT" \
DKG_RESHARE_ATTESTATION_OUTPUT="$DKG_RESHARE_ATTESTATION_OUTPUT" \
  "$ROOT_DIR/scripts/run-key-share-ceremony.sh" "$KEY_SHARE_CEREMONY" "$KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR" >/dev/null

[[ -s "$run_summary" ]] || fail "key-share ceremony runner did not write summary: $run_summary"

jq -S -n \
  --arg command_label "$DKG_CEREMONY_COMMAND_LABEL" \
  --arg command_log "$command_log" \
  --arg command_log_sha256 "$(sha256_file "$command_log")" \
  --arg key_share_ceremony "$KEY_SHARE_CEREMONY" \
  --arg key_share_ceremony_sha256 "$(sha256_file "$KEY_SHARE_CEREMONY")" \
  --arg evidence_root "$LOCAL_EVIDENCE_ROOT" \
  --arg key_share_run "$run_summary" \
  --arg key_share_run_sha256 "$(sha256_file "$run_summary")" \
  --arg dkg_reshare_attestation "$DKG_RESHARE_ATTESTATION_OUTPUT" \
  --arg dkg_reshare_attestation_sha256 "$(sha256_file "$DKG_RESHARE_ATTESTATION_OUTPUT")" \
  --arg output_dir "$OUTPUT_DIR" \
  --arg expected_chain_profile "$EXPECTED_CHAIN_PROFILE" \
  --arg expected_chain_id "$EXPECTED_CHAIN_ID" \
  --argjson production_strict "$(bool_true "$PRODUCTION_DKG_STRICT" && printf true || printf false)" \
  --argjson require_hardware_tpm "$(bool_true "$REQUIRE_HARDWARE_TPM" && printf true || printf false)" \
  --argjson require_on_chain_lifecycle "$(bool_true "$REQUIRE_ON_CHAIN_LIFECYCLE" && printf true || printf false)" \
  --argjson require_tpm_sealing_evidence "$(bool_true "$REQUIRE_TPM_SEALING_EVIDENCE" && printf true || printf false)" \
  --argjson require_dkg_reshare_attestation "$(bool_true "$REQUIRE_DKG_RESHARE_ATTESTATION" && printf true || printf false)" \
  --argjson verify_local_files "$(bool_true "$VERIFY_LOCAL_FILES" && printf true || printf false)" \
  '{
    schema_version: "monarch-production-dkg-ceremony-run/v1",
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
      production_strict: $production_strict,
      require_hardware_tpm: $require_hardware_tpm,
      require_on_chain_lifecycle: $require_on_chain_lifecycle,
      require_tpm_sealing_evidence: $require_tpm_sealing_evidence,
      require_dkg_reshare_attestation: $require_dkg_reshare_attestation,
      verify_local_files: $verify_local_files
    },
    artifacts: {
      key_share_ceremony: {
        file: $key_share_ceremony,
        sha256: $key_share_ceremony_sha256
      },
      evidence_root: $evidence_root,
      key_share_run: {
        file: $key_share_run,
        sha256: $key_share_run_sha256
      },
      dkg_reshare_attestation: {
        file: $dkg_reshare_attestation,
        sha256: $dkg_reshare_attestation_sha256
      }
    }
  }' >"$SUMMARY_OUTPUT"

cat "$SUMMARY_OUTPUT"
