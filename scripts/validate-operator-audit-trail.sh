#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${OPERATOR_AUDIT_TRAIL:-${1:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
LOCAL_EVIDENCE_ROOT="${LOCAL_EVIDENCE_ROOT:-}"
VERIFY_LOCAL_FILES="${VERIFY_LOCAL_FILES:-auto}"
DESKTOP_OPERATION_RECEIPT_SCHEMA="monarch-desktop-operation-receipt/v1"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "operator-audit-trail: $*" >&2
  exit 1
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$MANIFEST"
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

validate_signature() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,}|github-attestation:[A-Za-z0-9_.:/@+-]+)$ ]] \
    || fail "$label must be a hex, base64, or GitHub attestation signature"
}

validate_actor() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40}|ci:[A-Za-z0-9_.:-]+)$ ]] \
    || fail "$label must be mono1..., 0x..., or ci:..."
}

hash32_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local expected_norm actual_norm

  expected_norm="$(tr '[:upper:]' '[:lower:]' <<<"${expected#0x}")"
  actual_norm="$(tr '[:upper:]' '[:lower:]' <<<"${actual#0x}")"
  [[ "$expected_norm" == "$actual_norm" ]] \
    || fail "$label mismatch: expected=$expected actual=$actual"
}

local_path_for() {
  local remote_path="$1"

  if [[ -n "$LOCAL_EVIDENCE_ROOT" ]]; then
    printf '%s/%s' "${LOCAL_EVIDENCE_ROOT%/}" "${remote_path#/}"
    return
  fi
  printf '%s' "$remote_path"
}

verify_file_hash() {
  local label="$1"
  local remote_path="$2"
  local expected_sha="$3"
  local local_path actual_sha size_bytes

  [[ -n "$remote_path" ]] || fail "$label path is required"
  [[ -n "$expected_sha" ]] || fail "$label expected sha256 is required"
  local_path="$(local_path_for "$remote_path")"
  [[ -f "$local_path" ]] || fail "$label file not found: $local_path"
  actual_sha="$(sha256sum "$local_path" | awk '{print $1}')"
  size_bytes="$(wc -c <"$local_path" | tr -d '[:space:]')"
  hash32_equals "$label sha256" "$expected_sha" "$actual_sha"

  jq -n \
    --arg label "$label" \
    --arg path "$remote_path" \
    --arg local_path "$local_path" \
    --arg sha256 "$actual_sha" \
    --argjson size_bytes "$size_bytes" \
    '{label: $label, path: $path, local_path: $local_path, sha256: $sha256, size_bytes: $size_bytes}'
}

canonical_desktop_operation_receipt_hash() {
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

verify_desktop_receipt_file() {
  local evidence_index="$1"
  local label="$2"
  local remote_path="$3"
  local local_path receipt_id receipt_schema receipt_hash computed_hash manifest_count

  [[ -n "$remote_path" ]] || fail "desktop receipt evidence[$evidence_index].$label path is required"
  local_path="$(local_path_for "$remote_path")"
  [[ -f "$local_path" ]] || fail "desktop receipt evidence[$evidence_index].$label file not found: $local_path"
  receipt_id="$(jq -r '.id // ""' "$local_path")"
  receipt_schema="$(jq -r '.auditPayloadSchema // .audit_payload_schema // ""' "$local_path")"
  receipt_hash="$(jq -r '.auditPayloadHash // .audit_payload_hash // ""' "$local_path")"

  [[ -n "$receipt_id" ]] || fail "desktop receipt evidence[$evidence_index].$label id is required"
  [[ "$receipt_schema" == "$DESKTOP_OPERATION_RECEIPT_SCHEMA" ]] \
    || fail "desktop receipt evidence[$evidence_index].$label has unsupported auditPayloadSchema: $receipt_schema"
  validate_hash32 "desktop receipt evidence[$evidence_index].$label auditPayloadHash" "$receipt_hash"
  computed_hash="$(canonical_desktop_operation_receipt_hash "$local_path")"
  hash32_equals "desktop receipt evidence[$evidence_index].$label auditPayloadHash" "$computed_hash" "$receipt_hash"

  manifest_count="$(jq -r \
    --arg id "$receipt_id" \
    --arg schema "$DESKTOP_OPERATION_RECEIPT_SCHEMA" \
    --arg receipt_hash "${receipt_hash#0x}" '
      [
        .receipts[]?
        | select(
            .source == "desktop"
            and .id == $id
            and .audit_payload_schema == $schema
            and ((.audit_payload_hash | ascii_downcase | ltrimstr("0x")) == ($receipt_hash | ascii_downcase))
        )
      ] | length
    ' "$MANIFEST")"
  (( manifest_count >= 1 )) \
    || fail "desktop receipt evidence[$evidence_index].$label is not mirrored by a matching audited Desktop receipt entry"
}

canonical_audit_payload_hash() {
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
  ' "$MANIFEST" | sha256sum | awk '{print $1}'
}

need jq
need sha256sum

[[ -n "$MANIFEST" ]] || fail "OPERATOR_AUDIT_TRAIL or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$MANIFEST" >/dev/null; then
  fail "manifest contains placeholder string values"
fi

schema="$(field '.schema_version')"
audit_id="$(field '.audit.id')"
created_at="$(field '.audit.created_at')"
action="$(field '.audit.action')"
reason="$(field '.audit.reason')"
previous_audit_hash="$(field '.audit.previous_audit_hash')"
chain_profile="$(field '.chain.profile')"
chain_id="$(field '.chain.chain_id')"
actor_role="$(field '.actor.role')"
actor_address="$(field '.actor.address')"
release_metadata_sha="$(field '.release.metadata_sha256')"
protocore_digest="$(field '.release.protocore_digest')"
subject_type="$(field '.subject.type')"
subject_id="$(field '.subject.id')"
subject_sha="$(field '.subject.sha256')"
intent_summary="$(field '.intent.summary')"
expected_state_hash="$(field '.intent.expected_state_hash')"
diff_vs_intent_hash="$(field '.intent.diff_vs_intent_hash')"
intent_risk="$(field '.intent.risk')"

[[ "$schema" == "monarch-operator-audit-trail/v1" ]] \
  || fail "unsupported schema_version: $schema"
[[ -n "$audit_id" ]] || fail "audit.id is required"
[[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "audit.created_at must be an RFC3339 UTC timestamp"
case "$action" in
  enrollment|dkg-ceremony|tpm-sealing|key-share-handoff|key-share-rotation|certificate-rotation|backup|restore|disaster-recovery|incident-response|freeze-admission|kill-switch-freeze|upgrade|rollback|desktop-operation|chat-e2e|release-promotion) ;;
  *) fail "audit.action is unsupported: $action" ;;
esac
[[ -n "$reason" ]] || fail "audit.reason is required"
if [[ -n "$previous_audit_hash" ]]; then
  validate_hash32 "audit.previous_audit_hash" "$previous_audit_hash"
fi

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

case "$actor_role" in
  operator|foundation|desktop|os-ci|automation) ;;
  *) fail "actor.role is unsupported: $actor_role" ;;
esac
validate_actor "actor.address" "$actor_address"
actor_index="$(field '.actor.operator_index')"
if [[ -n "$actor_index" ]]; then
  [[ "$actor_index" =~ ^[0-9]+$ ]] || fail "actor.operator_index must be numeric"
  (( actor_index >= 0 && actor_index <= 9 )) || fail "actor.operator_index must be 0 through 9"
fi
actor_cluster="$(field '.actor.cluster_id')"
if [[ -n "$actor_cluster" ]]; then
  [[ "$actor_cluster" =~ ^[0-9]+$ ]] || fail "actor.cluster_id must be numeric"
fi

validate_hash32 "release.metadata_sha256" "$release_metadata_sha"
validate_hash32 "release.protocore_digest" "$protocore_digest"
case "$subject_type" in
  enrollment|key-share-ceremony|tpm-sealing-evidence|key-share-handoff|incident-response|disaster-recovery|talos-certificate-rotation|offline-backup|offline-restore|desktop-operation|desktop-e2e|release) ;;
  *) fail "subject.type is unsupported: $subject_type" ;;
