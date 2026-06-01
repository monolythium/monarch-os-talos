#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_PATH="${PROMOTION_METADATA:-${1:-}}"
POLICY_FILE="${CHANNEL_POLICY_FILE:-${2:-"$ROOT_DIR/channel-policy.json"}}"
RUN_ARTIFACT_VERIFIER="${RUN_ARTIFACT_VERIFIER:-true}"
RUN_PROVENANCE_VERIFIER="${RUN_PROVENANCE_VERIFIER:-true}"
DESKTOP_E2E_EVIDENCE="${DESKTOP_E2E_EVIDENCE:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "channel-promotion: $*" >&2
  exit 1
}

field() {
  local path="$1"
  local file="$2"
  jq -r "$path // \"\"" "$file"
}

bool_field() {
  local path="$1"
  local file="$2"
  jq -r "$path // false" "$file"
}

policy_field() {
  local path="$1"
  jq -r --arg channel "$channel" ".channels[\$channel]$path // \"\"" "$POLICY_FILE"
}

policy_bool() {
  local path="$1"
  jq -r --arg channel "$channel" ".channels[\$channel]$path // false" "$POLICY_FILE"
}

metadata_has_artifact() {
  local pattern="$1"
  jq -e --arg pattern "$pattern" 'any(.artifacts[]?.path; test($pattern))' "$METADATA_PATH" >/dev/null
}

need jq

[[ -n "$METADATA_PATH" ]] || fail "PROMOTION_METADATA or first argument is required"
[[ -f "$METADATA_PATH" ]] || fail "release metadata not found: $METADATA_PATH"
[[ -f "$POLICY_FILE" ]] || fail "channel policy not found: $POLICY_FILE"

jq -e . "$METADATA_PATH" >/dev/null || fail "release metadata is not valid JSON"
jq -e . "$POLICY_FILE" >/dev/null || fail "channel policy is not valid JSON"

metadata_schema="$(field '.schema_version' "$METADATA_PATH")"
policy_schema="$(field '.schema_version' "$POLICY_FILE")"
[[ "$metadata_schema" == "monarch-os-release-metadata/v1" ]] \
  || fail "metadata schema unsupported: $metadata_schema"
[[ "$policy_schema" == "monarch-os-channel-policy/v1" ]] \
  || fail "channel policy schema unsupported: $policy_schema"

channel="$(field '.channel.name' "$METADATA_PATH")"
[[ -n "$channel" ]] || fail "metadata lacks channel.name"
jq -e --arg channel "$channel" '.channels[$channel] != null' "$POLICY_FILE" >/dev/null \
  || fail "channel is not defined in policy: $channel"

enabled="$(policy_bool '.enabled')"
if [[ "$enabled" != "true" ]]; then
  reason="$(policy_field '.blocked_reason')"
  fail "channel is disabled by policy: $channel${reason:+ ($reason)}"
fi

expected_profile="$(policy_field '.chain_profile')"
expected_chain_id="$(policy_field '.chain_id')"
expected_desktop_channel="$(policy_field '.desktop_channel')"
actual_profile="$(field '.channel.chain.profile' "$METADATA_PATH")"
actual_chain_id="$(field '.channel.chain.chain_id' "$METADATA_PATH")"
actual_desktop_channel="$(field '.channel.compatibility.monarch_desktop.channel' "$METADATA_PATH")"

[[ "$actual_profile" == "$expected_profile" ]] \
  || fail "chain profile mismatch for $channel: expected=$expected_profile actual=$actual_profile"
if [[ -n "$expected_chain_id" ]]; then
  [[ "$actual_chain_id" == "$expected_chain_id" ]] \
    || fail "chain id mismatch for $channel: expected=$expected_chain_id actual=$actual_chain_id"
fi
[[ "$actual_desktop_channel" == "$expected_desktop_channel" ]] \
  || fail "Desktop channel mismatch for $channel: expected=$expected_desktop_channel actual=$actual_desktop_channel"

if [[ "$(policy_bool '.require_same_channel_upgrade')" == "true" ]]; then
  [[ "$(bool_field '.channel.upgrade.requires_same_channel' "$METADATA_PATH")" == "true" ]] \
    || fail "metadata must require same-channel upgrades for $channel"
fi

if [[ "$(policy_bool '.require_clean_sources')" == "true" ]]; then
  [[ "$(bool_field '.sources.monarch_os_talos.dirty' "$METADATA_PATH")" == "false" ]] \
    || fail "monarch-os-talos source is dirty"
  [[ "$(bool_field '.sources.mono_core.dirty' "$METADATA_PATH")" == "false" ]] \
    || fail "mono-core source is dirty"
