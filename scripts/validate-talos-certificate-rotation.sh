#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${TALOS_CERTIFICATE_ROTATION:-${1:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_DESKTOP_EVIDENCE="${REQUIRE_DESKTOP_EVIDENCE:-false}"
MIN_CERT_VALIDITY_DAYS="${MIN_CERT_VALIDITY_DAYS:-30}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "talos-certificate-rotation: $*" >&2
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

normalize_hash() {
  tr '[:upper:]' '[:lower:]' <<<"${1#0x}"
}

validate_iso_time() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "$label is required"
  date -u -d "$value" '+%s' >/dev/null 2>&1 \
    || fail "$label must be an ISO-like UTC timestamp: $value"
}

epoch_seconds() {
  date -u -d "$1" '+%s'
}

days_until() {
  local value="$1"
  local expiry now
  expiry="$(epoch_seconds "$value")"
  now="$(date -u '+%s')"
  printf '%s' "$(((expiry - now) / 86400))"
}

canonical_rotation_payload_hash() {
  jq -cS '
    def norm_hash: ascii_downcase | ltrimstr("0x");
    def maybe_string($v): if ($v // "") == "" then null else $v end;
    def maybe_hash($v): if ($v // "") == "" then null else ($v | norm_hash) end;
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
  ' "$MANIFEST" | sha256sum | awk '{print $1}'
}

need date
need jq
need sha256sum

[[ -n "$MANIFEST" ]] || fail "TALOS_CERTIFICATE_ROTATION or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

[[ "$MIN_CERT_VALIDITY_DAYS" =~ ^[0-9]+$ && "$MIN_CERT_VALIDITY_DAYS" -gt 0 ]] \
  || fail "MIN_CERT_VALIDITY_DAYS must be a positive integer"

schema="$(field '.schema_version')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
rotation_id="$(field '.rotation.id')"
rotation_type="$(field '.rotation.type')"
reason="$(field '.rotation.reason')"
runbook_id="$(field '.rotation.runbook_id')"
opened_at="$(field '.rotation.opened_at')"
approval_threshold="$(field '.rotation.approval_threshold')"
node_id="$(field '.node.node_id')"
node_role="$(field '.node.role')"
current_endpoint="$(field '.node.current_endpoint')"
next_endpoint="$(field '.node.next_endpoint')"
current_ca="$(field '.current_identity.ca_fingerprint_sha256')"
current_client="$(field '.current_identity.client_fingerprint_sha256')"
current_ca_not_after="$(field '.current_identity.ca_not_after')"
current_client_not_after="$(field '.current_identity.client_not_after')"
next_ca="$(field '.next_identity.ca_fingerprint_sha256')"
next_client="$(field '.next_identity.client_fingerprint_sha256')"
next_ca_not_after="$(field '.next_identity.ca_not_after')"
next_client_not_after="$(field '.next_identity.client_not_after')"
current_talosconfig_sha="$(field '.talosconfig.current_sha256')"
next_talosconfig_sha="$(field '.talosconfig.next_sha256')"
current_talosconfig_path="$(field '.talosconfig.current_path')"
next_talosconfig_path="$(field '.talosconfig.next_path')"

[[ "$schema" == "monarch-talos-certificate-rotation/v1" ]] \
  || fail "unsupported schema_version: $schema"
[[ -n "$chain_profile" ]] || fail "chain.profile is required"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "chain.chain_id must be numeric: $chain_id"
if [[ -n "$EXPECTED_CHAIN_PROFILE" ]]; then
  [[ "$chain_profile" == "$EXPECTED_CHAIN_PROFILE" ]] \
    || fail "chain.profile mismatch: expected=$EXPECTED_CHAIN_PROFILE actual=$chain_profile"
fi
if [[ -n "$EXPECTED_CHAIN_ID" ]]; then
  [[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] \
    || fail "chain.chain_id mismatch: expected=$EXPECTED_CHAIN_ID actual=$chain_id"
fi

case "$rotation_type" in
  client-cert-renewal|ca-rotation|endpoint-change|emergency-rekey) ;;
  *) fail "rotation.type must be client-cert-renewal, ca-rotation, endpoint-change, or emergency-rekey: $rotation_type" ;;
esac
case "$reason" in
  scheduled|certificate-expiry|talos-ca-mismatch|node-endpoint-change|compromise|lost-talosconfig) ;;
  *) fail "rotation.reason is unsupported: $reason" ;;