esac
[[ -n "$subject_id" ]] || fail "subject.id is required"
if [[ -n "$subject_sha" ]]; then
  validate_hash32 "subject.sha256" "$subject_sha"
fi

[[ -n "$intent_summary" ]] || fail "intent.summary is required"
validate_hash32 "intent.expected_state_hash" "$expected_state_hash"
validate_hash32 "intent.diff_vs_intent_hash" "$diff_vs_intent_hash"
case "$intent_risk" in
  low|medium|high|critical) ;;
  *) fail "intent.risk must be low, medium, high, or critical" ;;
esac

jq -e '(.evidence // []) | length >= 1' "$MANIFEST" >/dev/null \
  || fail "evidence must include at least one hash-bound item"
jq -e '
  all(.evidence[]?;
    (.label | type == "string" and length > 0)
    and (.type | IN("manifest", "receipt", "tx", "file", "desktop-e2e", "smoke-qemu", "talos-read", "rpc", "operator-note"))
    and (.sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
  )
' "$MANIFEST" >/dev/null || fail "evidence entries must include label, type, and sha256"

local_files_checked=false
case "$VERIFY_LOCAL_FILES" in
  auto|AUTO)
    [[ -n "$LOCAL_EVIDENCE_ROOT" ]] && local_files_checked=true
    ;;
  true|TRUE|1|yes|YES|on|ON)
    local_files_checked=true
    ;;
  false|FALSE|0|no|NO|off|OFF)
    local_files_checked=false
    ;;
  *)
    fail "VERIFY_LOCAL_FILES must be auto, true, or false"
    ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
