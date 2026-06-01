#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "talos certificate rotation test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>"$tmp_dir/$label.err"; then
    fail "$label unexpectedly succeeded"
  fi
}

canonical_rotation_payload_hash() {
  local manifest="$1"

  jq -cS '
    def norm_hash: ascii_downcase | ltrimstr("0x");
    def maybe_string($v): if ($v // "") == "" then null else $v end;
    {
      schema_version: "monarch-talos-certificate-rotation-payload/v1",
      chain: {
        profile: .chain.profile,
        chain_id: (.chain.chain_id | tostring)
      },
      rotation: {
        id: .rotation.id,
        type: .rotation.type,
        reason: .rotation.reason,
        runbook_id: .rotation.runbook_id,
        opened_at: .rotation.opened_at,
        approval_threshold: (.rotation.approval_threshold // 1)
      },
      node: {
        node_id: .node.node_id,
        role: .node.role,
        cluster_id: maybe_string(.node.cluster_id),
        current_endpoint: .node.current_endpoint,
        next_endpoint: .node.next_endpoint
      },
      current_identity: {
        ca_fingerprint_sha256: (.current_identity.ca_fingerprint_sha256 | norm_hash),
        client_fingerprint_sha256: (.current_identity.client_fingerprint_sha256 | norm_hash),
        ca_not_after: .current_identity.ca_not_after,
        client_not_after: .current_identity.client_not_after
      },
      next_identity: {
        ca_fingerprint_sha256: (.next_identity.ca_fingerprint_sha256 | norm_hash),
        client_fingerprint_sha256: (.next_identity.client_fingerprint_sha256 | norm_hash),
        ca_not_after: .next_identity.ca_not_after,
        client_not_after: .next_identity.client_not_after
      },
      talosconfig: {
        current_sha256: (.talosconfig.current_sha256 | norm_hash),
        next_sha256: (.talosconfig.next_sha256 | norm_hash),
        current_path: .talosconfig.current_path,
        next_path: .talosconfig.next_path
      },
      post_rotation: {
        desktop_e2e_evidence: (
          if (.post_rotation.desktop_e2e_evidence // null) == null then
            null
          else
            {
              schema_version: .post_rotation.desktop_e2e_evidence.schema_version,
              sha256: (.post_rotation.desktop_e2e_evidence.sha256 | norm_hash),
              talos_ca_fingerprint_sha256: (.post_rotation.desktop_e2e_evidence.talos_ca_fingerprint_sha256 | norm_hash),
              talos_endpoint: .post_rotation.desktop_e2e_evidence.talos_endpoint,
              ca_pin_status: .post_rotation.desktop_e2e_evidence.ca_pin_status,
              expires_min_days: .post_rotation.desktop_e2e_evidence.expires_min_days
            }
          end
        )
      }
    }
  ' "$manifest" | sha256sum | awk '{print $1}'
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

h0="$(printf '0%.0s' {1..64})"
h1="$(printf '1%.0s' {1..64})"
h2="$(printf '2%.0s' {1..64})"
h3="$(printf '3%.0s' {1..64})"
h4="$(printf '4%.0s' {1..64})"
h5="$(printf '5%.0s' {1..64})"
h6="$(printf '6%.0s' {1..64})"
h7="$(printf '7%.0s' {1..64})"
h8="$(printf '8%.0s' {1..64})"
h9="$(printf '9%.0s' {1..64})"
signature="$(printf 'a%.0s' {1..128})"

valid="$tmp_dir/talos-cert-rotation-valid.json"
missing_desktop="$tmp_dir/talos-cert-rotation-missing-desktop.json"
short_lived="$tmp_dir/talos-cert-rotation-short-lived.json"
mismatched_payload="$tmp_dir/talos-cert-rotation-mismatched-payload.json"
unchanged_ca="$tmp_dir/talos-cert-rotation-unchanged-ca.json"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg sig "0x$signature" \
  '{
    schema_version: "monarch-talos-certificate-rotation/v1",
    chain: {
      profile: "testnet",
      chain_id: 69420
    },
    rotation: {
      id: "talos-cert-rotation-test-001",
      type: "ca-rotation",
      reason: "scheduled",
      runbook_id: "talos-cert-rotation",
      opened_at: "2026-06-01T00:00:00Z",
      approval_threshold: 2
    },
    node: {
      node_id: "operator-001",
      role: "operator-signing",
      cluster_id: "C-001",
      current_endpoint: "10.0.0.10",
      next_endpoint: "10.0.0.10"
    },
    current_identity: {
      ca_fingerprint_sha256: $h1,
      client_fingerprint_sha256: $h2,
      ca_not_after: "2026-06-20T00:00:00Z",
      client_not_after: "2026-06-20T00:00:00Z"
    },
    next_identity: {
      ca_fingerprint_sha256: $h3,
      client_fingerprint_sha256: $h4,
      ca_not_after: "2027-06-01T00:00:00Z",
      client_not_after: "2027-06-01T00:00:00Z"
    },
    talosconfig: {
      current_path: "evidence/talosconfig.current",
      current_sha256: $h5,
      next_path: "evidence/talosconfig.next",
      next_sha256: $h6
    },
    post_rotation: {
      desktop_e2e_evidence: {
        schema_version: "monarch-desktop-e2e-evidence/v1",
        sha256: $h7,
        talos_ca_fingerprint_sha256: $h3,
        talos_endpoint: "10.0.0.10",
        ca_pin_status: "matched",
        expires_min_days: 180
      }
    },
    approvals: [
      {
        address: "0x1111111111111111111111111111111111111111",
        signature_scheme: "ML-DSA-65",
        signed_payload_hash: $h0,
        signature: $sig
      },
      {
        address: "0x2222222222222222222222222222222222222222",
        signature_scheme: "ML-DSA-65",
        signed_payload_hash: $h0,
        signature: $sig
      }
    ]
  }' > "$valid"

payload_hash="$(canonical_rotation_payload_hash "$valid")"
jq --arg payload_hash "$payload_hash" '
  .approvals |= map(.signed_payload_hash = $payload_hash)
' "$valid" >"$tmp_dir/valid.with-payload.json"
mv "$tmp_dir/valid.with-payload.json" "$valid"

EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_DESKTOP_EVIDENCE=true \
  "$ROOT_DIR/scripts/validate-talos-certificate-rotation.sh" "$valid" >/dev/null

jq 'del(.post_rotation.desktop_e2e_evidence)' "$valid" >"$missing_desktop"
expect_fail missing-desktop-evidence \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 REQUIRE_DESKTOP_EVIDENCE=true \
  "$ROOT_DIR/scripts/validate-talos-certificate-rotation.sh" "$missing_desktop"
grep -F "requires post_rotation.desktop_e2e_evidence" "$tmp_dir/missing-desktop-evidence.err" >/dev/null \
  || fail "missing desktop evidence rejection reason changed"

jq '.next_identity.client_not_after = "2026-06-02T00:00:00Z"' "$valid" >"$short_lived"
expect_fail short-lived-client \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 MIN_CERT_VALIDITY_DAYS=30 \
  "$ROOT_DIR/scripts/validate-talos-certificate-rotation.sh" "$short_lived"
grep -F "inside minimum validity window" "$tmp_dir/short-lived-client.err" >/dev/null \
  || fail "short-lived certificate rejection reason changed"

jq --arg h9 "$h9" '.approvals[0].signed_payload_hash = $h9' "$valid" >"$mismatched_payload"
expect_fail mismatched-payload-hash \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-talos-certificate-rotation.sh" "$mismatched_payload"
grep -F "must match canonical rotation payload hash" "$tmp_dir/mismatched-payload-hash.err" >/dev/null \
  || fail "mismatched payload rejection reason changed"

jq --arg h1 "$h1" '
  .next_identity.ca_fingerprint_sha256 = $h1
  | .post_rotation.desktop_e2e_evidence.talos_ca_fingerprint_sha256 = $h1
' "$valid" >"$unchanged_ca"
payload_hash="$(canonical_rotation_payload_hash "$unchanged_ca")"
jq --arg payload_hash "$payload_hash" '.approvals |= map(.signed_payload_hash = $payload_hash)' \
  "$unchanged_ca" >"$tmp_dir/unchanged-ca.with-payload.json"
mv "$tmp_dir/unchanged-ca.with-payload.json" "$unchanged_ca"
expect_fail unchanged-ca \
  env EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-talos-certificate-rotation.sh" "$unchanged_ca"
grep -F "ca-rotation must change" "$tmp_dir/unchanged-ca.err" >/dev/null \
  || fail "unchanged CA rejection reason changed"

printf '{"ok":true,"checked":"talos-certificate-rotation"}\n'
