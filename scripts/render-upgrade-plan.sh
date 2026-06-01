#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CURRENT_METADATA="${UPGRADE_CURRENT_METADATA:-${1:-}}"
TARGET_METADATA="${UPGRADE_TARGET_METADATA:-${2:-}}"
UPGRADE_IMAGE_REF="${UPGRADE_IMAGE_REF:-${3:-}}"
UPGRADE_STAGE="${UPGRADE_STAGE:-false}"
UPGRADE_REBOOT_MODE="${UPGRADE_REBOOT_MODE:-default}"
UPGRADE_PLAN_OUTPUT="${UPGRADE_PLAN_OUTPUT:-}"
TALOS_NODES="${TALOS_NODES:-}"
TALOS_ENDPOINTS="${TALOS_ENDPOINTS:-}"
TALOSCONFIG_FILE="${TALOSCONFIG_FILE:-}"
DISASTER_RECOVERY="${DISASTER_RECOVERY:-}"
REQUIRE_ON_CHAIN_RECOVERY="${REQUIRE_ON_CHAIN_RECOVERY:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "upgrade-plan: $*" >&2
  exit 1
}

bool_json() {
  case "$1" in
    true|TRUE|1|yes|YES) printf 'true' ;;
    false|FALSE|0|no|NO|"") printf 'false' ;;
    *) fail "$2 must be true or false: $1" ;;
  esac
}

field() {
  local path="$1"
  local file="$2"
  jq -r "$path // \"\"" "$file"
}

file_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

csv_json() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | jq -R -s 'split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

shell_join() {
  local out="" arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out="${out:+$out }$quoted"
  done
  printf '%s' "$out"
}

validate_image_ref() {
  local ref="$1"
  local image_name tag
  [[ -n "$ref" ]] || fail "UPGRADE_IMAGE_REF or third argument is required"
  [[ ! "$ref" =~ [[:space:]] ]] || fail "UPGRADE_IMAGE_REF must not contain whitespace"

  if [[ "$ref" =~ @sha256:[0-9a-fA-F]{64}$ ]]; then
    printf 'digest'
    return
  fi

  image_name="${ref##*/}"
  if [[ "$image_name" =~ :([A-Za-z0-9][A-Za-z0-9_.-]{0,127})$ ]]; then
    tag="${BASH_REMATCH[1]}"
    [[ "$tag" != "latest" ]] || fail "UPGRADE_IMAGE_REF must not use the mutable latest tag"
    printf 'tag'
    return
  fi

  fail "UPGRADE_IMAGE_REF must be a tagged or sha256-digested registry image reference"
}

need date
need jq
need sha256sum

[[ -n "$CURRENT_METADATA" ]] || fail "UPGRADE_CURRENT_METADATA or first argument is required"
[[ -n "$TARGET_METADATA" ]] || fail "UPGRADE_TARGET_METADATA or second argument is required"
[[ -f "$CURRENT_METADATA" ]] || fail "current metadata not found: $CURRENT_METADATA"
[[ -f "$TARGET_METADATA" ]] || fail "target metadata not found: $TARGET_METADATA"

stage_json="$(bool_json "$UPGRADE_STAGE" UPGRADE_STAGE)"
case "$UPGRADE_REBOOT_MODE" in
  default|powercycle) ;;
  *) fail "UPGRADE_REBOOT_MODE must be default or powercycle: $UPGRADE_REBOOT_MODE" ;;
esac
image_ref_kind="$(validate_image_ref "$UPGRADE_IMAGE_REF")"

readiness_json="$("$ROOT_DIR/scripts/check-upgrade-readiness.sh" "$CURRENT_METADATA" "$TARGET_METADATA")"

