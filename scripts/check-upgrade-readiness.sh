#!/usr/bin/env bash
set -euo pipefail

CURRENT_METADATA="${CURRENT_METADATA:-${1:-}}"
TARGET_METADATA="${TARGET_METADATA:-${2:-}}"
ALLOW_GENESIS_CHANGE="${ALLOW_GENESIS_CHANGE:-false}"
ALLOW_STATE_MIGRATION="${ALLOW_STATE_MIGRATION:-false}"
ALLOW_DIRTY_RELEASE="${ALLOW_DIRTY_RELEASE:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "upgrade-readiness: $*" >&2
  exit 1
}

field() {
  local path="$1"
  local file="$2"
  jq -r "$path // \"\"" "$file"
}

bool_field() {
  local path="$1"
  local file="$2"
  jq -r "$path // false" "$file"
}

artifact_present() {
  local file="$1"
  local pattern="$2"
  jq -e --arg pattern "$pattern" 'any(.artifacts[]?.path; test($pattern))' "$file" >/dev/null
}

need jq

[[ -n "$CURRENT_METADATA" ]] || fail "CURRENT_METADATA or first argument is required"
[[ -n "$TARGET_METADATA" ]] || fail "TARGET_METADATA or second argument is required"
[[ -f "$CURRENT_METADATA" ]] || fail "current metadata not found: $CURRENT_METADATA"
[[ -f "$TARGET_METADATA" ]] || fail "target metadata not found: $TARGET_METADATA"

jq -e . "$CURRENT_METADATA" >/dev/null || fail "current metadata is not valid JSON"
jq -e . "$TARGET_METADATA" >/dev/null || fail "target metadata is not valid JSON"

current_schema="$(field '.schema_version' "$CURRENT_METADATA")"
target_schema="$(field '.schema_version' "$TARGET_METADATA")"
[[ "$current_schema" == "monarch-os-release-metadata/v1" ]] \
  || fail "current metadata schema unsupported: $current_schema"
[[ "$target_schema" == "monarch-os-release-metadata/v1" ]] \
  || fail "target metadata schema unsupported: $target_schema"

current_channel="$(field '.channel.name' "$CURRENT_METADATA")"
target_channel="$(field '.channel.name' "$TARGET_METADATA")"
current_profile="$(field '.channel.chain.profile' "$CURRENT_METADATA")"
target_profile="$(field '.channel.chain.profile' "$TARGET_METADATA")"
current_chain_id="$(field '.channel.chain.chain_id' "$CURRENT_METADATA")"
target_chain_id="$(field '.channel.chain.chain_id' "$TARGET_METADATA")"
current_genesis_sha="$(field '.channel.chain.genesis.sha256' "$CURRENT_METADATA")"
target_genesis_sha="$(field '.channel.chain.genesis.sha256' "$TARGET_METADATA")"
target_protocore_version="$(field '.channel.compatibility.protocore.version' "$TARGET_METADATA")"
target_desktop_channel="$(field '.channel.compatibility.monarch_desktop.channel' "$TARGET_METADATA")"
target_desktop_min="$(field '.channel.compatibility.monarch_desktop.min_version' "$TARGET_METADATA")"
target_desktop_max="$(field '.channel.compatibility.monarch_desktop.max_version' "$TARGET_METADATA")"
target_kernel_baseline_schema="$(field '.substrate.kernel_hardening_baseline.schema' "$TARGET_METADATA")"
target_kernel_baseline_sha="$(field '.substrate.kernel_hardening_baseline.sha256' "$TARGET_METADATA")"
current_requires_same_channel="$(bool_field '.channel.upgrade.requires_same_channel' "$CURRENT_METADATA")"
target_requires_same_channel="$(bool_field '.channel.upgrade.requires_same_channel' "$TARGET_METADATA")"
target_migration_required="$(bool_field '.channel.upgrade.state_migration.required' "$TARGET_METADATA")"
target_migration_mode="$(field '.channel.upgrade.state_migration.mode' "$TARGET_METADATA")"
target_migration_runbook="$(field '.channel.upgrade.state_migration.runbook_id' "$TARGET_METADATA")"
target_rollback_supported="$(bool_field '.channel.upgrade.rollback.supported' "$TARGET_METADATA")"
target_rollback_blocks_one_way="$(bool_field '.channel.upgrade.rollback.blocked_when_state_migration_one_way' "$TARGET_METADATA")"

[[ -n "$current_channel" ]] || fail "current metadata lacks channel.name"
[[ -n "$target_channel" ]] || fail "target metadata lacks channel.name"
[[ -n "$current_profile" && -n "$target_profile" ]] || fail "metadata lacks chain profile"
[[ -n "$current_chain_id" && -n "$target_chain_id" ]] || fail "metadata lacks chain id"

if [[ "$current_requires_same_channel" == "true" || "$target_requires_same_channel" == "true" ]]; then
  [[ "$current_channel" == "$target_channel" ]] \
    || fail "same-channel upgrade required: current=$current_channel target=$target_channel"
fi

[[ "$current_profile" == "$target_profile" ]] \
  || fail "chain profile mismatch: current=$current_profile target=$target_profile"
[[ "$current_chain_id" == "$target_chain_id" ]] \
  || fail "chain id mismatch: current=$current_chain_id target=$target_chain_id"

if [[ "$current_genesis_sha" != "$target_genesis_sha" && "$ALLOW_GENESIS_CHANGE" != "true" ]]; then
  fail "genesis sha changed; set ALLOW_GENESIS_CHANGE=true only for a staged chain upgrade"
fi

