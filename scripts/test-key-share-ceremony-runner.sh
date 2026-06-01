#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "key-share ceremony runner test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

hex_repeat() {
  local byte="$1"
  local count="$2"
  printf "%${count}s" "" | tr ' ' "$byte"
}

key() {
  local byte="$1"
  printf '%096s' "" | tr ' ' "$byte"
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

evidence_root="$tmp_dir/evidence"
mkdir -p "$evidence_root/var/lib/protocore/secrets"
printf 'dkg transcript evidence\n' >"$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json"
for index in $(seq 0 9); do
  printf 'sealed share for operator %s\n' "$index" \
    >"$evidence_root/var/lib/protocore/secrets/share-${index}.sealed"
done

transcript_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json" | awk '{print $1}')"
h1="$(hex_repeat 1 64)"
h2="$(hex_repeat 2 64)"
h3="$(hex_repeat 3 64)"
h4="$(hex_repeat 4 64)"
h5="$(hex_repeat 5 64)"
h6="$(hex_repeat 6 64)"
h7="$(hex_repeat 7 64)"
h8="$(hex_repeat 8 64)"
sig="$(hex_repeat a 128)"
shares="$tmp_dir/shares.items"
: >"$shares"
for index in $(seq 0 9); do
  share_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share-${index}.sealed" | awk '{print $1}')"
  jq -n \
    --argjson operator_index "$index" \
    --arg sha "$share_hash" \
    '{operator_index: $operator_index, sha256: $sha}' >>"$shares"
done

ceremony="$tmp_dir/key-share-ceremony.json"
jq -S -n \
  --arg transcript_hash "$transcript_hash" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg h8 "$h8" \
  --arg sig "0x$sig" \
  --argjson shares "$(jq -s '.' "$shares")" \
  '{
    schema_version: "monarch-protocore-key-share-ceremony/v1",
    ceremony: {
      type: "operator-rotation",
      id: "runner-test",
      runbook_id: "key-share-ceremony-runner-test",
      created_at: "2026-06-01T00:00:00Z",
      reason: "key-share ceremony runner coverage"
    },
    chain: {profile: "testnet", chain_id: "69420"},
    cluster: {
      id: "1",
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
          address: ("0x" + (("0000000000000000000000000000000000000000" + (($i + 1) | tostring))[-40:])),
          position: (if $i < 7 then "active" else "standby" end),
          tpm_mode: "vtpm-testnet",
          pcr_quote_hash: $h1,
          pcr_event_log_hash: $h2,
          sealed_share_policy_hash: $h3
        }
    ],
    dkg: {
      threshold_scheme: "Ferveo-BLS12-381",
      previous_transcript_hash: $h4,
      next_transcript_file: "/var/lib/protocore/secrets/dkg-transcript-next.json",
      next_transcript_hash: $transcript_hash,
      transcript_commitment_hash: $h5,
      participant_commitments_hash: $h6,
      encrypted_share_bundle_hash: $h7,
      group_public_key_hex: ("0x" + ("b" * 96))
    },
    release: {
      metadata_sha256: $h8,
      protocore_digest: $h4
    },
    sealed_share_outputs: [
      $shares[]
      | {
          operator_index,
          share_file: ("/var/lib/protocore/secrets/share-" + (.operator_index | tostring) + ".sealed"),
          sha256,
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
          address: ("0x" + (("0000000000000000000000000000000000000000" + (($i + 1) | tostring))[-40:])),
          signature_scheme: "ML-DSA-65",
          signed_payload_hash: $h5,
          signature: $sig
        }
    ]
  }' >"$ceremony"

out="$tmp_dir/run"
keys="0x$(key 1)$(key 2)$(key 3)$(key 4)$(key 5)"
threshold_sig="0x$(hex_repeat c 192)"
LOCAL_EVIDENCE_ROOT="$evidence_root" \
VERIFY_LOCAL_FILES=true \
EXPECTED_CHAIN_PROFILE=testnet \
EXPECTED_CHAIN_ID=69420 \
DKG_RESHARE_CREATED_AT="2026-06-01T00:00:00Z" \
DKG_RESHARE_INTENT_ID=7 \
DKG_RESHARE_BLS_PUBLIC_KEYS_HEX="$keys" \
DKG_RESHARE_THRESHOLD_SIG_HEX="$threshold_sig" \
  "$ROOT_DIR/scripts/run-key-share-ceremony.sh" "$ceremony" "$out" >/dev/null

jq -e '
  .schema_version == "monarch-key-share-ceremony-run/v1"
  and .ok == true
  and (.handoffs | length) == 10
  and (.dkg_reshare_attestation.signer_count == 5)
' "$out/key-share-ceremony-run.json" >/dev/null \
  || fail "runner summary has wrong shape"

for index in $(seq 0 9); do
  [[ -s "$out/handoffs/operator-${index}.handoff.json" ]] \
    || fail "runner did not render handoff for operator $index"
done

if REQUIRE_DKG_RESHARE_ATTESTATION=true \
  "$ROOT_DIR/scripts/run-key-share-ceremony.sh" "$ceremony" "$tmp_dir/missing-dkg" \
    >/dev/null 2>"$tmp_dir/missing-dkg.err"; then
  fail "missing required DKG attestation was accepted"
fi
grep -F "DKG re-share attestation is required" "$tmp_dir/missing-dkg.err" >/dev/null \
  || fail "missing DKG rejection reason changed"

if REQUIRE_TPM_SEALING_EVIDENCE=true \
  DKG_RESHARE_INTENT_ID=7 \
  DKG_RESHARE_BLS_PUBLIC_KEYS_HEX="$keys" \
  DKG_RESHARE_THRESHOLD_SIG_HEX="$threshold_sig" \
  "$ROOT_DIR/scripts/run-key-share-ceremony.sh" "$ceremony" "$tmp_dir/missing-tpm" \
    >/dev/null 2>"$tmp_dir/missing-tpm.err"; then
  fail "missing required TPM sealing evidence was accepted"
fi
grep -F "requires TPM sealing evidence for operator index 0" "$tmp_dir/missing-tpm.err" >/dev/null \
  || fail "missing TPM rejection reason changed"

printf '{"ok":true,"checked":"key-share-ceremony-runner"}\n'
