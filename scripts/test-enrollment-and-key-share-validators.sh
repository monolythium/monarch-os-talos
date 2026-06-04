#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "enrollment/key-share validator test failed: $*" >&2
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

canonical_attestation_payload_hash() {
  local manifest="$1"

  jq -cS '
    def norm_hash: ascii_downcase | ltrimstr("0x");
    def pcr_values:
      .attestation.tpm.pcr_values
      | to_entries
      | map({key: .key, value: (.value | norm_hash)})
      | from_entries;
    def quote_verification:
      if (.attestation.tpm | has("quote_verification")) then
        {
          tool: .attestation.tpm.quote_verification.tool,
          ak_public_sha256: (.attestation.tpm.quote_verification.ak_public_sha256 | norm_hash),
          quote_signature_sha256: (.attestation.tpm.quote_verification.quote_signature_sha256 | norm_hash),
          pcr_digest_sha256: (.attestation.tpm.quote_verification.pcr_digest_sha256 | norm_hash)
        }
      else
        null
      end;
    {
      schema_version: "monarch-protocore-operator-attestation-payload/v1",
      chain: {
        profile: .node.chain_profile,
        chain_id: (.node.chain_id | tostring)
      },
      registry: {
        contract: .on_chain_registration.registry_contract,
        registration_method: .on_chain_registration.registration_method,
        registration_function_selector: .on_chain_registration.registration_function_selector,
        attestation_embedded_in_registration: .on_chain_registration.attestation_embedded_in_registration
      },
      operator: {
        address: .operator.address,
        index: .operator.index,
        position: .operator.position
      },
      cluster: {
        id: (.cluster.id | tostring),
        size: .cluster.size,
        threshold: .cluster.threshold,
        active_members: .cluster.active_members,
        standby_members: .cluster.standby_members,
        dkg_epoch: (.cluster.dkg_epoch | tostring)
      },
      endpoint_policy: (.endpoint_policy // {}),
      release: {
        expected_digest: (.release.expected_digest | norm_hash)
      },
      tpm: {
        mode: .attestation.tpm.mode,
        pcr_bank: .attestation.tpm.pcr_bank,
        pcr_values: pcr_values,
        quote_sha256: (.attestation.tpm.quote_sha256 | norm_hash),
        event_log_sha256: (.attestation.tpm.event_log_sha256 | norm_hash),
        quote_nonce: (.attestation.tpm.quote_nonce | norm_hash),
        sealed_key_policy: {
          pcrs: .attestation.tpm.sealed_key_policy.pcrs,
          key_share_refs: .attestation.tpm.sealed_key_policy.key_share_refs,
          policy_digest: (.attestation.tpm.sealed_key_policy.policy_digest | norm_hash),
          dkg_transcript_sha256: (.attestation.tpm.sealed_key_policy.dkg_transcript_sha256 | norm_hash),
          sealed_share_sha256: (.attestation.tpm.sealed_key_policy.sealed_share_sha256 | norm_hash)
        },
        quote_verification: quote_verification
      }
    }
  ' "$manifest" | sha256sum | awk '{print $1}'
}

canonical_key_share_lifecycle_payload_hash() {
  local manifest="$1"

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
  ' "$manifest" | sha256sum | awk '{print $1}'
}

need jq

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

h0="$(printf '0%.0s' {1..64})"
h1="$(printf '1%.0s' {1..64})"
h2="$(printf '2%.0s' {1..64})"
h3="$(printf '3%.0s' {1..64})"
h4="$(printf '4%.0s' {1..64})"
h5="$(printf '5%.0s' {1..64})"
h6="$(printf '6%.0s' {1..64})"
h7="$(printf '7%.0s' {1..64})"
h8="$(printf '8%.0s' {1..64})"
h9="$(printf '9%.0s' {1..64})"
bls_pubkey="$(printf 'b%.0s' {1..96})"
signature="$(printf 'a%.0s' {1..128})"

valid_enrollment="$tmp_dir/enrollment-valid.json"
missing_quote_hash="$tmp_dir/enrollment-missing-quote-hash.json"
missing_sealed_share_ref="$tmp_dir/enrollment-missing-sealed-share-ref.json"
evidence_enrollment="$tmp_dir/enrollment-evidence-valid.json"
bad_evidence_hash="$tmp_dir/enrollment-evidence-bad-hash.json"
valid_mainnet_enrollment="$tmp_dir/enrollment-mainnet-valid.json"
missing_hardware_quote_verification="$tmp_dir/enrollment-hardware-missing-quote-verification.json"
mismatched_mainnet_hash="$tmp_dir/enrollment-mainnet-mismatched-hash.json"
mismatched_payload_hash="$tmp_dir/enrollment-mainnet-mismatched-payload-hash.json"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  '{
    schema_version: "monarch-protocore-enrollment/v1",
    node: {
      role: "operator-signing",
      chain_profile: "testnet",
      chain_id: "69420",
      node_id: "operator-test-operator-0"
    },
    operator: {
      address: "0x1111111111111111111111111111111111111111",
      position: "active",
      index: 0
    },
    cluster: {
      id: 1,
      size: 10,
      threshold: 7,
      active_members: 7,
      standby_members: 3,
      dkg_epoch: 2
    },
    release: {
      expected_digest: $h0
    },
    attestation: {
      tpm: {
        mode: "vtpm-testnet",
        pcr_bank: "sha256",
        pcr_values: {
          "0": $h0,
          "2": $h2,
          "4": $h4,
          "7": $h7
        },
        quote_file: "/var/lib/protocore/attestation/quote.bin",
        event_log_file: "/var/lib/protocore/attestation/eventlog.bin",
        quote_sha256: $h1,
        event_log_sha256: $h2,
        quote_nonce: $h3,
        sealed_key_policy: {
          pcrs: [0, 2, 4, 7],
          key_share_refs: ["lythiumseal_operator_key"],
          policy_digest: $h4,
          dkg_transcript_sha256: $h5,
          sealed_share_sha256: $h6
        }
      }
    },
    secret_files: {
      operator_consensus_key: "/var/lib/protocore/secrets/operator-consensus.key",
      key_transcript: "/var/lib/protocore/secrets/key-transcript.json",
      lythiumseal_operator_key: "/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc",
      tpm_sealed_operator_key: "/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc",
      operator_identity_key: "/var/lib/protocore/secrets/operator-consensus.key",
      dkg_transcript: "/var/lib/protocore/secrets/key-transcript.json",
      tpm_sealed_bls_share: "/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc"
    }
  }' >"$valid_enrollment"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$valid_enrollment" >/dev/null