esac
[[ -n "$rotation_id" ]] || fail "rotation.id is required"
[[ -n "$runbook_id" ]] || fail "rotation.runbook_id is required"
validate_iso_time "rotation.opened_at" "$opened_at"
[[ "$approval_threshold" =~ ^[1-9][0-9]*$ ]] \
  || fail "rotation.approval_threshold must be a positive integer"

case "$node_role" in
  operator-signing|archive|rpc|bridge|full) ;;
  *) fail "node.role is unsupported: $node_role" ;;
esac
[[ -n "$node_id" ]] || fail "node.node_id is required"
[[ -n "$current_endpoint" && -n "$next_endpoint" ]] \
  || fail "node current/next endpoints are required"

validate_hash32 "current_identity.ca_fingerprint_sha256" "$current_ca"
validate_hash32 "current_identity.client_fingerprint_sha256" "$current_client"
validate_hash32 "next_identity.ca_fingerprint_sha256" "$next_ca"
validate_hash32 "next_identity.client_fingerprint_sha256" "$next_client"
validate_hash32 "talosconfig.current_sha256" "$current_talosconfig_sha"
validate_hash32 "talosconfig.next_sha256" "$next_talosconfig_sha"
validate_iso_time "current_identity.ca_not_after" "$current_ca_not_after"
validate_iso_time "current_identity.client_not_after" "$current_client_not_after"
validate_iso_time "next_identity.ca_not_after" "$next_ca_not_after"
validate_iso_time "next_identity.client_not_after" "$next_client_not_after"
[[ -n "$current_talosconfig_path" && -n "$next_talosconfig_path" ]] \
  || fail "talosconfig current_path and next_path are required"
[[ "$current_talosconfig_path" != "$next_talosconfig_path" ]] \
  || fail "talosconfig.current_path and next_path must be distinct reviewed artifacts"
[[ "$(normalize_hash "$current_talosconfig_sha")" != "$(normalize_hash "$next_talosconfig_sha")" ]] \
  || fail "talosconfig.current_sha256 and next_sha256 must differ"

current_ca_norm="$(normalize_hash "$current_ca")"
current_client_norm="$(normalize_hash "$current_client")"
next_ca_norm="$(normalize_hash "$next_ca")"
next_client_norm="$(normalize_hash "$next_client")"

case "$rotation_type" in
  client-cert-renewal)
    [[ "$current_client_norm" != "$next_client_norm" ]] \
      || fail "client-cert-renewal must change the client certificate fingerprint"
    ;;
  ca-rotation)
    [[ "$current_ca_norm" != "$next_ca_norm" ]] \
      || fail "ca-rotation must change the Talos CA fingerprint"
    ;;
  endpoint-change)
    [[ "$current_endpoint" != "$next_endpoint" ]] \
      || fail "endpoint-change must change the Talos endpoint"
    ;;
  emergency-rekey)
    [[ "$current_ca_norm" != "$next_ca_norm" || "$current_client_norm" != "$next_client_norm" ]] \
      || fail "emergency-rekey must change the Talos CA or client certificate fingerprint"
    ;;
esac
[[ "$current_ca_norm" != "$next_ca_norm" || "$current_client_norm" != "$next_client_norm" || "$current_endpoint" != "$next_endpoint" ]] \
  || fail "rotation must change CA fingerprint, client fingerprint, or endpoint"

next_ca_days="$(days_until "$next_ca_not_after")"
next_client_days="$(days_until "$next_client_not_after")"
(( next_ca_days >= MIN_CERT_VALIDITY_DAYS )) \
  || fail "next Talos CA certificate is inside minimum validity window: ${next_ca_days}d < ${MIN_CERT_VALIDITY_DAYS}d"
(( next_client_days >= MIN_CERT_VALIDITY_DAYS )) \
  || fail "next Talos client certificate is inside minimum validity window: ${next_client_days}d < ${MIN_CERT_VALIDITY_DAYS}d"

