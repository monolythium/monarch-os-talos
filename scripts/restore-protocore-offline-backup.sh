#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESTORE_BACKUP_MANIFEST="${RESTORE_BACKUP_MANIFEST:-${1:-}}"
RESTORE_OUTPUT_DIR="${RESTORE_OUTPUT_DIR:-${2:-}}"
RESTORE_SERVICE_STATE="${RESTORE_SERVICE_STATE:-}"
RESTORE_SERVICE_EVIDENCE="${RESTORE_SERVICE_EVIDENCE:-}"
RESTORE_EVIDENCE_OUTPUT="${RESTORE_EVIDENCE_OUTPUT:-}"
RESTORE_RELEASE_METADATA="${RESTORE_RELEASE_METADATA:-}"
RESTORE_OVERWRITE="${RESTORE_OVERWRITE:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "protocore-offline-restore: $*" >&2
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

abs_target_path() {
  local path="$1"
  local dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$dir"
  printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || fail "$label must be a 32-byte hex digest"
}

offline_state() {
  local lower="${1,,}"
  [[ "$lower" == "stopped" || "$lower" == "offline" || "$lower" == "down" || "$lower" == *stop* || "$lower" == *down* ]]
}

directory_has_entries() {
  local dir="$1"
  shopt -s nullglob dotglob
  local entries=("$dir"/*)
  shopt -u nullglob dotglob
  ((${#entries[@]} > 0))
}

safe_remove_restore_dir() {
  local restore_abs="$1"
  local marker_abs="$2"

  [[ -n "$restore_abs" ]] || fail "empty restore path"
  [[ "$restore_abs" != "/" ]] || fail "refusing to overwrite filesystem root"
  [[ "$restore_abs" != "$ROOT_DIR" ]] || fail "refusing to overwrite repository root"
  [[ "$restore_abs" != "$HOME" ]] || fail "refusing to overwrite home directory"
  [[ -f "$marker_abs" ]] || fail "refusing to overwrite non-empty restore output without restore marker: $restore_abs"
  jq -e --arg path "$restore_abs" '
    .schema_version == "monarch-protocore-offline-restore-marker/v1"
    and .restore_path == $path
  ' "$marker_abs" >/dev/null || fail "restore marker does not match restore output: $marker_abs"

  rm -rf "$restore_abs"
}

validate_tar_entries() {
  local archive="$1"
  local entry line type

  tar -tzf "$archive" >/dev/null || fail "archive is not a readable gzip tarball: $archive"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    case "$entry" in
      /*|../*|*/../*|*/..|..)
        fail "archive contains unsafe path entry: $entry"
        ;;
    esac
  done < <(tar -tzf "$archive")

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    type="${line:0:1}"
    case "$type" in
      -|d) ;;
      *) fail "archive contains unsupported entry type; only files and directories are allowed" ;;
    esac
  done < <(tar -tvzf "$archive")
}

tree_sha256() {
  local dir="$1"
  (
    cd "$dir"
    find . -type f -print0 \
      | sort -z \
      | while IFS= read -r -d '' file; do
          sha256sum "$file"
        done \
      | sha256sum \
      | awk '{print $1}'
  )
}

need date
need find
need jq
need sha256sum
need sort
need tar

[[ -n "$RESTORE_BACKUP_MANIFEST" ]] || fail "RESTORE_BACKUP_MANIFEST or first argument is required"
[[ -f "$RESTORE_BACKUP_MANIFEST" ]] || fail "backup manifest not found: $RESTORE_BACKUP_MANIFEST"
[[ -n "$RESTORE_OUTPUT_DIR" ]] || fail "RESTORE_OUTPUT_DIR or second argument is required"
[[ -n "$RESTORE_SERVICE_EVIDENCE" ]] || fail "RESTORE_SERVICE_EVIDENCE is required"
[[ -f "$RESTORE_SERVICE_EVIDENCE" ]] || fail "restore service evidence file not found: $RESTORE_SERVICE_EVIDENCE"

case "$RESTORE_SERVICE_STATE" in
  stopped|offline) ;;
  running|starting|restarting|degraded|unknown|"")
    fail "restore is refused unless RESTORE_SERVICE_STATE is stopped or offline"
    ;;
  *) fail "RESTORE_SERVICE_STATE must be stopped or offline: $RESTORE_SERVICE_STATE" ;;
esac

