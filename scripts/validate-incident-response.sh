#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${INCIDENT_RESPONSE:-${1:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_FOUNDATION_AUTHORIZATION="${REQUIRE_FOUNDATION_AUTHORIZATION:-false}"
REQUIRE_ON_CHAIN_ACTION="${REQUIRE_ON_CHAIN_ACTION:-false}"
NODE_REGISTRY_EXECUTOR_CONTRACT="0x0000000000000000000000000000000000001005"
BRIDGE_EXECUTOR_CONTRACT="0x0000000000000000000000000000000000001008"
FREEZE_ADMISSION_SELECTOR="0x7a2605cd"
PAUSE_BRIDGE_ROUTE_SELECTOR="0x11a2dc64"
ROLLBACK_BRIDGE_SELECTOR="0x059a1b5c"
EMERGENCY_KEY_ROTATION_SELECTOR="0x0aeeafbf"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "incident-response: $*" >&2
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

validate_address() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "$label must be a 0x-prefixed 20-byte contract address"
}

validate_selector() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "$label must be a 0x-prefixed 4-byte function selector"
}

validate_signature() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$ ]] \
    || fail "$label must be a hex or base64 signature"
}

hex_no_prefix_lower() {
  local value="$1"
  value="${value#0x}"
  value="${value#0X}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

executor_method_for_action() {
  case "$1" in
    freeze-admission) echo "freezeAdmission" ;;
    pause-bridge-route) echo "pauseBridgeRoute" ;;
    rollback-bridge) echo "rollbackBridge" ;;
    emergency-key-rotation) echo "emergencyKeyRotation" ;;
    *) echo "" ;;
  esac
}

executor_contract_for_action() {
  case "$1" in
    freeze-admission|emergency-key-rotation) echo "$NODE_REGISTRY_EXECUTOR_CONTRACT" ;;
    pause-bridge-route|rollback-bridge) echo "$BRIDGE_EXECUTOR_CONTRACT" ;;
    *) echo "" ;;
  esac
}

function_selector_for_action() {
  case "$1" in
    freeze-admission) echo "$FREEZE_ADMISSION_SELECTOR" ;;
    pause-bridge-route) echo "$PAUSE_BRIDGE_ROUTE_SELECTOR" ;;
    rollback-bridge) echo "$ROLLBACK_BRIDGE_SELECTOR" ;;
    emergency-key-rotation) echo "$EMERGENCY_KEY_ROTATION_SELECTOR" ;;
    *) echo "" ;;
  esac
}

need jq

[[ -n "$MANIFEST" ]] || fail "INCIDENT_RESPONSE or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

schema="$(field '.schema_version')"
incident_id="$(field '.incident.id')"
incident_type="$(field '.incident.type')"
severity="$(field '.incident.severity')"
status="$(field '.incident.status')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
action="$(field '.response.action')"
scope_type="$(field '.response.scope.scope_type')"
runbook_id="$(field '.runbook.id')"
runbook_schema_hash="$(field '.runbook.schema_hash')"
runbook_payload_hash="$(field '.runbook.signed_payload_hash')"
runbook_signature_scheme="$(field '.runbook.signature_scheme')"
runbook_signature="$(field '.runbook.signature')"
release_metadata_sha="$(field '.evidence.release_metadata_sha256')"

[[ "$schema" == "monarch-incident-response/v1" ]] \
  || fail "unsupported schema_version: $schema"
[[ -n "$incident_id" ]] || fail "incident.id is required"
case "$incident_type" in
  pcr-drift|substrate-proof-failure|talos-ca-mismatch|certificate-expiry|protocore-rpc-down|ext-protocore-crash-loop|network-partition|cryptographic-break|bridge-exploit|adversarial-fork|operator-key-compromise|release-provenance-failure) ;;
  routine-upgrade|parameter-change|protocol-direction|account-censorship|asset-confiscation|ongoing-supervision)
    fail "incident.type is outside the emergency mechanism scope: $incident_type"
    ;;
  *) fail "unsupported incident.type: $incident_type" ;;
