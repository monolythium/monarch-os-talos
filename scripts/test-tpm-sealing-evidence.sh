#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "tpm sealing evidence test failed: $*" >&2
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
  if "$@" >/dev/null 2>"$tmp_dir/$label.err"; then
    fail "$label was accepted"
  fi
}

canonical_tpm_sealing_payload_hash() {
  local manifest="$1"

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
  ' "$manifest" | sha256sum | awk '{print $1}'
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

evidence_root="$tmp_dir/evidence"
mkdir -p "$evidence_root/var/lib/protocore/attestation" "$evidence_root/var/lib/protocore/secrets"
printf 'quote evidence\n' >"$evidence_root/var/lib/protocore/attestation/quote.bin"
printf 'event log evidence\n' >"$evidence_root/var/lib/protocore/attestation/eventlog.bin"
printf 'dkg transcript evidence\n' >"$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json"
printf 'tpm sealing command log\n' >"$evidence_root/var/lib/protocore/attestation/tpm-seal.log"
printf 'tpm public blob\n' >"$evidence_root/var/lib/protocore/secrets/share.pub"
printf 'tpm private blob\n' >"$evidence_root/var/lib/protocore/secrets/share.priv"
printf 'tpm loaded context\n' >"$evidence_root/var/lib/protocore/secrets/share.ctx"
printf 'sealed share evidence\n' >"$evidence_root/var/lib/protocore/secrets/share-2.sealed"
for i in $(seq 0 9); do
  [[ "$i" == "2" ]] && continue
  cp "$evidence_root/var/lib/protocore/secrets/share-2.sealed" \
    "$evidence_root/var/lib/protocore/secrets/share-$i.sealed"
done

h0="$(printf '0%.0s' {1..64})"
h1="$(printf '1%.0s' {1..64})"
h2="$(printf '2%.0s' {1..64})"
h3="$(printf '3%.0s' {1..64})"
h4="$(printf '4%.0s' {1..64})"
h5="$(printf '5%.0s' {1..64})"
h6="$(printf '6%.0s' {1..64})"
h7="$(printf '7%.0s' {1..64})"
h9="$(printf '9%.0s' {1..64})"
bls_pubkey="$(printf 'b%.0s' {1..96})"
signature="$(printf 'a%.0s' {1..128})"

quote_hash="$(sha256sum "$evidence_root/var/lib/protocore/attestation/quote.bin" | awk '{print $1}')"
event_log_hash="$(sha256sum "$evidence_root/var/lib/protocore/attestation/eventlog.bin" | awk '{print $1}')"
dkg_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/dkg-transcript-next.json" | awk '{print $1}')"
sealed_share_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share-2.sealed" | awk '{print $1}')"
command_log_hash="$(sha256sum "$evidence_root/var/lib/protocore/attestation/tpm-seal.log" | awk '{print $1}')"
public_blob_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share.pub" | awk '{print $1}')"
private_blob_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share.priv" | awk '{print $1}')"
context_hash="$(sha256sum "$evidence_root/var/lib/protocore/secrets/share.ctx" | awk '{print $1}')"

valid="$tmp_dir/tpm-sealing-valid.json"
valid_ceremony="$tmp_dir/key-share-ceremony-valid.json"
valid_enrollment="$tmp_dir/enrollment-valid.json"
bad_payload="$tmp_dir/tpm-sealing-bad-payload.json"
bad_policy="$tmp_dir/tpm-sealing-bad-policy.json"
bad_evidence_root="$tmp_dir/bad-evidence"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg quote_hash "$quote_hash" \
  --arg event_log_hash "$event_log_hash" \
  --arg dkg_hash "$dkg_hash" \
  --arg sealed_share_hash "$sealed_share_hash" \
  --arg command_log_hash "$command_log_hash" \
  --arg public_blob_hash "$public_blob_hash" \
  --arg private_blob_hash "$private_blob_hash" \
  --arg context_hash "$context_hash" \
  --arg bls_pubkey "$bls_pubkey" \
  --arg signature "$signature" \
  '{
    schema_version: "monarch-protocore-tpm-sealing-evidence/v1",
    chain: {
      profile: "testnet",
      chain_id: "69420"
    },
    cluster: {
      id: 1,
      dkg_epoch: 2
    },
    operator: {
      index: 2,
      address: "0x3333333333333333333333333333333333333333",
      position: "active",
      tpm_mode: "vtpm-testnet"
    },
    release: {
      metadata_sha256: $h0,
      protocore_digest: $h4
    },
    tpm: {
      mode: "vtpm-testnet",
      pcr_bank: "sha256",
      pcrs: [0, 2, 4, 7],
      pcr_values: {
        "0": $h0,
        "2": $h2,
        "4": $h4,
        "7": $h7
      },
      quote_file: "/var/lib/protocore/attestation/quote.bin",
      event_log_file: "/var/lib/protocore/attestation/eventlog.bin",
      quote_sha256: $quote_hash,
      event_log_sha256: $event_log_hash,
      quote_nonce: $h5,
      sealed_share_policy_hash: $h3
    },
    dkg: {
      transcript_file: "/var/lib/protocore/secrets/dkg-transcript-next.json",
      transcript_sha256: $dkg_hash,
      encrypted_share_bundle_hash: $h6,
      group_public_key_hex: $bls_pubkey
    },
    sealed_share: {
      file: "/var/lib/protocore/secrets/share-2.sealed",
      sha256: $sealed_share_hash,
      plaintext_share_hash: $h1,
      sealed_to_tpm: true
    },
    sealing: {
      toolchain: "tpm2-tools",
      tool_version: "5.7",
      command_log_file: "/var/lib/protocore/attestation/tpm-seal.log",
      command_log_sha256: $command_log_hash,
      public_blob_file: "/var/lib/protocore/secrets/share.pub",
      public_blob_sha256: $public_blob_hash,
      private_blob_file: "/var/lib/protocore/secrets/share.priv",
      private_blob_sha256: $private_blob_hash,
      context_file: "/var/lib/protocore/secrets/share.ctx",
      context_sha256: $context_hash,
      unseal_validation: {
        performed: true,
        pcr_policy_digest: $h3,
        plaintext_share_hash: $h1
      }
    },
    approvals: [
      {
        operator_index: 2,
        address: "0x3333333333333333333333333333333333333333",
        signature_scheme: "ML-DSA-65",
        signed_payload_hash: $h0,
        signature: ("0x" + $signature)
      }
    ]
  }' >"$valid"

