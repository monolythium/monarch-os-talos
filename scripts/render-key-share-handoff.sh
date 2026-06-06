#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEREMONY="${KEY_SHARE_CEREMONY:-${1:-}}"
OPERATOR_INDEX="${OPERATOR_INDEX:-${2:-}}"
OUTPUT="${KEY_SHARE_HANDOFF:-${HANDOFF_OUTPUT:-${3:-}}}"
HANDOFF_SEALED_SHARE_FILE="${HANDOFF_SEALED_SHARE_FILE:-/var/lib/protocore/secrets/consensus-share.sealed}"
HANDOFF_DKG_TRANSCRIPT_FILE="${HANDOFF_DKG_TRANSCRIPT_FILE:-/var/lib/protocore/secrets/dkg-transcript.json}"
HANDOFF_CEREMONY_FILE="${HANDOFF_CEREMONY_FILE:-}"
HANDOFF_ID="${HANDOFF_ID:-}"
HANDOFF_CREATED_AT="${HANDOFF_CREATED_AT:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "key-share-handoff-render: $*" >&2
  exit 1
}

validate_file_ref() {
  local label="$1"
  local path="$2"
  local prefix="${3:-/var/lib/protocore/secrets/}"

  [[ -n "$path" ]] || fail "$label is required"
  [[ "$path" == "$prefix"* ]] || fail "$label must be under $prefix: $path"
  if [[ "$path" == *"@"* ]]; then
    fail "$label must be a file path, not an inline credential: $path"
  fi
  if grep -Eiq '<replace|replace-with|changeme|placeholder|example-secret' <<<"$path"; then
    fail "$label contains a placeholder path: $path"
  fi
}

need jq
need sha256sum

[[ -n "$CEREMONY" ]] || fail "KEY_SHARE_CEREMONY or first argument is required"
[[ -f "$CEREMONY" ]] || fail "ceremony manifest not found: $CEREMONY"
[[ "$OPERATOR_INDEX" =~ ^[0-9]+$ ]] || fail "OPERATOR_INDEX or second argument must be 0 through 9"
(( OPERATOR_INDEX >= 0 && OPERATOR_INDEX <= 9 )) || fail "operator index must be 0 through 9"

validate_file_ref "HANDOFF_SEALED_SHARE_FILE" "$HANDOFF_SEALED_SHARE_FILE"
validate_file_ref "HANDOFF_DKG_TRANSCRIPT_FILE" "$HANDOFF_DKG_TRANSCRIPT_FILE"

"$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$CEREMONY" >/dev/null

ceremony_sha="$(sha256sum "$CEREMONY" | awk '{print $1}')"
ceremony_id="$(jq -r '.ceremony.id' "$CEREMONY")"
ceremony_created_at="$(jq -r '.ceremony.created_at' "$CEREMONY")"
HANDOFF_CEREMONY_FILE="${HANDOFF_CEREMONY_FILE:-$CEREMONY}"
HANDOFF_ID="${HANDOFF_ID:-${ceremony_id}-operator-${OPERATOR_INDEX}}"
HANDOFF_CREATED_AT="${HANDOFF_CREATED_AT:-$ceremony_created_at}"

render() {
  jq -S -n \
    --slurpfile manifest "$CEREMONY" \
    --argjson operator_index "$OPERATOR_INDEX" \
    --arg ceremony_file "$HANDOFF_CEREMONY_FILE" \
    --arg ceremony_sha "$ceremony_sha" \
    --arg handoff_id "$HANDOFF_ID" \
    --arg handoff_created_at "$HANDOFF_CREATED_AT" \
    --arg sealed_import_file "$HANDOFF_SEALED_SHARE_FILE" \
    --arg dkg_import_file "$HANDOFF_DKG_TRANSCRIPT_FILE" \
    '
      ($manifest[0]) as $m
      | ($m.operators[] | select(.index == $operator_index)) as $operator
      | ($m.sealed_share_outputs[] | select(.operator_index == $operator_index)) as $share
      | {
          schema_version: "monarch-protocore-key-share-handoff/v1",
          handoff: {
            id: $handoff_id,
            created_at: $handoff_created_at,
            source_ceremony_id: $m.ceremony.id,
            source_ceremony_type: $m.ceremony.type,
            runbook_id: $m.ceremony.runbook_id
          },
          ceremony_manifest: {
            file: $ceremony_file,
            sha256: $ceremony_sha
          },
          chain: {
            profile: $m.chain.profile,
            chain_id: ($m.chain.chain_id | tostring)
          },
          cluster: {
            id: ($m.cluster.id | tostring),
            operator_index: $operator_index,
            position: $operator.position,
            next_dkg_epoch: $m.cluster.next_dkg_epoch
          },
          operator: $operator,
          dkg: {
            threshold_scheme: $m.dkg.threshold_scheme,
            transcript_source_file: $m.dkg.next_transcript_file,
            transcript_import_file: $dkg_import_file,
            transcript_sha256: $m.dkg.next_transcript_hash,
            transcript_commitment_hash: $m.dkg.transcript_commitment_hash,
            participant_commitments_hash: $m.dkg.participant_commitments_hash,
            encrypted_share_bundle_hash: $m.dkg.encrypted_share_bundle_hash,
            group_public_key_hex: $m.dkg.group_public_key_hex
          },
          sealed_share: {
            source_file: $share.share_file,
            import_file: $sealed_import_file,
            sha256: $share.sha256,
            sealed_to_tpm: $share.sealed_to_tpm,
            tpm_mode: $share.tpm_mode,
            pcr_quote_hash: $share.pcr_quote_hash,
            pcr_event_log_hash: $share.pcr_event_log_hash,
            sealed_share_policy_hash: $share.sealed_share_policy_hash,
            dkg_transcript_hash: $share.dkg_transcript_hash,
            dkg_epoch: $share.dkg_epoch
          },
          release: $m.release,
          import_contract: {
            service: "ext-protocore",
            file_mode: "0600",
            required_env: {
              PROTOCORE_REQUIRE_TPM_BINDING: "true",
              PROTOCORE_TPM_SEALED_BLS_SHARE_FILE: $sealed_import_file,
              PROTOCORE_DKG_TRANSCRIPT_FILE: $dkg_import_file
            }
          }
        }
    '
}

if [[ -n "$OUTPUT" ]]; then
  tmp_output="${OUTPUT}.tmp"
  render >"$tmp_output"
  mv "$tmp_output" "$OUTPUT"
else
  render
fi
