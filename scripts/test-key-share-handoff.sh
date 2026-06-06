#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "key-share handoff test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>"$tmp_dir/${label}.err"; then
    fail "$label was accepted"
  fi
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

evidence_root="$tmp_dir/evidence"
mkdir -p "$evidence_root/var/lib/protocore/secrets"
printf 'sealed share import for operator 2\n' >"$evidence_root/var/lib/protocore/secrets/consensus-share.sealed"
printf 'dkg transcript import\n' >"$evidence_root/var/lib/protocore/secrets/dkg-transcript.json"
cp "$evidence_root/var/lib/protocore/secrets/dkg-transcript.json" \
  "$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json"
for i in $(seq 0 9); do
  cp "$evidence_root/var/lib/protocore/secrets/consensus-share.sealed" \
    "$evidence_root/var/lib/protocore/secrets/share-$i.sealed"
done

h0="$(printf '0%.0s' {1..64})"
h1="$(printf '1%.0s' {1..64})"
h2="$(printf '2%.0s' {1..64})"
h3="$(printf '3%.0s' {1..64})"
h6="$(printf '6%.0s' {1..64})"
h7="$(printf '7%.0s' {1..64})"
h9="$(printf '9%.0s' {1..64})"
share_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/consensus-share.sealed" | awk '{print $1}')"
transcript_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/dkg-transcript.json" | awk '{print $1}')"
consensus_pubkey="$(printf 'b%.0s' {1..3904})"
signature="$(printf 'a%.0s' {1..128})"

valid_key_share="$tmp_dir/key-share-valid.json"
valid_handoff="$tmp_dir/key-share-handoff-valid.json"
bad_ceremony_hash="$tmp_dir/key-share-handoff-bad-ceremony-hash.json"
bad_operator="$tmp_dir/key-share-handoff-bad-operator.json"
bad_import_path="$tmp_dir/key-share-handoff-bad-import-path.json"
bad_evidence_root="$tmp_dir/bad-evidence"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg share_hash "$share_hash" \
  --arg transcript_hash "$transcript_hash" \
  --arg consensus_pubkey "$consensus_pubkey" \
  --arg signature "$signature" \
  '
    def addr($i): "0x" + (($i + 1 | tostring) * 40)[0:40];
    {
      schema_version: "monarch-protocore-key-share-ceremony/v1",
      ceremony: {
        type: "operator-rotation",
        id: "key-share-handoff-test",
        runbook_id: "handoff-validator-test",
        created_at: "2026-06-01T00:00:00Z",
        reason: "handoff validator coverage"
      },
      chain: {
        profile: "testnet",
        chain_id: "69420"
      },
      cluster: {
        id: 1,
        size: 10,
        threshold: 7,
        active_members: 7,
        standby_members: 3,
        previous_dkg_epoch: 1,
        next_dkg_epoch: 2
      },
      operators: [
        range(0; 10) as $i
        | {
          index: $i,
          address: addr($i),
          position: (if $i < 7 then "active" else "standby" end),
          tpm_mode: "vtpm-testnet",
          pcr_quote_hash: $h1,
          pcr_event_log_hash: $h2,
          sealed_share_policy_hash: $h3
        }
      ],
      dkg: {
        threshold_scheme: "ML-DSA-65-bitmap-multisig",
        previous_transcript_hash: $h0,
        next_transcript_file: "/var/lib/protocore/secrets/dkg-transcript-next.json",
        next_transcript_hash: $transcript_hash,
        transcript_commitment_hash: $h6,
        participant_commitments_hash: $h7,
        encrypted_share_bundle_hash: $share_hash,
        group_public_key_hex: $consensus_pubkey
      },
      release: {
        metadata_sha256: $h0,
        protocore_digest: $share_hash
      },
      sealed_share_outputs: [
        range(0; 10) as $i
        | {
          operator_index: $i,
          share_file: "/var/lib/protocore/secrets/share-\($i).sealed",
          sha256: $share_hash,
          sealed_to_tpm: true,
          tpm_mode: "vtpm-testnet",
          pcr_quote_hash: $h1,
          pcr_event_log_hash: $h2,
          sealed_share_policy_hash: $h3,
          dkg_transcript_hash: $transcript_hash,
          dkg_epoch: 2
        }
      ],
      approvals: [
        range(0; 7) as $i
        | {
          operator_index: $i,
          address: addr($i),
          signature_scheme: "ML-DSA-65",
          signed_payload_hash: $h6,
          signature: ("0x" + $signature)
        }
      ]
    }' >"$valid_key_share"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$valid_key_share" >/dev/null

HANDOFF_CREATED_AT=2026-06-01T00:00:00Z \
  "$ROOT_DIR/scripts/render-key-share-handoff.sh" "$valid_key_share" 2 "$valid_handoff"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$valid_handoff" "$valid_key_share" >/dev/null

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$valid_handoff" "$valid_key_share" >/dev/null

jq --arg h9 "$h9" '.ceremony_manifest.sha256 = $h9' \
  "$valid_handoff" >"$bad_ceremony_hash"
expect_fail bad-ceremony-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$bad_ceremony_hash" "$valid_key_share"

jq '.operator.address = "0x9999999999999999999999999999999999999999"' \
  "$valid_handoff" >"$bad_operator"
expect_fail bad-operator-binding \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$bad_operator" "$valid_key_share"

jq '.sealed_share.import_file = "/tmp/consensus-share.sealed"' \
  "$valid_handoff" >"$bad_import_path"
expect_fail bad-import-path \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$bad_import_path" "$valid_key_share"

cp -R "$evidence_root" "$bad_evidence_root"
printf 'not the sealed share\n' >"$bad_evidence_root/var/lib/protocore/secrets/consensus-share.sealed"
expect_fail bad-local-file-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 LOCAL_EVIDENCE_ROOT="$bad_evidence_root" VERIFY_LOCAL_FILES=true \
  "$ROOT_DIR/scripts/validate-key-share-handoff.sh" "$valid_handoff" "$valid_key_share"

printf '{"ok":true,"checked":"key-share-handoff"}\n'
