#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-"$MONO_CORE_DIR/target/release/protocore"}"
PROTOCORE_SOURCE="${PROTOCORE_SOURCE:-local}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-testnet}"
CHAIN_PROFILE="${CHAIN_PROFILE:-testnet}"
CHAIN_ID="${CHAIN_ID:-69420}"
GENESIS_TOML="${GENESIS_TOML:-"$ROOT_DIR/defaults/$CHAIN_PROFILE/genesis.toml"}"
KERNEL_BASELINE_FILE="${KERNEL_BASELINE_FILE:-"$ROOT_DIR/kernel-hardening-baseline.json"}"
MONARCH_DESKTOP_MIN_VERSION="${MONARCH_DESKTOP_MIN_VERSION:-0.0.5}"
MONARCH_DESKTOP_MAX_VERSION="${MONARCH_DESKTOP_MAX_VERSION:-<1.0.0}"
MONARCH_DESKTOP_CHANNEL="${MONARCH_DESKTOP_CHANNEL:-$RELEASE_CHANNEL}"
UPGRADE_REQUIRES_SAME_CHANNEL="${UPGRADE_REQUIRES_SAME_CHANNEL:-true}"
STATE_MIGRATION_REQUIRED="${STATE_MIGRATION_REQUIRED:-false}"
STATE_MIGRATION_MODE="${STATE_MIGRATION_MODE:-none}"
STATE_MIGRATION_RUNBOOK_ID="${STATE_MIGRATION_RUNBOOK_ID:-}"
ROLLBACK_SUPPORTED="${ROLLBACK_SUPPORTED:-true}"
PROTOCORE_P2P_LISTEN="${PROTOCORE_P2P_LISTEN:-/ip4/0.0.0.0/tcp/29898}"
PROTOCORE_RPC_LISTEN="${PROTOCORE_RPC_LISTEN:-0.0.0.0:8545}"
PROTOCORE_DISCOVERY="${PROTOCORE_DISCOVERY:-hybrid}"
PROTOCORE_NODE_MODE="${PROTOCORE_NODE_MODE:-operator}"
PROTOCORE_REQUIRE_ENROLLMENT="${PROTOCORE_REQUIRE_ENROLLMENT:-false}"
PROTOCORE_ENROLLMENT_FILE="${PROTOCORE_ENROLLMENT_FILE:-/var/lib/protocore/enrollment/enrollment.json}"
PROTOCORE_EXPECTED_DIGEST_FILE="${PROTOCORE_EXPECTED_DIGEST_FILE:-}"
PROTOCORE_REQUIRE_TPM_BINDING="${PROTOCORE_REQUIRE_TPM_BINDING:-false}"
PROTOCORE_TPM_QUOTE_FILE="${PROTOCORE_TPM_QUOTE_FILE:-}"
PROTOCORE_TPM_EVENT_LOG_FILE="${PROTOCORE_TPM_EVENT_LOG_FILE:-}"
PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="${PROTOCORE_TPM_SEALED_BLS_SHARE_FILE:-}"
PROTOCORE_DKG_TRANSCRIPT_FILE="${PROTOCORE_DKG_TRANSCRIPT_FILE:-}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-}"
if [[ "$PROTOCORE_REQUIRE_TPM_BINDING" == "true" ]]; then
  PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc}"
  PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="${PROTOCORE_TPM_SEALED_BLS_SHARE_FILE:-$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE}"
