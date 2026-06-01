#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROTOCORE_DATA_DIR="${PROTOCORE_DATA_DIR:-${1:-}}"
BACKUP_RELEASE_METADATA="${BACKUP_RELEASE_METADATA:-${2:-}}"
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-"$ROOT_DIR/_out/protocore-backups"}"
BACKUP_NODE_ID="${BACKUP_NODE_ID:-}"
BACKUP_NODE_ROLE="${BACKUP_NODE_ROLE:-archive}"
BACKUP_MODE="${BACKUP_MODE:-stopped-protocore-archive}"
BACKUP_SERVICE_STATE="${BACKUP_SERVICE_STATE:-}"
BACKUP_SERVICE_EVIDENCE="${BACKUP_SERVICE_EVIDENCE:-}"
BACKUP_ARCHIVE_NAME="${BACKUP_ARCHIVE_NAME:-}"
BACKUP_OVERWRITE="${BACKUP_OVERWRITE:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "protocore-offline-backup: $*" >&2
  exit 1
}

field() {
  local path="$1"
  local file="$2"
  jq -r "$path // \"\"" "$file"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

file_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
  fi
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || fail "$label must be a 32-byte hex digest"
}

need date
need gzip
need jq
need sha256sum
need tar

[[ -n "$PROTOCORE_DATA_DIR" ]] || fail "PROTOCORE_DATA_DIR or first argument is required"
[[ -d "$PROTOCORE_DATA_DIR" ]] || fail "PROTOCORE_DATA_DIR is not a directory: $PROTOCORE_DATA_DIR"
data_abs="$(abs_path "$PROTOCORE_DATA_DIR")"
[[ "$data_abs" != "/" ]] || fail "refusing to archive filesystem root"
shopt -s nullglob dotglob
data_entries=("$PROTOCORE_DATA_DIR"/*)
shopt -u nullglob dotglob
((${#data_entries[@]} > 0)) || fail "PROTOCORE_DATA_DIR is empty: $PROTOCORE_DATA_DIR"
[[ -n "$BACKUP_RELEASE_METADATA" ]] || fail "BACKUP_RELEASE_METADATA or second argument is required"
[[ -f "$BACKUP_RELEASE_METADATA" ]] || fail "release metadata not found: $BACKUP_RELEASE_METADATA"
[[ -n "$BACKUP_NODE_ID" ]] || fail "BACKUP_NODE_ID is required"
[[ -n "$BACKUP_SERVICE_EVIDENCE" ]] || fail "BACKUP_SERVICE_EVIDENCE is required"
[[ -f "$BACKUP_SERVICE_EVIDENCE" ]] || fail "service evidence file not found: $BACKUP_SERVICE_EVIDENCE"

case "$BACKUP_NODE_ROLE" in
  archive|operator-signing|rpc|bridge) ;;
  *) fail "BACKUP_NODE_ROLE must be archive, operator-signing, rpc, or bridge: $BACKUP_NODE_ROLE" ;;
esac

case "$BACKUP_MODE" in
  offline-snapshot|stopped-protocore-archive) ;;
  resync) fail "resync does not create a /var/lib/protocore backup archive" ;;
  *) fail "BACKUP_MODE must be offline-snapshot or stopped-protocore-archive: $BACKUP_MODE" ;;
esac

case "$BACKUP_SERVICE_STATE" in
  stopped|offline) ;;
  running|starting|restarting|degraded|unknown|"")
    fail "hot backups are refused; BACKUP_SERVICE_STATE must be stopped or offline"
    ;;
  *) fail "BACKUP_SERVICE_STATE must be stopped or offline: $BACKUP_SERVICE_STATE" ;;
esac

jq -e . "$BACKUP_RELEASE_METADATA" >/dev/null || fail "release metadata is not valid JSON"
metadata_schema="$(field '.schema_version' "$BACKUP_RELEASE_METADATA")"
[[ "$metadata_schema" == "monarch-os-release-metadata/v1" ]] \
  || fail "release metadata schema unsupported: $metadata_schema"

chain_profile="$(field '.channel.chain.profile' "$BACKUP_RELEASE_METADATA")"
chain_id="$(field '.channel.chain.chain_id' "$BACKUP_RELEASE_METADATA")"
genesis_sha="$(field '.channel.chain.genesis.sha256' "$BACKUP_RELEASE_METADATA")"
protocore_digest="$(field '.sources.protocore_binary.sha256' "$BACKUP_RELEASE_METADATA")"
release_channel="$(field '.channel.name' "$BACKUP_RELEASE_METADATA")"
protocore_version="$(field '.channel.compatibility.protocore.version' "$BACKUP_RELEASE_METADATA")"

[[ -n "$chain_profile" ]] || fail "release metadata lacks channel.chain.profile"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "release metadata chain id must be numeric: $chain_id"
validate_hash32 "release metadata genesis sha" "$genesis_sha"
validate_hash32 "release metadata protocore digest" "$protocore_digest"

mkdir -p "$BACKUP_OUTPUT_DIR"
output_abs="$(abs_path "$BACKUP_OUTPUT_DIR")"
case "$output_abs/" in
  "$data_abs"/*) fail "BACKUP_OUTPUT_DIR must not be inside PROTOCORE_DATA_DIR" ;;
esac
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
safe_node_id="$(printf '%s' "$BACKUP_NODE_ID" | tr -c 'A-Za-z0-9._-' '_')"
if [[ -n "$BACKUP_ARCHIVE_NAME" ]]; then
  archive_name="$BACKUP_ARCHIVE_NAME"
else
  archive_name="protocore-${safe_node_id}-${timestamp}.tar.gz"
fi
[[ "$archive_name" == *.tar.gz ]] || archive_name="$archive_name.tar.gz"
archive_path="$BACKUP_OUTPUT_DIR/$archive_name"
manifest_path="${archive_path%.tar.gz}.backup.json"

if [[ -e "$archive_path" || -e "$manifest_path" ]]; then
  bool_true "$BACKUP_OVERWRITE" || fail "backup output already exists; set BACKUP_OVERWRITE=true to replace it"
fi

tar -C "$PROTOCORE_DATA_DIR" -czf "$archive_path" .

archive_sha="$(file_sha256 "$archive_path")"
metadata_sha="$(file_sha256 "$BACKUP_RELEASE_METADATA")"
service_evidence_sha="$(file_sha256 "$BACKUP_SERVICE_EVIDENCE")"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
archive_abs="$(abs_path "$archive_path")"
manifest_abs="$(abs_path "$manifest_path")"
metadata_abs="$(abs_path "$BACKUP_RELEASE_METADATA")"
evidence_abs="$(abs_path "$BACKUP_SERVICE_EVIDENCE")"

jq -n \
  --arg created_at "$created_at" \
  --arg node_id "$BACKUP_NODE_ID" \
  --arg node_role "$BACKUP_NODE_ROLE" \
  --arg data_dir "$data_abs" \
  --arg archive_path "$archive_abs" \
  --arg archive_sha "$archive_sha" \
  --arg manifest_path "$manifest_abs" \
  --arg release_metadata "$metadata_abs" \
  --arg release_metadata_sha "$metadata_sha" \
  --arg release_channel "$release_channel" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg genesis_sha "$genesis_sha" \
  --arg protocore_version "$protocore_version" \
  --arg protocore_digest "$protocore_digest" \
  --arg backup_mode "$BACKUP_MODE" \
  --arg service_state "$BACKUP_SERVICE_STATE" \
  --arg service_evidence "$evidence_abs" \
  --arg service_evidence_sha "$service_evidence_sha" \
  '{
    schema_version: "monarch-protocore-offline-backup/v1",
    created_at: $created_at,
    ok: true,
    hot_backup: false,
    node: {
      node_id: $node_id,
      role: $node_role,
      signing_node_restore_blocked_until_key_share_recovery: ($node_role == "operator-signing")
    },
    source: {
      data_dir: $data_dir,
      expected_restore_path: "/var/lib/protocore"
    },
    release: {
      metadata_path: $release_metadata,
      metadata_sha256: $release_metadata_sha,
      channel: $release_channel,
      protocore_version: $protocore_version,
      protocore_digest: $protocore_digest
    },
    chain: {
      profile: $chain_profile,
      chain_id: $chain_id,
      genesis_sha256: $genesis_sha
    },
    backup: {
      mode: $backup_mode,
      protocore_service_state: $service_state,
      service_state_evidence_path: $service_evidence,
      service_state_evidence_sha256: $service_evidence_sha,
      archive_path: $archive_path,
      archive_sha256: $archive_sha,
      encrypted_by_this_tool: false
    },
    disaster_recovery_manifest_fields: {
      chain: {
        profile: $chain_profile,
        chain_id: ($chain_id | tonumber),
        genesis_sha256: $genesis_sha
      },
      release: {
        metadata_sha256: $release_metadata_sha,
        protocore_digest: $protocore_digest
      },
      backup: {
        mode: $backup_mode,
        protocore_service_state: $service_state,
        hot_backup: false,
        storage_uri: ("file://" + $archive_path),
        var_lib_protocore_sha256: $archive_sha
      },
      restore: {
        restore_path: "/var/lib/protocore",
        service_stopped_before_restore: true,
        post_restore_checks: [
          "release-digest-match",
          "genesis-match",
          "chain-id-match",
          "protocore-rpc-healthy"
        ]
      }
    }
  }' > "$manifest_path"

(cd "$(dirname "$manifest_path")" && sha256sum "$(basename "$manifest_path")" > "$(basename "$manifest_path").sha256")

jq -n \
  --arg archive "$archive_abs" \
  --arg archive_sha "$archive_sha" \
  --arg manifest "$manifest_abs" \
  --arg manifest_sha "$(file_sha256 "$manifest_path")" \
  '{
    ok: true,
    checked: "protocore-offline-backup",
    archive: $archive,
    archive_sha256: $archive_sha,
    manifest: $manifest,
    manifest_sha256: $manifest_sha
  }'
