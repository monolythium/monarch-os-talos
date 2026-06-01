#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "protocore offline restore test failed: $*" >&2
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
need tar

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

data_dir="$tmp_dir/var-lib-protocore"
backup_dir="$tmp_dir/backups"
restore_dir="$tmp_dir/restored-protocore"
metadata="$tmp_dir/release.json"
backup_service_evidence="$tmp_dir/ext-protocore-service-backup.json"
restore_service_evidence="$tmp_dir/ext-protocore-service-restore.json"
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

jq -n '{service: "ext-protocore", state: "stopped", phase: "backup"}' > "$backup_service_evidence"
jq -n '{service: "ext-protocore", state: "stopped", phase: "restore"}' > "$restore_service_evidence"

backup_summary="$(
  cd "$ROOT_DIR"
  make -s protocore-offline-backup \
    PROTOCORE_DATA_DIR="$data_dir" \
    BACKUP_RELEASE_METADATA="$metadata" \
    BACKUP_OUTPUT_DIR="$backup_dir" \
    BACKUP_NODE_ID="archive-restore-001" \
    BACKUP_NODE_ROLE="archive" \
    BACKUP_SERVICE_STATE="stopped" \
    BACKUP_SERVICE_EVIDENCE="$backup_service_evidence"
)"

archive="$(jq -r '.archive' <<<"$backup_summary")"
manifest="$(jq -r '.manifest' <<<"$backup_summary")"

restore_summary="$(
  cd "$ROOT_DIR"
  make -s protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$manifest" \
    RESTORE_OUTPUT_DIR="$restore_dir" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence"
)"

evidence="$(jq -r '.evidence' <<<"$restore_summary")"

[[ -f "$restore_dir/db/state.bin" ]] || fail "database file was not restored"
[[ -f "$restore_dir/config.toml" ]] || fail "config file was not restored"
cmp "$data_dir/db/state.bin" "$restore_dir/db/state.bin" >/dev/null \
  || fail "restored database content changed"
[[ -f "$evidence" ]] || fail "restore evidence was not created"
[[ -f "$restore_dir.restore-marker.json" ]] || fail "restore overwrite marker was not created"

jq -e '
  .schema_version == "monarch-protocore-offline-restore/v1"
  and .ok == true
  and .backup.hot_backup == false
  and .restore.service_state == "stopped"
  and .restore.service_stopped_before_restore == true
  and .restore.archive_entries_validated == true
  and .restore.extracted_file_count == 2
  and (.restore.extracted_tree_sha256 | test("^[0-9a-f]{64}$"))
  and .disaster_recovery_manifest_fields.restore_evidence.schema_version == "monarch-protocore-offline-restore/v1"
' "$evidence" >/dev/null || fail "restore evidence shape changed"

overwrite_summary="$(
  cd "$ROOT_DIR"
  make -s protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$manifest" \
    RESTORE_OUTPUT_DIR="$restore_dir" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" \
    RESTORE_OVERWRITE=true
)"
jq -e '.ok == true and .checked == "protocore-offline-restore"' <<<"$overwrite_summary" >/dev/null \
  || fail "marked restore overwrite failed"

desktop_manifest="$tmp_dir/desktop.backup.json"
jq -n \
  --arg archive "$archive" \
  --arg archive_sha "$(sha256sum "$archive" | awk '{print $1}')" \
  '{
    schema_version: "monarch-desktop-protocore-backup/v1",
    created_at_unix_seconds: 1812345678,
    ok: true,
    hot_backup: false,
    source: {
      path: "/var/lib/protocore",
      expected_restore_path: "/var/lib/protocore"
    },
    talos: {
      endpoint: "https://127.0.0.1:50000",
      node_address: "127.0.0.1",
      service_id: "ext-protocore",
      service_state: "stopped",
      service_raw_state: "Preparing: stopped",
      command: "talos copy /var/lib/protocore"
    },
    backup: {
      mode: "stopped-protocore-talos-copy",
      archive_path: $archive,
      archive_sha256: $archive_sha,
      archive_size_bytes: 100,
      encrypted_by_this_tool: false
    },
    restore: {
      service_stopped_before_backup: true,
      service_stopped_before_restore: true,
      post_restore_checks: ["release-digest-match", "genesis-match", "chain-id-match", "protocore-rpc-healthy"]
    }
  }' > "$desktop_manifest"

