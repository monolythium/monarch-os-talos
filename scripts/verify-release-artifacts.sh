#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
KERNEL_BASELINE_FILE="${KERNEL_BASELINE_FILE:-"$ROOT_DIR/kernel-hardening-baseline.json"}"
REQUIRE_SIGNATURES="${REQUIRE_SIGNATURES:-false}"
REQUIRE_SMOKE_QEMU="${REQUIRE_SMOKE_QEMU:-false}"
REQUIRE_CHANNEL_METADATA="${REQUIRE_CHANNEL_METADATA:-false}"
REQUIRE_COMPLETE_ARTIFACT_SET="${REQUIRE_COMPLETE_ARTIFACT_SET:-false}"
REQUIRE_SUBSTRATE_PROOF="${REQUIRE_SUBSTRATE_PROOF:-false}"
REQUIRE_NETWORK_POLICY="${REQUIRE_NETWORK_POLICY:-false}"
REQUIRE_PROVISIONING_POLICY="${REQUIRE_PROVISIONING_POLICY:-false}"
REQUIRE_INCIDENT_RESPONSE_POLICY="${REQUIRE_INCIDENT_RESPONSE_POLICY:-false}"
REQUIRE_DISASTER_RECOVERY_POLICY="${REQUIRE_DISASTER_RECOVERY_POLICY:-false}"
REQUIRE_AUDIT_TRAIL_POLICY="${REQUIRE_AUDIT_TRAIL_POLICY:-false}"
REQUIRE_SMOKE_QEMU_CONFIG_APPLY="${REQUIRE_SMOKE_QEMU_CONFIG_APPLY:-false}"
REQUIRE_SMOKE_QEMU_SERVICE="${REQUIRE_SMOKE_QEMU_SERVICE:-false}"
REQUIRE_SMOKE_QEMU_RPC="${REQUIRE_SMOKE_QEMU_RPC:-false}"
REQUIRE_SMOKE_QEMU_TALOSCTL="${REQUIRE_SMOKE_QEMU_TALOSCTL:-false}"
REQUIRE_ENROLLMENT_RUNTIME_PROOF="${REQUIRE_ENROLLMENT_RUNTIME_PROOF:-false}"
REQUIRE_TPM_BINDING_RUNTIME_PROOF="${REQUIRE_TPM_BINDING_RUNTIME_PROOF:-false}"
REQUIRE_SUBSTRATE_RUNTIME_PROOF="${REQUIRE_SUBSTRATE_RUNTIME_PROOF:-false}"
REQUIRE_DM_VERITY_ACTIVE="${REQUIRE_DM_VERITY_ACTIVE:-false}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$KERNEL_BASELINE_FILE" = /* ]] || KERNEL_BASELINE_FILE="$ROOT_DIR/$KERNEL_BASELINE_FILE"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "release artifact verification failed: $*" >&2
  exit 1
}

need jq
need sha256sum
need tar

metadata_path="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"
[[ -f "$metadata_path" ]] || fail "missing release metadata: $metadata_path"

check_sha_file() {
  local file="$1"
  local sum_file="$file.sha256"
  [[ -f "$sum_file" ]] || fail "missing checksum: $sum_file"
  (cd "$(dirname "$file")" && sha256sum -c "$(basename "$sum_file")" >/dev/null) \
    || fail "checksum mismatch: $sum_file"
}

check_signature_files() {
  local file="$1"
  [[ -s "$file.sig" ]] || fail "missing signature: $file.sig"
  [[ -s "$file.pem" ]] || fail "missing signing certificate: $file.pem"
}

check_release_metadata_digest() {
  local digest source
  digest="$(jq -r '.sources.protocore_binary.sha256 // ""' "$metadata_path")"
  source="$(jq -r '.sources.protocore_binary.source // ""' "$metadata_path")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || fail "release metadata lacks concrete protocore binary sha256: $digest"
  [[ -n "$source" && "$source" != "unknown" ]] \
    || fail "release metadata lacks concrete protocore binary source"
}

extension_tar_from_metadata() {
  local extension_tar
  extension_tar="$(jq -r --arg arch "$ARCH" '
    .artifacts[].path
    | select(startswith("monarch-protocore-" + $arch + "-") and endswith(".tar"))
  ' "$metadata_path" | head -n 1)"
  [[ -n "$extension_tar" ]] || fail "metadata lacks protocore extension tar artifact"
  extension_tar="$OUT_DIR/$extension_tar"
  [[ -f "$extension_tar" ]] || fail "protocore extension tar is missing: $extension_tar"
  printf '%s\n' "$extension_tar"
}

check_smoke_qemu() {
  local result="$OUT_DIR/smoke-qemu/result.json"
  local serial_log="$OUT_DIR/smoke-qemu/serial.log"
  local talos_log="$OUT_DIR/smoke-qemu/talos-version.txt"
  local service_log="$OUT_DIR/smoke-qemu/ext-protocore-service.txt"
  local rpc_log="$OUT_DIR/smoke-qemu/protocore-rpc.txt"
  local enrollment_log="$OUT_DIR/smoke-qemu/enrollment-runtime.json"
  local substrate_log="$OUT_DIR/smoke-qemu/substrate-runtime.json"
  [[ -f "$result" ]] || fail "missing QEMU smoke result: $result"
  [[ -f "$serial_log" ]] || fail "missing QEMU serial log: $serial_log"
  [[ -f "$talos_log" ]] || fail "missing Talos API probe log: $talos_log"

  local status raw_image require_probe probe machine_config service_check rpc_probe enrollment_proof substrate_proof
  status="$(jq -r '.status // ""' "$result")"
  raw_image="$(jq -r '.raw_image // ""' "$result")"
  require_probe="$(jq -r '.require_talos_api_probe // ""' "$result")"
  probe="$(jq -r '.talos_api_probe // ""' "$result")"
  machine_config="$(jq -r '.machine_config_applied // "false"' "$result")"
  service_check="$(jq -r '.extension_service_check // "not_required"' "$result")"
  rpc_probe="$(jq -r '.protocore_rpc_probe // "not_required"' "$result")"
  enrollment_proof="$(jq -r '.enrollment_runtime_proof // "not_required"' "$result")"
  substrate_proof="$(jq -r '.substrate_runtime_proof // "not_required"' "$result")"

  [[ "$status" == "ok" ]] || fail "QEMU smoke status is not ok: $status"
  [[ "$raw_image" == "monarch-os-talos-$TALOS_VERSION-$ARCH.raw" ]] \
    || fail "QEMU smoke raw image mismatch: $raw_image"
  [[ "$require_probe" == "true" ]] \
    || fail "QEMU smoke did not require Talos API probe"
  case "$probe" in
    tcp_only|talosctl_ok|talosctl_secure_ok|post_apply_tcp_only) ;;
    *) fail "QEMU smoke Talos API probe did not succeed: $probe" ;;
  esac
  if [[ "$REQUIRE_SMOKE_QEMU_TALOSCTL" == "true" ]]; then
    case "$probe" in
      talosctl_ok|talosctl_secure_ok) ;;
      *) fail "QEMU smoke did not verify Talos API with talosctl: $probe" ;;
    esac
  fi

  if [[ "$REQUIRE_SMOKE_QEMU_CONFIG_APPLY" == "true" ]]; then
    [[ "$machine_config" == "true" ]] \
      || fail "QEMU smoke did not apply a Talos machine config"
    [[ -s "$OUT_DIR/smoke-qemu/apply-config.txt" ]] \
      || fail "QEMU smoke is missing apply-config log"
  fi
  if [[ "$REQUIRE_SMOKE_QEMU_SERVICE" == "true" ]]; then
    [[ "$service_check" == "ok" ]] \
      || fail "QEMU smoke did not verify ext-protocore service: $service_check"
    [[ -s "$service_log" ]] \
      || fail "QEMU smoke is missing ext-protocore service log"
  fi
  if [[ "$REQUIRE_SMOKE_QEMU_RPC" == "true" ]]; then
    [[ "$rpc_probe" == "ok" ]] \
      || fail "QEMU smoke did not verify Protocore RPC: $rpc_probe"
    [[ -s "$rpc_log" ]] \
      || fail "QEMU smoke is missing Protocore RPC log"
  fi
  if [[ "$REQUIRE_TPM_BINDING_RUNTIME_PROOF" == "true" ]]; then
    REQUIRE_ENROLLMENT_RUNTIME_PROOF=true
  fi
  if [[ "$REQUIRE_ENROLLMENT_RUNTIME_PROOF" == "true" ]]; then
    [[ "$enrollment_proof" == "ok" ]] \
      || fail "QEMU smoke did not verify enrollment runtime proof: $enrollment_proof"
    [[ -s "$enrollment_log" ]] \
      || fail "QEMU smoke is missing enrollment runtime proof log"
    jq -e '.status == "ok"' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof status is not ok"
    jq -e '.chain.role == "operator-signing"' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not verify operator-signing role"
    jq -e '.cluster.size == 10 and .cluster.threshold == 7 and .cluster.active_members == 7 and .cluster.standby_members == 3' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not verify 7-of-10 cluster shape"
    jq -e '.digest_match == true' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not match release digest"
    local metadata_digest proof_digest metadata_chain_id proof_chain_id
    metadata_digest="$(jq -r '.sources.protocore_binary.sha256 // ""' "$metadata_path")"
    proof_digest="$(jq -r '.expected_digest // ""' "$enrollment_log")"
    metadata_chain_id="$(jq -r '.channel.chain.chain_id // ""' "$metadata_path")"
    proof_chain_id="$(jq -r '.chain.chain_id // ""' "$enrollment_log")"
    [[ "$proof_digest" == "$metadata_digest" ]] \
      || fail "enrollment runtime proof digest does not match metadata"
    [[ "$proof_chain_id" == "$metadata_chain_id" ]] \
      || fail "enrollment runtime proof chain id does not match metadata"
    jq -e '.file_hashes | map(select(.path == "/var/lib/protocore/enrollment/protocore.sha256")) | length == 1' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof lacks expected digest file evidence"
  fi
  if [[ "$REQUIRE_TPM_BINDING_RUNTIME_PROOF" == "true" ]]; then
    jq -e '.tpm.required == true' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not require TPM binding"
    jq -e '.tpm.mode == "hardware-tpm2" or .tpm.mode == "vtpm-testnet"' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not verify TPM mode"
    jq -e '.tpm.pcrs | sort == [0, 2, 4, 7]' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof did not verify TPM PCR policy"
    jq -e '.file_hashes | map(.label) | index("tpm_quote") and index("tpm_event_log") and index("lythiumseal_operator_key") and index("dkg_transcript")' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof lacks TPM/DKG file evidence"
    jq -e '
      def norm: ascii_downcase | ltrimstr("0x");
      . as $root |
      (.tpm.quote_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.tpm.event_log_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.tpm.quote_nonce | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.tpm.pcr_policy_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.tpm.dkg_transcript_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.tpm.sealed_share_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and any($root.file_hashes[]; .label == "tpm_quote" and (.sha256 | norm) == ($root.tpm.quote_sha256 | norm))
      and any($root.file_hashes[]; .label == "tpm_event_log" and (.sha256 | norm) == ($root.tpm.event_log_sha256 | norm))
      and any($root.file_hashes[]; .label == "lythiumseal_operator_key" and (.sha256 | norm) == ($root.tpm.sealed_share_sha256 | norm))
      and any($root.file_hashes[]; .label == "dkg_transcript" and (.sha256 | norm) == ($root.tpm.dkg_transcript_sha256 | norm))
    ' "$enrollment_log" >/dev/null \
      || fail "enrollment runtime proof does not bind TPM/DKG file hashes to manifest claims"
  fi
  if [[ "$REQUIRE_SUBSTRATE_RUNTIME_PROOF" == "true" ]]; then
    [[ "$substrate_proof" == "ok" ]] \
      || fail "QEMU smoke did not verify runtime substrate proof: $substrate_proof"
    [[ -s "$substrate_log" ]] \
      || fail "QEMU smoke is missing runtime substrate proof log"
    jq -e '.status == "ok"' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof status is not ok"
    jq -e '.root_mount.read_only == true' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof did not verify read-only root mount"
    jq -e '.root_integrity.immutable_base_mount_present == true' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof did not verify an immutable base filesystem mount"
    jq -e '.root_integrity.dm_verity.kernel_support == true' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof did not verify dm-verity kernel support"
    jq -e '.kernel_config.required_enabled | to_entries | all(.value == true)' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof did not verify required kernel options enabled"
    jq -e '.kernel_config.required_disabled_or_absent | to_entries | all(.value == true)' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof did not verify required kernel options disabled"
    jq -e '.runtime_network.no_ssh_listener == true' "$substrate_log" >/dev/null \
      || fail "runtime substrate proof detected an SSH listener on TCP port 22"
    local metadata_baseline_path metadata_baseline_sha proof_baseline_sha proof_baseline_schema
    metadata_baseline_path="$(jq -r '.substrate.kernel_hardening_baseline.path // ""' "$metadata_path")"
    metadata_baseline_sha="$(jq -r '.substrate.kernel_hardening_baseline.sha256 // ""' "$metadata_path")"
    proof_baseline_sha="$(jq -r '.kernel_baseline.sha256 // ""' "$substrate_log")"
    proof_baseline_schema="$(jq -r '.kernel_baseline.schema // ""' "$substrate_log")"
    [[ "$proof_baseline_schema" == "monarch-os-kernel-hardening-baseline/v1" ]] \
      || fail "runtime substrate proof baseline schema mismatch: $proof_baseline_schema"
    [[ -n "$metadata_baseline_path" && -f "$ROOT_DIR/$metadata_baseline_path" ]] \
      || fail "metadata kernel hardening baseline is missing from checkout: $metadata_baseline_path"
    local actual_baseline_sha
    actual_baseline_sha="$(sha256sum "$ROOT_DIR/$metadata_baseline_path" | awk '{print $1}')"
    [[ "$actual_baseline_sha" == "$metadata_baseline_sha" ]] \
      || fail "metadata kernel hardening baseline sha256 mismatch"
    [[ "$proof_baseline_sha" == "$metadata_baseline_sha" ]] \
      || fail "runtime substrate proof baseline sha256 does not match metadata"
    local baseline_requires_active
    baseline_requires_active="$(jq -r '.rootfs.dm_verity_active_evidence_required // false' "$ROOT_DIR/$metadata_baseline_path")"
    if [[ "$REQUIRE_DM_VERITY_ACTIVE" == "true" || "$baseline_requires_active" == "true" ]]; then
      local expected_root_hashes_json
      expected_root_hashes_json="$(jq -c '
        [.substrate.dm_verity.expected_root_hashes[]?
          | ascii_downcase
          | sub("^sha256:"; "")
          | sub("^0x"; "")
        ]
      ' "$metadata_path")"
      jq -e 'length > 0 and all(.[]; test("^[0-9a-f]{64}([0-9a-f]{64})?$"))' <<<"$expected_root_hashes_json" >/dev/null \
        || fail "release metadata must pin expected dm-verity root hashes when active dm-verity is required"
      jq -e '.root_integrity.dm_verity.active_evidence == true' "$substrate_log" >/dev/null \
        || fail "runtime substrate proof did not verify active dm-verity evidence"
      jq -e '.root_integrity.dm_verity.root_hash_evidence == true' "$substrate_log" >/dev/null \
        || fail "runtime substrate proof did not capture dm-verity root-hash evidence"
      jq -e '.root_integrity.dm_verity.root_hashes | length > 0' "$substrate_log" >/dev/null \
        || fail "runtime substrate proof has no dm-verity root hashes"
      jq -e --argjson expected "$expected_root_hashes_json" '
        [.root_integrity.dm_verity.root_hashes[]?
          | ascii_downcase
          | sub("^sha256:"; "")
          | sub("^0x"; "")
        ] as $actual
        | any($expected[]; . as $hash | $actual | index($hash))
      ' "$substrate_log" >/dev/null \
        || fail "runtime substrate proof dm-verity root hashes do not match release metadata"
      jq -e '.root_mount.device | strings | length > 0' "$substrate_log" >/dev/null \
        || fail "runtime substrate proof lacks root device evidence"
    fi
  fi
}

check_channel_metadata() {
  local channel chain_profile chain_id genesis_path genesis_sha genesis_embedded desktop_channel desktop_min desktop_max protocore_version upgrade_same_channel migration_required migration_mode rollback_supported rollback_blocks_one_way
  channel="$(jq -r '.channel.name // ""' "$metadata_path")"
  chain_profile="$(jq -r '.channel.chain.profile // ""' "$metadata_path")"
  chain_id="$(jq -r '.channel.chain.chain_id // ""' "$metadata_path")"
  genesis_path="$(jq -r '.channel.chain.genesis.path // ""' "$metadata_path")"
  genesis_sha="$(jq -r '.channel.chain.genesis.sha256 // ""' "$metadata_path")"
  genesis_embedded="$(jq -r '.channel.chain.genesis.embedded_in_extension // ""' "$metadata_path")"
  desktop_channel="$(jq -r '.channel.compatibility.monarch_desktop.channel // ""' "$metadata_path")"
  desktop_min="$(jq -r '.channel.compatibility.monarch_desktop.min_version // ""' "$metadata_path")"
  desktop_max="$(jq -r '.channel.compatibility.monarch_desktop.max_version // ""' "$metadata_path")"
  protocore_version="$(jq -r '.channel.compatibility.protocore.version // ""' "$metadata_path")"
  upgrade_same_channel="$(jq -r '.channel.upgrade.requires_same_channel // ""' "$metadata_path")"
  migration_required="$(jq -r 'if ((.channel.upgrade.state_migration // {}) | has("required")) then .channel.upgrade.state_migration.required else "" end' "$metadata_path")"
  migration_mode="$(jq -r '.channel.upgrade.state_migration.mode // ""' "$metadata_path")"
  rollback_supported="$(jq -r 'if ((.channel.upgrade.rollback // {}) | has("supported")) then .channel.upgrade.rollback.supported else "" end' "$metadata_path")"
  rollback_blocks_one_way="$(jq -r 'if ((.channel.upgrade.rollback // {}) | has("blocked_when_state_migration_one_way")) then .channel.upgrade.rollback.blocked_when_state_migration_one_way else "" end' "$metadata_path")"

  case "$channel" in
    dev|testnet|mainnet) ;;
    *) fail "release channel must be dev, testnet, or mainnet: $channel" ;;
  esac
  [[ -n "$chain_profile" ]] || fail "channel metadata lacks chain profile"
  [[ "$chain_id" =~ ^[0-9]+$ ]] || fail "channel metadata chain_id is not numeric: $chain_id"
  [[ -n "$genesis_path" && "$genesis_path" != "none" ]] || fail "channel metadata lacks genesis path"
  [[ "$genesis_sha" =~ ^[0-9a-f]{64}$ ]] || fail "channel metadata genesis sha256 is invalid: $genesis_sha"
  [[ "$genesis_embedded" == "true" ]] || fail "channel metadata genesis is not marked embedded"
  [[ -n "$desktop_channel" ]] || fail "channel metadata lacks Monarch Desktop channel"
  [[ -n "$desktop_min" ]] || fail "channel metadata lacks Monarch Desktop minimum version"
  [[ -n "$desktop_max" ]] || fail "channel metadata lacks Monarch Desktop maximum version"
  [[ -n "$protocore_version" && "$protocore_version" != "unknown" ]] \
    || fail "channel metadata lacks concrete protocore version"
  [[ "$upgrade_same_channel" == "true" ]] \
    || fail "channel metadata must require same-channel upgrades"
  [[ "$migration_required" == "true" || "$migration_required" == "false" ]] \
    || fail "channel metadata must declare state migration required flag"
  case "$migration_mode" in
    none|backward-compatible|one-way) ;;
    *) fail "channel metadata has invalid state migration mode: $migration_mode" ;;
  esac
  if [[ "$migration_required" == "false" ]]; then
    [[ "$migration_mode" == "none" ]] \
      || fail "channel metadata state migration mode must be none when migration is not required"
  else
    [[ "$migration_mode" != "none" ]] \
      || fail "channel metadata migration required cannot use mode=none"
    [[ "$(jq -r '.channel.upgrade.state_migration.runbook_id // ""' "$metadata_path")" != "" ]] \
      || fail "channel metadata migration required must include a runbook id"
  fi
  jq -e '
    .channel.upgrade.state_migration.backup_required_before_migration == true
    and .channel.upgrade.state_migration.disaster_recovery_manifest_required == true
    and .channel.upgrade.state_migration.operator_approval_required == true
  ' "$metadata_path" >/dev/null || fail "channel metadata migration policy must require backup, DR manifest, and operator approval"
  [[ "$rollback_supported" == "true" || "$rollback_supported" == "false" ]] \
    || fail "channel metadata must declare rollback support"
  [[ "$rollback_blocks_one_way" == "true" ]] \
    || fail "channel metadata must block rollback on one-way migrations"

  local genesis_file="$ROOT_DIR/$genesis_path"
  [[ -f "$genesis_file" ]] || fail "metadata genesis file is missing from checkout: $genesis_path"
  local actual_genesis_sha
  actual_genesis_sha="$(sha256sum "$genesis_file" | awk '{print $1}')"
  [[ "$actual_genesis_sha" == "$genesis_sha" ]] \
    || fail "metadata genesis sha256 mismatch for: $genesis_path"

  local extension_tar
  extension_tar="$(extension_tar_from_metadata)"

  local extension_genesis="rootfs/usr/local/lib/containers/protocore/defaults/$chain_profile/genesis.toml"
  local extension_service="rootfs/usr/local/etc/containers/protocore.yaml"
  local extension_genesis_sha
  extension_genesis_sha="$(tar -xOf "$extension_tar" "$extension_genesis" 2>/dev/null | sha256sum | awk '{print $1}')" \
    || fail "protocore extension tar lacks staged genesis: $extension_genesis"
  [[ "$extension_genesis_sha" == "$genesis_sha" ]] \
    || fail "protocore extension staged genesis sha256 mismatch"

  tar -xOf "$extension_tar" "$extension_service" 2>/dev/null \
    | grep -Fx "    - PROTOCORE_NETWORK=$chain_profile" >/dev/null \
    || fail "protocore service config does not pin network profile: $chain_profile"
  tar -xOf "$extension_tar" "$extension_service" 2>/dev/null \
    | grep -Fx "    - PROTOCORE_CHAIN_ID=$chain_id" >/dev/null \
    || fail "protocore service config does not pin chain id: $chain_id"
  tar -xOf "$extension_tar" "$extension_service" 2>/dev/null \
    | grep -Fx "    - PROTOCORE_GENESIS_TOML=./defaults/$chain_profile/genesis.toml" >/dev/null \
    || fail "protocore service config does not pin channel genesis path"
}

check_substrate_proof() {
  local base control no_ssh no_package_manager no_shell entrypoint mount_count mount0 baseline_path baseline_sha baseline_schema
  base="$(jq -r '.substrate.base // ""' "$metadata_path")"
  control="$(jq -r '.substrate.control_plane // ""' "$metadata_path")"
  no_ssh="$(jq -r '.substrate.no_ssh_server // ""' "$metadata_path")"
  no_package_manager="$(jq -r '.substrate.no_package_manager // ""' "$metadata_path")"
  no_shell="$(jq -r '.substrate.no_interactive_shell // ""' "$metadata_path")"
  entrypoint="$(jq -r '.substrate.extension_policy.entrypoint // ""' "$metadata_path")"
  mount_count="$(jq -r '.substrate.extension_policy.allowed_writable_mounts | length // 0' "$metadata_path")"
  mount0="$(jq -r '.substrate.extension_policy.allowed_writable_mounts[0] // ""' "$metadata_path")"
  baseline_path="$(jq -r '.substrate.kernel_hardening_baseline.path // ""' "$metadata_path")"
  baseline_sha="$(jq -r '.substrate.kernel_hardening_baseline.sha256 // ""' "$metadata_path")"
  baseline_schema="$(jq -r '.substrate.kernel_hardening_baseline.schema // ""' "$metadata_path")"

  [[ "$base" == "talos" ]] || fail "substrate metadata base is not talos: $base"
  [[ "$control" == "talos_api_mtls" ]] || fail "substrate metadata control plane is not Talos API mTLS: $control"
  [[ "$no_ssh" == "true" ]] || fail "substrate metadata does not declare no SSH server"
  [[ "$no_package_manager" == "true" ]] || fail "substrate metadata does not declare no package manager"
  [[ "$no_shell" == "true" ]] || fail "substrate metadata does not declare no interactive shell"
  [[ "$entrypoint" == "./protocore-entrypoint" ]] || fail "substrate metadata entrypoint mismatch: $entrypoint"
  [[ "$mount_count" == "1" && "$mount0" == "/var/lib/protocore" ]] \
    || fail "substrate metadata writable mounts must be exactly /var/lib/protocore"
  [[ "$baseline_schema" == "monarch-os-kernel-hardening-baseline/v1" ]] \
    || fail "substrate metadata kernel hardening baseline schema mismatch: $baseline_schema"
  [[ -n "$baseline_path" && -f "$ROOT_DIR/$baseline_path" ]] \
    || fail "substrate metadata kernel hardening baseline missing from checkout: $baseline_path"
  local actual_baseline_sha
  actual_baseline_sha="$(sha256sum "$ROOT_DIR/$baseline_path" | awk '{print $1}')"
  [[ "$actual_baseline_sha" == "$baseline_sha" ]] \
    || fail "substrate metadata kernel hardening baseline sha256 mismatch"
  jq -e '.schema_version == "monarch-os-kernel-hardening-baseline/v1"' "$ROOT_DIR/$baseline_path" >/dev/null \
    || fail "kernel hardening baseline file has unsupported schema"
  jq -e --arg talos "$TALOS_VERSION" --arg arch "$ARCH" '.talos_version == $talos and .arch == $arch' "$ROOT_DIR/$baseline_path" >/dev/null \
    || fail "kernel hardening baseline does not match Talos version/arch"

  local extension_tar service_config members_file
  extension_tar="$(extension_tar_from_metadata)"
  members_file="$(mktemp)"
  tar -tf "$extension_tar" > "$members_file"

  grep -Fx "manifest.yaml" "$members_file" >/dev/null \
    || fail "protocore extension lacks manifest.yaml"
  grep -Fx "rootfs/usr/local/lib/containers/protocore/protocore" "$members_file" >/dev/null \
    || fail "protocore extension lacks protocore binary"
  grep -Fx "rootfs/usr/local/lib/containers/protocore/protocore-entrypoint" "$members_file" >/dev/null \
    || fail "protocore extension lacks static entrypoint"
  grep -Fx "rootfs/usr/local/etc/containers/protocore.yaml" "$members_file" >/dev/null \
    || fail "protocore extension lacks Talos service config"

  if grep -E '(^|/)(bin|sbin|usr/bin|usr/sbin)/(sh|bash|dash|ash|zsh|fish|ssh|sshd|scp|sftp|apt|apt-get|dpkg|apk|yum|dnf|rpm|pacman)(/|$)' "$members_file" >/dev/null; then
    fail "protocore extension contains shell, SSH, or package-manager executable"
  fi
  if grep -E '(^|/)etc/ssh(/|$)|(^|/)usr/lib/ssh(/|$)|(^|/)var/lib/(dpkg|rpm|pacman)(/|$)|(^|/)lib/apk(/|$)' "$members_file" >/dev/null; then
    fail "protocore extension contains SSH or package-manager state directories"
  fi

  service_config="$(tar -xOf "$extension_tar" rootfs/usr/local/etc/containers/protocore.yaml 2>/dev/null)" \
    || fail "failed to read protocore service config from extension"
  grep -Fx "  entrypoint: ./protocore-entrypoint" <<<"$service_config" >/dev/null \
    || fail "protocore service entrypoint is not ./protocore-entrypoint"
  grep -Fx "    - source: /var/lib/protocore" <<<"$service_config" >/dev/null \
    || fail "protocore service writable source is not /var/lib/protocore"
  grep -Fx "      destination: /var/lib/protocore" <<<"$service_config" >/dev/null \
    || fail "protocore service writable destination is not /var/lib/protocore"
  grep -Fx "      type: bind" <<<"$service_config" >/dev/null \
    || fail "protocore service does not use an explicit bind mount"
  grep -Fx "        - rw" <<<"$service_config" >/dev/null \
    || fail "protocore service writable mount is not explicit"
  if grep -E '(^|[[:space:]])(/bin/sh|/bin/bash|sh -c|bash -c|sshd|ssh |apt |apt-get |apk |yum |dnf |pacman )' <<<"$service_config" >/dev/null; then
    fail "protocore service config invokes shell, SSH, or package manager"
  fi

  rm -f "$members_file"
}

check_network_policy() {
  local talos_port rpc_listen rpc_port p2p_listen p2p_port discovery
  talos_port="$(jq -r '.network_policy.talos_api.port // ""' "$metadata_path")"
  rpc_listen="$(jq -r '.network_policy.protocore_rpc.listen // ""' "$metadata_path")"
  rpc_port="$(jq -r '.network_policy.protocore_rpc.port // ""' "$metadata_path")"
  p2p_listen="$(jq -r '.network_policy.protocore_p2p.listen // ""' "$metadata_path")"
  p2p_port="$(jq -r '.network_policy.protocore_p2p.port // ""' "$metadata_path")"
  discovery="$(jq -r '.network_policy.protocore_p2p.discovery // ""' "$metadata_path")"

  [[ "$talos_port" == "50000" ]] || fail "network policy Talos API port must be 50000: $talos_port"
  [[ "$rpc_listen" == "0.0.0.0:8545" ]] || fail "network policy RPC listen must be 0.0.0.0:8545: $rpc_listen"
  [[ "$rpc_port" == "8545" ]] || fail "network policy RPC port must be 8545: $rpc_port"
  [[ "$p2p_listen" == "/ip4/0.0.0.0/tcp/29898" ]] || fail "network policy P2P listen mismatch: $p2p_listen"
  [[ "$p2p_port" == "29898" ]] || fail "network policy P2P port must be 29898: $p2p_port"
  [[ "$discovery" == "hybrid" ]] || fail "network policy discovery must be hybrid: $discovery"

  local extension_tar service_config
  extension_tar="$(extension_tar_from_metadata)"
  service_config="$(tar -xOf "$extension_tar" rootfs/usr/local/etc/containers/protocore.yaml 2>/dev/null)" \
    || fail "failed to read protocore service config from extension"
  grep -Fx "    - PROTOCORE_RPC_LISTEN=$rpc_listen" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin RPC listen: $rpc_listen"
  grep -Fx "    - PROTOCORE_P2P_LISTEN=$p2p_listen" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin P2P listen: $p2p_listen"
  grep -Fx "    - PROTOCORE_DISCOVERY=$discovery" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin discovery mode: $discovery"
  if grep -E '(^|[[:space:]])(22|:22|0\.0\.0\.0:22|sshd|ssh )' <<<"$service_config" >/dev/null; then
    fail "protocore service config exposes SSH or port 22"
  fi
}

check_provisioning_policy() {
  local no_default inline_prohibited enrollment_required enrollment_path enrollment_schema enrollment_schema_path enrollment_validator enrollment_hashes_required enrollment_payload_schema enrollment_payload_canonicalization enrollment_payload_hash enrollment_payload_validator enrollment_on_chain_required enrollment_call_binding_required enrollment_payload_binding_required registration_method registration_signature registration_selector attestation_binding digest_env digest_file_env digest_file_path tpm_required tpm_env tpm_quote_env tpm_quote_path tpm_event_log_env tpm_event_log_path tpm_sealed_env tpm_sealed_path tpm_quote_validator tpm_quote_tool tpm_quote_hardware_required tpm_quote_mainnet_required dkg_env dkg_path lifecycle_schema lifecycle_schema_path lifecycle_validator lifecycle_cluster_size lifecycle_threshold lifecycle_approval_threshold lifecycle_mainnet lifecycle_hardware_tpm lifecycle_tpm_binding lifecycle_payload_schema lifecycle_payload_canonicalization lifecycle_payload_hash lifecycle_payload_validator lifecycle_payload_ceremony_method lifecycle_payload_ceremony_selector lifecycle_payload_attestation_method lifecycle_payload_attestation_selector lifecycle_on_chain
  no_default="$(jq -r '.provisioning_policy.no_default_secrets // ""' "$metadata_path")"
  inline_prohibited="$(jq -r '.provisioning_policy.inline_secret_env_prohibited // ""' "$metadata_path")"
  enrollment_required="$(jq -r '.provisioning_policy.enrollment.required' "$metadata_path")"
  enrollment_path="$(jq -r '.provisioning_policy.enrollment.manifest_path // ""' "$metadata_path")"
  enrollment_schema="$(jq -r '.provisioning_policy.enrollment.schema // ""' "$metadata_path")"
  enrollment_schema_path="$(jq -r '.provisioning_policy.enrollment.schema_path // ""' "$metadata_path")"
  enrollment_validator="$(jq -r '.provisioning_policy.enrollment.validator // ""' "$metadata_path")"
  enrollment_hashes_required="$(jq -r '.provisioning_policy.enrollment.attestation_evidence_hashes_required // false' "$metadata_path")"
  enrollment_payload_schema="$(jq -r '.provisioning_policy.enrollment.attestation_payload.schema // ""' "$metadata_path")"
  enrollment_payload_canonicalization="$(jq -r '.provisioning_policy.enrollment.attestation_payload.canonicalization // ""' "$metadata_path")"
  enrollment_payload_hash="$(jq -r '.provisioning_policy.enrollment.attestation_payload.hash // ""' "$metadata_path")"
  enrollment_payload_validator="$(jq -r '.provisioning_policy.enrollment.attestation_payload.validator // ""' "$metadata_path")"
  enrollment_on_chain_required="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_required_for_mainnet_operator_signing // false' "$metadata_path")"
  enrollment_call_binding_required="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_call_binding_required_for_mainnet // false' "$metadata_path")"
  enrollment_payload_binding_required="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_attestation_payload_binding_required_for_mainnet // false' "$metadata_path")"
  registration_method="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_methods.registration // ""' "$metadata_path")"
  registration_signature="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_methods.registration_signature // ""' "$metadata_path")"
  registration_selector="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_methods.registration_selector // ""' "$metadata_path")"
  attestation_binding="$(jq -r '.provisioning_policy.enrollment.on_chain_registration_methods.attestation_binding // ""' "$metadata_path")"
  digest_env="$(jq -r '.provisioning_policy.release_digest.env // ""' "$metadata_path")"
  digest_file_env="$(jq -r '.provisioning_policy.release_digest.file_env // ""' "$metadata_path")"
  digest_file_path="$(jq -r '.provisioning_policy.release_digest.file_path // ""' "$metadata_path")"
  tpm_required="$(jq -r '.provisioning_policy.tpm_binding.required // false' "$metadata_path")"
  tpm_env="$(jq -r '.provisioning_policy.tpm_binding.env // ""' "$metadata_path")"
  tpm_quote_env="$(jq -r '.provisioning_policy.tpm_binding.quote_file_env // ""' "$metadata_path")"
  tpm_quote_path="$(jq -r '.provisioning_policy.tpm_binding.quote_file_path // ""' "$metadata_path")"
  tpm_event_log_env="$(jq -r '.provisioning_policy.tpm_binding.event_log_file_env // ""' "$metadata_path")"
  tpm_event_log_path="$(jq -r '.provisioning_policy.tpm_binding.event_log_file_path // ""' "$metadata_path")"
  tpm_sealed_env="$(jq -r '.provisioning_policy.tpm_binding.sealed_bls_share_file_env // ""' "$metadata_path")"
  tpm_sealed_path="$(jq -r '.provisioning_policy.tpm_binding.sealed_bls_share_file_path // ""' "$metadata_path")"
  local lythiumseal_env lythiumseal_path lythiumseal_ek_path lythiumseal_generate lythiumseal_index lythiumseal_epoch
  lythiumseal_env="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_key_file_env // ""' "$metadata_path")"
  lythiumseal_path="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_key_file_path // ""' "$metadata_path")"
  lythiumseal_ek_path="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_encapsulation_key_file_path // ""' "$metadata_path")"
  lythiumseal_generate="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.generate_value // ""' "$metadata_path")"
  lythiumseal_index="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.operator_index // ""' "$metadata_path")"
  lythiumseal_epoch="$(jq -r '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.epoch // ""' "$metadata_path")"
  dkg_env="$(jq -r '.provisioning_policy.tpm_binding.dkg_transcript_file_env // ""' "$metadata_path")"
  dkg_path="$(jq -r '.provisioning_policy.tpm_binding.dkg_transcript_file_path // ""' "$metadata_path")"
  tpm_quote_validator="$(jq -r '.provisioning_policy.tpm_binding.quote_verification.validator // ""' "$metadata_path")"
  tpm_quote_tool="$(jq -r '.provisioning_policy.tpm_binding.quote_verification.tool // ""' "$metadata_path")"
  tpm_quote_hardware_required="$(jq -r '.provisioning_policy.tpm_binding.quote_verification.required_for_hardware_tpm // false' "$metadata_path")"
  tpm_quote_mainnet_required="$(jq -r '.provisioning_policy.tpm_binding.quote_verification.required_for_mainnet_operator_signing // false' "$metadata_path")"
  tpm_sealing_schema="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.schema // ""' "$metadata_path")"
  tpm_sealing_schema_path="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.schema_path // ""' "$metadata_path")"
  tpm_sealing_validator="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.validator // ""' "$metadata_path")"
  tpm_sealing_required="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.required_for_operator_signing // false' "$metadata_path")"
  tpm_sealing_mainnet_required="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.required_for_mainnet_operator_signing // false' "$metadata_path")"
  tpm_sealing_hardware_required="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.requires_hardware_tpm_on_mainnet // false' "$metadata_path")"
  tpm_sealing_payload_schema="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.signed_payload_schema // ""' "$metadata_path")"
  tpm_sealing_canonicalization="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.canonicalization // ""' "$metadata_path")"
  tpm_sealing_hash="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.hash // ""' "$metadata_path")"
  tpm_sealing_binds_ceremony="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.binds_key_share_ceremony // false' "$metadata_path")"
  tpm_sealing_binds_enrollment="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.binds_enrollment_manifest // false' "$metadata_path")"
  tpm_sealing_quote_hashes="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.verifies_tpm_quote_event_log_hashes // false' "$metadata_path")"
  tpm_sealing_policy_binding="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.verifies_policy_digest_binding // false' "$metadata_path")"
  tpm_sealing_unseal_binding="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.verifies_unseal_plaintext_hash_binding // false' "$metadata_path")"
  tpm_sealing_share_hash="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.verifies_sealed_share_file_hash // false' "$metadata_path")"
  tpm_sealing_object_blobs="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.verifies_tpm2_object_blobs // false' "$metadata_path")"
  tpm_sealing_local_env="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.local_file_hash_verification_env // ""' "$metadata_path")"
  tpm_sealing_local_toggle_env="$(jq -r '.provisioning_policy.tpm_binding.sealing_evidence.local_file_hash_verification_toggle_env // ""' "$metadata_path")"
  lifecycle_schema="$(jq -r '.provisioning_policy.key_share_lifecycle.schema // ""' "$metadata_path")"
  lifecycle_schema_path="$(jq -r '.provisioning_policy.key_share_lifecycle.schema_path // ""' "$metadata_path")"
  lifecycle_validator="$(jq -r '.provisioning_policy.key_share_lifecycle.validator // ""' "$metadata_path")"
  lifecycle_cluster_size="$(jq -r '.provisioning_policy.key_share_lifecycle.cluster_size // 0' "$metadata_path")"
  lifecycle_threshold="$(jq -r '.provisioning_policy.key_share_lifecycle.threshold // 0' "$metadata_path")"
  lifecycle_approval_threshold="$(jq -r '.provisioning_policy.key_share_lifecycle.approval_threshold // 0' "$metadata_path")"
  lifecycle_mainnet="$(jq -r '.provisioning_policy.key_share_lifecycle.required_for_mainnet_operator_signing // false' "$metadata_path")"
  lifecycle_hardware_tpm="$(jq -r '.provisioning_policy.key_share_lifecycle.requires_hardware_tpm_on_mainnet // false' "$metadata_path")"
  lifecycle_tpm_binding="$(jq -r '.provisioning_policy.key_share_lifecycle.requires_tpm_evidence_hash_binding // false' "$metadata_path")"
  lifecycle_local_env="$(jq -r '.provisioning_policy.key_share_lifecycle.local_file_hash_verification_env // ""' "$metadata_path")"
  lifecycle_local_toggle_env="$(jq -r '.provisioning_policy.key_share_lifecycle.local_file_hash_verification_toggle_env // ""' "$metadata_path")"
  lifecycle_verifies_dkg_file="$(jq -r '.provisioning_policy.key_share_lifecycle.verifies_dkg_transcript_file // false' "$metadata_path")"
  lifecycle_verifies_all_share_files="$(jq -r '.provisioning_policy.key_share_lifecycle.verifies_all_sealed_share_output_files // false' "$metadata_path")"
  lifecycle_payload_schema="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.schema // ""' "$metadata_path")"
  lifecycle_payload_canonicalization="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.canonicalization // ""' "$metadata_path")"
  lifecycle_payload_hash="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.hash // ""' "$metadata_path")"
  lifecycle_payload_validator="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.validator // ""' "$metadata_path")"
  lifecycle_payload_ceremony_method="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.methods.ceremony // ""' "$metadata_path")"
  lifecycle_payload_ceremony_selector="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.methods.ceremony_selector // ""' "$metadata_path")"
  lifecycle_payload_attestation_method="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.methods.attestation // ""' "$metadata_path")"
  lifecycle_payload_attestation_selector="$(jq -r '.provisioning_policy.key_share_lifecycle.on_chain_lifecycle_payload.methods.attestation_selector // ""' "$metadata_path")"
  lifecycle_on_chain="$(jq -r '.provisioning_policy.key_share_lifecycle.requires_on_chain_lifecycle_on_mainnet // false' "$metadata_path")"
  local handoff_schema handoff_schema_path handoff_renderer handoff_validator handoff_source_schema handoff_required handoff_ceremony_sha handoff_roster_binding handoff_share_binding handoff_transcript_binding handoff_local_env handoff_local_toggle_env handoff_sealed_path handoff_dkg_path
  handoff_schema="$(jq -r '.provisioning_policy.key_share_handoff.schema // ""' "$metadata_path")"
  handoff_schema_path="$(jq -r '.provisioning_policy.key_share_handoff.schema_path // ""' "$metadata_path")"
  handoff_renderer="$(jq -r '.provisioning_policy.key_share_handoff.renderer // ""' "$metadata_path")"
  handoff_validator="$(jq -r '.provisioning_policy.key_share_handoff.validator // ""' "$metadata_path")"
  handoff_source_schema="$(jq -r '.provisioning_policy.key_share_handoff.source_schema // ""' "$metadata_path")"
  handoff_required="$(jq -r '.provisioning_policy.key_share_handoff.required_for_operator_signing_import // false' "$metadata_path")"
  handoff_ceremony_sha="$(jq -r '.provisioning_policy.key_share_handoff.ceremony_manifest_sha256_required // false' "$metadata_path")"
  handoff_roster_binding="$(jq -r '.provisioning_policy.key_share_handoff.verifies_operator_roster_binding // false' "$metadata_path")"
  handoff_share_binding="$(jq -r '.provisioning_policy.key_share_handoff.verifies_tpm_sealed_share_hash_binding // false' "$metadata_path")"
  handoff_transcript_binding="$(jq -r '.provisioning_policy.key_share_handoff.verifies_dkg_transcript_hash_binding // false' "$metadata_path")"
  handoff_local_env="$(jq -r '.provisioning_policy.key_share_handoff.local_file_hash_verification_env // ""' "$metadata_path")"
  handoff_local_toggle_env="$(jq -r '.provisioning_policy.key_share_handoff.local_file_hash_verification_toggle_env // ""' "$metadata_path")"
  handoff_sealed_path="$(jq -r '.provisioning_policy.key_share_handoff.import_paths.sealed_share_file // ""' "$metadata_path")"
  handoff_dkg_path="$(jq -r '.provisioning_policy.key_share_handoff.import_paths.dkg_transcript_file // ""' "$metadata_path")"

  [[ "$no_default" == "true" ]] || fail "provisioning policy must declare no default secrets"
  [[ "$inline_prohibited" == "true" ]] || fail "provisioning policy must prohibit inline secret env"
  [[ "$enrollment_required" == "true" || "$enrollment_required" == "false" ]] \
    || fail "provisioning policy enrollment.required must be boolean"
  [[ "$enrollment_path" == "/var/lib/protocore/enrollment/enrollment.json" ]] \
    || fail "provisioning policy enrollment manifest path mismatch: $enrollment_path"
  [[ "$enrollment_schema" == "monarch-protocore-enrollment/v1" ]] \
    || fail "provisioning policy enrollment schema mismatch: $enrollment_schema"
  [[ "$enrollment_schema_path" == "schemas/protocore-enrollment-manifest.schema.json" ]] \
    || fail "provisioning policy enrollment schema path mismatch: $enrollment_schema_path"
  [[ -f "$ROOT_DIR/$enrollment_schema_path" ]] \
    || fail "enrollment schema file is missing: $enrollment_schema_path"
  [[ "$enrollment_validator" == "scripts/validate-enrollment-manifest.sh" ]] \
    || fail "provisioning policy enrollment validator mismatch: $enrollment_validator"
  [[ -x "$ROOT_DIR/$enrollment_validator" ]] \
    || fail "enrollment validator is missing or not executable: $enrollment_validator"
  [[ "$enrollment_hashes_required" == "true" ]] \
    || fail "provisioning policy must require enrollment attestation evidence hashes"
  [[ "$enrollment_payload_schema" == "monarch-protocore-operator-attestation-payload/v1" ]] \
    || fail "provisioning policy enrollment attestation payload schema mismatch: $enrollment_payload_schema"
  [[ "$enrollment_payload_canonicalization" == "jq-canonical-sorted-json/v1" && "$enrollment_payload_hash" == "sha256" ]] \
    || fail "provisioning policy enrollment attestation payload hash/canonicalization mismatch"
  [[ "$enrollment_payload_validator" == "scripts/validate-enrollment-manifest.sh" ]] \
    || fail "provisioning policy enrollment attestation payload validator mismatch: $enrollment_payload_validator"
  [[ "$enrollment_on_chain_required" == "true" && "$enrollment_call_binding_required" == "true" && "$enrollment_payload_binding_required" == "true" ]] \
    || fail "provisioning policy must require mainnet enrollment on-chain call and attestation payload bindings"
  [[ "$registration_method" == "register" ]] \
    || fail "provisioning policy enrollment registration method mismatch: $registration_method"
  [[ "$registration_signature" == "register(bytes32,string,bytes32,uint32,uint32,bytes,bytes,bytes)" ]] \
    || fail "provisioning policy enrollment registration signature mismatch"
  [[ "$registration_selector" == "0xf4896df2" ]] \
    || fail "provisioning policy enrollment registration selector mismatch: $registration_selector"
  [[ "$attestation_binding" == "embedded_in_register" ]] \
    || fail "provisioning policy enrollment attestation binding mismatch: $attestation_binding"
  [[ "$digest_env" == "PROTOCORE_EXPECTED_DIGEST" ]] \
    || fail "provisioning policy digest env mismatch: $digest_env"
  [[ "$digest_file_env" == "PROTOCORE_EXPECTED_DIGEST_FILE" ]] \
    || fail "provisioning policy digest file env mismatch: $digest_file_env"
  if [[ "$enrollment_required" == "true" ]]; then
    [[ "$digest_file_path" == "/var/lib/protocore/enrollment/protocore.sha256" ]] \
      || fail "provisioning policy digest file path mismatch: $digest_file_path"
  fi
  [[ "$tpm_required" == "true" || "$tpm_required" == "false" ]] \
    || fail "provisioning policy TPM binding required must be boolean"
  [[ "$tpm_env" == "PROTOCORE_REQUIRE_TPM_BINDING" ]] \
    || fail "provisioning policy TPM binding env mismatch: $tpm_env"
  [[ "$tpm_quote_env" == "PROTOCORE_TPM_QUOTE_FILE" ]] \
    || fail "provisioning policy TPM quote file env mismatch: $tpm_quote_env"
  if [[ "$tpm_required" == "true" ]]; then
    [[ "$tpm_quote_path" == "/var/lib/protocore/attestation/quote.bin" ]] \
      || fail "provisioning policy TPM quote file path mismatch: $tpm_quote_path"
  fi
  [[ "$tpm_event_log_env" == "PROTOCORE_TPM_EVENT_LOG_FILE" ]] \
    || fail "provisioning policy TPM event log file env mismatch: $tpm_event_log_env"
  if [[ "$tpm_required" == "true" ]]; then
    [[ "$tpm_event_log_path" == "/var/lib/protocore/attestation/eventlog.bin" ]] \
      || fail "provisioning policy TPM event-log file path mismatch: $tpm_event_log_path"
  fi
  [[ "$tpm_sealed_env" == "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" ]] \
    || fail "provisioning policy TPM sealed BLS share file env mismatch: $tpm_sealed_env"
  if [[ "$tpm_required" == "true" ]]; then
    [[ "$tpm_sealed_path" == "$lythiumseal_path" ]] \
      || fail "provisioning policy TPM sealed share alias must match LythiumSeal key path: sealed=$tpm_sealed_path lythiumseal=$lythiumseal_path"
  fi
  [[ "$lythiumseal_env" == "PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" ]] \
    || fail "provisioning policy LythiumSeal operator key env mismatch: $lythiumseal_env"
  [[ "$lythiumseal_ek_path" == "/var/lib/protocore/operator/threshold/lythiumseal-operator-key.ek" ]] \
    || fail "provisioning policy LythiumSeal operator EK path mismatch: $lythiumseal_ek_path"
  if [[ "$tpm_required" == "true" ]]; then
    [[ "$lythiumseal_path" == "/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc" ]] \
      || fail "provisioning policy LythiumSeal operator key path mismatch: $lythiumseal_path"
  fi
  [[ "$dkg_env" == "PROTOCORE_DKG_TRANSCRIPT_FILE" ]] \
    || fail "provisioning policy DKG transcript file env mismatch: $dkg_env"
  if [[ "$tpm_required" == "true" ]]; then
    [[ "$dkg_path" == "/var/lib/protocore/secrets/dkg-transcript.json" ]] \
      || fail "provisioning policy DKG transcript file path mismatch: $dkg_path"
  fi
  [[ "$tpm_quote_validator" == "scripts/validate-tpm-attestation-evidence.sh" ]] \
    || fail "TPM quote verification validator mismatch: $tpm_quote_validator"
  [[ -x "$ROOT_DIR/$tpm_quote_validator" ]] \
    || fail "TPM quote verification validator is missing or not executable: $tpm_quote_validator"
  [[ "$tpm_quote_tool" == "tpm2_checkquote" ]] \
    || fail "TPM quote verification tool mismatch: $tpm_quote_tool"
  [[ "$tpm_quote_hardware_required" == "true" && "$tpm_quote_mainnet_required" == "true" ]] \
    || fail "TPM quote verification must be required for hardware TPM and mainnet operator-signing"
  [[ "$tpm_sealing_schema" == "monarch-protocore-tpm-sealing-evidence/v1" ]] \
    || fail "TPM sealing evidence schema mismatch: $tpm_sealing_schema"
  [[ "$tpm_sealing_schema_path" == "schemas/protocore-tpm-sealing-evidence.schema.json" ]] \
    || fail "TPM sealing evidence schema path mismatch: $tpm_sealing_schema_path"
  [[ -f "$ROOT_DIR/$tpm_sealing_schema_path" ]] \
    || fail "TPM sealing evidence schema file is missing: $tpm_sealing_schema_path"
  [[ "$tpm_sealing_validator" == "scripts/validate-tpm-sealing-evidence.sh" ]] \
    || fail "TPM sealing evidence validator mismatch: $tpm_sealing_validator"
  [[ -x "$ROOT_DIR/$tpm_sealing_validator" ]] \
    || fail "TPM sealing evidence validator is missing or not executable: $tpm_sealing_validator"
  [[ "$tpm_sealing_required" == "true" && "$tpm_sealing_mainnet_required" == "true" && "$tpm_sealing_hardware_required" == "true" ]] \
    || fail "TPM sealing evidence must be required for operator-signing and mainnet hardware TPM"
  [[ "$tpm_sealing_payload_schema" == "monarch-protocore-tpm-sealing-payload/v1" ]] \
    || fail "TPM sealing evidence payload schema mismatch: $tpm_sealing_payload_schema"
  [[ "$tpm_sealing_canonicalization" == "jq-canonical-sorted-json/v1" && "$tpm_sealing_hash" == "sha256" ]] \
    || fail "TPM sealing evidence payload hash/canonicalization mismatch"
  [[ "$tpm_sealing_binds_ceremony" == "true" && "$tpm_sealing_binds_enrollment" == "true" ]] \
    || fail "TPM sealing evidence must bind the key-share ceremony and enrollment manifest"
  [[ "$tpm_sealing_quote_hashes" == "true" && "$tpm_sealing_policy_binding" == "true" && "$tpm_sealing_unseal_binding" == "true" && "$tpm_sealing_share_hash" == "true" && "$tpm_sealing_object_blobs" == "true" ]] \
    || fail "TPM sealing evidence must verify quote/event-log hashes, policy binding, unseal binding, sealed share, and TPM2 object blobs"
  [[ "$tpm_sealing_local_env" == "LOCAL_EVIDENCE_ROOT" && "$tpm_sealing_local_toggle_env" == "VERIFY_LOCAL_FILES" ]] \
    || fail "TPM sealing evidence local file verification env mismatch"
  [[ "$lifecycle_schema" == "monarch-protocore-key-share-ceremony/v1" ]] \
    || fail "key-share lifecycle schema mismatch: $lifecycle_schema"
  [[ "$lifecycle_schema_path" == "schemas/protocore-key-share-ceremony.schema.json" ]] \
    || fail "key-share lifecycle schema path mismatch: $lifecycle_schema_path"
  [[ -f "$ROOT_DIR/$lifecycle_schema_path" ]] \
    || fail "key-share lifecycle schema file is missing: $lifecycle_schema_path"
  [[ "$lifecycle_validator" == "scripts/validate-key-share-ceremony.sh" ]] \
    || fail "key-share lifecycle validator mismatch: $lifecycle_validator"
  [[ -x "$ROOT_DIR/$lifecycle_validator" ]] \
    || fail "key-share lifecycle validator is missing or not executable: $lifecycle_validator"
  [[ "$lifecycle_cluster_size" == "10" && "$lifecycle_threshold" == "7" && "$lifecycle_approval_threshold" == "7" ]] \
    || fail "key-share lifecycle policy must require 10-member, 7-of-10 ceremonies"
  [[ "$lifecycle_payload_schema" == "monarch-protocore-key-share-lifecycle-payload/v1" ]] \
    || fail "key-share lifecycle payload schema mismatch: $lifecycle_payload_schema"
  [[ "$lifecycle_payload_canonicalization" == "jq-canonical-sorted-json/v1" && "$lifecycle_payload_hash" == "sha256" ]] \
    || fail "key-share lifecycle payload hash/canonicalization mismatch"
  [[ "$lifecycle_payload_validator" == "scripts/validate-key-share-ceremony.sh" ]] \
    || fail "key-share lifecycle payload validator mismatch: $lifecycle_payload_validator"
  [[ "$lifecycle_payload_ceremony_method" == "submitPendingChange" && "$lifecycle_payload_attestation_method" == "attestDkgReshare" ]] \
    || fail "key-share lifecycle on-chain method binding mismatch"
  [[ "$lifecycle_payload_ceremony_selector" == "0x7d09426c" && "$lifecycle_payload_attestation_selector" == "0x36e34030" ]] \
    || fail "key-share lifecycle on-chain selector binding mismatch"
  [[ "$lifecycle_mainnet" == "true" && "$lifecycle_hardware_tpm" == "true" && "$lifecycle_tpm_binding" == "true" && "$lifecycle_on_chain" == "true" ]] \
    || fail "key-share lifecycle policy must require mainnet hardware TPM, TPM evidence hash binding, and on-chain lifecycle evidence"
  [[ "$lifecycle_local_env" == "LOCAL_EVIDENCE_ROOT" && "$lifecycle_local_toggle_env" == "VERIFY_LOCAL_FILES" ]] \
    || fail "key-share lifecycle local file verification env mismatch"
  [[ "$lifecycle_verifies_dkg_file" == "true" && "$lifecycle_verifies_all_share_files" == "true" ]] \
    || fail "key-share lifecycle policy must verify the staged DKG transcript and all sealed-share output files"
  [[ "$handoff_schema" == "monarch-protocore-key-share-handoff/v1" ]] \
    || fail "key-share handoff schema mismatch: $handoff_schema"
  [[ "$handoff_schema_path" == "schemas/protocore-key-share-handoff.schema.json" ]] \
    || fail "key-share handoff schema path mismatch: $handoff_schema_path"
  [[ -f "$ROOT_DIR/$handoff_schema_path" ]] \
    || fail "key-share handoff schema file is missing: $handoff_schema_path"
  [[ "$handoff_renderer" == "scripts/render-key-share-handoff.sh" ]] \
    || fail "key-share handoff renderer mismatch: $handoff_renderer"
  [[ -x "$ROOT_DIR/$handoff_renderer" ]] \
    || fail "key-share handoff renderer is missing or not executable: $handoff_renderer"
  [[ "$handoff_validator" == "scripts/validate-key-share-handoff.sh" ]] \
    || fail "key-share handoff validator mismatch: $handoff_validator"
  [[ -x "$ROOT_DIR/$handoff_validator" ]] \
    || fail "key-share handoff validator is missing or not executable: $handoff_validator"
  [[ "$handoff_source_schema" == "monarch-protocore-key-share-ceremony/v1" ]] \
    || fail "key-share handoff source schema mismatch: $handoff_source_schema"
  [[ "$handoff_required" == "true" && "$handoff_ceremony_sha" == "true" && "$handoff_roster_binding" == "true" && "$handoff_share_binding" == "true" && "$handoff_transcript_binding" == "true" ]] \
    || fail "key-share handoff policy must require ceremony hash, roster, TPM-sealed share, and DKG transcript binding"
  [[ "$handoff_local_env" == "LOCAL_EVIDENCE_ROOT" && "$handoff_local_toggle_env" == "VERIFY_LOCAL_FILES" ]] \
    || fail "key-share handoff local file verification env mismatch"
  [[ "$handoff_sealed_path" == "$tpm_sealed_path" && "$handoff_dkg_path" == "$dkg_path" ]] \
    || fail "key-share handoff import paths must match Protocore TPM/DKG service paths"

  local extension_tar service_config forbidden
  extension_tar="$(extension_tar_from_metadata)"
  service_config="$(tar -xOf "$extension_tar" rootfs/usr/local/etc/containers/protocore.yaml 2>/dev/null)" \
    || fail "failed to read protocore service config from extension"

  grep -Fx "    - PROTOCORE_REQUIRE_ENROLLMENT=$enrollment_required" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin enrollment requirement: $enrollment_required"
  grep -Fx "    - PROTOCORE_ENROLLMENT_FILE=$enrollment_path" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin enrollment file: $enrollment_path"
  if [[ "$enrollment_required" == "true" ]]; then
    grep -Fx "    - PROTOCORE_EXPECTED_DIGEST_FILE=$digest_file_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin expected digest file: $digest_file_path"
  fi
  grep -Fx "    - PROTOCORE_REQUIRE_TPM_BINDING=$tpm_required" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin TPM binding requirement: $tpm_required"
  grep -Fx "    - PROTOCORE_NODE_MODE=$(jq -r '.provisioning_policy.default_node_role' "$metadata_path")" <<<"$service_config" >/dev/null \
    || fail "protocore service config does not pin node mode"
  if [[ "$tpm_required" == "true" ]]; then
    grep -Fx "    - PROTOCORE_TPM_QUOTE_FILE=$tpm_quote_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin TPM quote file: $tpm_quote_path"
    grep -Fx "    - PROTOCORE_TPM_EVENT_LOG_FILE=$tpm_event_log_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin TPM event-log file: $tpm_event_log_path"
    grep -Fx "    - PROTOCORE_TPM_SEALED_BLS_SHARE_FILE=$tpm_sealed_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin TPM-sealed share compatibility alias: $tpm_sealed_path"
    grep -Fx "    - PROTOCORE_DKG_TRANSCRIPT_FILE=$dkg_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin DKG transcript file: $dkg_path"
    grep -Fx "    - PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE=$lythiumseal_path" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin LythiumSeal operator key file: $lythiumseal_path"
  fi
  if [[ -n "$lythiumseal_generate" ]]; then
    grep -Fx "    - PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY=$lythiumseal_generate" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin LythiumSeal keygen flag: $lythiumseal_generate"
  fi
  if [[ -n "$lythiumseal_index" ]]; then
    grep -Fx "    - PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX=$lythiumseal_index" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin LythiumSeal operator index: $lythiumseal_index"
  fi
  if [[ -n "$lythiumseal_epoch" ]]; then
    grep -Fx "    - PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH=$lythiumseal_epoch" <<<"$service_config" >/dev/null \
      || fail "protocore service config does not pin LythiumSeal operator epoch: $lythiumseal_epoch"
  fi

  mapfile -t forbidden < <(jq -r '.provisioning_policy.prohibited_inline_secret_env[]?' "$metadata_path")
  for name in "${forbidden[@]}"; do
    if grep -E "(^|[[:space:]]|-)${name}=" <<<"$service_config" >/dev/null; then
      fail "protocore service config includes forbidden inline secret env: $name"
    fi
  done

  if grep -E '<replace|replace-with|changeme|placeholder|example-secret' <<<"$service_config" >/dev/null; then
    fail "protocore service config contains placeholder secret/config value"
  fi
}

check_incident_response_policy() {
  local schema schema_path validator signed_required evidence_required on_chain_mainnet_count auth_count disallowed_count executor_binding_required executor_method_count executor_binding_count
  schema="$(jq -r '.incident_response_policy.schema // ""' "$metadata_path")"
  schema_path="$(jq -r '.incident_response_policy.schema_path // ""' "$metadata_path")"
  validator="$(jq -r '.incident_response_policy.validator // ""' "$metadata_path")"
  signed_required="$(jq -r '.incident_response_policy.signed_runbook_required // false' "$metadata_path")"
  evidence_required="$(jq -r '.incident_response_policy.evidence_file_hashes_required // false' "$metadata_path")"
  auth_count="$(jq -r '(.incident_response_policy.foundation_authorization_required_for // []) | length' "$metadata_path")"
  on_chain_mainnet_count="$(jq -r '(.incident_response_policy.on_chain_action_required_for_mainnet // []) | length' "$metadata_path")"
  disallowed_count="$(jq -r '(.incident_response_policy.disallowed_freeze_reasons // []) | length' "$metadata_path")"
  executor_binding_required="$(jq -r '.incident_response_policy.executor_binding_required_for_mainnet // false' "$metadata_path")"
  executor_method_count="$(jq -r '(.incident_response_policy.on_chain_executor_methods // {}) | length' "$metadata_path")"
  executor_binding_count="$(jq -r '(.incident_response_policy.on_chain_executor_bindings // {}) | length' "$metadata_path")"

  [[ "$schema" == "monarch-incident-response/v1" ]] \
    || fail "incident response schema mismatch: $schema"
  [[ "$schema_path" == "schemas/monarch-incident-response.schema.json" ]] \
    || fail "incident response schema path mismatch: $schema_path"
  [[ -f "$ROOT_DIR/$schema_path" ]] \
    || fail "incident response schema file is missing: $schema_path"
  [[ "$validator" == "scripts/validate-incident-response.sh" ]] \
    || fail "incident response validator mismatch: $validator"
  [[ -x "$ROOT_DIR/$validator" ]] \
    || fail "incident response validator is missing or not executable: $validator"
  [[ "$signed_required" == "true" ]] \
    || fail "incident response policy must require signed runbooks"
  [[ "$evidence_required" == "true" ]] \
    || fail "incident response policy must require evidence file hashes"
  [[ "$auth_count" == "4" && "$on_chain_mainnet_count" == "4" ]] \
    || fail "incident response policy must require authorization/on-chain evidence for all emergency actions"
  [[ "$executor_binding_required" == "true" && "$executor_method_count" == "4" && "$executor_binding_count" == "4" ]] \
    || fail "incident response policy must require executor bindings for all mainnet emergency actions"
  [[ "$disallowed_count" -ge 6 ]] \
    || fail "incident response policy must enumerate disallowed freeze reasons"
  for action in freeze-admission pause-bridge-route rollback-bridge emergency-key-rotation; do
    jq -e --arg action "$action" '.incident_response_policy.foundation_authorization_required_for | index($action)' "$metadata_path" >/dev/null \
      || fail "incident response policy lacks foundation authorization action: $action"
    jq -e --arg action "$action" '.incident_response_policy.on_chain_action_required_for_mainnet | index($action)' "$metadata_path" >/dev/null \
      || fail "incident response policy lacks mainnet on-chain action: $action"
  done
  jq -e '
    .incident_response_policy.on_chain_executor_methods["freeze-admission"] == "freezeAdmission"
    and .incident_response_policy.on_chain_executor_methods["pause-bridge-route"] == "pauseBridgeRoute"
    and .incident_response_policy.on_chain_executor_methods["rollback-bridge"] == "rollbackBridge"
    and .incident_response_policy.on_chain_executor_methods["emergency-key-rotation"] == "emergencyKeyRotation"
  ' "$metadata_path" >/dev/null || fail "incident response policy has mismatched on-chain executor methods"
  jq -e '
    .incident_response_policy.on_chain_executor_bindings["freeze-admission"] == {
      contract: "0x0000000000000000000000000000000000001005",
      method: "freezeAdmission",
      selector: "0x7a2605cd",
      argument: "reason_hash"
    }
    and .incident_response_policy.on_chain_executor_bindings["pause-bridge-route"] == {
      contract: "0x0000000000000000000000000000000000001008",
      method: "pauseBridgeRoute",
      selector: "0x11a2dc64",
      argument: "bridge_route_id,reason_hash"
    }
    and .incident_response_policy.on_chain_executor_bindings["rollback-bridge"] == {
      contract: "0x0000000000000000000000000000000000001008",
      method: "rollbackBridge",
      selector: "0x059a1b5c",
      argument: "bridge_route_id,reason_hash"
    }
    and .incident_response_policy.on_chain_executor_bindings["emergency-key-rotation"] == {
      contract: "0x0000000000000000000000000000000000001005",
      method: "emergencyKeyRotation",
      selector: "0x0aeeafbf",
      argument: "target_bls_pubkey,effective_epoch,intent_id"
    }
  ' "$metadata_path" >/dev/null || fail "incident response policy has mismatched on-chain executor bindings"
  for reason in routine-upgrade parameter-change protocol-direction account-censorship asset-confiscation ongoing-supervision; do
    jq -e --arg reason "$reason" '.incident_response_policy.disallowed_freeze_reasons | index($reason)' "$metadata_path" >/dev/null \
      || fail "incident response policy lacks disallowed freeze reason: $reason"
  done
}

check_audit_trail_policy() {
  local schema schema_path validator payload_schema canonicalization hash required mainnet_required evidence_required local_env local_toggle hash_chain high_risk_threshold desktop_binding on_chain_binding diff_required peer_count supported_count
  schema="$(jq -r '.audit_trail_policy.schema // ""' "$metadata_path")"
  schema_path="$(jq -r '.audit_trail_policy.schema_path // ""' "$metadata_path")"
  validator="$(jq -r '.audit_trail_policy.validator // ""' "$metadata_path")"
  payload_schema="$(jq -r '.audit_trail_policy.signed_payload_schema // ""' "$metadata_path")"
  canonicalization="$(jq -r '.audit_trail_policy.canonicalization // ""' "$metadata_path")"
  hash="$(jq -r '.audit_trail_policy.hash // ""' "$metadata_path")"
  required="$(jq -r '.audit_trail_policy.required_for_operator_actions // false' "$metadata_path")"
  mainnet_required="$(jq -r '.audit_trail_policy.required_for_mainnet_operator_actions // false' "$metadata_path")"
  evidence_required="$(jq -r '.audit_trail_policy.evidence_file_hashes_required // false' "$metadata_path")"
  local_env="$(jq -r '.audit_trail_policy.local_file_hash_verification_env // ""' "$metadata_path")"
  local_toggle="$(jq -r '.audit_trail_policy.local_file_hash_verification_toggle_env // ""' "$metadata_path")"
  hash_chain="$(jq -r '.audit_trail_policy.hash_chain_supported // false' "$metadata_path")"
  high_risk_threshold="$(jq -r '.audit_trail_policy.high_risk_approval_threshold // 0' "$metadata_path")"
  desktop_binding="$(jq -r '.audit_trail_policy.desktop_receipt_binding_required // false' "$metadata_path")"
  on_chain_binding="$(jq -r '.audit_trail_policy.on_chain_receipt_binding_required_for_mainnet // false' "$metadata_path")"
  diff_required="$(jq -r '.audit_trail_policy.diff_vs_intent_required // false' "$metadata_path")"
  peer_count="$(jq -r '(.audit_trail_policy.peer_vouches_required_for // []) | length' "$metadata_path")"
  supported_count="$(jq -r '(.audit_trail_policy.supported_actions // []) | length' "$metadata_path")"

  [[ "$schema" == "monarch-operator-audit-trail/v1" ]] \
    || fail "audit trail schema mismatch: $schema"
  [[ "$schema_path" == "schemas/monarch-operator-audit-trail.schema.json" ]] \
    || fail "audit trail schema path mismatch: $schema_path"
  [[ -f "$ROOT_DIR/$schema_path" ]] \
    || fail "audit trail schema file is missing: $schema_path"
  [[ "$validator" == "scripts/validate-operator-audit-trail.sh" ]] \
    || fail "audit trail validator mismatch: $validator"
  [[ -x "$ROOT_DIR/$validator" ]] \
    || fail "audit trail validator is missing or not executable: $validator"
  [[ "$payload_schema" == "monarch-operator-audit-payload/v1" ]] \
    || fail "audit trail payload schema mismatch: $payload_schema"
  [[ "$canonicalization" == "jq-canonical-sorted-json/v1" && "$hash" == "sha256" ]] \
    || fail "audit trail payload hash/canonicalization mismatch"
  [[ "$required" == "true" && "$mainnet_required" == "true" && "$evidence_required" == "true" ]] \
    || fail "audit trail policy must require operator action audit evidence"
  [[ "$local_env" == "LOCAL_EVIDENCE_ROOT" && "$local_toggle" == "VERIFY_LOCAL_FILES" ]] \
    || fail "audit trail local file verification env mismatch"
  [[ "$hash_chain" == "true" && "$high_risk_threshold" == "2" ]] \
    || fail "audit trail policy must support hash chaining and two approval high-risk actions"
  [[ "$desktop_binding" == "true" && "$on_chain_binding" == "true" && "$diff_required" == "true" ]] \
    || fail "audit trail policy must require desktop/on-chain receipt binding and diff-vs-intent hashes"
  [[ "$peer_count" == "2" && "$supported_count" -ge 17 ]] \
    || fail "audit trail policy must enumerate peer-vouched freeze actions and supported actions"
  for action in freeze-admission kill-switch-freeze; do
    jq -e --arg action "$action" '.audit_trail_policy.peer_vouches_required_for | index($action)' "$metadata_path" >/dev/null \
      || fail "audit trail policy lacks peer-vouched freeze action: $action"
  done
  for action in enrollment dkg-ceremony tpm-sealing key-share-handoff key-share-rotation incident-response disaster-recovery upgrade rollback desktop-operation chat-e2e release-promotion; do
    jq -e --arg action "$action" '.audit_trail_policy.supported_actions | index($action)' "$metadata_path" >/dev/null \
      || fail "audit trail policy lacks supported action: $action"
  done
}

check_disaster_recovery_policy() {
  local schema schema_path validator data_path hot_backup stopped_required manifest_required modes_count checks_count signing_required on_chain_required executor_method
  schema="$(jq -r '.disaster_recovery_policy.schema // ""' "$metadata_path")"
  schema_path="$(jq -r '.disaster_recovery_policy.schema_path // ""' "$metadata_path")"
  validator="$(jq -r '.disaster_recovery_policy.validator // ""' "$metadata_path")"
  data_path="$(jq -r '.disaster_recovery_policy.protocore_data_path // ""' "$metadata_path")"
  hot_backup="$(jq -r '.disaster_recovery_policy.hot_backup_prohibited // false' "$metadata_path")"
  stopped_required="$(jq -r '.disaster_recovery_policy.stopped_or_offline_backup_required // false' "$metadata_path")"
  manifest_required="$(jq -r '.disaster_recovery_policy.restore_manifest_required_before_cluster_rejoin // false' "$metadata_path")"
  modes_count="$(jq -r '(.disaster_recovery_policy.supported_recovery_modes // []) | length' "$metadata_path")"
  checks_count="$(jq -r '(.disaster_recovery_policy.required_post_restore_checks // []) | length' "$metadata_path")"
  signing_required="$(jq -r '.disaster_recovery_policy.signing_node_key_share_recovery_required // false' "$metadata_path")"
  on_chain_required="$(jq -r '.disaster_recovery_policy.on_chain_recovery_required_for_mainnet_signing // false' "$metadata_path")"
  calldata_hash="$(jq -r '.disaster_recovery_policy.on_chain_recovery_calldata_hash // ""' "$metadata_path")"
  executor_method="$(jq -r '.disaster_recovery_policy.on_chain_executor_methods.recover_operator_node // ""' "$metadata_path")"
  executor_contract="$(jq -r '.disaster_recovery_policy.on_chain_executor_bindings.recover_operator_node.contract // ""' "$metadata_path")"
  executor_selector="$(jq -r '.disaster_recovery_policy.on_chain_executor_bindings.recover_operator_node.selector // ""' "$metadata_path")"
  executor_argument="$(jq -r '.disaster_recovery_policy.on_chain_executor_bindings.recover_operator_node.argument // ""' "$metadata_path")"

  [[ "$schema" == "monarch-disaster-recovery/v1" ]] \
    || fail "disaster recovery schema mismatch: $schema"
  [[ "$schema_path" == "schemas/monarch-disaster-recovery.schema.json" ]] \
    || fail "disaster recovery schema path mismatch: $schema_path"
  [[ -f "$ROOT_DIR/$schema_path" ]] \
    || fail "disaster recovery schema file is missing: $schema_path"
  [[ "$validator" == "scripts/validate-disaster-recovery.sh" ]] \
    || fail "disaster recovery validator mismatch: $validator"
  [[ -x "$ROOT_DIR/$validator" ]] \
    || fail "disaster recovery validator is missing or not executable: $validator"
  [[ "$data_path" == "/var/lib/protocore" ]] \
    || fail "disaster recovery policy data path mismatch: $data_path"
  [[ "$hot_backup" == "true" && "$stopped_required" == "true" && "$manifest_required" == "true" ]] \
    || fail "disaster recovery policy must prohibit hot backup and require stopped/offline manifest evidence"
  [[ "$modes_count" == "4" && "$checks_count" -ge 4 ]] \
    || fail "disaster recovery policy must enumerate recovery modes and post-restore checks"
  [[ "$signing_required" == "true" && "$on_chain_required" == "true" ]] \
    || fail "disaster recovery policy must require signing-node key-share and mainnet on-chain recovery evidence"
  [[ "$executor_method" == "recoverOperatorNode" ]] \
    || fail "disaster recovery policy recover executor method mismatch: $executor_method"
  [[ "$calldata_hash" == "sha256" ]] \
    || fail "disaster recovery policy calldata hash mismatch: $calldata_hash"
  [[ "$executor_contract" == "0x0000000000000000000000000000000000001005" ]] \
    || fail "disaster recovery policy recover executor contract mismatch: $executor_contract"
  [[ "$executor_selector" == "0xe58729e6" ]] \
    || fail "disaster recovery policy recover executor selector mismatch: $executor_selector"
  [[ "$executor_argument" == "operator_peer_id" ]] \
    || fail "disaster recovery policy recover executor argument mismatch: $executor_argument"
  for mode in resync offline-restore disk-replacement signing-node-reseal; do
    jq -e --arg mode "$mode" '.disaster_recovery_policy.supported_recovery_modes | index($mode)' "$metadata_path" >/dev/null \
      || fail "disaster recovery policy lacks supported mode: $mode"
  done
  for check in release-digest-match genesis-match chain-id-match protocore-rpc-healthy; do
    jq -e --arg check "$check" '.disaster_recovery_policy.required_post_restore_checks | index($check)' "$metadata_path" >/dev/null \
      || fail "disaster recovery policy lacks post-restore check: $check"
  done
}

check_complete_artifact_set() {
  local iso="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.iso"
  local raw_xz="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.raw.xz"
  local iso_sbom="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.iso.spdx.json"
  local raw_sbom="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.raw.spdx.json"

  [[ -f "$iso" ]] || fail "complete artifact set missing ISO: $(basename "$iso")"
  [[ -f "$raw_xz" ]] || fail "complete artifact set missing compressed raw image: $(basename "$raw_xz")"
  [[ -f "$metadata_path" ]] || fail "complete artifact set missing release metadata: $(basename "$metadata_path")"
  [[ -f "$iso_sbom" ]] || fail "complete artifact set missing ISO SBOM: $(basename "$iso_sbom")"
  [[ -f "$raw_sbom" ]] || fail "complete artifact set missing raw-image SBOM: $(basename "$raw_sbom")"

  shopt -s nullglob
  local extension_tars=("$OUT_DIR"/monarch-protocore-"$ARCH"-*.tar)
  (( ${#extension_tars[@]} > 0 )) || fail "complete artifact set missing protocore extension tar"

  local required_paths=(
    "$(basename "$iso")"
    "$(basename "$raw_xz")"
    "$(basename "$iso_sbom")"
    "$(basename "$raw_sbom")"
    "$(basename "${extension_tars[0]}")"
  )
  local path
  for path in "${required_paths[@]}"; do
    jq -e --arg path "$path" '.artifacts[] | select(.path == $path)' "$metadata_path" >/dev/null \
      || fail "release metadata does not include required artifact: $path"
  done
}

check_sha_file "$metadata_path"
check_release_metadata_digest

if [[ "$REQUIRE_COMPLETE_ARTIFACT_SET" == "true" ]]; then
  check_complete_artifact_set
fi

if [[ "$REQUIRE_CHANNEL_METADATA" == "true" ]]; then
  check_channel_metadata
fi

if [[ "$REQUIRE_SUBSTRATE_PROOF" == "true" ]]; then
  check_substrate_proof
fi

if [[ "$REQUIRE_NETWORK_POLICY" == "true" ]]; then
  check_network_policy
fi

if [[ "$REQUIRE_PROVISIONING_POLICY" == "true" ]]; then
  check_provisioning_policy
fi

if [[ "$REQUIRE_INCIDENT_RESPONSE_POLICY" == "true" ]]; then
  check_incident_response_policy
fi

if [[ "$REQUIRE_DISASTER_RECOVERY_POLICY" == "true" ]]; then
  check_disaster_recovery_policy
fi

if [[ "$REQUIRE_AUDIT_TRAIL_POLICY" == "true" ]]; then
  check_audit_trail_policy
fi

mapfile -t artifact_paths < <(jq -r '.artifacts[].path' "$metadata_path")
(( ${#artifact_paths[@]} > 0 )) || fail "release metadata has no artifacts"

for path in "${artifact_paths[@]}"; do
  artifact="$OUT_DIR/$path"
  [[ -f "$artifact" ]] || fail "metadata references missing artifact: $path"
  expected_sha="$(jq -r --arg path "$path" '.artifacts[] | select(.path == $path) | .sha256' "$metadata_path" | head -n 1)"
  [[ -n "$expected_sha" && "$expected_sha" != "null" ]] || fail "metadata lacks sha256 for: $path"
  actual_sha="$(sha256sum "$artifact" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "metadata sha256 mismatch for: $path"
done

shopt -s nullglob
releasable_artifacts=(
  "$OUT_DIR"/*.iso
  "$OUT_DIR"/*.raw.xz
  "$OUT_DIR"/*.tar
  "$OUT_DIR"/*.release.json
  "$OUT_DIR"/*.spdx.json
)

(( ${#releasable_artifacts[@]} > 0 )) || fail "no releasable artifacts found in $OUT_DIR"

for artifact in "${releasable_artifacts[@]}"; do
  check_sha_file "$artifact"
  if [[ "$REQUIRE_SIGNATURES" == "true" ]]; then
    check_signature_files "$artifact"
  fi
done

if [[ "$REQUIRE_SMOKE_QEMU" == "true" ]]; then
  check_smoke_qemu
fi

printf 'verified %d metadata artifacts and %d releasable files in %s (smoke_qemu=%s)\n' \
  "${#artifact_paths[@]}" "${#releasable_artifacts[@]}" "$OUT_DIR" "$REQUIRE_SMOKE_QEMU"
