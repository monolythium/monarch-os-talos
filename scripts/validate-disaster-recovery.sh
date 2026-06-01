#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${DISASTER_RECOVERY:-${1:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_ON_CHAIN_RECOVERY="${REQUIRE_ON_CHAIN_RECOVERY:-false}"
NODE_REGISTRY_EXECUTOR_CONTRACT="0x0000000000000000000000000000000000001005"
RECOVER_OPERATOR_NODE_SELECTOR="0xe58729e6"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "disaster-recovery: $*" >&2
  exit 1
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$MANIFEST"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 32-byte hex digest"
}

validate_tx_hash() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 0x-prefixed 32-byte transaction hash"
}

hex_no_prefix_lower() {
  local value="$1"
  value="${value#0x}"
  value="${value#0X}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

sha256_hex_bytes() {
  local hex="$1"
  printf '%s' "$hex" | xxd -r -p | sha256sum | awk '{print $1}'
}

need jq

[[ -n "$MANIFEST" ]] || fail "DISASTER_RECOVERY or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

schema="$(field '.schema_version')"
recovery_type="$(field '.recovery.type')"
recovery_id="$(field '.recovery.id')"
runbook_id="$(field '.recovery.runbook_id')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
genesis_sha="$(field '.chain.genesis_sha256')"
metadata_sha="$(field '.release.metadata_sha256')"
protocore_digest="$(field '.release.protocore_digest')"
node_role="$(field '.node.role')"
node_id="$(field '.node.node_id')"
backup_mode="$(field '.backup.mode')"
service_state="$(field '.backup.protocore_service_state')"
hot_backup="$(jq -r '.backup.hot_backup // false' "$MANIFEST")"
restore_path="$(field '.restore.restore_path')"
service_stopped="$(jq -r '.restore.service_stopped_before_restore // false' "$MANIFEST")"
resync_from_peers="$(jq -r '.restore.resync_from_peers // false' "$MANIFEST")"

[[ "$schema" == "monarch-disaster-recovery/v1" ]] \
  || fail "unsupported schema_version: $schema"
case "$recovery_type" in
  resync|offline-restore|disk-replacement|signing-node-reseal) ;;
  *) fail "recovery.type must be resync, offline-restore, disk-replacement, or signing-node-reseal: $recovery_type" ;;
esac
[[ -n "$recovery_id" ]] || fail "recovery.id is required"
[[ -n "$runbook_id" ]] || fail "recovery.runbook_id is required"
[[ -n "$chain_profile" ]] || fail "chain.profile is required"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "chain.chain_id must be numeric: $chain_id"
[[ -n "$node_id" ]] || fail "node.node_id is required"
case "$node_role" in
  archive|operator-signing|rpc|bridge) ;;
  *) fail "node.role must be archive, operator-signing, rpc, or bridge: $node_role" ;;
esac

if [[ -n "$EXPECTED_CHAIN_PROFILE" ]]; then
  [[ "$chain_profile" == "$EXPECTED_CHAIN_PROFILE" ]] \
    || fail "chain profile mismatch: expected=$EXPECTED_CHAIN_PROFILE actual=$chain_profile"
fi
if [[ -n "$EXPECTED_CHAIN_ID" ]]; then
  [[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] \
    || fail "chain id mismatch: expected=$EXPECTED_CHAIN_ID actual=$chain_id"
fi

if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$MANIFEST" >/dev/null; then
  fail "manifest contains placeholder string values"
fi

validate_hash32 "chain.genesis_sha256" "$genesis_sha"
validate_hash32 "release.metadata_sha256" "$metadata_sha"
validate_hash32 "release.protocore_digest" "$protocore_digest"

case "$backup_mode" in
  resync|offline-snapshot|stopped-protocore-archive) ;;
  *) fail "backup.mode must be resync, offline-snapshot, or stopped-protocore-archive: $backup_mode" ;;
esac
case "$service_state" in
  not-applicable|stopped|offline) ;;
  *) fail "backup.protocore_service_state must be not-applicable, stopped, or offline: $service_state" ;;
esac
[[ "$hot_backup" == "false" ]] || fail "hot backups are not accepted for disaster recovery"
[[ "$restore_path" == "/var/lib/protocore" ]] \
  || fail "restore.restore_path must be /var/lib/protocore"

if [[ "$backup_mode" == "resync" || "$recovery_type" == "resync" ]]; then
  [[ "$backup_mode" == "resync" ]] || fail "resync recovery must use backup.mode=resync"
  [[ "$service_state" == "not-applicable" ]] \
    || fail "resync recovery must use backup.protocore_service_state=not-applicable"
  [[ "$resync_from_peers" == "true" ]] \
    || fail "resync recovery must set restore.resync_from_peers=true"
else
  [[ "$service_state" == "stopped" || "$service_state" == "offline" ]] \
    || fail "data restore requires a stopped or offline protocore backup"
  [[ "$service_stopped" == "true" ]] \
    || fail "restore.service_stopped_before_restore must be true for data restore"
  validate_hash32 "backup.var_lib_protocore_sha256" "$(field '.backup.var_lib_protocore_sha256')"
  validate_hash32 "backup.manifest_sha256" "$(field '.backup.manifest_sha256')"
  [[ -n "$(field '.backup.storage_uri')" || -n "$(field '.backup.snapshot_id')" ]] \
    || fail "data restore requires backup.storage_uri or backup.snapshot_id"
fi

