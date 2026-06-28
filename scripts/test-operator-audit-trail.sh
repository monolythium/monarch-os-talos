#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_OPERATION_RECEIPT_SCHEMA="monarch-desktop-operation-receipt/v1"

fail() {
  echo "operator audit trail test failed: $*" >&2
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
    fail "$label was accepted"
  fi
}

canonical_audit_payload_hash() {
  local manifest="$1"

  jq -cS '
    def norm_hex: ascii_downcase | ltrimstr("0x");
    def maybe_norm_hash($v): if ($v // "") == "" then null else ($v | norm_hex) end;
    {
      schema_version: "monarch-operator-audit-payload/v1",
      audit: {
        id: .audit.id,
        created_at: .audit.created_at,
        action: .audit.action,
        reason: .audit.reason,
        previous_audit_hash: maybe_norm_hash(.audit.previous_audit_hash)
      },
      chain: {
        profile: .chain.profile,
        chain_id: (.chain.chain_id | tostring)
      },
      actor: {
        role: .actor.role,
        address: .actor.address,
        operator_index: (.actor.operator_index // null),
        cluster_id: (if (.actor.cluster_id // null) == null then null else (.actor.cluster_id | tostring) end)
      },
      release: {
        metadata_sha256: (.release.metadata_sha256 | norm_hex),
        protocore_digest: (.release.protocore_digest | norm_hex)
      },
      subject: {
        type: .subject.type,
        id: .subject.id,
        schema_version: (.subject.schema_version // null),
        sha256: maybe_norm_hash(.subject.sha256)
      },
      intent: {
        summary: .intent.summary,
        expected_state_hash: (.intent.expected_state_hash | norm_hex),
        diff_vs_intent_hash: (.intent.diff_vs_intent_hash | norm_hex),
        risk: .intent.risk,
        requires_approval: (.intent.requires_approval // true)
      },
      evidence: (
        .evidence
        | sort_by(.label, .type)
        | map({
            label,
            type,
            path: (.path // null),
            schema_version: (.schema_version // null),
            sha256: (.sha256 | norm_hex)
          })
      ),
      receipts: (
        (.receipts // [])
        | sort_by(.source, .id)
        | map({
            source,
            status,
            id,
            kind: (.kind // null),
            audit_payload_schema: (.audit_payload_schema // null),
            audit_payload_hash: maybe_norm_hash(.audit_payload_hash),
            tx_hash: (.tx_hash // null),
            dag_round: (if (.dag_round // null) == null then null else (.dag_round | tostring) end),
            quorum_certificate_hash: maybe_norm_hash(.quorum_certificate_hash),
            artifact_sha256: maybe_norm_hash(.artifact_sha256)
          })
      ),
      peer_vouches: (
        (.peer_vouches // [])
        | sort_by(.peer_id, .address)
        | map({
            peer_id,
            address
          })
      )
    }
  ' "$manifest" | sha256sum | awk '{print $1}'
}

desktop_receipt_audit_hash() {
  local receipt_file="$1"

  jq -cS --arg schema "$DESKTOP_OPERATION_RECEIPT_SCHEMA" '
    def pick($camel; $snake):
      if .[$camel] != null then .[$camel] else (.[$snake] // null) end;
    def maybe_lower($v):
      if ($v // "") == "" then null else ($v | tostring | ascii_downcase) end;
    {
      schema_version: $schema,
      id: pick("id"; "id"),
      created_at: pick("createdAt"; "created_at"),
      kind: pick("kind"; "kind"),
      title: pick("title"; "title"),
      status: pick("status"; "status"),
      message: pick("message"; "message"),
      transport: pick("transport"; "transport"),
      service: pick("service"; "service"),
      action: pick("action"; "action"),
      endpoint: pick("endpoint"; "endpoint"),
      node_address: pick("nodeAddress"; "node_address"),
      command: pick("command"; "command"),
      tx_hash: maybe_lower(pick("txHash"; "tx_hash")),
      artifact_path: pick("artifactPath"; "artifact_path"),
      artifact_sha256: maybe_lower(pick("artifactSha256"; "artifact_sha256"))
    }
  ' "$receipt_file" | sha256sum | awk '{print $1}'
}

stamp_desktop_receipt_hash() {
  local path="$1"
  local hash

  hash="$(desktop_receipt_audit_hash "$path")"
  jq --arg schema "$DESKTOP_OPERATION_RECEIPT_SCHEMA" --arg hash "$hash" \
    '.auditPayloadSchema = $schema | .auditPayloadHash = $hash' \
    "$path" >"$tmp_dir/stamped-desktop-receipt.json"
  mv "$tmp_dir/stamped-desktop-receipt.json" "$path"
}

stamp_payload_hash() {
  local path="$1"
  local hash

  hash="$(canonical_audit_payload_hash "$path")"
  jq --arg hash "$hash" \
    '(.approvals[].signed_payload_hash) = $hash
     | if has("peer_vouches") then (.peer_vouches[].signed_payload_hash) = $hash else . end' \
    "$path" >"$tmp_dir/stamped.json"
  mv "$tmp_dir/stamped.json" "$path"
}

need jq
need sha256sum

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

evidence_root="$tmp_dir/evidence"
mkdir -p "$evidence_root/audit"
printf 'tpm-sealing evidence\n' >"$evidence_root/audit/tpm-sealing-evidence.json"
jq -n \
  --arg h4 "$(printf '4%.0s' {1..64})" \
  '{
    id: "receipt-rotation-001",
    createdAt: "2026-06-01T00:00:01.000Z",
    kind: "rotate-keys",
    title: "Rotate operator key",
    status: "ok",
    message: "submitted operator key rotation",
    txHash: ("0x" + $h4),
    transport: "operator-key-rotation-tx",
    service: null,
    action: "rotateOperatorKey",
    endpoint: "https://rpc.monolythium.com",
    nodeAddress: "mono1operator000000000000000000000000000000000",
    command: null,
    artifactPath: null,
    artifactSha256: null
  }' >"$evidence_root/audit/desktop-receipt.json"
stamp_desktop_receipt_hash "$evidence_root/audit/desktop-receipt.json"
evidence_sha="$(sha256sum "$evidence_root/audit/tpm-sealing-evidence.json" | awk '{print $1}')"
receipt_sha="$(sha256sum "$evidence_root/audit/desktop-receipt.json" | awk '{print $1}')"
receipt_audit_hash="$(jq -r '.auditPayloadHash' "$evidence_root/audit/desktop-receipt.json")"

h0="$(printf '0%.0s' {1..64})"
h1="$(printf '1%.0s' {1..64})"
h2="$(printf '2%.0s' {1..64})"
h3="$(printf '3%.0s' {1..64})"
h4="$(printf '4%.0s' {1..64})"
h5="$(printf '5%.0s' {1..64})"
h6="$(printf '6%.0s' {1..64})"
h7="$(printf '7%.0s' {1..64})"
h9="$(printf '9%.0s' {1..64})"
signature="$(printf 'a%.0s' {1..128})"

valid="$tmp_dir/audit-valid.json"
bad_payload="$tmp_dir/audit-bad-payload.json"
bad_desktop_audit_hash="$tmp_dir/audit-bad-desktop-audit-hash.json"
bad_desktop_receipt_file="$tmp_dir/audit-bad-desktop-receipt-file.json"
bad_local_hash_root="$tmp_dir/bad-evidence"
bad_desktop_receipt_root="$tmp_dir/bad-desktop-receipt-evidence"
freeze="$tmp_dir/audit-freeze.json"
freeze_missing_peer="$tmp_dir/audit-freeze-missing-peer.json"

jq -n \
  --arg h0 "$h0" \
  --arg h1 "$h1" \
  --arg h2 "$h2" \
  --arg h3 "$h3" \
  --arg h4 "$h4" \
  --arg h5 "$h5" \
  --arg h6 "$h6" \
  --arg h7 "$h7" \
  --arg evidence_sha "$evidence_sha" \
  --arg receipt_sha "$receipt_sha" \
  --arg receipt_audit_hash "$receipt_audit_hash" \
  --arg desktop_schema "$DESKTOP_OPERATION_RECEIPT_SCHEMA" \
  --arg sig "0x$signature" \
  '{
    schema_version: "monarch-operator-audit-trail/v1",
    audit: {
      id: "audit-operator-key-rotation-001",
      created_at: "2026-06-01T00:00:00Z",
      action: "operator-key-rotation",
      reason: "planned operator rotation",
      previous_audit_hash: $h7
    },
    chain: {
      profile: "testnet",
      chain_id: "69420"
    },
    actor: {
      role: "operator",
      address: "0x1111111111111111111111111111111111111111",
      operator_index: 0,
      cluster_id: 1
    },
    release: {
      metadata_sha256: $h0,
      protocore_digest: $h1
    },
    subject: {
      type: "tpm-sealing-evidence",
      id: "opkey-rotation-001",
      schema_version: "monarch-operator-key-rotation/v1",
      sha256: $evidence_sha
    },
    intent: {
      summary: "rotate one standby operator into the active set",
      expected_state_hash: $h2,
      diff_vs_intent_hash: $h3,
      risk: "high",
      requires_approval: true
    },
    evidence: [
      {
        label: "tpm-sealing-evidence",
        type: "manifest",
        path: "/audit/tpm-sealing-evidence.json",
        schema_version: "monarch-operator-key-rotation/v1",
        sha256: $evidence_sha
      },
      {
        label: "desktop-receipt",
        type: "receipt",
        path: "/audit/desktop-receipt.json",
        schema_version: $desktop_schema,
        sha256: $receipt_sha
      }
    ],
    receipts: [
      {
        source: "desktop",
        status: "ok",
        id: "receipt-rotation-001",
        kind: "rotate-keys",
        audit_payload_schema: $desktop_schema,
        audit_payload_hash: $receipt_audit_hash,
        tx_hash: ("0x" + $h4),
        dag_round: 12345,
        quorum_certificate_hash: $h5,
        artifact_sha256: $receipt_sha
      }
    ],
    approvals: [
      {
        signer: "0x1111111111111111111111111111111111111111",
        signer_role: "operator",
        signature_scheme: "ML-DSA-65",
        signed_payload_hash: $h6,
        signature: $sig
      },
      {
        signer: "0x2222222222222222222222222222222222222222",
        signer_role: "operator",
        signature_scheme: "ML-DSA-65",
        signed_payload_hash: $h6,
        signature: $sig
      }
    ]
  }' >"$valid"
stamp_payload_hash "$valid"

LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$valid" >/dev/null

jq --arg h9 "$h9" '.approvals[0].signed_payload_hash = $h9' "$valid" >"$bad_payload"
expect_fail bad-payload-hash \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$bad_payload"

jq --arg h9 "$h9" '.receipts[0].audit_payload_hash = $h9' "$valid" >"$bad_desktop_audit_hash"
stamp_payload_hash "$bad_desktop_audit_hash"
expect_fail bad-desktop-audit-hash \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$bad_desktop_audit_hash"

cp -R "$evidence_root" "$bad_desktop_receipt_root"
jq --arg h9 "$h9" '.auditPayloadHash = $h9' \
  "$bad_desktop_receipt_root/audit/desktop-receipt.json" >"$tmp_dir/tampered-desktop-receipt.json"
mv "$tmp_dir/tampered-desktop-receipt.json" "$bad_desktop_receipt_root/audit/desktop-receipt.json"
bad_receipt_sha="$(sha256sum "$bad_desktop_receipt_root/audit/desktop-receipt.json" | awk '{print $1}')"
jq --arg bad_receipt_sha "$bad_receipt_sha" \
  '(.evidence[] | select(.label == "desktop-receipt")).sha256 = $bad_receipt_sha' \
  "$valid" >"$bad_desktop_receipt_file"
stamp_payload_hash "$bad_desktop_receipt_file"
expect_fail bad-desktop-receipt-file \
  env LOCAL_EVIDENCE_ROOT="$bad_desktop_receipt_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$bad_desktop_receipt_file"

cp -R "$evidence_root" "$bad_local_hash_root"
printf 'tampered evidence\n' >"$bad_local_hash_root/audit/tpm-sealing-evidence.json"
expect_fail bad-local-evidence-hash \
  env LOCAL_EVIDENCE_ROOT="$bad_local_hash_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$valid"

jq \
  --arg h6 "$h6" \
  --arg sig "0x$signature" \
  '.audit.action = "kill-switch-freeze"
   | .audit.id = "audit-freeze-001"
   | .audit.reason = "peer-vouched emergency freeze rehearsal"
   | .subject.type = "incident-response"
   | .subject.id = "incident-freeze-001"
   | .intent.risk = "critical"
   | .receipts = []
   | .evidence = [.evidence[] | select(.label != "desktop-receipt")]
   | .peer_vouches = [
      {
        peer_id: "peer-a",
        address: "0x3333333333333333333333333333333333333333",
        signed_payload_hash: $h6,
        signature: $sig
      },
      {
        peer_id: "peer-b",
        address: "0x4444444444444444444444444444444444444444",
        signed_payload_hash: $h6,
        signature: $sig
      }
    ]' "$valid" >"$freeze"
stamp_payload_hash "$freeze"

LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$freeze" >/dev/null

jq 'del(.peer_vouches[1])' "$freeze" >"$freeze_missing_peer"
expect_fail freeze-missing-peer-vouch \
  env LOCAL_EVIDENCE_ROOT="$evidence_root" VERIFY_LOCAL_FILES=true EXPECTED_CHAIN_PROFILE=testnet EXPECTED_CHAIN_ID=69420 \
  "$ROOT_DIR/scripts/validate-operator-audit-trail.sh" "$freeze_missing_peer"

printf '{"ok":true,"checked":"operator-audit-trail"}\n'