fi

if [[ "$(policy_bool '.require_concrete_protocore')" == "true" ]]; then
  protocore_version="$(field '.channel.compatibility.protocore.version' "$METADATA_PATH")"
  protocore_sha="$(field '.sources.protocore_binary.sha256' "$METADATA_PATH")"
  [[ -n "$protocore_version" && "$protocore_version" != "unknown" ]] \
    || fail "metadata lacks concrete protocore version"
  [[ "$protocore_sha" =~ ^[0-9a-f]{64}$ ]] \
    || fail "metadata lacks concrete protocore binary sha256"
fi

while read -r pattern; do
  [[ -n "$pattern" ]] || continue
  metadata_has_artifact "$pattern" || fail "metadata lacks required channel artifact: $pattern"
done < <(jq -r --arg channel "$channel" '.channels[$channel].required_artifact_patterns[]?' "$POLICY_FILE")

talos_version="$(field '.talos.version' "$METADATA_PATH")"
arch="$(field '.talos.arch' "$METADATA_PATH")"
[[ -n "$talos_version" ]] || fail "metadata lacks talos.version"
[[ -n "$arch" ]] || fail "metadata lacks talos.arch"

if [[ "$RUN_ARTIFACT_VERIFIER" == "true" ]]; then

  out_dir="$(cd "$(dirname "$METADATA_PATH")" && pwd)"
  while IFS='=' read -r key value; do
    export "$key=$value"
  done < <(
    jq -r --arg channel "$channel" '
      .channels[$channel].required_verifier_flags
      | to_entries[]
      | "\(.key)=\(.value)"
    ' "$POLICY_FILE"
  )

  OUT_DIR="$out_dir" TALOS_VERSION="$talos_version" ARCH="$arch" \
    "$ROOT_DIR/scripts/verify-release-artifacts.sh" >/dev/null
fi

if [[ "$RUN_PROVENANCE_VERIFIER" == "true" ]]; then
  out_dir="$(cd "$(dirname "$METADATA_PATH")" && pwd)"
  while IFS='=' read -r key value; do
    export "$key=$value"
  done < <(
    jq -r --arg channel "$channel" '
      .channels[$channel].required_provenance_flags
      | to_entries[]
      | "\(.key)=\(.value)"
    ' "$POLICY_FILE"
  )

  OUT_DIR="$out_dir" TALOS_VERSION="$talos_version" ARCH="$arch" \
    "$ROOT_DIR/scripts/verify-release-provenance.sh" >/dev/null
fi

desktop_e2e_required="$(policy_bool '.required_desktop_e2e_evidence')"
desktop_e2e_ran=false
if [[ "$desktop_e2e_required" == "true" || -n "$DESKTOP_E2E_EVIDENCE" ]]; then
  [[ -n "$DESKTOP_E2E_EVIDENCE" ]] \
    || fail "Desktop e2e evidence is required for $channel but DESKTOP_E2E_EVIDENCE is not set; run scripts/resolve-desktop-e2e-evidence.sh or set DESKTOP_E2E_EVIDENCE"
  RELEASE_METADATA="$METADATA_PATH" \
    "$ROOT_DIR/scripts/verify-desktop-e2e-evidence.sh" "$DESKTOP_E2E_EVIDENCE" >/dev/null
  desktop_e2e_ran=true
fi

jq -n \
  --arg channel "$channel" \
  --arg release_stage "$(policy_field '.release_stage')" \
  --arg metadata "$(basename "$METADATA_PATH")" \
  --arg policy "$(basename "$POLICY_FILE")" \
  --argjson verifier_ran "$([[ "$RUN_ARTIFACT_VERIFIER" == "true" ]] && printf true || printf false)" \
  --argjson provenance_verifier_ran "$([[ "$RUN_PROVENANCE_VERIFIER" == "true" ]] && printf true || printf false)" \
  --argjson desktop_e2e_verifier_ran "$desktop_e2e_ran" \
  '{
    ok: true,
    channel: $channel,
    release_stage: $release_stage,
    metadata: $metadata,
    policy: $policy,
    artifact_verifier_ran: $verifier_ran,
    provenance_verifier_ran: $provenance_verifier_ran,
    desktop_e2e_verifier_ran: $desktop_e2e_verifier_ran
  }'