payload_hash="$(canonical_tpm_sealing_payload_hash "$valid")"
jq --arg payload_hash "$payload_hash" '.approvals[].signed_payload_hash = $payload_hash' \
  "$valid" >"$tmp_dir/tpm-sealing-valid.with-payload.json"
mv "$tmp_dir/tpm-sealing-valid.with-payload.json" "$valid"

jq -n \
  --arg h0 "$h0" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg quote_hash "$quote_hash" \
  --arg event_log_hash "$event_log_hash" \
  --arg dkg_hash "$dkg_hash" \
  --arg sealed_share_hash "$sealed_share_hash" \
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
        type: "share-reseal",
        id: "tpm-seal-validator-test",
        runbook_id: "tpm-seal-validator",
        created_at: "2026-06-01T00:00:00Z",
        reason: "TPM seal evidence validator coverage"
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
          pcr_quote_hash: $quote_hash,
          pcr_event_log_hash: $event_log_hash,
          sealed_share_policy_hash: $h3
        }
      ],
      dkg: {
        threshold_scheme: "Ferveo-BLS12-381",
        previous_transcript_hash: $h0,
        next_transcript_file: "/var/lib/protocore/secrets/dkg-transcript-next.json",
        next_transcript_hash: $dkg_hash,
        transcript_commitment_hash: $h7,
        participant_commitments_hash: $h0,
        encrypted_share_bundle_hash: $h6,
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
          sha256: $sealed_share_hash,
          sealed_to_tpm: true,
          tpm_mode: "vtpm-testnet",
          pcr_quote_hash: $quote_hash,
          pcr_event_log_hash: $event_log_hash,
          sealed_share_policy_hash: $h3,
          dkg_transcript_hash: $dkg_hash,
          dkg_epoch: 2
        }
      ],
      approvals: [
        range(0; 7) as $i
        | {
          operator_index: $i,
          address: addr($i),
          signature_scheme: "ML-DSA-65",
          signed_payload_hash: $h7,
          signature: ("0x" + $signature)
        }
      ]
    }' >"$valid_ceremony"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h7 "$h7" \
  --arg quote_hash "$quote_hash" \
  --arg event_log_hash "$event_log_hash" \
  --arg dkg_hash "$dkg_hash" \
  --arg sealed_share_hash "$sealed_share_hash" \
  '{
    schema_version: "monarch-protocore-enrollment/v1",
    node: {
      role: "operator-signing",
      chain_profile: "testnet",
      chain_id: "69420",
      node_id: "operator-2"
    },
    operator: {
      address: "0x3333333333333333333333333333333333333333",
      position: "active",
      index: 2
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
      expected_digest: $h4
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
        quote_sha256: $quote_hash,
        event_log_sha256: $event_log_hash,
        quote_nonce: $h5,
        sealed_key_policy: {
          pcrs: [0, 2, 4, 7],
          key_share_refs: ["lythiumseal_operator_key"],
          policy_digest: $h3,
          dkg_transcript_sha256: $dkg_hash,
          sealed_share_sha256: $sealed_share_hash
        }
      }
    },
    secret_files: {
      operator_identity_key: "/var/lib/protocore/secrets/operator-identity.key",
      bls_share: "/var/lib/protocore/secrets/bls-share",
      cluster_key_share: "/var/lib/protocore/secrets/cluster-key-share",
      dkg_transcript: "/var/lib/protocore/secrets/dkg-transcript-next.json",
      lythiumseal_operator_key: "/var/lib/protocore/secrets/share-2.sealed",
      tpm_sealed_bls_share: "/var/lib/protocore/secrets/share-2.sealed"
    }
  }' >"$valid_enrollment"

LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
KEY_SHARE_CEREMONY="$valid_ceremony" ENROLLMENT_MANIFEST="$valid_enrollment" \
  "$ROOT_DIR/scripts/validate-tpm-sealing-evidence.sh" "$valid" >/dev/null

jq --arg h9 "$h9" '.approvals[0].signed_payload_hash = $h9' "$valid" >"$bad_payload"
expect_fail bad-payload-hash \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  KEY_SHARE_CEREMONY="$valid_ceremony" ENROLLMENT_MANIFEST="$valid_enrollment" \
  "$ROOT_DIR/scripts/validate-tpm-sealing-evidence.sh" "$bad_payload"

jq --arg h9 "$h9" '.sealing.unseal_validation.pcr_policy_digest = $h9' "$valid" >"$bad_policy"
expect_fail bad-policy-binding \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  KEY_SHARE_CEREMONY="$valid_ceremony" ENROLLMENT_MANIFEST="$valid_enrollment" \
  "$ROOT_DIR/scripts/validate-tpm-sealing-evidence.sh" "$bad_policy"

cp -R "$evidence_root" "$bad_evidence_root"
printf 'tampered sealed share\n' >"$bad_evidence_root/var/lib/protocore/secrets/share-2.sealed"
expect_fail bad-local-sealed-share-hash \
  env LOCAL_EVIDENCE_ROOT="$bad_evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  KEY_SHARE_CEREMONY="$valid_ceremony" ENROLLMENT_MANIFEST="$valid_enrollment" \
  "$ROOT_DIR/scripts/validate-tpm-sealing-evidence.sh" "$valid"

printf '{"ok":true,"checked":"tpm-sealing-evidence"}\n'
