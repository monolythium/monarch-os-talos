#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "fleet upgrade plan test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need jq

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

hash0="0000000000000000000000000000000000000000000000000000000000000000"
hash1="1111111111111111111111111111111111111111111111111111111111111111"
hash2="2222222222222222222222222222222222222222222222222222222222222222"
signature="$(printf 'a%.0s' {1..128})"

write_metadata() {
  local path="$1"
  local version="$2"
  local migration_required="$3"
  local migration_mode="$4"
  local rollback_supported="$5"
  local runbook_id="$6"

  jq -n \
    --arg version "$version" \
    --arg genesis "$hash0" \
    --arg baseline "$hash1" \
    --arg mode "$migration_mode" \
    --arg runbook_id "$runbook_id" \
    --argjson migration_required "$migration_required" \
    --argjson rollback_supported "$rollback_supported" \
    '{
      schema_version: "monarch-os-release-metadata/v1",
      substrate: {
        no_ssh_server: true,
        no_package_manager: true,
        no_interactive_shell: true,
        kernel_hardening_baseline: {
          schema: "monarch-os-kernel-hardening-baseline/v1",
          sha256: $baseline
        }
      },
      network_policy: {
        protocore_rpc: {listen: "0.0.0.0:8545"},
        protocore_p2p: {listen: "/ip4/0.0.0.0/tcp/29898"}
      },
      provisioning_policy: {
        no_default_secrets: true,
        inline_secret_env_prohibited: true
      },
      channel: {
        name: "testnet",
        chain: {
          profile: "testnet",
          chain_id: "69420",
          genesis: {sha256: $genesis}
        },
        compatibility: {
          protocore: {version: $version},
          monarch_desktop: {
            channel: "testnet",
            min_version: "0.0.5",
            max_version: "<1.0.0"
          }
        },
        upgrade: {
          requires_same_channel: true,
          state_migration: {
            required: $migration_required,
            mode: $mode,
            runbook_id: (if $runbook_id == "" then null else $runbook_id end),
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
        monarch_os_talos: {dirty: false},
        mono_core: {dirty: false}
      },
      artifacts: [
        {
          path: ("monarch-os-talos-" + $version + "-amd64.raw.xz"),
          sha256: $genesis,
          size_bytes: 128
        },
        {
          path: ("monarch-protocore-amd64-" + $version + ".tar"),
          sha256: $baseline,
          size_bytes: 64
        }
      ]
    }' > "$path"
}

write_disaster_recovery() {
  local path="$1"
  jq -n \
    --arg h0 "$hash0" \
    --arg h1 "$hash1" \
    --arg h2 "$hash2" \
    --arg sig "0x$signature" \
    '{
      schema_version: "monarch-disaster-recovery/v1",
      recovery: {
        id: "fleet-dr-test-001",
        type: "offline-restore",
        runbook_id: "fleet-upgrade-migration-test",
        opened_at: "2026-06-01T00:00:00Z"
      },
      chain: {
        profile: "testnet",
        chain_id: 69420,
        genesis_sha256: $h0
      },
      release: {
        metadata_sha256: $h1,
        protocore_digest: $h2
      },
      node: {
        role: "archive",
        node_id: "archive-001"
      },
      backup: {
        mode: "offline-snapshot",
        created_at: "2026-06-01T00:00:00Z",
        protocore_service_state: "offline",
        hot_backup: false,
        storage_uri: "s3://monarch-dr-test/archive-001",
        var_lib_protocore_sha256: $h1,
        manifest_sha256: $h2,
        encrypted: true,
        encryption_key_ref: "kms://monarch-dr-test"
      },
      restore: {
        target_node_id: "archive-001-replacement",
        restore_path: "/var/lib/protocore",
        service_stopped_before_restore: true,
        post_restore_checks: [
          "release-digest-match",
          "genesis-match",
          "chain-id-match",
          "protocore-rpc-healthy"
        ]
      },
      approvals: [
        {
          address: "0x1111111111111111111111111111111111111111",
          signature_scheme: "ML-DSA-65",
          signed_payload_hash: $h0,
          signature: $sig
        }
      ]
    }' > "$path"
}

write_operator_fleet() {
  local path="$1"
  local active_count="$2"
  local quorum="$3"

  jq -n \
    --argjson active_count "$active_count" \
    --argjson quorum "$quorum" \
    '{
      schema_version: "monarch-talos-fleet-upgrade-manifest/v1",
      fleet: {
        id: "testnet-operators-a",
        max_unavailable: 1,
        canary_count: 1,
        operator_signing_quorum: $quorum
      },
      nodes: [
        range(0; $active_count)
        | {
            node_id: ("operator-" + tostring),
            role: "operator-signing",
            cluster_id: "C-001",
            operator_index: .,
            cluster_position: "active",
            talos_node: ("10.0.0." + (10 + . | tostring)),
            talos_endpoint: ("10.0.0." + (10 + . | tostring))
          }
      ]
    }' > "$path"
}

