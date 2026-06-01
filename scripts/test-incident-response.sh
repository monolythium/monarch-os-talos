#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "incident response test failed: $*" >&2
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

hash0="$(printf '00%.0s' {1..32})"
hash1="$(printf '11%.0s' {1..32})"
hash2="$(printf '22%.0s' {1..32})"
hash3="$(printf '33%.0s' {1..32})"
sig_a="$(printf 'aa%.0s' {1..80})"
sig_b="$(printf 'bb%.0s' {1..80})"

write_base_manifest() {
  local path="$1"
  jq -n \
    --arg h0 "$hash0" \
    --arg h1 "$hash1" \
    --arg h2 "$hash2" \
    --arg h3 "$hash3" \
    --arg sig_a "0x$sig_a" \
    --arg sig_b "0x$sig_b" \
    '{
      schema_version: "monarch-incident-response/v1",
      incident: {
        id: "inc-validator-001",
        type: "cryptographic-break",
        severity: "critical",
        status: "contained",
        opened_at: "2026-06-01T00:00:00Z",
        summary: "validator test incident"
      },
      chain: {
        profile: "testnet",
        chain_id: 69420
      },
      response: {
        action: "freeze-admission",
        scope: {
          scope_type: "global"
        },
        operator_instructions: [
          "Stop new operator admission until the signed runbook clears the incident."
        ]
      },
      runbook: {
        id: "incident-validator-test",
        version: "1",
        schema_hash: $h0,
        signed_payload_hash: $h1,
        signature_scheme: "ML-DSA-65",
        signature: $sig_a
      },
      evidence: {
        release_metadata_sha256: $h2,
        files: [
          {
            label: "incident-report",
            source: "local-test",
            sha256: $h3
          }
        ]
      },
      foundation_authorization: {
        threshold: 2,
        signer_set_hash: $h0,
        ratification_deadline: "2026-06-02T00:00:00Z",
        signatures: [
          {
            signer_id: "foundation-a",
            public_key_hash: $h1,
            signature_scheme: "ML-DSA-65",
            signed_payload_hash: $h2,
            signature: $sig_a
          },
          {
            signer_id: "foundation-b",
            public_key_hash: $h2,
            signature_scheme: "ML-DSA-65",
            signed_payload_hash: $h2,
            signature: $sig_b
          }
        ]
      }
    }' > "$path"
}

with_on_chain_action() {
  local input="$1"
  local output="$2"
  local contract="$3"
  local method="$4"
  local selector="$5"
  jq \
    --arg contract "$contract" \
    --arg method "$method" \
    --arg selector "$selector" \
    --arg calldata "$hash3" \
    '.on_chain_action = {
      tx_hash: "0x4444444444444444444444444444444444444444444444444444444444444444",
      dag_round: 1234,
      quorum_certificate_hash: "5555555555555555555555555555555555555555555555555555555555555555",
      executor_contract: $contract,
      executor_method: $method,
      function_selector: $selector,
      calldata_hash: $calldata
    }' "$input" > "$output"
}

base="$tmp_dir/freeze-base.json"
freeze_on_chain="$tmp_dir/freeze-on-chain.json"
bad_freeze_selector="$tmp_dir/freeze-bad-selector.json"
rollback_base="$tmp_dir/rollback-base.json"
rollback_on_chain="$tmp_dir/rollback-on-chain.json"
bad_rollback_contract="$tmp_dir/rollback-bad-contract.json"
emergency_base="$tmp_dir/emergency-base.json"
emergency_on_chain="$tmp_dir/emergency-on-chain.json"
pause_base="$tmp_dir/pause-base.json"
pause_on_chain="$tmp_dir/pause-on-chain.json"

write_base_manifest "$base"

"$ROOT_DIR/scripts/validate-incident-response.sh" "$base" >/dev/null \
  || fail "valid freeze-admission manifest was rejected"

if REQUIRE_ON_CHAIN_ACTION=true \
  "$ROOT_DIR/scripts/validate-incident-response.sh" "$base" >/dev/null 2>"$tmp_dir/require-on-chain.err"; then
  fail "required on-chain incident evidence was not enforced"