[[ -n "$target_protocore_version" && "$target_protocore_version" != "unknown" ]] \
  || fail "target metadata lacks concrete protocore version"
[[ -n "$target_desktop_channel" ]] || fail "target metadata lacks Desktop channel"
[[ -n "$target_desktop_min" ]] || fail "target metadata lacks Desktop minimum version"
[[ -n "$target_desktop_max" ]] || fail "target metadata lacks Desktop maximum version"
case "$target_migration_mode" in
  none|backward-compatible|one-way) ;;
  "") fail "target metadata lacks state migration policy" ;;
  *) fail "target metadata has invalid state migration mode: $target_migration_mode" ;;
esac
if [[ "$target_migration_required" == "false" ]]; then
  [[ "$target_migration_mode" == "none" ]] \
    || fail "target state migration mode must be none when migration is not required"
else
  [[ "$target_migration_mode" != "none" ]] \
    || fail "target state migration is required but mode is none"
fi
if [[ "$target_migration_required" == "true" || "$target_migration_mode" == "one-way" ]]; then
  [[ "$ALLOW_STATE_MIGRATION" == "true" ]] \
    || fail "target requires a state migration; set ALLOW_STATE_MIGRATION=true only for a staged operator event"
  [[ -n "$target_migration_runbook" ]] \
    || fail "target state migration requires a runbook id"
  jq -e '
    .channel.upgrade.state_migration.backup_required_before_migration == true
    and .channel.upgrade.state_migration.disaster_recovery_manifest_required == true
    and .channel.upgrade.state_migration.operator_approval_required == true
  ' "$TARGET_METADATA" >/dev/null || fail "target state migration must require backup, DR manifest, and operator approval"
fi
if [[ "$target_migration_mode" == "one-way" ]]; then
  [[ "$target_rollback_blocks_one_way" == "true" ]] \
    || fail "target one-way migration must explicitly block rollback"
fi
if [[ "$target_rollback_supported" != "true" && "$ALLOW_STATE_MIGRATION" != "true" ]]; then
  fail "target rollback is not supported; set ALLOW_STATE_MIGRATION=true only for a staged operator event"
fi

[[ "$(bool_field '.substrate.no_ssh_server' "$TARGET_METADATA")" == "true" ]] \
  || fail "target substrate policy does not assert no SSH server"
[[ "$(bool_field '.substrate.no_package_manager' "$TARGET_METADATA")" == "true" ]] \
  || fail "target substrate policy does not assert no package manager"
[[ "$(bool_field '.substrate.no_interactive_shell' "$TARGET_METADATA")" == "true" ]] \
  || fail "target substrate policy does not assert no interactive shell"
[[ "$target_kernel_baseline_schema" == "monarch-os-kernel-hardening-baseline/v1" ]] \
  || fail "target metadata lacks supported kernel hardening baseline"
[[ "$target_kernel_baseline_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "target metadata lacks kernel hardening baseline sha256"
[[ "$(field '.network_policy.protocore_rpc.listen' "$TARGET_METADATA")" == "0.0.0.0:8545" ]] \
  || fail "target RPC listener policy mismatch"
[[ "$(field '.network_policy.protocore_p2p.listen' "$TARGET_METADATA")" == "/ip4/0.0.0.0/tcp/29898" ]] \
  || fail "target P2P listener policy mismatch"
[[ "$(bool_field '.provisioning_policy.no_default_secrets' "$TARGET_METADATA")" == "true" ]] \
  || fail "target provisioning policy does not assert no default secrets"
[[ "$(bool_field '.provisioning_policy.inline_secret_env_prohibited' "$TARGET_METADATA")" == "true" ]] \
  || fail "target provisioning policy does not prohibit inline secret env"

artifact_present "$TARGET_METADATA" '^monarch-os-talos-.*\.raw\.xz$' \
  || fail "target metadata lacks raw.xz artifact"
artifact_present "$TARGET_METADATA" '^monarch-protocore-.*\.tar$' \
  || fail "target metadata lacks monarch-protocore extension artifact"

if [[ "$ALLOW_DIRTY_RELEASE" != "true" ]]; then
  [[ "$(bool_field '.sources.monarch_os_talos.dirty' "$TARGET_METADATA")" == "false" ]] \
    || fail "target monarch-os-talos source is dirty"
  [[ "$(bool_field '.sources.mono_core.dirty' "$TARGET_METADATA")" == "false" ]] \
    || fail "target mono-core source is dirty"
fi

jq -n \
  --arg current_channel "$current_channel" \
  --arg target_channel "$target_channel" \
  --arg chain_profile "$target_profile" \
  --arg chain_id "$target_chain_id" \
  --arg protocore_version "$target_protocore_version" \
  --arg desktop_channel "$target_desktop_channel" \
  --arg desktop_min "$target_desktop_min" \
  --arg desktop_max "$target_desktop_max" \
  --arg kernel_baseline "$target_kernel_baseline_sha" \
  --arg migration_mode "$target_migration_mode" \
  --argjson migration_required "$target_migration_required" \
  --argjson rollback_supported "$target_rollback_supported" \
  '{
    ok: true,
    current_channel: $current_channel,
    target_channel: $target_channel,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    target: {
      protocore_version: $protocore_version,
      monarch_desktop: {
        channel: $desktop_channel,
        min_version: $desktop_min,
        max_version: $desktop_max
      },
      kernel_hardening_baseline_sha256: $kernel_baseline,
      state_migration: {
        required: $migration_required,
        mode: $migration_mode
      },
      rollback_supported: $rollback_supported
    }
  }'