esac
case "$severity" in
  low|medium|high|critical) ;;
  *) fail "incident.severity must be low, medium, high, or critical: $severity" ;;
esac
case "$status" in
  detected|triaged|contained|mitigated|postmortem) ;;
  *) fail "incident.status must be detected, triaged, contained, mitigated, or postmortem: $status" ;;
esac
[[ -n "$chain_profile" ]] || fail "chain.profile is required"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "chain.chain_id must be numeric: $chain_id"

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

case "$action" in
  observe|isolate-node|stop-signing|rotate-certs|rotate-operator-key|pause-bridge-route|freeze-admission|emergency-key-rotation|rollback-bridge|publish-replacement-release|recover-node) ;;
  *) fail "response.action is unsupported: $action" ;;
esac
case "$scope_type" in
  node|cluster|release|bridge-route|global) ;;
  *) fail "response.scope.scope_type must be node, cluster, release, bridge-route, or global: $scope_type" ;;
esac

case "$action" in
  freeze-admission)
    case "$incident_type" in
      cryptographic-break|adversarial-fork) ;;
      *) fail "freeze-admission is only allowed for cryptographic-break or adversarial-fork incidents" ;;
    esac
    [[ "$scope_type" == "global" ]] || fail "freeze-admission must use global scope"
    ;;
  pause-bridge-route|rollback-bridge)
    [[ "$incident_type" == "bridge-exploit" ]] \
      || fail "$action is only allowed for bridge-exploit incidents"
    [[ "$scope_type" == "bridge-route" ]] || fail "$action must use bridge-route scope"
    [[ -n "$(field '.response.scope.bridge_route_id')" ]] || fail "$action requires response.scope.bridge_route_id"
    ;;
  emergency-key-rotation)
    [[ "$incident_type" == "cryptographic-break" ]] \
      || fail "emergency-key-rotation is only allowed for cryptographic-break incidents"
    ;;
esac

[[ -n "$runbook_id" ]] || fail "runbook.id is required"
validate_hash32 "runbook.schema_hash" "$runbook_schema_hash"
validate_hash32 "runbook.signed_payload_hash" "$runbook_payload_hash"
case "$runbook_signature_scheme" in
  ML-DSA-65|SLH-DSA) ;;
  *) fail "runbook.signature_scheme must be ML-DSA-65 or SLH-DSA" ;;
esac
validate_signature "runbook.signature" "$runbook_signature"

validate_hash32 "evidence.release_metadata_sha256" "$release_metadata_sha"
jq -e '(.evidence.files // []) | length >= 1' "$MANIFEST" >/dev/null \
  || fail "evidence.files must include at least one evidence file hash"
jq -e '
  all(.evidence.files[]?;
    (.label | type == "string" and length > 0)
    and (.source | type == "string" and length > 0)
    and (.sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
  )
' "$MANIFEST" >/dev/null || fail "evidence.files entries must include label, source, and sha256"

if [[ "$incident_type" == "pcr-drift" ]]; then
  validate_hash32 "evidence.pcr_quote_hash" "$(field '.evidence.pcr_quote_hash')"
fi

requires_foundation=false
case "$action" in
  freeze-admission|pause-bridge-route|rollback-bridge|emergency-key-rotation)
    requires_foundation=true
    ;;
esac
if [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_FOUNDATION_AUTHORIZATION"; then
  case "$action" in
    freeze-admission|pause-bridge-route|rollback-bridge|emergency-key-rotation)
      requires_foundation=true
      ;;
  esac
fi

