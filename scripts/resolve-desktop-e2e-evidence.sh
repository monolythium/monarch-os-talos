#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
EVIDENCE_PATH="${DESKTOP_E2E_EVIDENCE:-${1:-}}"
METADATA_PATH="${PROMOTION_METADATA:-${RELEASE_METADATA:-${2:-}}}"
POLICY_FILE="${CHANNEL_POLICY_FILE:-"$ROOT_DIR/channel-policy.json"}"
DOWNLOAD_DIR="${DESKTOP_E2E_DOWNLOAD_DIR:-"$OUT_DIR/desktop-e2e-evidence"}"
DESKTOP_E2E_REPO="${DESKTOP_E2E_REPO:-monolythium/monarch-desktop}"
DESKTOP_E2E_ARTIFACT_RUN_ID="${DESKTOP_E2E_ARTIFACT_RUN_ID:-}"
DESKTOP_E2E_ARTIFACT_NAME="${DESKTOP_E2E_ARTIFACT_NAME:-monarch-desktop-e2e-evidence}"
DESKTOP_E2E_RELEASE_TAG="${DESKTOP_E2E_RELEASE_TAG:-}"
DESKTOP_E2E_RELEASE_PATTERN="${DESKTOP_E2E_RELEASE_PATTERN:-monarch-desktop-e2e-evidence*.json}"
DESKTOP_E2E_EVIDENCE_URL="${DESKTOP_E2E_EVIDENCE_URL:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "desktop e2e evidence resolver: $*" >&2
  exit 1
}

abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  elif [[ -f "$path" ]]; then
    printf '%s/%s\n' "$PWD" "$path"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$path"
  fi
}

find_evidence_json() {
  local dir="$1"
  local found=""

  while IFS= read -r file; do
    if jq -e '.schema_version == "monarch-desktop-e2e-evidence/v1"' "$file" >/dev/null 2>&1; then
      found="$file"
      break
    fi
  done < <(find "$dir" -type f -name '*.json' | sort)

  [[ -n "$found" ]] || fail "no monarch-desktop-e2e-evidence/v1 JSON found under $dir"
  abs_path "$found"
}

need jq

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$DOWNLOAD_DIR" = /* ]] || DOWNLOAD_DIR="$ROOT_DIR/$DOWNLOAD_DIR"
[[ "$POLICY_FILE" = /* ]] || POLICY_FILE="$ROOT_DIR/$POLICY_FILE"

if [[ -n "$METADATA_PATH" ]]; then
  [[ "$METADATA_PATH" = /* ]] || METADATA_PATH="$ROOT_DIR/$METADATA_PATH"
  [[ -f "$METADATA_PATH" ]] || fail "release metadata not found: $METADATA_PATH"
  [[ -f "$POLICY_FILE" ]] || fail "channel policy not found: $POLICY_FILE"
  jq -e . "$METADATA_PATH" >/dev/null || fail "release metadata is not valid JSON"
  jq -e . "$POLICY_FILE" >/dev/null || fail "channel policy is not valid JSON"
  channel="$(jq -r '.channel.name // ""' "$METADATA_PATH")"
  [[ -n "$channel" ]] || fail "release metadata lacks channel.name"
  evidence_required="$(jq -r --arg channel "$channel" '.channels[$channel].required_desktop_e2e_evidence // false' "$POLICY_FILE")"
else
  channel=""
  evidence_required=false
fi

if [[ -n "$EVIDENCE_PATH" ]]; then
  resolved="$(abs_path "$EVIDENCE_PATH")"
  [[ -f "$resolved" ]] || fail "Desktop e2e evidence file not found: $resolved"
  jq -e '.schema_version == "monarch-desktop-e2e-evidence/v1"' "$resolved" >/dev/null \
    || fail "Desktop e2e evidence has unsupported schema: $resolved"
  printf '%s\n' "$resolved"
  exit 0
fi

if [[ -z "$DESKTOP_E2E_RELEASE_TAG" && -z "$DESKTOP_E2E_ARTIFACT_RUN_ID" && -z "$DESKTOP_E2E_EVIDENCE_URL" ]]; then
  if [[ "$evidence_required" == "true" ]]; then
    fail "Desktop e2e evidence is required for channel ${channel:-unknown}; set DESKTOP_E2E_EVIDENCE, DESKTOP_E2E_RELEASE_TAG, DESKTOP_E2E_ARTIFACT_RUN_ID, or DESKTOP_E2E_EVIDENCE_URL"
  fi
  exit 0
fi

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

if [[ -n "$DESKTOP_E2E_EVIDENCE_URL" ]]; then
  need curl
  curl -fsSL "$DESKTOP_E2E_EVIDENCE_URL" -o "$DOWNLOAD_DIR/monarch-desktop-e2e-evidence.json"
elif [[ -n "$DESKTOP_E2E_RELEASE_TAG" ]]; then
  need gh
  gh release download "$DESKTOP_E2E_RELEASE_TAG" \
    --repo "$DESKTOP_E2E_REPO" \
    --pattern "$DESKTOP_E2E_RELEASE_PATTERN" \
    --dir "$DOWNLOAD_DIR" >/dev/null
elif [[ -n "$DESKTOP_E2E_ARTIFACT_RUN_ID" ]]; then
  need gh
  gh run download "$DESKTOP_E2E_ARTIFACT_RUN_ID" \
    --repo "$DESKTOP_E2E_REPO" \
    --name "$DESKTOP_E2E_ARTIFACT_NAME" \
    --dir "$DOWNLOAD_DIR" >/dev/null
fi

find_evidence_json "$DOWNLOAD_DIR"