fi
grep -F "on_chain_action.tx_hash" "$tmp_dir/require-on-chain.err" >/dev/null \
  || fail "required on-chain rejection reason changed"

with_on_chain_action \
  "$base" \
  "$freeze_on_chain" \
  "0x0000000000000000000000000000000000001005" \
  "freezeAdmission" \
  "0x7a2605cd"
REQUIRE_ON_CHAIN_ACTION=true "$ROOT_DIR/scripts/validate-incident-response.sh" "$freeze_on_chain" >/dev/null \
  || fail "valid freeze-admission on-chain binding was rejected"

jq '.on_chain_action.function_selector = "0x11111111"' "$freeze_on_chain" > "$bad_freeze_selector"
if REQUIRE_ON_CHAIN_ACTION=true \
  "$ROOT_DIR/scripts/validate-incident-response.sh" "$bad_freeze_selector" >/dev/null 2>"$tmp_dir/bad-freeze-selector.err"; then
  fail "bad freezeAdmission selector was accepted"
fi
grep -F "function_selector must be 0x7a2605cd" "$tmp_dir/bad-freeze-selector.err" >/dev/null \
  || fail "bad freeze selector rejection reason changed"

jq '
  .incident.type = "bridge-exploit"
  | .response.action = "rollback-bridge"
  | .response.scope = {
      scope_type: "bridge-route",
      bridge_route_id: "0x9999999999999999999999999999999999999999999999999999999999999999"
    }
' "$base" > "$rollback_base"
with_on_chain_action \
  "$rollback_base" \
  "$rollback_on_chain" \
  "0x0000000000000000000000000000000000001008" \
  "rollbackBridge" \
  "0x059a1b5c"
REQUIRE_ON_CHAIN_ACTION=true "$ROOT_DIR/scripts/validate-incident-response.sh" "$rollback_on_chain" >/dev/null \
  || fail "valid rollbackBridge on-chain binding was rejected"

jq '.on_chain_action.executor_contract = "0x0000000000000000000000000000000000001005"' \
  "$rollback_on_chain" > "$bad_rollback_contract"
if REQUIRE_ON_CHAIN_ACTION=true \
  "$ROOT_DIR/scripts/validate-incident-response.sh" "$bad_rollback_contract" >/dev/null 2>"$tmp_dir/bad-rollback-contract.err"; then
  fail "bad rollbackBridge contract was accepted"
fi
grep -F "executor_contract must be 0x0000000000000000000000000000000000001008" "$tmp_dir/bad-rollback-contract.err" >/dev/null \
  || fail "bad rollback contract rejection reason changed"

jq '
  .response.action = "emergency-key-rotation"
  | .response.scope = {scope_type: "cluster", cluster_id: 1}
' "$base" > "$emergency_base"
with_on_chain_action \
  "$emergency_base" \
  "$emergency_on_chain" \
  "0x0000000000000000000000000000000000001005" \
  "emergencyKeyRotation" \
  "0x0aeeafbf"
REQUIRE_ON_CHAIN_ACTION=true "$ROOT_DIR/scripts/validate-incident-response.sh" "$emergency_on_chain" >/dev/null \
  || fail "valid emergencyKeyRotation on-chain binding was rejected"

jq '
  .incident.type = "bridge-exploit"
  | .response.action = "pause-bridge-route"
  | .response.scope = {
      scope_type: "bridge-route",
      bridge_route_id: "0x9999999999999999999999999999999999999999999999999999999999999999"
    }
' "$base" > "$pause_base"
with_on_chain_action \
  "$pause_base" \
  "$pause_on_chain" \
  "0x0000000000000000000000000000000000001008" \
  "pauseBridgeRoute" \
  "0x11a2dc64"
REQUIRE_ON_CHAIN_ACTION=true "$ROOT_DIR/scripts/validate-incident-response.sh" "$pause_on_chain" >/dev/null \
  || fail "valid pauseBridgeRoute on-chain binding was rejected"

printf '{"ok":true,"checked":"incident-response-validator"}\n'