jq 'del(.attestation.tpm.quote_sha256)' "$valid_enrollment" >"$missing_quote_hash"
expect_fail missing-quote-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$missing_quote_hash"

jq '.attestation.tpm.sealed_key_policy.key_share_refs = ["bls_share"]' \
  "$valid_enrollment" >"$missing_sealed_share_ref"
expect_fail missing-sealed-share-ref \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$missing_sealed_share_ref"

evidence_root="$tmp_dir/evidence-root"
mkdir -p \
  "$evidence_root/var/lib/protocore/attestation" \
  "$evidence_root/var/lib/protocore/secrets" \
  "$evidence_root/var/lib/protocore/operator/threshold"
printf 'quote-evidence\n' >"$evidence_root/var/lib/protocore/attestation/quote.bin"
printf 'event-log-evidence\n' >"$evidence_root/var/lib/protocore/attestation/eventlog.bin"
printf 'key-transcript-evidence\n' >"$evidence_root/var/lib/protocore/secrets/key-transcript.json"
printf 'lythiumseal-operator-key-evidence\n' >"$evidence_root/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc"
quote_actual="$(sha256sum "$evidence_root/var/lib/protocore/attestation/quote.bin" | awk '{print $1}')"
event_log_actual="$(sha256sum "$evidence_root/var/lib/protocore/attestation/eventlog.bin" | awk '{print $1}')"
key_transcript_actual="$(sha256sum "$evidence_root/var/lib/protocore/secrets/key-transcript.json" | awk '{print $1}')"
sealed_actual="$(sha256sum "$evidence_root/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc" | awk '{print $1}')"
jq \
  --arg quote_actual "$quote_actual" \
  --arg event_log_actual "$event_log_actual" \
  --arg key_transcript_actual "$key_transcript_actual" \
  --arg sealed_actual "$sealed_actual" \
  '.attestation.tpm.quote_sha256 = $quote_actual
   | .attestation.tpm.event_log_sha256 = $event_log_actual
   | .attestation.tpm.sealed_key_policy.dkg_transcript_sha256 = $key_transcript_actual
   | .attestation.tpm.sealed_key_policy.sealed_share_sha256 = $sealed_actual' \
  "$valid_enrollment" >"$evidence_enrollment"

LOCAL_EVIDENCE_ROOT="$evidence_root" EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_TPM2_CHECKQUOTE=false \
  "$ROOT_DIR/scripts/validate-tpm-attestation-evidence.sh" "$evidence_enrollment" >/dev/null

jq --arg h9 "$h9" '.attestation.tpm.event_log_sha256 = $h9' \
  "$evidence_enrollment" >"$bad_evidence_hash"
expect_fail bad-evidence-hash \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_TPM2_CHECKQUOTE=false \
  "$ROOT_DIR/scripts/validate-tpm-attestation-evidence.sh" "$bad_evidence_hash"