target_profile="$(field '.channel.chain.profile' "$TARGET_METADATA")"
target_chain_id="$(field '.channel.chain.chain_id' "$TARGET_METADATA")"
target_migration_required="$(jq -r '.channel.upgrade.state_migration.required // false' "$TARGET_METADATA")"
target_migration_mode="$(field '.channel.upgrade.state_migration.mode' "$TARGET_METADATA")"
target_rollback_supported="$(jq -r '.channel.upgrade.rollback.supported // false' "$TARGET_METADATA")"
target_rollback_blocks_one_way="$(jq -r '.channel.upgrade.rollback.blocked_when_state_migration_one_way // false' "$TARGET_METADATA")"
target_state_runbook="$(field '.channel.upgrade.state_migration.runbook_id' "$TARGET_METADATA")"
target_backup_required="$(jq -r '.channel.upgrade.state_migration.backup_required_before_migration // false' "$TARGET_METADATA")"
target_dr_required_by_metadata="$(jq -r '.channel.upgrade.state_migration.disaster_recovery_manifest_required // false' "$TARGET_METADATA")"
target_operator_approval_required="$(jq -r '.channel.upgrade.state_migration.operator_approval_required // false' "$TARGET_METADATA")"

dr_required=false
if [[ "$target_migration_required" == "true" || "$target_migration_mode" != "none" || "$target_rollback_supported" != "true" ]]; then
  dr_required=true
fi

dr_report='null'
dr_validated=false
if [[ -n "$DISASTER_RECOVERY" ]]; then
  [[ -f "$DISASTER_RECOVERY" ]] || fail "DISASTER_RECOVERY not found: $DISASTER_RECOVERY"
  dr_report="$(EXPECTED_CHAIN_PROFILE="$target_profile" EXPECTED_CHAIN_ID="$target_chain_id" REQUIRE_ON_CHAIN_RECOVERY="$REQUIRE_ON_CHAIN_RECOVERY" \
    "$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$DISASTER_RECOVERY")"
  dr_validated=true
elif [[ "$dr_required" == "true" ]]; then
  fail "target migration or unsupported rollback requires DISASTER_RECOVERY with a validated restore manifest"
fi

current_metadata_sha="$(file_sha256 "$CURRENT_METADATA")"
target_metadata_sha="$(file_sha256 "$TARGET_METADATA")"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
raw_artifact="$(jq -c '[.artifacts[]? | select(.path | test("^monarch-os-talos-.*\\.raw\\.xz$"))][0] // null' "$TARGET_METADATA")"
extension_artifact="$(jq -c '[.artifacts[]? | select(.path | test("^monarch-protocore-.*\\.tar$"))][0] // null' "$TARGET_METADATA")"
nodes_json="$(csv_json "$TALOS_NODES")"
endpoints_json="$(csv_json "$TALOS_ENDPOINTS")"

upgrade_cli_supported=true
upgrade_cli_command=""
if [[ "$stage_json" == "true" ]]; then
  upgrade_cli_supported=false
else
  upgrade_cmd=(talosctl upgrade)
  [[ -n "$TALOSCONFIG_FILE" ]] && upgrade_cmd+=(--talosconfig "$TALOSCONFIG_FILE")
  [[ -n "$TALOS_NODES" ]] && upgrade_cmd+=(--nodes "$TALOS_NODES")
  [[ -n "$TALOS_ENDPOINTS" ]] && upgrade_cmd+=(--endpoints "$TALOS_ENDPOINTS")
  upgrade_cmd+=(--image "$UPGRADE_IMAGE_REF")
  [[ "$UPGRADE_REBOOT_MODE" == "powercycle" ]] && upgrade_cmd+=(--reboot-mode powercycle)
  upgrade_cli_command="$(shell_join "${upgrade_cmd[@]}")"
fi

rollback_cmd=(talosctl rollback)
[[ -n "$TALOSCONFIG_FILE" ]] && rollback_cmd+=(--talosconfig "$TALOSCONFIG_FILE")
[[ -n "$TALOS_NODES" ]] && rollback_cmd+=(--nodes "$TALOS_NODES")
[[ -n "$TALOS_ENDPOINTS" ]] && rollback_cmd+=(--endpoints "$TALOS_ENDPOINTS")
rollback_cli_command="$(shell_join "${rollback_cmd[@]}")"

