#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "on-chain enrollment runner test failed: $*" >&2
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

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

h0="$(hex_repeat 0 64)"
h1="$(hex_repeat 1 64)"
h2="$(hex_repeat 2 64)"
h3="$(hex_repeat 3 64)"
h4="$(hex_repeat 4 64)"
h5="$(hex_repeat 5 64)"
h6="$(hex_repeat 6 64)"
h7="$(hex_repeat 7 64)"

input_manifest="$tmp_dir/enrollment-input.json"
jq -S -n \
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
      node_id: "on-chain-enrollment-runner-test-operator-0"
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
  }' >"$input_manifest"

helper="$tmp_dir/external-on-chain-enrollment-fixture.sh"
cat >"$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

hex_repeat() {
  local byte="$1"
  local count="$2"
  printf "%${count}s" "" | tr ' ' "$byte"
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

h3="$(hex_repeat 3 64)"
h4="$(hex_repeat 4 64)"
h8="$(hex_repeat 8 64)"

jq -S \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h8 "$h8" \
  '.on_chain_registration = {
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
    release_expected_digest: .release.expected_digest,
    quote_sha256: .attestation.tpm.quote_sha256,
    event_log_sha256: .attestation.tpm.event_log_sha256,
    pcr_policy_hash: .attestation.tpm.sealed_key_policy.policy_digest,
    dkg_transcript_sha256: .attestation.tpm.sealed_key_policy.dkg_transcript_sha256,
    sealed_share_sha256: .attestation.tpm.sealed_key_policy.sealed_share_sha256,
    attestation_payload_hash: $h8
  }' "$MONARCH_ENROLLMENT_INPUT_MANIFEST" >"$MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST"

payload_hash="$(canonical_attestation_payload_hash "$MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST")"
jq -S --arg payload_hash "$payload_hash" \
  '.on_chain_registration.attestation_payload_hash = $payload_hash' \
  "$MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST" >"$MONARCH_ENROLLMENT_OUTPUT_DIR/enrollment.on-chain.with-payload.json"
mv "$MONARCH_ENROLLMENT_OUTPUT_DIR/enrollment.on-chain.with-payload.json" \
  "$MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST"
SH
chmod +x "$helper"

out="$tmp_dir/on-chain-enrollment"
ENROLLMENT_MANIFEST="$input_manifest" \
ENROLLMENT_ON_CHAIN_COMMAND="$helper" \
ENROLLMENT_ON_CHAIN_COMMAND_LABEL="fixture-node-registry-register" \
ENROLLMENT_ON_CHAIN_STRICT=false \
REQUIRE_RELEASE_DIGEST=true \
EXPECTED_CHAIN_PROFILE=testnet \
EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/run-on-chain-enrollment.sh" "$out" >/dev/null

jq -e '
  .schema_version == "monarch-on-chain-enrollment-run/v1"
  and .ok == true
  and .external_command.label == "fixture-node-registry-register"
  and .policy.enrollment_strict == false
  and .policy.require_on_chain_registration == true
  and .policy.require_hardware_tpm == false
  and .registration.registration_method == "register"
  and .registration.registration_function_selector == "0xf4896df2"
  and .registration.operator_address == "0x1111111111111111111111111111111111111111"
  and (.registration.attestation_payload_hash | test("^[0-9a-f]{64}$"))
  and (.artifacts.on_chain_manifest.sha256 | test("^[0-9a-f]{64}$"))
' "$out/on-chain-enrollment-run.json" >/dev/null \
  || fail "on-chain enrollment summary has wrong shape"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_ON_CHAIN_REGISTRATION=true \
  "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$out/enrollment.on-chain.json" >/dev/null

if ENROLLMENT_MANIFEST="$input_manifest" \
  ENROLLMENT_ON_CHAIN_STRICT=false \
    "$ROOT_DIR/scripts/run-on-chain-enrollment.sh" "$tmp_dir/no-command" \
      >/dev/null 2>"$tmp_dir/no-command.err"; then
  fail "missing external on-chain enrollment command was accepted"
fi
grep -F "ENROLLMENT_ON_CHAIN_COMMAND is required" "$tmp_dir/no-command.err" >/dev/null \
  || fail "missing-command rejection reason changed"

no_proof_helper="$tmp_dir/external-no-on-chain-proof.sh"
cat >"$no_proof_helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cp "$MONARCH_ENROLLMENT_INPUT_MANIFEST" "$MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST"
SH
chmod +x "$no_proof_helper"

if ENROLLMENT_MANIFEST="$input_manifest" \
  ENROLLMENT_ON_CHAIN_COMMAND="$no_proof_helper" \
  ENROLLMENT_ON_CHAIN_STRICT=false \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
    "$ROOT_DIR/scripts/run-on-chain-enrollment.sh" "$tmp_dir/no-proof" \
      >/dev/null 2>"$tmp_dir/no-proof.err"; then
  fail "missing on-chain registration proof was accepted"
fi
grep -F "did not write on_chain_registration proof" "$tmp_dir/no-proof.err" >/dev/null \
  || fail "missing-proof rejection reason changed"

if ENROLLMENT_MANIFEST="$input_manifest" \
  ENROLLMENT_ON_CHAIN_COMMAND="$helper" \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
    "$ROOT_DIR/scripts/run-on-chain-enrollment.sh" "$tmp_dir/strict-vtpm" \
      >/dev/null 2>"$tmp_dir/strict-vtpm.err"; then
  fail "strict production enrollment accepted vtpm-testnet input"
fi
grep -F "REQUIRE_HARDWARE_TPM=true" "$tmp_dir/strict-vtpm.err" >/dev/null \
  || fail "strict hardware TPM rejection reason changed"

printf '{"ok":true,"checked":"on-chain-enrollment-runner"}\n'