jq \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg h8 "$h8" \
  --arg h9 "$h9" \
  '.node.chain_profile = "mainnet"
   | .attestation.tpm.mode = "hardware-tpm2"
   | .attestation.tpm.quote_verification = {
      tool: "tpm2_checkquote",
      ak_public_file: "/var/lib/protocore/attestation/ak.pub",
      quote_signature_file: "/var/lib/protocore/attestation/quote.sig",
      pcr_digest_file: "/var/lib/protocore/attestation/pcr.digest",
      ak_public_sha256: $h7,
      quote_signature_sha256: $h8,
      pcr_digest_sha256: $h9
    }
   | .on_chain_registration = {
      registry_contract: "0x2222222222222222222222222222222222222222",
      operator_address: .operator.address,
      cluster_id: .cluster.id,
      operator_index: .operator.index,
      registration_tx_hash: ("0x" + $h8),
      dag_round: 12345,
      quorum_certificate_hash: $h3,
      registration_method: "register",
      registration_function_selector: "0xf4896df2",
      registration_calldata_hash: $h4,
      attestation_embedded_in_registration: true,
      release_expected_digest: $h0,
      quote_sha256: $h1,
      event_log_sha256: $h2,
      pcr_policy_hash: $h4,
      dkg_transcript_sha256: $h5,
      sealed_share_sha256: $h6,
      attestation_payload_hash: $h8
    }' "$valid_enrollment" >"$valid_mainnet_enrollment"
payload_hash="$(canonical_attestation_payload_hash "$valid_mainnet_enrollment")"
jq --arg payload_hash "$payload_hash" \
  '.on_chain_registration.attestation_payload_hash = $payload_hash' \
  "$valid_mainnet_enrollment" >"$tmp_dir/enrollment-mainnet-valid.with-payload.json"
mv "$tmp_dir/enrollment-mainnet-valid.with-payload.json" "$valid_mainnet_enrollment"

EXPECTED_CHAIN_PROFILE=mainnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$valid_mainnet_enrollment" >/dev/null

jq 'del(.attestation.tpm.quote_verification)' \
  "$valid_mainnet_enrollment" >"$missing_hardware_quote_verification"
expect_fail missing-hardware-quote-verification \
  env EXPECTED_CHAIN_PROFILE=mainnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$missing_hardware_quote_verification"

jq --arg h9 "$h9" '.on_chain_registration.quote_sha256 = $h9' \
  "$valid_mainnet_enrollment" >"$mismatched_mainnet_hash"
expect_fail mismatched-mainnet-attestation-hash \
  env EXPECTED_CHAIN_PROFILE=mainnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$mismatched_mainnet_hash"

jq --arg h9 "$h9" '.on_chain_registration.attestation_payload_hash = $h9' \
  "$valid_mainnet_enrollment" >"$mismatched_payload_hash"
expect_fail mismatched-mainnet-payload-hash \
  env EXPECTED_CHAIN_PROFILE=mainnet EXPECTED_CHAIN_ID=69420 REQUIRE_RELEASE_DIGEST=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$mismatched_payload_hash"

