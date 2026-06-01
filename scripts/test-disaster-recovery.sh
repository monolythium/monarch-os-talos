#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "disaster recovery test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need jq
need sha256sum
need xxd

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

hash0="$(printf '00%.0s' {1..32})"
hash1="$(printf '11%.0s' {1..32})"
hash2="$(printf '22%.0s' {1..32})"
signature="$(printf 'aa%.0s' {1..80})"
peer_id="$(printf 'cc%.0s' {1..32})"
selector="e58729e6"
calldata_hash="$(printf '%s' "$selector$peer_id" | xxd -r -p | sha256sum | awk '{print $1}')"

write_manifest() {
  local path="$1"
  jq -n \
    --arg h0 "$hash0" \
    --arg h1 "$hash1" \
    --arg h2 "$hash2" \
    --arg sig "0x$signature" \
    '{
      schema_version: "monarch-disaster-recovery/v1",
      recovery: {
        id: "dr-validator-001",
        type: "offline-restore",
        runbook_id: "dr-validator-test",
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
        manifest_sha256: $h2
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

valid="$tmp_dir/valid.json"
on_chain="$tmp_dir/on-chain.json"
bad_selector="$tmp_dir/bad-selector.json"
bad_hash="$tmp_dir/bad-hash.json"

write_manifest "$valid"

"$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$valid" >/dev/null \
  || fail "valid offline restore manifest was rejected"

if REQUIRE_ON_CHAIN_RECOVERY=true \
  "$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$valid" >/dev/null 2>"$tmp_dir/require-on-chain.err"; then
  fail "required on-chain recovery evidence was not enforced"
fi
grep -F "must include on_chain_recovery" "$tmp_dir/require-on-chain.err" >/dev/null \
  || fail "required on-chain recovery rejection reason changed"

jq \
  --arg peer "0x$peer_id" \
  --arg calldata "0x$calldata_hash" \
  '.on_chain_recovery = {
    tx_hash: "0x3333333333333333333333333333333333333333333333333333333333333333",
    dag_round: 1234,
    quorum_certificate_hash: "4444444444444444444444444444444444444444444444444444444444444444",
    executor_contract: "0x0000000000000000000000000000000000001005",
    executor_method: "recoverOperatorNode",
    operator_peer_id: $peer,
    function_selector: "0xe58729e6",
    calldata_hash: $calldata
  }' "$valid" > "$on_chain"

REQUIRE_ON_CHAIN_RECOVERY=true "$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$on_chain" >/dev/null \
  || fail "valid on-chain recovery manifest was rejected"

jq '.on_chain_recovery.function_selector = "0x11111111"' "$on_chain" > "$bad_selector"
if "$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$bad_selector" >/dev/null 2>"$tmp_dir/bad-selector.err"; then
  fail "bad recoverOperatorNode selector was accepted"
fi
grep -F "function_selector must be 0xe58729e6" "$tmp_dir/bad-selector.err" >/dev/null \
  || fail "bad selector rejection reason changed"

jq '.on_chain_recovery.calldata_hash = "0x5555555555555555555555555555555555555555555555555555555555555555"' \
  "$on_chain" > "$bad_hash"
if "$ROOT_DIR/scripts/validate-disaster-recovery.sh" "$bad_hash" >/dev/null 2>"$tmp_dir/bad-hash.err"; then
  fail "bad recoverOperatorNode calldata hash was accepted"
fi
grep -F "calldata_hash does not match recoverOperatorNode(operator_peer_id)" "$tmp_dir/bad-hash.err" >/dev/null \
  || fail "bad calldata hash rejection reason changed"

printf '{"ok":true,"checked":"disaster-recovery-validator"}\n'