for check in release-digest-match genesis-match chain-id-match protocore-rpc-healthy; do
  jq -e --arg check "$check" '.restore.post_restore_checks | index($check)' "$MANIFEST" >/dev/null \
    || fail "restore.post_restore_checks must include $check"
done

approval_count="$(jq -r '[.approvals[]?.address] | unique | length' "$MANIFEST")"
(( approval_count >= 1 )) || fail "approvals must include at least one signer"
jq -e '
  all(.approvals[]?;
    .signature_scheme == "ML-DSA-65"
    and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$"))
  )
' "$MANIFEST" >/dev/null || fail "approvals must use ML-DSA-65 signatures and signed payload hashes"

key_share_present="$(jq -r 'has("key_share_recovery")' "$MANIFEST")"
if [[ "$node_role" == "operator-signing" || "$recovery_type" == "signing-node-reseal" ]]; then
  [[ "$key_share_present" == "true" ]] \
    || fail "operator-signing recovery requires key_share_recovery evidence"
  validate_hash32 "key_share_recovery.ceremony_manifest_sha256" "$(field '.key_share_recovery.ceremony_manifest_sha256')"
  validate_hash32 "key_share_recovery.sealed_share_sha256" "$(field '.key_share_recovery.sealed_share_sha256')"
  validate_hash32 "key_share_recovery.dkg_transcript_hash" "$(field '.key_share_recovery.dkg_transcript_hash')"
  key_share_approvals="$(field '.key_share_recovery.approval_count')"
  [[ "$key_share_approvals" =~ ^[0-9]+$ && "$key_share_approvals" -ge 7 ]] \
    || fail "key_share_recovery.approval_count must be at least 7"
  (( approval_count >= 7 )) \
    || fail "operator-signing recovery approvals must include at least 7 unique signers"
  jq -e '.restore.post_restore_checks | index("no-double-sign-window") and index("key-share-resealed")' "$MANIFEST" >/dev/null \
    || fail "operator-signing recovery must check no-double-sign-window and key-share-resealed"
fi

on_chain_present="$(jq -r 'has("on_chain_recovery")' "$MANIFEST")"
if [[ "$on_chain_present" == "true" ]]; then
  need sha256sum
  need xxd
  executor_contract="$(field '.on_chain_recovery.executor_contract')"
  function_selector="$(field '.on_chain_recovery.function_selector')"
  operator_peer_id="$(field '.on_chain_recovery.operator_peer_id')"
  calldata_hash="$(field '.on_chain_recovery.calldata_hash')"

  validate_tx_hash "on_chain_recovery.tx_hash" "$(field '.on_chain_recovery.tx_hash')"
  validate_hash32 "on_chain_recovery.quorum_certificate_hash" "$(field '.on_chain_recovery.quorum_certificate_hash')"
  [[ "$executor_contract" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "on_chain_recovery.executor_contract must be a 0x-prefixed 20-byte address"
  [[ "$(hex_no_prefix_lower "$executor_contract")" == "$(hex_no_prefix_lower "$NODE_REGISTRY_EXECUTOR_CONTRACT")" ]] \
    || fail "on_chain_recovery.executor_contract must be node-registry $NODE_REGISTRY_EXECUTOR_CONTRACT"
  [[ "$(field '.on_chain_recovery.executor_method')" == "recoverOperatorNode" ]] \
    || fail "on_chain_recovery.executor_method must be recoverOperatorNode"
  [[ "$function_selector" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "on_chain_recovery.function_selector must be a 4-byte selector"
  [[ "$(hex_no_prefix_lower "$function_selector")" == "$(hex_no_prefix_lower "$RECOVER_OPERATOR_NODE_SELECTOR")" ]] \
    || fail "on_chain_recovery.function_selector must be $RECOVER_OPERATOR_NODE_SELECTOR"
  validate_hash32 "on_chain_recovery.operator_peer_id" "$operator_peer_id"
  validate_hash32 "on_chain_recovery.calldata_hash" "$calldata_hash"
  expected_calldata_hash="$(
    sha256_hex_bytes "$(hex_no_prefix_lower "$RECOVER_OPERATOR_NODE_SELECTOR")$(hex_no_prefix_lower "$operator_peer_id")"
  )"
  [[ "$(hex_no_prefix_lower "$calldata_hash")" == "$expected_calldata_hash" ]] \
    || fail "on_chain_recovery.calldata_hash does not match recoverOperatorNode(operator_peer_id)"
  [[ "$(field '.on_chain_recovery.dag_round')" =~ ^[0-9]+$ ]] \
    || fail "on_chain_recovery.dag_round must be numeric"
elif [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_ON_CHAIN_RECOVERY"; then
  fail "mainnet or REQUIRE_ON_CHAIN_RECOVERY disaster recovery must include on_chain_recovery"
fi

jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg recovery_type "$recovery_type" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg node_role "$node_role" \
  --arg backup_mode "$backup_mode" \
  --argjson approval_count "$approval_count" \
  --argjson key_share_checked "$([[ "$key_share_present" == "true" ]] && printf true || printf false)" \
  --argjson on_chain_checked "$([[ "$on_chain_present" == "true" ]] && printf true || printf false)" \
  '{
    ok: true,
    manifest: $manifest,
    recovery_type: $recovery_type,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    node_role: $node_role,
    backup_mode: $backup_mode,
    approval_count: $approval_count,
    key_share_recovery_checked: $key_share_checked,
    on_chain_recovery_checked: $on_chain_checked
  }'