valid_key_share="$tmp_dir/key-share-valid.json"
valid_key_share_with_files="$tmp_dir/key-share-local-files-valid.json"
valid_key_share_on_chain="$tmp_dir/key-share-on-chain-valid.json"
mismatched_output_hash="$tmp_dir/key-share-output-mismatched-hash.json"
missing_roster_hash="$tmp_dir/key-share-missing-roster-hash.json"
mismatched_lifecycle_payload="$tmp_dir/key-share-mismatched-lifecycle-payload.json"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg bls_pubkey "$bls_pubkey" \
  --arg signature "$signature" \
  'def addr($i): [
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
      "0x3333333333333333333333333333333333333333",
      "0x4444444444444444444444444444444444444444",
      "0x5555555555555555555555555555555555555555",
      "0x6666666666666666666666666666666666666666",
      "0x7777777777777777777777777777777777777777",
      "0x8888888888888888888888888888888888888888",
      "0x9999999999999999999999999999999999999999",
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ][$i];
    {
      schema_version: "monarch-protocore-key-share-ceremony/v1",
      ceremony: {
        type: "operator-rotation",
        id: "key-share-validator-test",
        runbook_id: "validator-test",
        created_at: "2026-06-01T00:00:00Z",
        reason: "validator coverage"
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
        threshold_scheme: "Ferveo-BLS12-381",
        previous_transcript_hash: $h0,
        next_transcript_file: "/var/lib/protocore/secrets/dkg-transcript-next.json",
        next_transcript_hash: $h5,
        transcript_commitment_hash: $h6,
        participant_commitments_hash: $h7,
        encrypted_share_bundle_hash: $h4,
        group_public_key_hex: $bls_pubkey
      },
      release: {
        metadata_sha256: $h0,
        protocore_digest: $h4
      },
      sealed_share_outputs: [
        range(0; 10) as $i
        | {
          operator_index: $i,
          share_file: "/var/lib/protocore/secrets/share-\($i).sealed",
          sha256: $h4,
          sealed_to_tpm: true,
          tpm_mode: "vtpm-testnet",
          pcr_quote_hash: $h1,
          pcr_event_log_hash: $h2,
          sealed_share_policy_hash: $h3,
          dkg_transcript_hash: $h5,
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

printf 'key-share-next-transcript-evidence\n' >"$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json"
for i in $(seq 0 9); do
  printf 'sealed-share-evidence\n' >"$evidence_root/var/lib/protocore/secrets/share-$i.sealed"
done
key_share_transcript_actual="$(sha256sum "$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json" | awk '{print $1}')"
key_share_share_actual="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share-0.sealed" | awk '{print $1}')"
jq \
  --arg transcript_actual "$key_share_transcript_actual" \
  --arg share_actual "$key_share_share_actual" \
  '.dkg.next_transcript_hash = $transcript_actual
   | .sealed_share_outputs[].dkg_transcript_hash = $transcript_actual
   | .sealed_share_outputs[].sha256 = $share_actual' \
  "$valid_key_share" >"$valid_key_share_with_files"

LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$valid_key_share_with_files" >/dev/null

bad_key_share_transcript_root="$tmp_dir/key-share-bad-transcript-root"
cp -R "$evidence_root" "$bad_key_share_transcript_root"
printf 'tampered-key-share-transcript\n' >"$bad_key_share_transcript_root/var/lib/protocore/secrets/dkg-transcript-next.json"
expect_fail bad-key-share-transcript-file-hash \
  env LOCAL_EVIDENCE_ROOT="$bad_key_share_transcript_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$valid_key_share_with_files"

bad_key_share_share_root="$tmp_dir/key-share-bad-share-root"
cp -R "$evidence_root" "$bad_key_share_share_root"
printf 'tampered-key-share-output\n' >"$bad_key_share_share_root/var/lib/protocore/secrets/share-0.sealed"
expect_fail bad-key-share-sealed-output-file-hash \
  env LOCAL_EVIDENCE_ROOT="$bad_key_share_share_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$valid_key_share_with_files"

jq \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  '.on_chain_lifecycle = {
    registry_contract: "0x2222222222222222222222222222222222222222",
    cluster_id: .cluster.id,
    next_dkg_epoch: .cluster.next_dkg_epoch,
    ceremony_tx_hash: ("0x" + $h1),
    attestation_tx_hash: ("0x" + $h2),
    dag_round: 12345,
    quorum_certificate_hash: $h3,
    ceremony_method: "submitPendingChange",
    ceremony_function_selector: "0x7d09426c",
    ceremony_calldata_hash: $h4,
    attestation_method: "attestDkgReshare",
    attestation_function_selector: "0x36e34030",
    attestation_calldata_hash: $h5,
    lifecycle_payload_hash: $h1
  }' "$valid_key_share" >"$valid_key_share_on_chain"
lifecycle_payload_hash="$(canonical_key_share_lifecycle_payload_hash "$valid_key_share_on_chain")"
jq --arg lifecycle_payload_hash "$lifecycle_payload_hash" \
  '.on_chain_lifecycle.lifecycle_payload_hash = $lifecycle_payload_hash' \
  "$valid_key_share_on_chain" >"$tmp_dir/key-share-on-chain-valid.with-payload.json"
mv "$tmp_dir/key-share-on-chain-valid.with-payload.json" "$valid_key_share_on_chain"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_ON_CHAIN_LIFECYCLE=true \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$valid_key_share_on_chain" >/dev/null

jq --arg h9 "$h9" '.on_chain_lifecycle.lifecycle_payload_hash = $h9' \
  "$valid_key_share_on_chain" >"$mismatched_lifecycle_payload"
expect_fail mismatched-lifecycle-payload \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_ON_CHAIN_LIFECYCLE=true \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$mismatched_lifecycle_payload"

jq --arg h9 "$h9" '.sealed_share_outputs[0].pcr_quote_hash = $h9' \
  "$valid_key_share" >"$mismatched_output_hash"
expect_fail mismatched-sealed-output-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$mismatched_output_hash"

jq 'del(.operators[0].pcr_event_log_hash)' "$valid_key_share" >"$missing_roster_hash"
expect_fail missing-roster-event-log-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-key-share-ceremony.sh" "$missing_roster_hash"

printf '{"ok":true,"checked":"enrollment-and-key-share-validators"}\n'
