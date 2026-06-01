#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "production DKG ceremony runner test failed: $*" >&2
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

bls_key() {
  local byte="$1"
  printf '%096s' "" | tr ' ' "$byte"
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

helper="$tmp_dir/external-dkg-fixture.sh"
cat >"$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

hex_repeat() {
  local byte="$1"
  local count="$2"
  printf "%${count}s" "" | tr ' ' "$byte"
}

bls_key() {
  local byte="$1"
  printf '%096s' "" | tr ' ' "$byte"
}

mkdir -p "$MONARCH_DKG_EVIDENCE_ROOT/var/lib/protocore/secrets"
printf 'production dkg transcript fixture\n' >"$MONARCH_DKG_EVIDENCE_ROOT/var/lib/protocore/secrets/dkg-transcript-next.json"
shares="$MONARCH_DKG_OUTPUT_DIR/shares.items"
: >"$shares"
for index in $(seq 0 9); do
  printf 'tpm sealed production share fixture %s\n' "$index" \
    >"$MONARCH_DKG_EVIDENCE_ROOT/var/lib/protocore/secrets/share-${index}.sealed"
  share_hash="$(sha256sum "$MONARCH_DKG_EVIDENCE_ROOT/var/lib/protocore/secrets/share-${index}.sealed" | awk '{print $1}')"
  jq -n --argjson operator_index "$index" --arg sha "$share_hash" \
    '{operator_index: $operator_index, sha256: $sha}' >>"$shares"
done

transcript_hash="$(sha256sum "$MONARCH_DKG_EVIDENCE_ROOT/var/lib/protocore/secrets/dkg-transcript-next.json" | awk '{print $1}')"
h1="$(hex_repeat 1 64)"
h2="$(hex_repeat 2 64)"
h3="$(hex_repeat 3 64)"
h4="$(hex_repeat 4 64)"
h5="$(hex_repeat 5 64)"
h6="$(hex_repeat 6 64)"
h7="$(hex_repeat 7 64)"
h8="$(hex_repeat 8 64)"
sig="$(hex_repeat a 128)"

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
      id: "production-runner-test",
      runbook_id: "production-dkg-ceremony-runner-test",
      created_at: "2026-06-01T00:00:00Z",
      reason: "external DKG command fixture"
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
  }' >"$MONARCH_DKG_CEREMONY_MANIFEST"

keys="0x$(bls_key 1)$(bls_key 2)$(bls_key 3)$(bls_key 4)$(bls_key 5)"
threshold_sig="0x$(hex_repeat c 192)"
DKG_RESHARE_CREATED_AT="2026-06-01T00:00:00Z" \
  "$MONARCH_DKG_ROOT_DIR/scripts/render-dkg-reshare-attestation.sh" \
    7 "$keys" "$threshold_sig" "$MONARCH_DKG_DKG_RESHARE_ATTESTATION"
SH
chmod +x "$helper"

out="$tmp_dir/production-dkg"
DKG_CEREMONY_COMMAND="$helper" \
DKG_CEREMONY_COMMAND_LABEL="fixture-distributed-dkg" \
PRODUCTION_DKG_OUTPUT_DIR="$out" \
EXPECTED_CHAIN_PROFILE=testnet \
EXPECTED_CHAIN_ID=69420 \
PRODUCTION_DKG_STRICT=false \
REQUIRE_HARDWARE_TPM=false \
REQUIRE_ON_CHAIN_LIFECYCLE=false \
REQUIRE_TPM_SEALING_EVIDENCE=false \
VERIFY_LOCAL_FILES=true \
  "$ROOT_DIR/scripts/run-production-dkg-ceremony.sh" >/dev/null

jq -e '
  .schema_version == "monarch-production-dkg-ceremony-run/v1"
  and .ok == true
  and .external_command.label == "fixture-distributed-dkg"
  and .policy.production_strict == false
  and .policy.verify_local_files == true
  and (.artifacts.key_share_run.sha256 | test("^[0-9a-f]{64}$"))
  and (.artifacts.dkg_reshare_attestation.sha256 | test("^[0-9a-f]{64}$"))
' "$out/production-dkg-ceremony-run.json" >/dev/null \
  || fail "production DKG summary has wrong shape"

jq -e '
  .schema_version == "monarch-key-share-ceremony-run/v1"
  and .ok == true
  and (.handoffs | length) == 10
  and (.dkg_reshare_attestation.signer_count == 5)
' "$out/key-share-run/key-share-ceremony-run.json" >/dev/null \
  || fail "inner key-share ceremony run summary has wrong shape"

if "$ROOT_DIR/scripts/run-production-dkg-ceremony.sh" "$tmp_dir/no-command" \
    >/dev/null 2>"$tmp_dir/no-command.err"; then
  fail "missing external DKG command was accepted"
fi
grep -F "DKG_CEREMONY_COMMAND is required" "$tmp_dir/no-command.err" >/dev/null \
  || fail "missing-command rejection reason changed"

no_attest_helper="$tmp_dir/external-no-attestation.sh"
sed '/render-dkg-reshare-attestation/,$d' "$helper" >"$no_attest_helper"
chmod +x "$no_attest_helper"
if DKG_CEREMONY_COMMAND="$no_attest_helper" \
  PRODUCTION_DKG_OUTPUT_DIR="$tmp_dir/no-attestation" \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  PRODUCTION_DKG_STRICT=false \
  REQUIRE_HARDWARE_TPM=false \
  REQUIRE_ON_CHAIN_LIFECYCLE=false \
  REQUIRE_TPM_SEALING_EVIDENCE=false \
  VERIFY_LOCAL_FILES=true \
    "$ROOT_DIR/scripts/run-production-dkg-ceremony.sh" >/dev/null 2>"$tmp_dir/no-attestation.err"; then
  fail "missing external DKG attestation was accepted"
fi
grep -F "did not write DKG re-share attestation" "$tmp_dir/no-attestation.err" >/dev/null \
  || fail "missing-attestation rejection reason changed"

printf '{"ok":true,"checked":"production-dkg-ceremony-runner"}\n'