jq -e . "$RESTORE_BACKUP_MANIFEST" >/dev/null || fail "backup manifest is not valid JSON"
manifest_schema="$(field '.schema_version' "$RESTORE_BACKUP_MANIFEST")"
case "$manifest_schema" in
  monarch-protocore-offline-backup/v1)
    manifest_source="os"
    ;;
  monarch-desktop-protocore-backup/v1)
    manifest_source="desktop"
    ;;
  *)
    fail "backup manifest schema unsupported: $manifest_schema"
    ;;
esac

manifest_ok="$(jq -r '.ok == true' "$RESTORE_BACKUP_MANIFEST")"
[[ "$manifest_ok" == "true" ]] || fail "backup manifest is not ok"
hot_backup="$(jq -r '.hot_backup == true' "$RESTORE_BACKUP_MANIFEST")"
[[ "$hot_backup" == "false" ]] || fail "hot backup manifests cannot be restored"

release_metadata_path=""
release_metadata_sha=""

if [[ "$manifest_source" == "os" ]]; then
  backup_service_state="$(field '.backup.protocore_service_state' "$RESTORE_BACKUP_MANIFEST")"
  archive_path="$(field '.backup.archive_path' "$RESTORE_BACKUP_MANIFEST")"
  archive_sha="$(field '.backup.archive_sha256' "$RESTORE_BACKUP_MANIFEST")"
  expected_restore_path="$(field '.source.expected_restore_path' "$RESTORE_BACKUP_MANIFEST")"
  chain_profile="$(field '.chain.profile' "$RESTORE_BACKUP_MANIFEST")"
  chain_id="$(field '.chain.chain_id' "$RESTORE_BACKUP_MANIFEST")"
  genesis_sha="$(field '.chain.genesis_sha256' "$RESTORE_BACKUP_MANIFEST")"
  release_channel="$(field '.release.channel' "$RESTORE_BACKUP_MANIFEST")"
  protocore_version="$(field '.release.protocore_version' "$RESTORE_BACKUP_MANIFEST")"
  protocore_digest="$(field '.release.protocore_digest' "$RESTORE_BACKUP_MANIFEST")"
  release_metadata_path="$(field '.release.metadata_path' "$RESTORE_BACKUP_MANIFEST")"
  release_metadata_sha="$(field '.release.metadata_sha256' "$RESTORE_BACKUP_MANIFEST")"
  node_id="$(field '.node.node_id' "$RESTORE_BACKUP_MANIFEST")"
  node_role="$(field '.node.role' "$RESTORE_BACKUP_MANIFEST")"
else
  backup_service_state="$(field '.talos.service_state' "$RESTORE_BACKUP_MANIFEST")"
  [[ -n "$backup_service_state" ]] || backup_service_state="$(field '.talos.service_raw_state' "$RESTORE_BACKUP_MANIFEST")"
  archive_path="$(field '.backup.archive_path' "$RESTORE_BACKUP_MANIFEST")"
  archive_sha="$(field '.backup.archive_sha256' "$RESTORE_BACKUP_MANIFEST")"
  expected_restore_path="$(field '.source.expected_restore_path' "$RESTORE_BACKUP_MANIFEST")"
  [[ -n "$expected_restore_path" ]] || expected_restore_path="$(field '.source.path' "$RESTORE_BACKUP_MANIFEST")"
  node_id="$(field '.talos.node_address' "$RESTORE_BACKUP_MANIFEST")"
  [[ -n "$node_id" ]] || node_id="$(field '.talos.endpoint' "$RESTORE_BACKUP_MANIFEST")"
  node_role="archive"

  [[ -n "$RESTORE_RELEASE_METADATA" ]] \
    || fail "RESTORE_RELEASE_METADATA is required when restoring a monarch-desktop-protocore-backup/v1 manifest"
  [[ -f "$RESTORE_RELEASE_METADATA" ]] || fail "release metadata not found: $RESTORE_RELEASE_METADATA"
  jq -e . "$RESTORE_RELEASE_METADATA" >/dev/null || fail "release metadata is not valid JSON"
  release_metadata_schema="$(field '.schema_version' "$RESTORE_RELEASE_METADATA")"
  [[ "$release_metadata_schema" == "monarch-os-release-metadata/v1" ]] \
    || fail "release metadata schema unsupported: $release_metadata_schema"

  chain_profile="$(field '.channel.chain.profile' "$RESTORE_RELEASE_METADATA")"
  chain_id="$(field '.channel.chain.chain_id' "$RESTORE_RELEASE_METADATA")"
  genesis_sha="$(field '.channel.chain.genesis.sha256' "$RESTORE_RELEASE_METADATA")"
  release_channel="$(field '.channel.name' "$RESTORE_RELEASE_METADATA")"
  protocore_version="$(field '.channel.compatibility.protocore.version' "$RESTORE_RELEASE_METADATA")"
  protocore_digest="$(field '.sources.protocore_binary.sha256' "$RESTORE_RELEASE_METADATA")"
  release_metadata_path="$(abs_path "$RESTORE_RELEASE_METADATA")"
  release_metadata_sha="$(file_sha256 "$RESTORE_RELEASE_METADATA")"
