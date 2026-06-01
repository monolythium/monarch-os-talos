#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "protocore offline backup test failed: $*" >&2
  exit 1
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need jq
need tar

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

data_dir="$tmp_dir/var-lib-protocore"
backup_dir="$tmp_dir/backups"
metadata="$tmp_dir/release.json"
service_evidence="$tmp_dir/ext-protocore-service.json"
mkdir -p "$data_dir/db" "$backup_dir"
printf 'chain-state\n' > "$data_dir/db/state.bin"
printf 'node-config\n' > "$data_dir/config.toml"

jq -n \
  '{
    schema_version: "monarch-os-release-metadata/v1",
    channel: {
      name: "testnet",
      chain: {
        profile: "testnet",
        chain_id: "69420",
        genesis: {
          sha256: "0000000000000000000000000000000000000000000000000000000000000000"
        }
      },
      compatibility: {
        protocore: {version: "0.0.17"}
      }
    },
    sources: {
      protocore_binary: {
        sha256: "1111111111111111111111111111111111111111111111111111111111111111"
      }
    }
  }' > "$metadata"

jq -n '{service: "ext-protocore", state: "stopped"}' > "$service_evidence"

summary="$(
  cd "$ROOT_DIR"
  make -s protocore-offline-backup \
    PROTOCORE_DATA_DIR="$data_dir" \
    BACKUP_RELEASE_METADATA="$metadata" \
    BACKUP_OUTPUT_DIR="$backup_dir" \
    BACKUP_NODE_ID="archive-001" \
    BACKUP_NODE_ROLE="archive" \
    BACKUP_SERVICE_STATE="stopped" \
    BACKUP_SERVICE_EVIDENCE="$service_evidence"
)"

archive="$(jq -r '.archive' <<<"$summary")"
manifest="$(jq -r '.manifest' <<<"$summary")"

[[ -f "$archive" ]] || fail "backup archive was not created"
[[ -f "$manifest" ]] || fail "backup manifest was not created"
[[ -f "$manifest.sha256" ]] || fail "backup manifest checksum was not created"

tar -tzf "$archive" | grep -F './db/state.bin' >/dev/null \
  || fail "archive did not contain Protocore data"

jq -e '
  .schema_version == "monarch-protocore-offline-backup/v1"
  and .ok == true
  and .hot_backup == false
  and .backup.mode == "stopped-protocore-archive"
  and .backup.protocore_service_state == "stopped"
  and (.backup.archive_sha256 | test("^[0-9a-f]{64}$"))
  and .disaster_recovery_manifest_fields.backup.hot_backup == false
  and .disaster_recovery_manifest_fields.restore.service_stopped_before_restore == true
' "$manifest" >/dev/null || fail "backup manifest shape changed"

if (
  cd "$ROOT_DIR"
  make protocore-offline-backup \
    PROTOCORE_DATA_DIR="$data_dir" \
    BACKUP_RELEASE_METADATA="$metadata" \
    BACKUP_OUTPUT_DIR="$backup_dir" \
    BACKUP_NODE_ID="archive-002" \
    BACKUP_SERVICE_STATE="running" \
    BACKUP_SERVICE_EVIDENCE="$service_evidence" >/dev/null 2>"$tmp_dir/running.err"
); then
  fail "running service state was accepted"
fi
grep -F "hot backups are refused" "$tmp_dir/running.err" >/dev/null \
  || fail "running-state rejection reason changed"

if (
  cd "$ROOT_DIR"
  make protocore-offline-backup \
    PROTOCORE_DATA_DIR="$data_dir" \
    BACKUP_RELEASE_METADATA="$metadata" \
    BACKUP_OUTPUT_DIR="$backup_dir" \
    BACKUP_NODE_ID="archive-003" \
    BACKUP_SERVICE_STATE="stopped" >/dev/null 2>"$tmp_dir/missing-evidence.err"
); then
  fail "missing service evidence was accepted"
fi
grep -F "BACKUP_SERVICE_EVIDENCE is required" "$tmp_dir/missing-evidence.err" >/dev/null \
  || fail "missing-evidence rejection reason changed"

if (
  cd "$ROOT_DIR"
  make protocore-offline-backup \
    PROTOCORE_DATA_DIR="$data_dir" \
    BACKUP_RELEASE_METADATA="$metadata" \
    BACKUP_OUTPUT_DIR="$data_dir/backups" \
    BACKUP_NODE_ID="archive-004" \
    BACKUP_SERVICE_STATE="stopped" \
    BACKUP_SERVICE_EVIDENCE="$service_evidence" >/dev/null 2>"$tmp_dir/nested-output.err"
); then
  fail "backup output directory inside data directory was accepted"
fi
grep -F "BACKUP_OUTPUT_DIR must not be inside PROTOCORE_DATA_DIR" "$tmp_dir/nested-output.err" >/dev/null \
  || fail "nested-output rejection reason changed"

printf '{"ok":true,"checked":"protocore-offline-backup"}\n'
