#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CURRENT_METADATA="${FLEET_CURRENT_METADATA:-${UPGRADE_CURRENT_METADATA:-${1:-}}}"
TARGET_METADATA="${FLEET_TARGET_METADATA:-${UPGRADE_TARGET_METADATA:-${2:-}}}"
FLEET_MANIFEST="${FLEET_MANIFEST:-${3:-}}"
UPGRADE_IMAGE_REF="${UPGRADE_IMAGE_REF:-${4:-}}"
FLEET_PLAN_OUTPUT="${FLEET_PLAN_OUTPUT:-}"
UPGRADE_STAGE="${UPGRADE_STAGE:-false}"
UPGRADE_REBOOT_MODE="${UPGRADE_REBOOT_MODE:-default}"
TALOSCONFIG_FILE="${TALOSCONFIG_FILE:-}"
ALLOW_GENESIS_CHANGE="${ALLOW_GENESIS_CHANGE:-false}"
ALLOW_STATE_MIGRATION="${ALLOW_STATE_MIGRATION:-false}"
ALLOW_DIRTY_RELEASE="${ALLOW_DIRTY_RELEASE:-false}"
ALLOW_SIGNING_QUORUM_RISK="${ALLOW_SIGNING_QUORUM_RISK:-false}"
DISASTER_RECOVERY="${DISASTER_RECOVERY:-}"
REQUIRE_ON_CHAIN_RECOVERY="${REQUIRE_ON_CHAIN_RECOVERY:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "fleet-upgrade-plan: $*" >&2
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

validate_image_ref() {
  local ref="$1"
  local image_name tag
  [[ -n "$ref" ]] || fail "UPGRADE_IMAGE_REF or fourth argument is required"
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

[[ -n "$CURRENT_METADATA" ]] || fail "FLEET_CURRENT_METADATA, UPGRADE_CURRENT_METADATA, or first argument is required"
[[ -n "$TARGET_METADATA" ]] || fail "FLEET_TARGET_METADATA, UPGRADE_TARGET_METADATA, or second argument is required"
[[ -n "$FLEET_MANIFEST" ]] || fail "FLEET_MANIFEST or third argument is required"
[[ -f "$CURRENT_METADATA" ]] || fail "current metadata not found: $CURRENT_METADATA"
[[ -f "$TARGET_METADATA" ]] || fail "target metadata not found: $TARGET_METADATA"
[[ -f "$FLEET_MANIFEST" ]] || fail "fleet manifest not found: $FLEET_MANIFEST"

jq -e . "$FLEET_MANIFEST" >/dev/null || fail "fleet manifest is not valid JSON"
fleet_schema="$(field '.schema_version' "$FLEET_MANIFEST")"
[[ "$fleet_schema" == "monarch-talos-fleet-upgrade-manifest/v1" ]] \
  || fail "unsupported fleet manifest schema: $fleet_schema"

stage_json="$(bool_json "$UPGRADE_STAGE" UPGRADE_STAGE)"
allow_quorum_risk_json="$(bool_json "$ALLOW_SIGNING_QUORUM_RISK" ALLOW_SIGNING_QUORUM_RISK)"
case "$UPGRADE_REBOOT_MODE" in
  default|powercycle) ;;
  *) fail "UPGRADE_REBOOT_MODE must be default or powercycle: $UPGRADE_REBOOT_MODE" ;;
esac
image_ref_kind="$(validate_image_ref "$UPGRADE_IMAGE_REF")"

node_count="$(jq -r '.nodes | length' "$FLEET_MANIFEST")"
(( node_count > 0 )) || fail "fleet manifest must include at least one node"

max_unavailable="$(jq -r '.fleet.max_unavailable // 1' "$FLEET_MANIFEST")"
canary_count="$(jq -r '.fleet.canary_count // 1' "$FLEET_MANIFEST")"
operator_quorum="$(jq -r '.fleet.operator_signing_quorum // 7' "$FLEET_MANIFEST")"

[[ "$max_unavailable" =~ ^[1-9][0-9]*$ ]] \
  || fail "fleet.max_unavailable must be a positive integer"
[[ "$canary_count" =~ ^[0-9]+$ ]] \
  || fail "fleet.canary_count must be a non-negative integer"
[[ "$operator_quorum" =~ ^[1-9][0-9]*$ ]] \
  || fail "fleet.operator_signing_quorum must be a positive integer"