items="$tmp_dir/file-hashes.items"
: >"$items"
if [[ "$local_files_checked" == "true" ]]; then
  while IFS=$'\t' read -r index label path sha; do
    [[ -n "$index" ]] || continue
    if [[ -n "$path" ]]; then
      verify_file_hash "evidence[$index].$label" "$path" "$sha" >>"$items"
    fi
  done < <(jq -r '.evidence | to_entries[] | [
    .key,
    .value.label,
    (.value.path // ""),
    .value.sha256
  ] | @tsv' "$MANIFEST")

  while IFS=$'\t' read -r index label path schema sha; do
    [[ -n "$index" ]] || continue
    if [[ "$schema" == "$DESKTOP_OPERATION_RECEIPT_SCHEMA" ]]; then
      verify_desktop_receipt_file "$index" "$label" "$path"
    fi
  done < <(jq -r '.evidence | to_entries[] | [
    .key,
    .value.label,
    (.value.path // ""),
    (.value.schema_version // ""),
    .value.sha256
  ] | @tsv' "$MANIFEST")
fi

if jq -e 'has("receipts")' "$MANIFEST" >/dev/null; then
  jq -e '
    all(.receipts[]?;
      (.source | IN("desktop", "talos", "on-chain", "ci", "operator"))
      and (.status == "ok" or .status == "error")
      and (.id | type == "string" and length > 0)
    )
  ' "$MANIFEST" >/dev/null || fail "receipts entries must include source, status, and id"
  while IFS=$'\t' read -r index tx_hash dag_round quorum_hash artifact_sha; do
    [[ -n "$index" ]] || continue
    if [[ -n "$tx_hash" ]]; then
      validate_tx_hash "receipts[$index].tx_hash" "$tx_hash"
    fi
    if [[ -n "$dag_round" ]]; then
      [[ "$dag_round" =~ ^[0-9]+$ ]] || fail "receipts[$index].dag_round must be numeric"
    fi
    if [[ -n "$quorum_hash" ]]; then
      validate_hash32 "receipts[$index].quorum_certificate_hash" "$quorum_hash"
    fi
    if [[ -n "$artifact_sha" ]]; then
      validate_hash32 "receipts[$index].artifact_sha256" "$artifact_sha"
    fi
  done < <(jq -r '.receipts // [] | to_entries[] | [
    .key,
    (.value.tx_hash // ""),
    (.value.dag_round // ""),
    (.value.quorum_certificate_hash // ""),
    (.value.artifact_sha256 // "")
  ] | @tsv' "$MANIFEST")

  while IFS=$'\t' read -r index source audit_schema audit_hash; do
    [[ -n "$index" ]] || continue
    if [[ "$source" == "desktop" ]]; then
      [[ "$audit_schema" == "$DESKTOP_OPERATION_RECEIPT_SCHEMA" ]] \
        || fail "receipts[$index].audit_payload_schema must be $DESKTOP_OPERATION_RECEIPT_SCHEMA for Desktop receipts"
      validate_hash32 "receipts[$index].audit_payload_hash" "$audit_hash"
    elif [[ -n "$audit_schema" || -n "$audit_hash" ]]; then
      [[ -n "$audit_schema" && -n "$audit_hash" ]] \
        || fail "receipts[$index] audit payload schema/hash must be supplied together"
      validate_hash32 "receipts[$index].audit_payload_hash" "$audit_hash"
    fi
  done < <(jq -r '.receipts // [] | to_entries[] | [
    .key,
    .value.source,
    (.value.audit_payload_schema // ""),
    (.value.audit_payload_hash // "")
  ] | @tsv' "$MANIFEST")
fi

payload_hash="$(canonical_audit_payload_hash)"
approval_count="$(jq -r '[.approvals[]?.signer] | unique | length' "$MANIFEST")"
(( approval_count >= 1 )) || fail "approvals must include at least one unique signer"

case "$intent_risk:$action" in
  high:*|critical:*|*:dkg-ceremony|*:key-share-rotation|*:disaster-recovery|*:incident-response|*:freeze-admission|*:kill-switch-freeze|*:upgrade|*:rollback|*:release-promotion)
    (( approval_count >= 2 )) || fail "high-risk and production-control audit trails require at least two unique approvals"
    ;;
esac

jq -e '
  all(.approvals[]?;
    (.signer | test("^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40}|ci:[A-Za-z0-9_.:-]+)$"))
    and (.signer_role | IN("operator", "foundation", "desktop", "os-ci", "automation", "peer"))
    and (.signature_scheme | IN("ML-DSA-65", "SLH-DSA", "ci-attestation"))
    and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,}|github-attestation:[A-Za-z0-9_.:/@+-]+)$"))
  )
' "$MANIFEST" >/dev/null || fail "approvals entries must include signer, signer role, scheme, signed payload hash, and signature"
while IFS=$'\t' read -r index signed_hash signature; do
  [[ -n "$index" ]] || continue
  validate_hash32 "approvals[$index].signed_payload_hash" "$signed_hash"
  validate_signature "approvals[$index].signature" "$signature"
  hash32_equals "approvals[$index].signed_payload_hash" "$payload_hash" "$signed_hash"
done < <(jq -r '.approvals | to_entries[] | [.key, .value.signed_payload_hash, .value.signature] | @tsv' "$MANIFEST")

peer_vouch_count="$(jq -r '[.peer_vouches[]?.address] | unique | length' "$MANIFEST")"
case "$action" in
  freeze-admission|kill-switch-freeze)
    (( peer_vouch_count >= 2 )) || fail "$action audit trails require at least two peer vouches"
    jq -e '
      all(.peer_vouches[]?;
        (.peer_id | type == "string" and length > 0)
        and (.address | test("^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$"))
        and (.signed_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
        and (.signature | test("^(0x[0-9a-fA-F]{128,}|[A-Za-z0-9+/=]{128,}|github-attestation:[A-Za-z0-9_.:/@+-]+)$"))
      )
    ' "$MANIFEST" >/dev/null || fail "peer_vouches entries must include peer id, address, signed payload hash, and signature"
    while IFS=$'\t' read -r index signed_hash signature; do
      [[ -n "$index" ]] || continue
      validate_hash32 "peer_vouches[$index].signed_payload_hash" "$signed_hash"
      validate_signature "peer_vouches[$index].signature" "$signature"
      hash32_equals "peer_vouches[$index].signed_payload_hash" "$payload_hash" "$signed_hash"
    done < <(jq -r '.peer_vouches | to_entries[] | [.key, .value.signed_payload_hash, .value.signature] | @tsv' "$MANIFEST")
    ;;
esac

if [[ "$subject_type" == "desktop-operation" || "$action" == "desktop-operation" ]]; then
  jq -e --arg schema "$DESKTOP_OPERATION_RECEIPT_SCHEMA" '
    any(.receipts[]?;
      .source == "desktop"
      and .id != ""
      and .audit_payload_schema == $schema
      and (.audit_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    )
  ' "$MANIFEST" >/dev/null \
    || fail "desktop-operation audit trails require an audited Desktop receipt"
fi
if [[ "$action" == "release-promotion" ]]; then
  jq -e 'any(.evidence[]?; .type == "desktop-e2e")' "$MANIFEST" >/dev/null \
    || fail "release-promotion audit trails require Desktop e2e evidence"
fi

file_hashes="$(jq -s '.' "$items")"
jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg audit_id "$audit_id" \
  --arg action "$action" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg actor_role "$actor_role" \
  --arg actor_address "$actor_address" \
  --arg subject_type "$subject_type" \
  --arg subject_id "$subject_id" \
  --arg payload_hash "$payload_hash" \
  --argjson approval_count "$approval_count" \
  --argjson peer_vouch_count "$peer_vouch_count" \
  --argjson evidence_count "$(jq -r '.evidence | length' "$MANIFEST")" \
  --argjson local_files_checked "$([[ "$local_files_checked" == "true" ]] && printf true || printf false)" \
  --argjson file_hashes "$file_hashes" \
  '{
    ok: true,
    manifest: $manifest,
    audit: {id: $audit_id, action: $action, signed_payload_hash: $payload_hash},
    chain: {profile: $chain_profile, chain_id: $chain_id},
    actor: {role: $actor_role, address: $actor_address},
    subject: {type: $subject_type, id: $subject_id},
    approval_count: $approval_count,
    peer_vouch_count: $peer_vouch_count,
    evidence_count: $evidence_count,
    local_files_checked: $local_files_checked,
    file_hashes: $file_hashes
  }'