desktop_present="$(jq -r '(.post_rotation.desktop_e2e_evidence // null) != null' "$MANIFEST")"
if [[ "$desktop_present" == "true" ]]; then
  desktop_schema="$(field '.post_rotation.desktop_e2e_evidence.schema_version')"
  desktop_sha="$(field '.post_rotation.desktop_e2e_evidence.sha256')"
  desktop_ca="$(field '.post_rotation.desktop_e2e_evidence.talos_ca_fingerprint_sha256')"
  desktop_endpoint="$(field '.post_rotation.desktop_e2e_evidence.talos_endpoint')"
  desktop_pin="$(field '.post_rotation.desktop_e2e_evidence.ca_pin_status')"
  desktop_min_days="$(field '.post_rotation.desktop_e2e_evidence.expires_min_days')"

  [[ "$desktop_schema" == "monarch-desktop-e2e-evidence/v1" ]] \
    || fail "post_rotation.desktop_e2e_evidence.schema_version must be monarch-desktop-e2e-evidence/v1"
  validate_hash32 "post_rotation.desktop_e2e_evidence.sha256" "$desktop_sha"
  validate_hash32 "post_rotation.desktop_e2e_evidence.talos_ca_fingerprint_sha256" "$desktop_ca"
  [[ "$(normalize_hash "$desktop_ca")" == "$next_ca_norm" ]] \
    || fail "post_rotation desktop evidence must bind the next Talos CA fingerprint"
  [[ "$desktop_endpoint" == "$next_endpoint" ]] \
    || fail "post_rotation desktop evidence must bind the next Talos endpoint"
  [[ "$desktop_pin" == "matched" || "$desktop_pin" == "trusted" ]] \
    || fail "post_rotation desktop evidence ca_pin_status must be matched or trusted"
  [[ "$desktop_min_days" =~ ^[0-9]+$ && "$desktop_min_days" -ge 14 ]] \
    || fail "post_rotation desktop evidence must prove certificates outside the 14-day rotation window"
elif bool_true "$REQUIRE_DESKTOP_EVIDENCE"; then
  fail "REQUIRE_DESKTOP_EVIDENCE=true requires post_rotation.desktop_e2e_evidence"
fi

approval_count="$(jq -r '[.approvals[]?.address] | unique | length' "$MANIFEST")"
(( approval_count >= approval_threshold )) \
  || fail "approvals must include at least $approval_threshold unique operator approvals"
jq -e '
  all(.approvals[]?;
    (.address | test("^0x[0-9a-fA-F]{40}$"))
    and .signature_scheme == "ML-DSA-65"
    and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,})$"))
  )
' "$MANIFEST" >/dev/null || fail "approvals must use ML-DSA-65 signatures, addresses, and signed payload hashes"

payload_hash="$(canonical_rotation_payload_hash)"
jq -e --arg payload_hash "$payload_hash" '
  def norm: ascii_downcase | ltrimstr("0x");
  all(.approvals[]?; (.signed_payload_hash | norm) == $payload_hash)
' "$MANIFEST" >/dev/null || fail "approval signed_payload_hash values must match canonical rotation payload hash"

jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg rotation_id "$rotation_id" \
  --arg rotation_type "$rotation_type" \
  --arg node_id "$node_id" \
  --arg current_endpoint "$current_endpoint" \
  --arg next_endpoint "$next_endpoint" \
  --arg next_ca "$next_ca_norm" \
  --arg next_client "$next_client_norm" \
  --arg payload_hash "$payload_hash" \
  --argjson approval_count "$approval_count" \
  --argjson approval_threshold "$approval_threshold" \
  --argjson desktop_evidence "$desktop_present" \
  '{
    ok: true,
    manifest: $manifest,
    schema_version: "monarch-talos-certificate-rotation/v1",
    chain: {profile: $chain_profile, chain_id: $chain_id},
    rotation: {
      id: $rotation_id,
      type: $rotation_type,
      canonical_payload_hash: $payload_hash,
      approvals: $approval_count,
      approval_threshold: $approval_threshold
    },
    node: {
      node_id: $node_id,
      current_endpoint: $current_endpoint,
      next_endpoint: $next_endpoint
    },
    next_identity: {
      ca_fingerprint_sha256: $next_ca,
      client_fingerprint_sha256: $next_client
    },
    desktop_evidence_checked: $desktop_evidence
  }'