(( max_unavailable <= node_count )) \
  || fail "fleet.max_unavailable cannot exceed node count"
if (( canary_count > 0 )); then
  (( canary_count <= max_unavailable )) \
    || fail "fleet.canary_count cannot exceed fleet.max_unavailable"
  if (( node_count > 1 )); then
    (( canary_count < node_count )) \
      || fail "fleet.canary_count must leave at least one rolling wave"
  fi
fi

jq -e '
  def nonempty_string: type == "string" and length > 0 and (test("\\s") | not);
  .nodes | type == "array" and length > 0
  and all(.[]?;
    (.node_id | nonempty_string)
    and (.role | IN("operator-signing", "archive", "rpc", "bridge", "full"))
    and (.talos_node | nonempty_string)
    and (.talos_endpoint | nonempty_string)
    and (
      .role != "operator-signing"
      or (
        (.cluster_id | nonempty_string)
        and (.operator_index | type == "number" and . >= 0 and . <= 9)
        and (.cluster_position | IN("active", "standby"))
      )
    )
  )
' "$FLEET_MANIFEST" >/dev/null || fail "fleet nodes must have unique ids, roles, Talos endpoints, and operator metadata for signing nodes"

jq -e '
  . as $root
  | ($root.nodes | map(.node_id) | unique | length) == ($root.nodes | length)
  and ($root.nodes | map(.talos_node) | unique | length) == ($root.nodes | length)
  and (
    [$root.nodes[] | select(.role == "operator-signing") | .operator_index] as $idx
    | ($idx | unique | length) == ($idx | length)
  )
  and (
    if $root | has("waves") then
      ($root.waves | type == "array" and length > 0)
      and all($root.waves[]; (.node_ids | type == "array" and length > 0))
      and (
        [$root.waves[]?.node_ids[]?] as $ids
        | ($ids | length) == ($root.nodes | length)
        and ($ids | unique | length) == ($ids | length)
        and all($ids[]; . as $id | any($root.nodes[]; .node_id == $id))
      )
    else
      true
    end
  )
' "$FLEET_MANIFEST" >/dev/null || fail "fleet manifest has duplicate nodes or an invalid explicit wave list"

readiness_json="$(
  ALLOW_GENESIS_CHANGE="$ALLOW_GENESIS_CHANGE" \
  ALLOW_STATE_MIGRATION="$ALLOW_STATE_MIGRATION" \
  ALLOW_DIRTY_RELEASE="$ALLOW_DIRTY_RELEASE" \
  "$ROOT_DIR/scripts/check-upgrade-readiness.sh" "$CURRENT_METADATA" "$TARGET_METADATA"
)"

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