fi
DM_VERITY_EXPECTED_ROOT_HASHES="${DM_VERITY_EXPECTED_ROOT_HASHES:-}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
[[ "$PROTOCORE_BINARY" = /* ]] || PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"
if [[ -n "$GENESIS_TOML" && "$GENESIS_TOML" != /* ]]; then
  GENESIS_TOML="$ROOT_DIR/$GENESIS_TOML"
fi
if [[ -n "$KERNEL_BASELINE_FILE" && "$KERNEL_BASELINE_FILE" != /* ]]; then
  KERNEL_BASELINE_FILE="$ROOT_DIR/$KERNEL_BASELINE_FILE"
fi

mkdir -p "$OUT_DIR"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need git
need jq
need sha256sum
need stat

git_commit() {
  git -C "$1" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

git_dirty() {
  if [[ ! -d "$1/.git" ]]; then
    printf 'false'
    return
  fi
  if ! git -C "$1" diff --quiet --ignore-submodules -- 2>/dev/null; then
    printf 'true'
    return
  fi
  if [[ -n "$(git -C "$1" status --short --untracked-files=no 2>/dev/null)" ]]; then
    printf 'true'
    return
  fi
  printf 'false'
}

protocore_version() {
  if [[ -x "$PROTOCORE_BINARY" ]]; then
    "$PROTOCORE_BINARY" version --output json 2>/dev/null | jq -r '.version // "unknown"' || printf 'unknown'
    return
  fi
  printf 'unknown'
}

protocore_binary_sha256() {
  if [[ -x "$PROTOCORE_BINARY" ]]; then
    sha256sum "$PROTOCORE_BINARY" | awk '{print $1}'
    return
  fi
  printf 'unknown'
}

file_sha256_or_unknown() {
  if [[ -f "$1" ]]; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  printf 'unknown'
}

metadata_path_for_file() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf 'none'
  elif [[ "$path" == "$ROOT_DIR/"* ]]; then
    printf '%s' "${path#"$ROOT_DIR/"}"
  else
    printf '%s' "$path"
  fi
}

bool_json() {
  case "$1" in
    true|TRUE|1|yes|YES) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

hash_list_json() {
  printf '%s\n' "$1" \
    | tr ',' '\n' \
    | jq -R -s '
      split("\n")
      | map(gsub("^\\s+|\\s+$"; ""))
      | map(ascii_downcase | sub("^sha256:"; "") | sub("^0x"; ""))
      | map(select(length > 0))
    '
}

artifacts_file="$(mktemp)"
trap 'rm -f "$artifacts_file"' EXIT

find "$OUT_DIR" -maxdepth 1 -type f \
  \( -name "monarch-os-talos-$TALOS_VERSION-$ARCH.iso" \
    -o -name "monarch-os-talos-$TALOS_VERSION-$ARCH.raw" \
    -o -name "monarch-os-talos-$TALOS_VERSION-$ARCH.raw.xz" \
    -o -name "monarch-protocore-$ARCH-*.tar" \
    -o -name "monarch-*.spdx.json" \) \
  | sort \
  | while read -r artifact; do
      sha="$(sha256sum "$artifact" | awk '{print $1}')"
      size="$(stat -c '%s' "$artifact")"
      jq -n \
        --arg path "$(basename "$artifact")" \
        --arg sha256 "$sha" \
        --argjson size "$size" \
        '{path: $path, sha256: $sha256, size_bytes: $size}'
    done > "$artifacts_file"

metadata_path="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"
repo_commit="$(git_commit "$ROOT_DIR")"
mono_core_commit="$(git_commit "$MONO_CORE_DIR")"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
protocore_version_value="$(protocore_version)"
genesis_metadata_path="$(metadata_path_for_file "$GENESIS_TOML")"
genesis_sha256="$(file_sha256_or_unknown "$GENESIS_TOML")"
kernel_baseline_metadata_path="$(metadata_path_for_file "$KERNEL_BASELINE_FILE")"
kernel_baseline_sha256="$(file_sha256_or_unknown "$KERNEL_BASELINE_FILE")"
dm_verity_expected_root_hashes_json="$(hash_list_json "$DM_VERITY_EXPECTED_ROOT_HASHES")"
jq -e 'all(.[]; test("^[0-9a-f]{64}([0-9a-f]{64})?$"))' <<<"$dm_verity_expected_root_hashes_json" >/dev/null \
  || {
    echo "DM_VERITY_EXPECTED_ROOT_HASHES must be comma-separated 32-byte or 64-byte hex hashes" >&2
    exit 1
  }
case "$STATE_MIGRATION_MODE" in
  none|backward-compatible|one-way) ;;
  *)
    echo "STATE_MIGRATION_MODE must be none, backward-compatible, or one-way" >&2
    exit 1
    ;;
esac
state_migration_required_json="$(bool_json "$STATE_MIGRATION_REQUIRED")"
rollback_supported_json="$(bool_json "$ROLLBACK_SUPPORTED")"
if [[ "$state_migration_required_json" == "false" && "$STATE_MIGRATION_MODE" != "none" ]]; then
  echo "STATE_MIGRATION_MODE must be none when STATE_MIGRATION_REQUIRED=false" >&2
  exit 1
fi
if [[ "$state_migration_required_json" == "true" ]]; then
  [[ "$STATE_MIGRATION_MODE" != "none" ]] || {
    echo "STATE_MIGRATION_REQUIRED=true requires STATE_MIGRATION_MODE=backward-compatible or one-way" >&2
    exit 1
  }
  [[ -n "$STATE_MIGRATION_RUNBOOK_ID" ]] || {
    echo "STATE_MIGRATION_REQUIRED=true requires STATE_MIGRATION_RUNBOOK_ID" >&2
    exit 1
  }
fi

jq -s \
  --arg schema_version "monarch-os-release-metadata/v1" \
  --arg generated_at "$generated_at" \
  --arg talos_version "$TALOS_VERSION" \
  --arg arch "$ARCH" \
  --arg repo_commit "$repo_commit" \
  --argjson repo_dirty "$(git_dirty "$ROOT_DIR")" \
  --arg mono_core_commit "$mono_core_commit" \
  --argjson mono_core_dirty "$(git_dirty "$MONO_CORE_DIR")" \
  --arg protocore_version "$protocore_version_value" \
  --arg protocore_source "$PROTOCORE_SOURCE" \
  --arg protocore_binary "$(basename "$PROTOCORE_BINARY")" \
  --arg protocore_binary_sha256 "$(protocore_binary_sha256)" \
  --arg release_channel "$RELEASE_CHANNEL" \
  --arg chain_profile "$CHAIN_PROFILE" \
  --arg chain_id "$CHAIN_ID" \
  --arg genesis_path "$genesis_metadata_path" \
  --arg genesis_sha256 "$genesis_sha256" \
  --arg kernel_baseline_path "$kernel_baseline_metadata_path" \
  --arg kernel_baseline_sha256 "$kernel_baseline_sha256" \
  --arg monarch_desktop_min_version "$MONARCH_DESKTOP_MIN_VERSION" \
  --arg monarch_desktop_max_version "$MONARCH_DESKTOP_MAX_VERSION" \
  --arg monarch_desktop_channel "$MONARCH_DESKTOP_CHANNEL" \
  --arg protocore_p2p_listen "$PROTOCORE_P2P_LISTEN" \
  --arg protocore_rpc_listen "$PROTOCORE_RPC_LISTEN" \
  --arg protocore_discovery "$PROTOCORE_DISCOVERY" \
  --arg protocore_node_mode "$PROTOCORE_NODE_MODE" \
  --arg protocore_enrollment_file "$PROTOCORE_ENROLLMENT_FILE" \
  --arg protocore_expected_digest_file "$PROTOCORE_EXPECTED_DIGEST_FILE" \
  --arg protocore_tpm_quote_file "$PROTOCORE_TPM_QUOTE_FILE" \
  --arg protocore_tpm_event_log_file "$PROTOCORE_TPM_EVENT_LOG_FILE" \
  --arg protocore_tpm_sealed_bls_share_file "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" \
  --arg protocore_dkg_transcript_file "$PROTOCORE_DKG_TRANSCRIPT_FILE" \
  --arg protocore_lythiumseal_operator_key_file "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" \
  --argjson genesis_embedded "$(bool_json "$([[ -f "$GENESIS_TOML" ]] && printf true || printf false)")" \
  --argjson upgrade_requires_same_channel "$(bool_json "$UPGRADE_REQUIRES_SAME_CHANNEL")" \
  --arg state_migration_mode "$STATE_MIGRATION_MODE" \
  --arg state_migration_runbook_id "$STATE_MIGRATION_RUNBOOK_ID" \
  --argjson state_migration_required "$state_migration_required_json" \
  --argjson rollback_supported "$rollback_supported_json" \
  --argjson protocore_require_enrollment "$(bool_json "$PROTOCORE_REQUIRE_ENROLLMENT")" \
  --argjson protocore_require_tpm_binding "$(bool_json "$PROTOCORE_REQUIRE_TPM_BINDING")" \
  --argjson dm_verity_expected_root_hashes "$dm_verity_expected_root_hashes_json" \
  '{
    schema_version: $schema_version,
    generated_at: $generated_at,
    talos: {
      version: $talos_version,
      arch: $arch
    },
    substrate: {
      base: "talos",
      control_plane: "talos_api_mtls",
      no_ssh_server: true,
      no_package_manager: true,
      no_interactive_shell: true,
      extension_policy: {
        service: "protocore",
        entrypoint: "./protocore-entrypoint",
        allowed_writable_mounts: ["/var/lib/protocore"],
        forbidden_payloads: [
          "ssh_server",
          "interactive_shell",
          "package_manager"
        ]
      },
      kernel_hardening_baseline: {
        path: $kernel_baseline_path,
        sha256: $kernel_baseline_sha256,
        schema: "monarch-os-kernel-hardening-baseline/v1"
      },
      dm_verity: {
        expected_root_hashes: $dm_verity_expected_root_hashes,
        expected_root_hash_source: "DM_VERITY_EXPECTED_ROOT_HASHES",
        root_hash_binding_required_when_enforced: true
      }
    },
    network_policy: {
      talos_api: {
        port: 50000,
        transport: "mTLS",
        exposure: "operator_control_plane"
      },
      protocore_rpc: {
        env: "PROTOCORE_RPC_LISTEN",
        listen: $protocore_rpc_listen,
        port: 8545,
        exposure: "operator_data_plane"
      },
      protocore_p2p: {
        env: "PROTOCORE_P2P_LISTEN",
        listen: $protocore_p2p_listen,
        port: 29898,
        discovery: $protocore_discovery,
        exposure: "public_p2p"
      },
      prohibited: [
        "ssh",
        "http_shell",
        "package_manager_ports"
      ]
    },
    provisioning_policy: {
      default_node_role: $protocore_node_mode,
      operator_identity_autogenerated_on_first_boot: ($protocore_node_mode != "full"),
      operator_identity_opt_out_env: "PROTOCORE_NO_OPERATOR",
      no_default_secrets: true,
      inline_secret_env_prohibited: true,
      prohibited_inline_secret_env: [
        "PROTOCORE_KEYSTORE_PASSPHRASE",
        "PROTOCORE_OPERATOR_MNEMONIC",
        "PROTOCORE_OPERATOR_PRIVATE_KEY",
        "PROTOCORE_BLS_SHARE",
        "PROTOCORE_CLUSTER_KEY_SHARE",
        "PROTOCORE_KEY_SHARE"
      ],
      enrollment: {
        required: $protocore_require_enrollment,
        env: "PROTOCORE_REQUIRE_ENROLLMENT",
        file_env: "PROTOCORE_ENROLLMENT_FILE",
        manifest_path: $protocore_enrollment_file,
        schema: "monarch-protocore-enrollment/v1",
        schema_path: "schemas/protocore-enrollment-manifest.schema.json",
        validator: "scripts/validate-enrollment-manifest.sh",
        required_for_operator_signing: true,
        attestation_evidence_hashes_required: true,
        attestation_payload: {
          schema: "monarch-protocore-operator-attestation-payload/v1",
          canonicalization: "jq-canonical-sorted-json/v1",
          hash: "sha256",
          validator: "scripts/validate-enrollment-manifest.sh"
        },
        on_chain_registration_required_for_mainnet_operator_signing: true,
        on_chain_registration_call_binding_required_for_mainnet: true,
        on_chain_registration_attestation_payload_binding_required_for_mainnet: true,
        on_chain_registration_methods: {
          registration: "register",
          registration_signature: "register(bytes32,string,bytes32,uint32,uint32,bytes,bytes,bytes)",
          registration_selector: "0xf4896df2",
          attestation_binding: "embedded_in_register"
        }
      },
      release_digest: {
        env: "PROTOCORE_EXPECTED_DIGEST",
        file_env: "PROTOCORE_EXPECTED_DIGEST_FILE",
        file_path: $protocore_expected_digest_file,
        fail_closed_when_set: true
      },
      tpm_binding: {
        required: $protocore_require_tpm_binding,
        env: "PROTOCORE_REQUIRE_TPM_BINDING",
        quote_file_env: "PROTOCORE_TPM_QUOTE_FILE",
        quote_file_path: $protocore_tpm_quote_file,
        event_log_file_env: "PROTOCORE_TPM_EVENT_LOG_FILE",
        event_log_file_path: $protocore_tpm_event_log_file,
        sealed_bls_share_file_env: "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE",
        sealed_bls_share_file_path: $protocore_tpm_sealed_bls_share_file,
        dkg_transcript_file_env: "PROTOCORE_DKG_TRANSCRIPT_FILE",
        dkg_transcript_file_path: $protocore_dkg_transcript_file,
        lythiumseal_operator_key_file_env: "PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE",
        lythiumseal_operator_key_file_path: $protocore_lythiumseal_operator_key_file,
        required_for_operator_signing: true,
        quote_verification: {
          validator: "scripts/validate-tpm-attestation-evidence.sh",
          tool: "tpm2_checkquote",
          required_for_hardware_tpm: true,
          required_for_mainnet_operator_signing: true
        },
        sealing_evidence: {
          schema: "monarch-protocore-tpm-sealing-evidence/v1",
          schema_path: "schemas/protocore-tpm-sealing-evidence.schema.json",
          validator: "scripts/validate-tpm-sealing-evidence.sh",
          required_for_operator_signing: true,
          required_for_mainnet_operator_signing: true,
          requires_hardware_tpm_on_mainnet: true,
          signed_payload_schema: "monarch-protocore-tpm-sealing-payload/v1",
          canonicalization: "jq-canonical-sorted-json/v1",
          hash: "sha256",
          binds_key_share_ceremony: true,
          binds_enrollment_manifest: true,
          verifies_tpm_quote_event_log_hashes: true,
          verifies_policy_digest_binding: true,
          verifies_unseal_plaintext_hash_binding: true,
          verifies_sealed_share_file_hash: true,
          verifies_tpm2_object_blobs: true,
          local_file_hash_verification_env: "LOCAL_EVIDENCE_ROOT",
          local_file_hash_verification_toggle_env: "VERIFY_LOCAL_FILES"
        }
      },
      key_share_lifecycle: {
        schema: "monarch-protocore-key-share-ceremony/v1",
        schema_path: "schemas/protocore-key-share-ceremony.schema.json",
        validator: "scripts/validate-key-share-ceremony.sh",
        cluster_size: 10,
        threshold: 7,
        approval_threshold: 7,
        required_for_mainnet_operator_signing: true,
        requires_hardware_tpm_on_mainnet: true,
        requires_tpm_evidence_hash_binding: true,
        local_file_hash_verification_env: "LOCAL_EVIDENCE_ROOT",
        local_file_hash_verification_toggle_env: "VERIFY_LOCAL_FILES",
        verifies_dkg_transcript_file: true,
        verifies_all_sealed_share_output_files: true,
        on_chain_lifecycle_payload: {
          schema: "monarch-protocore-key-share-lifecycle-payload/v1",
          canonicalization: "jq-canonical-sorted-json/v1",
          hash: "sha256",
          validator: "scripts/validate-key-share-ceremony.sh",
          methods: {
            ceremony: "submitPendingChange",
            ceremony_selector: "0x7d09426c",
            attestation: "attestDkgReshare",
            attestation_selector: "0x36e34030"
          }
        },
        requires_on_chain_lifecycle_on_mainnet: true
      },
      key_share_handoff: {
        schema: "monarch-protocore-key-share-handoff/v1",
        schema_path: "schemas/protocore-key-share-handoff.schema.json",
        renderer: "scripts/render-key-share-handoff.sh",
        validator: "scripts/validate-key-share-handoff.sh",
        source_schema: "monarch-protocore-key-share-ceremony/v1",
        required_for_operator_signing_import: true,
        ceremony_manifest_sha256_required: true,
        verifies_operator_roster_binding: true,
        verifies_tpm_sealed_share_hash_binding: true,
        verifies_dkg_transcript_hash_binding: true,
        local_file_hash_verification_env: "LOCAL_EVIDENCE_ROOT",
        local_file_hash_verification_toggle_env: "VERIFY_LOCAL_FILES",
        import_paths: {
          sealed_share_file: $protocore_tpm_sealed_bls_share_file,
          dkg_transcript_file: $protocore_dkg_transcript_file
        }
      },
      external_secret_file_env: [
        "PROTOCORE_EXPECTED_DIGEST_FILE",
        "PROTOCORE_INDEXER_POSTGRES_URL_FILE",
        "PROTOCORE_TPM_QUOTE_FILE",
        "PROTOCORE_TPM_EVENT_LOG_FILE",
        "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE",
        "PROTOCORE_DKG_TRANSCRIPT_FILE",
        "PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE"
      ]
    },
    incident_response_policy: {
      schema: "monarch-incident-response/v1",
      schema_path: "schemas/monarch-incident-response.schema.json",
      validator: "scripts/validate-incident-response.sh",
      signed_runbook_required: true,
      evidence_file_hashes_required: true,
      foundation_authorization_required_for: [
        "freeze-admission",
        "pause-bridge-route",
        "rollback-bridge",
        "emergency-key-rotation"
      ],
      on_chain_action_required_for_mainnet: [
        "freeze-admission",
        "pause-bridge-route",
        "rollback-bridge",
        "emergency-key-rotation"
      ],
      executor_binding_required_for_mainnet: true,
      on_chain_executor_methods: {
        "freeze-admission": "freezeAdmission",
        "pause-bridge-route": "pauseBridgeRoute",
        "rollback-bridge": "rollbackBridge",
        "emergency-key-rotation": "emergencyKeyRotation"
      },
      on_chain_executor_bindings: {
        "freeze-admission": {
          contract: "0x0000000000000000000000000000000000001005",
          method: "freezeAdmission",
          selector: "0x7a2605cd",
          argument: "reason_hash"
        },
        "pause-bridge-route": {
          contract: "0x0000000000000000000000000000000000001008",
          method: "pauseBridgeRoute",
          selector: "0x11a2dc64",
          argument: "bridge_route_id,reason_hash"
        },
        "rollback-bridge": {
          contract: "0x0000000000000000000000000000000000001008",
          method: "rollbackBridge",
          selector: "0x059a1b5c",
          argument: "bridge_route_id,reason_hash"
        },
        "emergency-key-rotation": {
          contract: "0x0000000000000000000000000000000000001005",
          method: "emergencyKeyRotation",
          selector: "0x0aeeafbf",
          argument: "target_bls_pubkey,effective_epoch,intent_id"
        }
      },
      disallowed_freeze_reasons: [
        "routine-upgrade",
        "parameter-change",
        "protocol-direction",
        "account-censorship",
        "asset-confiscation",
        "ongoing-supervision"
      ]
    },
    audit_trail_policy: {
      schema: "monarch-operator-audit-trail/v1",
      schema_path: "schemas/monarch-operator-audit-trail.schema.json",
      validator: "scripts/validate-operator-audit-trail.sh",
      signed_payload_schema: "monarch-operator-audit-payload/v1",
      canonicalization: "jq-canonical-sorted-json/v1",
      hash: "sha256",
      required_for_operator_actions: true,
      required_for_mainnet_operator_actions: true,
      evidence_file_hashes_required: true,
      local_file_hash_verification_env: "LOCAL_EVIDENCE_ROOT",
      local_file_hash_verification_toggle_env: "VERIFY_LOCAL_FILES",
      hash_chain_supported: true,
      high_risk_approval_threshold: 2,
      desktop_receipt_binding_required: true,
      on_chain_receipt_binding_required_for_mainnet: true,
      diff_vs_intent_required: true,
      peer_vouches_required_for: [
        "freeze-admission",
        "kill-switch-freeze"
      ],
      supported_actions: [
        "enrollment",
        "dkg-ceremony",
        "tpm-sealing",
        "key-share-handoff",
        "key-share-rotation",
        "certificate-rotation",
        "backup",
        "restore",
        "disaster-recovery",
        "incident-response",
        "freeze-admission",
        "kill-switch-freeze",
        "upgrade",
        "rollback",
        "desktop-operation",
        "chat-e2e",
        "release-promotion"
      ]
    },
    disaster_recovery_policy: {
      schema: "monarch-disaster-recovery/v1",
      schema_path: "schemas/monarch-disaster-recovery.schema.json",
      validator: "scripts/validate-disaster-recovery.sh",
      protocore_data_path: "/var/lib/protocore",
      hot_backup_prohibited: true,
      stopped_or_offline_backup_required: true,
      restore_manifest_required_before_cluster_rejoin: true,
      supported_recovery_modes: [
        "resync",
        "offline-restore",
        "disk-replacement",
        "signing-node-reseal"
      ],
      required_post_restore_checks: [
        "release-digest-match",
        "genesis-match",
        "chain-id-match",
        "protocore-rpc-healthy"
      ],
      signing_node_key_share_recovery_required: true,
      on_chain_recovery_required_for_mainnet_signing: true,
      on_chain_recovery_calldata_hash: "sha256",
      on_chain_executor_methods: {
        recover_operator_node: "recoverOperatorNode"
      },
      on_chain_executor_bindings: {
        recover_operator_node: {
          contract: "0x0000000000000000000000000000000000001005",
          method: "recoverOperatorNode",
          selector: "0xe58729e6",
          argument: "operator_peer_id"
        }
      }
    },
    channel: {
      name: $release_channel,
      chain: {
        profile: $chain_profile,
        chain_id: $chain_id,
        genesis: {
          path: $genesis_path,
          sha256: $genesis_sha256,
          embedded_in_extension: $genesis_embedded
        }
      },
      compatibility: {
        protocore: {
          version: $protocore_version
        },
        monarch_desktop: {
          channel: $monarch_desktop_channel,
          min_version: $monarch_desktop_min_version,
          max_version: $monarch_desktop_max_version
        }
      },
      upgrade: {
        requires_same_channel: $upgrade_requires_same_channel,
        state_migration: {
          required: $state_migration_required,
          mode: $state_migration_mode,
          runbook_id: (if $state_migration_runbook_id == "" then null else $state_migration_runbook_id end),
          backup_required_before_migration: true,
          disaster_recovery_manifest_required: true,
          operator_approval_required: true
        },
        rollback: {
          supported: $rollback_supported,
          blocked_when_state_migration_one_way: true
        }
      }
    },
    sources: {
      monarch_os_talos: {
        commit: $repo_commit,
        dirty: $repo_dirty
      },
      mono_core: {
        commit: $mono_core_commit,
        dirty: $mono_core_dirty,
        protocore_version: $protocore_version
      },
      protocore_binary: {
        source: $protocore_source,
        path: $protocore_binary,
        sha256: $protocore_binary_sha256
      }
    },
    artifacts: .
  }' "$artifacts_file" > "$metadata_path"

(cd "$(dirname "$metadata_path")" && sha256sum "$(basename "$metadata_path")" > "$(basename "$metadata_path").sha256")
printf '%s\n' "$metadata_path"