plan_json="$(jq -n \
  --arg generated_at "$generated_at" \
  --arg current_metadata "$CURRENT_METADATA" \
  --arg current_metadata_sha "$current_metadata_sha" \
  --arg target_metadata "$TARGET_METADATA" \
  --arg target_metadata_sha "$target_metadata_sha" \
  --arg image_ref "$UPGRADE_IMAGE_REF" \
  --arg image_ref_kind "$image_ref_kind" \
  --arg reboot_mode "$UPGRADE_REBOOT_MODE" \
  --arg talosconfig "$TALOSCONFIG_FILE" \
  --arg target_profile "$target_profile" \
  --arg target_chain_id "$target_chain_id" \
  --arg state_migration_mode "$target_migration_mode" \
  --arg state_migration_runbook "$target_state_runbook" \
  --arg upgrade_cli_command "$upgrade_cli_command" \
  --arg rollback_cli_command "$rollback_cli_command" \
  --argjson readiness "$readiness_json" \
  --argjson stage "$stage_json" \
  --argjson raw_artifact "$raw_artifact" \
  --argjson extension_artifact "$extension_artifact" \
  --argjson nodes "$nodes_json" \
  --argjson endpoints "$endpoints_json" \
  --argjson migration_required "$target_migration_required" \
  --argjson rollback_supported "$target_rollback_supported" \
  --argjson rollback_blocks_one_way "$target_rollback_blocks_one_way" \
  --argjson backup_required "$target_backup_required" \
  --argjson dr_required_by_metadata "$target_dr_required_by_metadata" \
  --argjson operator_approval_required "$target_operator_approval_required" \
  --argjson dr_required "$dr_required" \
  --argjson dr_validated "$dr_validated" \
  --argjson dr_report "$dr_report" \
  --argjson upgrade_cli_supported "$upgrade_cli_supported" \
  '{
    schema_version: "monarch-talos-upgrade-plan/v1",
    generated_at: $generated_at,
    ok: true,
    dry_run: true,
    inputs: {
      current_metadata: {path: $current_metadata, sha256: $current_metadata_sha},
      target_metadata: {path: $target_metadata, sha256: $target_metadata_sha}
    },
    target_release: {
      channel: $readiness.target_channel,
      chain: {profile: $target_profile, chain_id: $target_chain_id},
      protocore_version: $readiness.target.protocore_version,
      monarch_desktop: $readiness.target.monarch_desktop,
      kernel_hardening_baseline_sha256: $readiness.target.kernel_hardening_baseline_sha256
    },
    target_artifacts: {
      raw_xz: $raw_artifact,
      protocore_extension: $extension_artifact
    },
    talos_context: {
      nodes: $nodes,
      endpoints: $endpoints,
      talosconfig: (if $talosconfig == "" then null else $talosconfig end)
    },
    upgrade: {
      image_ref: $image_ref,
      image_ref_kind: $image_ref_kind,
      talos_api_request: {
        method: "machine.Upgrade",
        image: $image_ref,
        preserve: true,
        stage: $stage,
        force: false,
        reboot_mode: $reboot_mode
      },
      desktop_operation: {
        kind: "ota-apply",
        input: {
          image: $image_ref,
          stage: $stage,
          rebootMode: $reboot_mode
        }
      },
      talosctl: {
        upgrade_command: (if $upgrade_cli_supported then $upgrade_cli_command else null end),
        stage_supported_by_command: $upgrade_cli_supported,
        note: (if $upgrade_cli_supported then "talosctl command is a dry-run rendering; execute only after operator approval" else "stage=true requires the native Talos Upgrade API path used by Monarch Desktop" end)
      }
    },
    rollback: {
      supported_by_target: $rollback_supported,
      blocked_when_state_migration_one_way: $rollback_blocks_one_way,
      talos_api_request: {method: "machine.Rollback"},
      desktop_operation: {kind: "ota-rollback"},
      talosctl_command: $rollback_cli_command
    },
    gates: {
      readiness: $readiness,
      state_migration: {
        required: $migration_required,
        mode: $state_migration_mode,
        runbook_id: (if $state_migration_runbook == "" then null else $state_migration_runbook end),
        backup_required_before_migration: $backup_required,
        disaster_recovery_manifest_required: $dr_required_by_metadata,
        operator_approval_required: $operator_approval_required
      },
      disaster_recovery: {
        required: $dr_required,
        validated: $dr_validated,
        report: $dr_report
      }
    }
  }')"

if [[ -n "$UPGRADE_PLAN_OUTPUT" ]]; then
  mkdir -p "$(dirname "$UPGRADE_PLAN_OUTPUT")"
  printf '%s\n' "$plan_json" > "$UPGRADE_PLAN_OUTPUT"
  printf '%s\n' "$UPGRADE_PLAN_OUTPUT"
else
  printf '%s\n' "$plan_json"
fi