waves_json="$(jq -c \
  --argjson max_unavailable "$max_unavailable" \
  --argjson canary_count "$canary_count" \
  '
    def batch($n): [range(0; length; $n) as $i | .[$i:($i + $n)]];
    def node_by_id($root; $id): $root.nodes[] | select(.node_id == $id);
    . as $root
    | if $root | has("waves") then
        [
          $root.waves
          | to_entries[]
          | {
              wave: (.key + 1),
              id: (.value.id // ("wave-" + ((.key + 1) | tostring))),
              kind: (.value.kind // (if .key == 0 then "canary" else "rolling" end)),
              nodes: [.value.node_ids[] as $id | node_by_id($root; $id)]
            }
        ]
      else
        $root.nodes as $nodes
        | (
            (if $canary_count > 0 then
              [{wave: 1, id: "canary", kind: "canary", nodes: $nodes[0:$canary_count]}]
            else
              []
            end)
            + (
              $nodes[$canary_count:]
              | batch($max_unavailable)
              | to_entries
              | map({
                  wave: (.key + (if $canary_count > 0 then 2 else 1 end)),
                  id: ("wave-" + ((.key + (if $canary_count > 0 then 2 else 1 end)) | tostring)),
                  kind: "rolling",
                  nodes: .value
                })
            )
          )
      end
  ' "$FLEET_MANIFEST")"

jq -e --argjson max_unavailable "$max_unavailable" '
  all(.[]; (.nodes | length) > 0 and (.nodes | length) <= $max_unavailable)
' <<<"$waves_json" >/dev/null || fail "each wave must contain 1..fleet.max_unavailable nodes"

active_signing_count="$(jq -r '[.nodes[] | select(.role == "operator-signing" and .cluster_position == "active")] | length' "$FLEET_MANIFEST")"
quorum_waves_json="$(jq -c \
  --argjson active_signing_count "$active_signing_count" \
  --argjson operator_quorum "$operator_quorum" \
  '
    map(
      ([.nodes[] | select(.role == "operator-signing" and .cluster_position == "active")] | length) as $active_in_wave
      | {
          wave,
          id,
          active_operator_signing_unavailable: $active_in_wave,
          active_operator_signing_remaining: ($active_signing_count - $active_in_wave),
          operator_signing_quorum: $operator_quorum,
          quorum_preserved: (($active_signing_count - $active_in_wave) >= $operator_quorum)
        }
    )
  ' <<<"$waves_json")"

unsafe_quorum_waves="$(jq -r '[.[] | select(.quorum_preserved == false)] | length' <<<"$quorum_waves_json")"
if (( active_signing_count > 0 && unsafe_quorum_waves > 0 )) && [[ "$allow_quorum_risk_json" != "true" ]]; then
  first_unsafe="$(jq -r '[.[] | select(.quorum_preserved == false)][0] | "\(.id) would leave \(.active_operator_signing_remaining) active signing nodes below quorum \(.operator_signing_quorum)"' <<<"$quorum_waves_json")"
  fail "fleet rollout would reduce signing capacity below quorum: $first_unsafe"
fi

current_metadata_sha="$(file_sha256 "$CURRENT_METADATA")"
target_metadata_sha="$(file_sha256 "$TARGET_METADATA")"
fleet_manifest_sha="$(file_sha256 "$FLEET_MANIFEST")"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fleet_id="$(field '.fleet.id' "$FLEET_MANIFEST")"
fleet_id="${fleet_id:-monarch-fleet}"
raw_artifact="$(jq -c '[.artifacts[]? | select(.path | test("^monarch-os-talos-.*\\.raw\\.xz$"))][0] // null' "$TARGET_METADATA")"
extension_artifact="$(jq -c '[.artifacts[]? | select(.path | test("^monarch-protocore-.*\\.tar$"))][0] // null' "$TARGET_METADATA")"

plan_json="$(jq -n \
  --arg generated_at "$generated_at" \
  --arg current_metadata "$CURRENT_METADATA" \
  --arg current_metadata_sha "$current_metadata_sha" \
  --arg target_metadata "$TARGET_METADATA" \
  --arg target_metadata_sha "$target_metadata_sha" \
  --arg fleet_manifest "$FLEET_MANIFEST" \
  --arg fleet_manifest_sha "$fleet_manifest_sha" \
  --arg fleet_id "$fleet_id" \
  --arg image_ref "$UPGRADE_IMAGE_REF" \
  --arg image_ref_kind "$image_ref_kind" \
  --arg reboot_mode "$UPGRADE_REBOOT_MODE" \
  --arg talosconfig "$TALOSCONFIG_FILE" \
  --arg target_profile "$target_profile" \
  --arg target_chain_id "$target_chain_id" \
  --arg state_migration_mode "$target_migration_mode" \
  --arg state_migration_runbook "$target_state_runbook" \
  --argjson readiness "$readiness_json" \
  --argjson raw_artifact "$raw_artifact" \
  --argjson extension_artifact "$extension_artifact" \
  --argjson stage "$stage_json" \
  --argjson node_count "$node_count" \
  --argjson max_unavailable "$max_unavailable" \
  --argjson canary_count "$canary_count" \
  --argjson active_signing_count "$active_signing_count" \
  --argjson operator_quorum "$operator_quorum" \
  --argjson allow_quorum_risk "$allow_quorum_risk_json" \
  --argjson quorum_waves "$quorum_waves_json" \
  --argjson waves "$waves_json" \
  --argjson migration_required "$target_migration_required" \
  --argjson rollback_supported "$target_rollback_supported" \
  --argjson rollback_blocks_one_way "$target_rollback_blocks_one_way" \
  --argjson backup_required "$target_backup_required" \
  --argjson dr_required_by_metadata "$target_dr_required_by_metadata" \
  --argjson operator_approval_required "$target_operator_approval_required" \
  --argjson dr_required "$dr_required" \
  --argjson dr_validated "$dr_validated" \
  --argjson dr_report "$dr_report" \
  '{
    schema_version: "monarch-talos-fleet-upgrade-plan/v1",
    generated_at: $generated_at,
    ok: true,
    dry_run: true,
    inputs: {
      current_metadata: {path: $current_metadata, sha256: $current_metadata_sha},
      target_metadata: {path: $target_metadata, sha256: $target_metadata_sha},
      fleet_manifest: {path: $fleet_manifest, sha256: $fleet_manifest_sha}
    },
    fleet: {
      id: $fleet_id,
      node_count: $node_count,
      max_unavailable: $max_unavailable,
      canary_count: $canary_count,
      active_operator_signing_nodes: $active_signing_count,
      operator_signing_quorum: $operator_quorum
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
    upgrade: {
      image_ref: $image_ref,
      image_ref_kind: $image_ref_kind,
      talos_api_request_template: {
        method: "machine.Upgrade",
        image: $image_ref,
        preserve: true,
        stage: $stage,
        force: false,
        reboot_mode: $reboot_mode
      },
      desktop_operation_template: {
        kind: "ota-apply",
        input: {
          image: $image_ref,
          stage: $stage,
          rebootMode: $reboot_mode
        }
      }
    },
    rollout: {
      strategy: "canary-then-rolling",
      waves: [
        $waves[] as $wave
        | ($quorum_waves[] | select(.wave == $wave.wave)) as $quorum
        | {
            wave: $wave.wave,
            id: $wave.id,
            kind: $wave.kind,
            max_unavailable: $max_unavailable,
            concurrency: ($wave.nodes | length),
            signing_quorum: $quorum,
            nodes: [
              $wave.nodes[] as $node
              | (($node.talosconfig // $talosconfig) // "") as $node_talosconfig
              | {
                  node_id: $node.node_id,
                  role: $node.role,
                  cluster_id: ($node.cluster_id // null),
                  operator_index: ($node.operator_index // null),
                  cluster_position: ($node.cluster_position // null),
                  talos_context: {
                    node: $node.talos_node,
                    endpoint: $node.talos_endpoint,
                    talosconfig: (if $node_talosconfig == "" then null else $node_talosconfig end)
                  },
                  upgrade: {
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
                      nodeId: $node.node_id,
                      input: {
                        image: $image_ref,
                        stage: $stage,
                        rebootMode: $reboot_mode
                      }
                    },
                    talosctl_argv: (
                      ["talosctl", "upgrade"]
                      + (if $node_talosconfig == "" then [] else ["--talosconfig", $node_talosconfig] end)
                      + ["--nodes", $node.talos_node, "--endpoints", $node.talos_endpoint, "--image", $image_ref]
                      + (if $reboot_mode == "powercycle" then ["--reboot-mode", "powercycle"] else [] end)
                    )
                  },
                  rollback: {
                    talos_api_request: {method: "machine.Rollback"},
                    desktop_operation: {kind: "ota-rollback", nodeId: $node.node_id},
                    talosctl_argv: (
                      ["talosctl", "rollback"]
                      + (if $node_talosconfig == "" then [] else ["--talosconfig", $node_talosconfig] end)
                      + ["--nodes", $node.talos_node, "--endpoints", $node.talos_endpoint]
                    )
                  },
                  post_upgrade_health_gates: [
                    "talos-api-reachable",
                    "ext-protocore-service-queried",
                    "protocore-rpc-healthy",
                    "release-digest-match",
                    "chain-id-match",
                    "genesis-match"
                  ]
                }
            ]
          }
      ]
    },
    gates: {
      readiness: $readiness,
      signing_quorum: {
        enforced: ($active_signing_count > 0 and ($allow_quorum_risk | not)),
        allow_risk_override: $allow_quorum_risk,
        safe: (all($quorum_waves[]; .quorum_preserved == true)),
        waves: $quorum_waves
      },
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

if [[ -n "$FLEET_PLAN_OUTPUT" ]]; then
  mkdir -p "$(dirname "$FLEET_PLAN_OUTPUT")"
  printf '%s\n' "$plan_json" > "$FLEET_PLAN_OUTPUT"
  printf '%s\n' "$FLEET_PLAN_OUTPUT"
else
  printf '%s\n' "$plan_json"
fi