fi

offline_state "$backup_service_state" || fail "backup manifest does not prove stopped/offline service state"

[[ -n "$archive_path" ]] || fail "backup manifest lacks backup.archive_path"
[[ -f "$archive_path" ]] || fail "backup archive not found: $archive_path"
validate_hash32 "backup archive sha" "$archive_sha"
[[ -n "$expected_restore_path" ]] || fail "backup manifest lacks source.expected_restore_path"
[[ -n "$chain_profile" ]] || fail "backup manifest lacks chain.profile"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "backup manifest chain id must be numeric: $chain_id"
validate_hash32 "backup manifest genesis sha" "$genesis_sha"
validate_hash32 "backup manifest protocore digest" "$protocore_digest"

archive_abs="$(abs_path "$archive_path")"
manifest_abs="$(abs_path "$RESTORE_BACKUP_MANIFEST")"
restore_abs="$(abs_target_path "$RESTORE_OUTPUT_DIR")"
service_evidence_abs="$(abs_path "$RESTORE_SERVICE_EVIDENCE")"
marker_abs="${restore_abs}.restore-marker.json"

[[ "$restore_abs" != "/" ]] || fail "refusing to restore into filesystem root"
case "$archive_abs" in
  "$restore_abs"/*) fail "backup archive must not be inside RESTORE_OUTPUT_DIR" ;;
esac

actual_archive_sha="$(file_sha256 "$archive_abs")"
[[ "$actual_archive_sha" == "$archive_sha" ]] \
  || fail "archive sha256 mismatch: expected $archive_sha got $actual_archive_sha"

validate_tar_entries "$archive_abs"

if [[ -e "$restore_abs" && ! -d "$restore_abs" ]]; then
  fail "RESTORE_OUTPUT_DIR exists and is not a directory: $restore_abs"
fi
if [[ -d "$restore_abs" ]] && directory_has_entries "$restore_abs"; then
  if bool_true "$RESTORE_OVERWRITE"; then
    safe_remove_restore_dir "$restore_abs" "$marker_abs"
  else
    fail "restore output exists and is not empty; set RESTORE_OVERWRITE=true only for a previously marked restore directory"
  fi
fi

if [[ -z "$RESTORE_EVIDENCE_OUTPUT" ]]; then
  RESTORE_EVIDENCE_OUTPUT="${restore_abs}.restore.json"
fi
evidence_abs="$(abs_target_path "$RESTORE_EVIDENCE_OUTPUT")"
case "$evidence_abs" in
  "$restore_abs"/*) fail "RESTORE_EVIDENCE_OUTPUT must not be inside RESTORE_OUTPUT_DIR" ;;
esac
if [[ -e "$evidence_abs" ]]; then
  bool_true "$RESTORE_OVERWRITE" || fail "restore evidence already exists; set RESTORE_OVERWRITE=true to replace it"
fi

mkdir -p "$restore_abs"
tar --extract --gzip --file "$archive_abs" --directory "$restore_abs" --no-same-owner --no-same-permissions

file_count="$(find "$restore_abs" -type f | wc -l | awk '{print $1}')"
[[ "$file_count" =~ ^[0-9]+$ && "$file_count" -gt 0 ]] || fail "restore produced no files"
tree_sha="$(tree_sha256 "$restore_abs")"
manifest_sha="$(file_sha256 "$manifest_abs")"
service_evidence_sha="$(file_sha256 "$service_evidence_abs")"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ "$manifest_source" == "os" ]]; then
  dr_fields="$(jq -c '.disaster_recovery_manifest_fields' "$manifest_abs")"
  [[ "$dr_fields" != "null" ]] || fail "backup manifest lacks disaster_recovery_manifest_fields"
else
  dr_fields="$(
    jq -n \
      --arg chain_profile "$chain_profile" \
      --arg chain_id "$chain_id" \
      --arg genesis_sha "$genesis_sha" \
      --arg release_metadata_sha "$release_metadata_sha" \
      --arg protocore_digest "$protocore_digest" \
      --arg backup_service_state "$backup_service_state" \
      --arg archive "$archive_abs" \
      --arg archive_sha "$archive_sha" \
      --arg restore_path "$expected_restore_path" \
      '{
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
          mode: "stopped-protocore-talos-copy",
          protocore_service_state: $backup_service_state,
          hot_backup: false,
          storage_uri: ("file://" + $archive),
          var_lib_protocore_sha256: $archive_sha
        },
        restore: {
          restore_path: $restore_path,
          service_stopped_before_restore: true,
          post_restore_checks: [
            "release-digest-match",
            "genesis-match",
            "chain-id-match",
            "protocore-rpc-healthy"
          ]
        }
      }'
  )"
fi

jq -n \
  --arg created_at "$created_at" \
  --arg manifest "$manifest_abs" \
  --arg manifest_sha "$manifest_sha" \
  --arg archive "$archive_abs" \
  --arg archive_sha "$archive_sha" \
  --arg restore_path "$restore_abs" \
  --arg expected_restore_path "$expected_restore_path" \
  --arg restore_service_state "$RESTORE_SERVICE_STATE" \
  --arg restore_service_evidence "$service_evidence_abs" \
  --arg restore_service_evidence_sha "$service_evidence_sha" \
  --arg file_count "$file_count" \
  --arg tree_sha "$tree_sha" \
  --arg node_id "$node_id" \
  --arg node_role "$node_role" \
  --arg release_channel "$release_channel" \
  --arg release_metadata "$release_metadata_path" \
  --arg release_metadata_sha "$release_metadata_sha" \
  --arg protocore_version "$protocore_version" \
  --arg protocore_digest "$protocore_digest" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg genesis_sha "$genesis_sha" \
  --argjson dr_fields "$dr_fields" \
  '{
    schema_version: "monarch-protocore-offline-restore/v1",
    created_at: $created_at,
    ok: true,
    node: {
      node_id: $node_id,
      role: $node_role
    },
    chain: {
      profile: $chain_profile,
      chain_id: $chain_id,
      genesis_sha256: $genesis_sha
    },
    release: {
      channel: $release_channel,
      metadata_path: $release_metadata,
      metadata_sha256: $release_metadata_sha,
      protocore_version: $protocore_version,
      protocore_digest: $protocore_digest
    },
    backup_manifest: {
      path: $manifest,
      sha256: $manifest_sha
    },
    backup: {
      archive_path: $archive,
      archive_sha256: $archive_sha,
      protocore_service_state: $dr_fields.backup.protocore_service_state,
      hot_backup: false
    },
    restore: {
      target_path: $restore_path,
      expected_restore_path: $expected_restore_path,
      service_state: $restore_service_state,
      service_state_evidence_path: $restore_service_evidence,
      service_state_evidence_sha256: $restore_service_evidence_sha,
      service_stopped_before_restore: true,
      archive_entries_validated: true,
      extracted_file_count: ($file_count | tonumber),
      extracted_tree_sha256: $tree_sha,
      post_restore_checks_required: [
        "release-digest-match",
        "genesis-match",
        "chain-id-match",
        "protocore-rpc-healthy"
      ]
    },
    disaster_recovery_manifest_fields: ($dr_fields + {
      restore_evidence: {
        schema_version: "monarch-protocore-offline-restore/v1",
        restore_path: $restore_path,
        service_state: $restore_service_state,
        service_state_evidence_sha256: $restore_service_evidence_sha,
        extracted_tree_sha256: $tree_sha
      }
    })
  }' > "$evidence_abs"

evidence_sha="$(file_sha256 "$evidence_abs")"
jq -n \
  --arg created_at "$created_at" \
  --arg restore_path "$restore_abs" \
  --arg evidence "$evidence_abs" \
  --arg evidence_sha "$evidence_sha" \
  '{
    schema_version: "monarch-protocore-offline-restore-marker/v1",
    created_at: $created_at,
    restore_path: $restore_path,
    evidence_path: $evidence,
    evidence_sha256: $evidence_sha
  }' > "$marker_abs"

jq -n \
  --arg restore_dir "$restore_abs" \
  --arg evidence "$evidence_abs" \
  --arg evidence_sha "$evidence_sha" \
  --arg archive "$archive_abs" \
  --arg archive_sha "$archive_sha" \
  '{
    ok: true,
    checked: "protocore-offline-restore",
    restore_dir: $restore_dir,
    evidence: $evidence,
    evidence_sha256: $evidence_sha,
    archive: $archive,
    archive_sha256: $archive_sha
  }'