current="$tmp_dir/current.release.json"
target="$tmp_dir/target.release.json"
migration_target="$tmp_dir/target-migration.release.json"
dr_manifest="$tmp_dir/dr.json"
fleet="$tmp_dir/fleet.json"
duplicate_fleet="$tmp_dir/fleet-duplicate.json"
unsafe_fleet="$tmp_dir/fleet-unsafe.json"
plan="$tmp_dir/fleet-upgrade-plan.json"

write_metadata "$current" "0.0.16" false none true ""
write_metadata "$target" "0.0.17" false none true ""
write_metadata "$migration_target" "0.0.18" true backward-compatible false "testnet-fleet-upgrade-drill"
write_disaster_recovery "$dr_manifest"
write_operator_fleet "$fleet" 8 7
write_operator_fleet "$unsafe_fleet" 7 7

(
  cd "$ROOT_DIR"
  make fleet-upgrade-plan \
    UPGRADE_CURRENT_METADATA="$current" \
    UPGRADE_TARGET_METADATA="$target" \
    FLEET_MANIFEST="$fleet" \
    UPGRADE_IMAGE_REF="ghcr.io/monolythium/monarch-os:testnet-0.0.17" \
    FLEET_PLAN_OUTPUT="$plan" >/dev/null
)

jq -e '
  .schema_version == "monarch-talos-fleet-upgrade-plan/v1"
  and .ok == true
  and .dry_run == true
  and .fleet.node_count == 8
  and .fleet.max_unavailable == 1
  and (.rollout.waves | length) == 8
  and all(.rollout.waves[]; .concurrency == 1)
  and .gates.signing_quorum.safe == true
  and .upgrade.talos_api_request_template.preserve == true
  and .upgrade.talos_api_request_template.force == false
  and .rollout.waves[0].nodes[0].upgrade.talosctl_argv[0:2] == ["talosctl", "upgrade"]
  and (.rollout.waves[0].nodes[0].upgrade.talosctl_argv | index("ghcr.io/monolythium/monarch-os:testnet-0.0.17"))
  and .target_artifacts.raw_xz.path == "monarch-os-talos-0.0.17-amd64.raw.xz"
' "$plan" >/dev/null || fail "fleet upgrade plan shape changed"

jq '.nodes[1].node_id = .nodes[0].node_id' "$fleet" >"$duplicate_fleet"
if (
  cd "$ROOT_DIR"
  make fleet-upgrade-plan \
    UPGRADE_CURRENT_METADATA="$current" \
    UPGRADE_TARGET_METADATA="$target" \
    FLEET_MANIFEST="$duplicate_fleet" \
    UPGRADE_IMAGE_REF="ghcr.io/monolythium/monarch-os:testnet-0.0.17" >/dev/null 2>"$tmp_dir/duplicate.err"
); then
  fail "duplicate fleet node id was accepted"
fi
grep -E "duplicate|invalid explicit wave" "$tmp_dir/duplicate.err" >/dev/null \
  || fail "duplicate node rejection reason changed"

if (
  cd "$ROOT_DIR"
  make fleet-upgrade-plan \
    UPGRADE_CURRENT_METADATA="$current" \
    UPGRADE_TARGET_METADATA="$target" \
    FLEET_MANIFEST="$unsafe_fleet" \
    UPGRADE_IMAGE_REF="ghcr.io/monolythium/monarch-os:testnet-0.0.17" >/dev/null 2>"$tmp_dir/quorum.err"
); then
  fail "below-quorum fleet rollout was accepted"
fi
grep -F "below quorum" "$tmp_dir/quorum.err" >/dev/null \
  || fail "below-quorum rejection reason changed"

if (
  cd "$ROOT_DIR"
  make fleet-upgrade-plan \
    ALLOW_STATE_MIGRATION=true \
    UPGRADE_CURRENT_METADATA="$current" \
    UPGRADE_TARGET_METADATA="$migration_target" \
    FLEET_MANIFEST="$fleet" \
    UPGRADE_IMAGE_REF="ghcr.io/monolythium/monarch-os:testnet-0.0.18" >/dev/null 2>"$tmp_dir/missing-dr.err"
); then
  fail "migration fleet upgrade without disaster recovery manifest was accepted"
fi
grep -F "requires DISASTER_RECOVERY" "$tmp_dir/missing-dr.err" >/dev/null \
  || fail "missing disaster-recovery rejection reason changed"

(
  cd "$ROOT_DIR"
  make fleet-upgrade-plan \
    ALLOW_STATE_MIGRATION=true \
    UPGRADE_CURRENT_METADATA="$current" \
    UPGRADE_TARGET_METADATA="$migration_target" \
    FLEET_MANIFEST="$fleet" \
    UPGRADE_IMAGE_REF="ghcr.io/monolythium/monarch-os:testnet-0.0.18" \
    DISASTER_RECOVERY="$dr_manifest" \
    FLEET_PLAN_OUTPUT="$plan" >/dev/null
)

jq -e '
  .gates.state_migration.required == true
  and .gates.disaster_recovery.required == true
  and .gates.disaster_recovery.validated == true
  and .gates.disaster_recovery.report.ok == true
  and .rollback? == null
  and .gates.signing_quorum.safe == true
' "$plan" >/dev/null || fail "migration fleet plan did not bind validated DR evidence"

printf '{"ok":true,"checked":"fleet-upgrade-plan"}\n'