foundation_checked=false
if [[ "$requires_foundation" == "true" ]]; then
  threshold="$(field '.foundation_authorization.threshold')"
  signer_set_hash="$(field '.foundation_authorization.signer_set_hash')"
  ratification_deadline="$(field '.foundation_authorization.ratification_deadline')"
  [[ "$threshold" =~ ^[0-9]+$ && "$threshold" -ge 2 ]] \
    || fail "foundation_authorization.threshold must be numeric and at least 2"
  validate_hash32 "foundation_authorization.signer_set_hash" "$signer_set_hash"
  [[ "$ratification_deadline" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "foundation_authorization.ratification_deadline must be an RFC3339 UTC timestamp"

  signature_count="$(jq -r '[.foundation_authorization.signatures[]?.signer_id] | unique | length' "$MANIFEST")"
  (( signature_count >= threshold )) \
    || fail "foundation_authorization.signatures must meet threshold"
  jq -e '
    all(.foundation_authorization.signatures[]?;
      (.signer_id | type == "string" and length > 0)
      and (.public_key_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.signature_scheme == "ML-DSA-65" or .signature_scheme == "SLH-DSA")
      and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$"))
    )
  ' "$MANIFEST" >/dev/null || fail "foundation_authorization signatures are malformed"
  foundation_checked=true
fi

on_chain_checked=false
executor_binding_checked=false
executor_method=""
case "$action" in
  freeze-admission|pause-bridge-route|rollback-bridge|emergency-key-rotation)
    if [[ "$chain_profile" == "mainnet" ]] || bool_true "$REQUIRE_ON_CHAIN_ACTION"; then
      tx_hash="$(field '.on_chain_action.tx_hash')"
      dag_round="$(field '.on_chain_action.dag_round')"
      quorum_hash="$(field '.on_chain_action.quorum_certificate_hash')"
      executor_contract="$(field '.on_chain_action.executor_contract')"
      executor_method="$(field '.on_chain_action.executor_method')"
      function_selector="$(field '.on_chain_action.function_selector')"
      calldata_hash="$(field '.on_chain_action.calldata_hash')"
      expected_executor_method="$(executor_method_for_action "$action")"
      expected_executor_contract="$(executor_contract_for_action "$action")"
      expected_function_selector="$(function_selector_for_action "$action")"
      validate_tx_hash "on_chain_action.tx_hash" "$tx_hash"
      [[ "$dag_round" =~ ^[0-9]+$ ]] || fail "on_chain_action.dag_round must be numeric"
      validate_hash32 "on_chain_action.quorum_certificate_hash" "$quorum_hash"
      validate_address "on_chain_action.executor_contract" "$executor_contract"
      [[ "$(hex_no_prefix_lower "$executor_contract")" == "$(hex_no_prefix_lower "$expected_executor_contract")" ]] \
        || fail "on_chain_action.executor_contract must be $expected_executor_contract for $action"
      [[ "$executor_method" == "$expected_executor_method" ]] \
        || fail "on_chain_action.executor_method must be $expected_executor_method for $action"
      validate_selector "on_chain_action.function_selector" "$function_selector"
      [[ "$(hex_no_prefix_lower "$function_selector")" == "$(hex_no_prefix_lower "$expected_function_selector")" ]] \
        || fail "on_chain_action.function_selector must be $expected_function_selector for $action"
      validate_hash32 "on_chain_action.calldata_hash" "$calldata_hash"
      on_chain_checked=true
      executor_binding_checked=true
    fi
    ;;
esac

jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg incident_id "$incident_id" \
  --arg incident_type "$incident_type" \
  --arg severity "$severity" \
  --arg status "$status" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg action "$action" \
  --arg scope_type "$scope_type" \
  --arg executor_method "$executor_method" \
  --argjson foundation_checked "$foundation_checked" \
  --argjson on_chain_checked "$on_chain_checked" \
  --argjson executor_binding_checked "$executor_binding_checked" \
  '{
    ok: true,
    manifest: $manifest,
    incident: {
      id: $incident_id,
      type: $incident_type,
      severity: $severity,
      status: $status
    },
    chain: {profile: $chain_profile, chain_id: $chain_id},
    response: {action: $action, scope_type: $scope_type},
    foundation_authorization_checked: $foundation_checked,
    on_chain_action_checked: $on_chain_checked,
    executor_binding_checked: $executor_binding_checked,
    executor_method: (if $executor_method == "" then null else $executor_method end)
  }'