desktop_restore_summary="$(
  cd "$ROOT_DIR"
  make -s protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$desktop_manifest" \
    RESTORE_RELEASE_METADATA="$metadata" \
    RESTORE_OUTPUT_DIR="$tmp_dir/desktop-restored-protocore" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence"
)"
desktop_evidence="$(jq -r '.evidence' <<<"$desktop_restore_summary")"
jq -e '
  .schema_version == "monarch-protocore-offline-restore/v1"
  and .node.node_id == "127.0.0.1"
  and .release.metadata_sha256 != ""
  and .disaster_recovery_manifest_fields.backup.mode == "stopped-protocore-talos-copy"
  and .disaster_recovery_manifest_fields.release.protocore_digest == "1111111111111111111111111111111111111111111111111111111111111111"
' "$desktop_evidence" >/dev/null || fail "desktop backup restore evidence shape changed"

if (
  cd "$ROOT_DIR"
  make protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$desktop_manifest" \
    RESTORE_OUTPUT_DIR="$tmp_dir/missing-release-metadata" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" >/dev/null 2>"$tmp_dir/missing-release-metadata.err"
); then
  fail "desktop backup restore without release metadata was accepted"
fi
grep -F "RESTORE_RELEASE_METADATA is required" "$tmp_dir/missing-release-metadata.err" >/dev/null \
  || fail "missing release metadata rejection reason changed"

if (
  cd "$ROOT_DIR"
  make protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$manifest" \
    RESTORE_OUTPUT_DIR="$tmp_dir/running-restore" \
    RESTORE_SERVICE_STATE="running" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" >/dev/null 2>"$tmp_dir/running.err"
); then
  fail "running restore service state was accepted"
fi
grep -F "restore is refused unless RESTORE_SERVICE_STATE is stopped or offline" "$tmp_dir/running.err" >/dev/null \
  || fail "running-state rejection reason changed"

mkdir -p "$tmp_dir/non-empty"
printf 'do-not-delete\n' > "$tmp_dir/non-empty/existing.txt"
if (
  cd "$ROOT_DIR"
  make protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$manifest" \
    RESTORE_OUTPUT_DIR="$tmp_dir/non-empty" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" >/dev/null 2>"$tmp_dir/non-empty.err"
); then
  fail "non-empty unmarked restore output was accepted"
fi
grep -F "restore output exists and is not empty" "$tmp_dir/non-empty.err" >/dev/null \
  || fail "non-empty rejection reason changed"

bad_manifest="$tmp_dir/bad-archive-sha.backup.json"
jq '.backup.archive_sha256 = "2222222222222222222222222222222222222222222222222222222222222222"' \
  "$manifest" > "$bad_manifest"
if (
  cd "$ROOT_DIR"
  make protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$bad_manifest" \
    RESTORE_OUTPUT_DIR="$tmp_dir/bad-sha-restore" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" >/dev/null 2>"$tmp_dir/bad-sha.err"
); then
  fail "archive sha mismatch was accepted"
fi
grep -F "archive sha256 mismatch" "$tmp_dir/bad-sha.err" >/dev/null \
  || fail "archive-sha rejection reason changed"

malicious_dir="$tmp_dir/malicious"
mkdir -p "$malicious_dir"
ln -s /tmp "$malicious_dir/outside"
malicious_archive="$tmp_dir/malicious.tar.gz"
tar -C "$malicious_dir" -czf "$malicious_archive" outside
malicious_sha="$(sha256sum "$malicious_archive" | awk '{print $1}')"
malicious_manifest="$tmp_dir/malicious.backup.json"
jq \
  --arg archive "$malicious_archive" \
  --arg sha "$malicious_sha" \
  '.backup.archive_path = $archive | .backup.archive_sha256 = $sha' \
  "$manifest" > "$malicious_manifest"
if (
  cd "$ROOT_DIR"
  make protocore-offline-restore \
    RESTORE_BACKUP_MANIFEST="$malicious_manifest" \
    RESTORE_OUTPUT_DIR="$tmp_dir/malicious-restore" \
    RESTORE_SERVICE_STATE="stopped" \
    RESTORE_SERVICE_EVIDENCE="$restore_service_evidence" >/dev/null 2>"$tmp_dir/malicious.err"
); then
  fail "archive with symlink entry was accepted"
fi
grep -F "archive contains unsupported entry type" "$tmp_dir/malicious.err" >/dev/null \
  || fail "unsupported-entry rejection reason changed"

jq -n \
  --arg archive "$archive" \
  --arg manifest "$manifest" \
  --arg evidence "$evidence" \
  '{
    ok: true,
    checked: "protocore-offline-restore",
    archive: $archive,
    manifest: $manifest,
    evidence: $evidence
  }'
