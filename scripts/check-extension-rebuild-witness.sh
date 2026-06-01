#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
METADATA_PATH="${METADATA_PATH:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"}"
REBUILD_OUT_DIR="${REBUILD_OUT_DIR:-"$OUT_DIR/rebuild-extension"}"
REBUILD_WITNESS_PATH="${REBUILD_WITNESS_PATH:-"$OUT_DIR/monarch-protocore-$ARCH.rebuild-witness.json"}"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-"$MONO_CORE_DIR/target/release/protocore"}"
REBUILD_BUILD_DIR="${REBUILD_BUILD_DIR:-"$REBUILD_OUT_DIR/build"}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$METADATA_PATH" = /* ]] || METADATA_PATH="$ROOT_DIR/$METADATA_PATH"
[[ "$REBUILD_OUT_DIR" = /* ]] || REBUILD_OUT_DIR="$ROOT_DIR/$REBUILD_OUT_DIR"
[[ "$REBUILD_WITNESS_PATH" = /* ]] || REBUILD_WITNESS_PATH="$ROOT_DIR/$REBUILD_WITNESS_PATH"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
[[ "$PROTOCORE_BINARY" = /* ]] || PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"
[[ "$REBUILD_BUILD_DIR" = /* ]] || REBUILD_BUILD_DIR="$ROOT_DIR/$REBUILD_BUILD_DIR"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "extension rebuild witness failed: $*" >&2
  exit 1
}

metadata_field() {
  jq -r "$1 // \"\"" "$METADATA_PATH"
}

need jq
need sha256sum
need stat

[[ -f "$METADATA_PATH" ]] || fail "release metadata not found: $METADATA_PATH"
jq -e . "$METADATA_PATH" >/dev/null || fail "release metadata is not valid JSON"
[[ "$(metadata_field '.schema_version')" == "monarch-os-release-metadata/v1" ]] \
  || fail "unsupported metadata schema: $(metadata_field '.schema_version')"

if [[ -f "$METADATA_PATH.sha256" ]]; then
  (cd "$(dirname "$METADATA_PATH")" && sha256sum -c "$(basename "$METADATA_PATH.sha256")" >/dev/null) \
    || fail "release metadata checksum mismatch"
fi

case "$REBUILD_OUT_DIR" in
  ""|"/"|"$ROOT_DIR"|"$OUT_DIR")
    fail "unsafe REBUILD_OUT_DIR: $REBUILD_OUT_DIR"
    ;;
esac

mapfile -t extension_artifacts < <(
  jq -r --arg arch "$ARCH" '
    .artifacts[]?.path
    | select(test("^monarch-protocore-" + $arch + "-.*\\.tar$"))
  ' "$METADATA_PATH"
)

(( ${#extension_artifacts[@]} == 1 )) \
  || fail "expected exactly one versioned monarch-protocore extension artifact, found ${#extension_artifacts[@]}"

extension_path="${extension_artifacts[0]}"
[[ "$extension_path" == "$(basename "$extension_path")" ]] \
  || fail "extension artifact path must be a basename: $extension_path"

expected_extension_sha="$(jq -r --arg path "$extension_path" '.artifacts[] | select(.path == $path) | .sha256' "$METADATA_PATH")"
expected_extension_size="$(jq -r --arg path "$extension_path" '.artifacts[] | select(.path == $path) | .size_bytes // 0' "$METADATA_PATH")"
[[ "$expected_extension_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "metadata extension sha256 is invalid: $expected_extension_sha"

channel="$(metadata_field '.channel.name')"
chain_profile="$(metadata_field '.channel.chain.profile')"
chain_id="$(metadata_field '.channel.chain.chain_id')"
genesis_path="$(metadata_field '.channel.chain.genesis.path')"
genesis_sha="$(metadata_field '.channel.chain.genesis.sha256')"
desktop_channel="$(metadata_field '.channel.compatibility.monarch_desktop.channel')"
desktop_min="$(metadata_field '.channel.compatibility.monarch_desktop.min_version')"
desktop_max="$(metadata_field '.channel.compatibility.monarch_desktop.max_version')"
same_channel="$(metadata_field '.channel.upgrade.requires_same_channel')"
p2p_listen="$(metadata_field '.network_policy.protocore_p2p.listen')"
rpc_listen="$(metadata_field '.network_policy.protocore_rpc.listen')"
discovery="$(metadata_field '.network_policy.protocore_p2p.discovery')"
enrollment_required="$(metadata_field '.provisioning_policy.enrollment.required')"
enrollment_file="$(metadata_field '.provisioning_policy.enrollment.manifest_path')"
digest_file="$(metadata_field '.provisioning_policy.release_digest.file_path')"
tpm_required="$(metadata_field '.provisioning_policy.tpm_binding.required')"
tpm_quote_file="$(metadata_field '.provisioning_policy.tpm_binding.quote_file_path')"
tpm_event_log_file="$(metadata_field '.provisioning_policy.tpm_binding.event_log_file_path')"
tpm_sealed_bls_share_file="$(metadata_field '.provisioning_policy.tpm_binding.sealed_bls_share_file_path')"
dkg_transcript_file="$(metadata_field '.provisioning_policy.tpm_binding.dkg_transcript_file_path')"
protocore_source="$(metadata_field '.sources.protocore_binary.source')"
expected_protocore_sha="$(metadata_field '.sources.protocore_binary.sha256')"

[[ -n "$channel" ]] || fail "metadata lacks channel.name"
[[ -n "$chain_profile" ]] || fail "metadata lacks channel.chain.profile"
[[ -n "$chain_id" ]] || fail "metadata lacks channel.chain.chain_id"
[[ -n "$genesis_path" && -f "$ROOT_DIR/$genesis_path" ]] \
  || fail "metadata genesis path is not present in checkout: $genesis_path"
if [[ "$genesis_sha" =~ ^[0-9a-f]{64}$ ]]; then
  actual_genesis_sha="$(sha256sum "$ROOT_DIR/$genesis_path" | awk '{print $1}')"
  [[ "$actual_genesis_sha" == "$genesis_sha" ]] \
    || fail "metadata genesis sha256 mismatch: $actual_genesis_sha != $genesis_sha"
fi
[[ "$expected_protocore_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "metadata lacks concrete protocore binary sha256"

rm -rf "$REBUILD_OUT_DIR"
mkdir -p "$REBUILD_OUT_DIR" "$REBUILD_BUILD_DIR" "$(dirname "$REBUILD_WITNESS_PATH")"

env \
  TALOS_VERSION="$TALOS_VERSION" \
  ARCH="$ARCH" \
  OUT_DIR="$REBUILD_OUT_DIR" \
  BUILD_DIR="$REBUILD_BUILD_DIR" \
  RELEASE_CHANNEL="$channel" \
  CHAIN_PROFILE="$chain_profile" \
  CHAIN_ID="$chain_id" \
  GENESIS_TOML="$ROOT_DIR/$genesis_path" \
  MONARCH_DESKTOP_CHANNEL="$desktop_channel" \
  MONARCH_DESKTOP_MIN_VERSION="$desktop_min" \
  MONARCH_DESKTOP_MAX_VERSION="$desktop_max" \
  UPGRADE_REQUIRES_SAME_CHANNEL="$same_channel" \
  PROTOCORE_P2P_LISTEN="$p2p_listen" \
  PROTOCORE_RPC_LISTEN="$rpc_listen" \
  PROTOCORE_DISCOVERY="$discovery" \
  PROTOCORE_REQUIRE_ENROLLMENT="$enrollment_required" \
  PROTOCORE_ENROLLMENT_FILE="$enrollment_file" \
  PROTOCORE_EXPECTED_DIGEST_FILE="$digest_file" \
  PROTOCORE_REQUIRE_TPM_BINDING="$tpm_required" \
  PROTOCORE_TPM_QUOTE_FILE="$tpm_quote_file" \
  PROTOCORE_TPM_EVENT_LOG_FILE="$tpm_event_log_file" \
  PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="$tpm_sealed_bls_share_file" \
  PROTOCORE_DKG_TRANSCRIPT_FILE="$dkg_transcript_file" \
  PROTOCORE_SOURCE="$protocore_source" \
  PROTOCORE_BINARY="$PROTOCORE_BINARY" \
  MONO_CORE_DIR="$MONO_CORE_DIR" \
  "$ROOT_DIR/scripts/build-protocore-extension.sh" >/dev/null

[[ -x "$PROTOCORE_BINARY" ]] || fail "PROTOCORE_BINARY is not executable after rebuild: $PROTOCORE_BINARY"
actual_protocore_sha="$(sha256sum "$PROTOCORE_BINARY" | awk '{print $1}')"
[[ "$actual_protocore_sha" == "$expected_protocore_sha" ]] \
  || fail "protocore binary sha256 mismatch: $actual_protocore_sha != $expected_protocore_sha"

rebuilt_extension="$REBUILD_OUT_DIR/$extension_path"
[[ -f "$rebuilt_extension" ]] \
  || fail "rebuild did not produce the expected extension artifact: $extension_path"

actual_extension_sha="$(sha256sum "$rebuilt_extension" | awk '{print $1}')"
actual_extension_size="$(stat -c '%s' "$rebuilt_extension")"
[[ "$actual_extension_sha" == "$expected_extension_sha" ]] \
  || fail "extension rebuild sha256 mismatch for $extension_path: $actual_extension_sha != $expected_extension_sha"

metadata_sha="$(sha256sum "$METADATA_PATH" | awk '{print $1}')"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
tmp_witness="$(mktemp)"

jq -n \
  --arg schema_version "monarch-extension-rebuild-witness/v1" \
  --arg generated_at "$generated_at" \
  --arg metadata_path "$(basename "$METADATA_PATH")" \
  --arg metadata_sha "$metadata_sha" \
  --arg talos_version "$TALOS_VERSION" \
  --arg arch "$ARCH" \
  --arg extension_path "$extension_path" \
  --arg expected_extension_sha "$expected_extension_sha" \
  --arg actual_extension_sha "$actual_extension_sha" \
  --argjson expected_extension_size "$expected_extension_size" \
  --argjson actual_extension_size "$actual_extension_size" \
  --arg protocore_binary "$(basename "$PROTOCORE_BINARY")" \
  --arg expected_protocore_sha "$expected_protocore_sha" \
  --arg actual_protocore_sha "$actual_protocore_sha" \
  --arg channel "$channel" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg genesis_path "$genesis_path" \
  --arg genesis_sha "$genesis_sha" \
  --arg p2p_listen "$p2p_listen" \
  --arg rpc_listen "$rpc_listen" \
  --arg discovery "$discovery" \
  --arg enrollment_required "$enrollment_required" \
  --arg enrollment_file "$enrollment_file" \
  --arg tpm_required "$tpm_required" \
  --arg command "scripts/build-protocore-extension.sh" \
  --arg rebuild_out_dir "$REBUILD_OUT_DIR" \
  '{
    schema_version: $schema_version,
    generated_at: $generated_at,
    ok: true,
    metadata: {
      path: $metadata_path,
      sha256: $metadata_sha
    },
    talos: {
      version: $talos_version,
      arch: $arch
    },
    extension: {
      path: $extension_path,
      expected_sha256: $expected_extension_sha,
      rebuilt_sha256: $actual_extension_sha,
      expected_size_bytes: $expected_extension_size,
      rebuilt_size_bytes: $actual_extension_size,
      matched: true
    },
    protocore_binary: {
      path: $protocore_binary,
      expected_sha256: $expected_protocore_sha,
      actual_sha256: $actual_protocore_sha,
      matched: true
    },
    inputs: {
      channel: $channel,
      chain_profile: $chain_profile,
      chain_id: $chain_id,
      genesis: {
        path: $genesis_path,
        sha256: $genesis_sha
      },
      network: {
        p2p_listen: $p2p_listen,
        rpc_listen: $rpc_listen,
        discovery: $discovery
      },
      provisioning: {
        enrollment_required: ($enrollment_required == "true"),
        enrollment_file: $enrollment_file,
        tpm_binding_required: ($tpm_required == "true")
      }
    },
    rebuild: {
      command: $command,
      out_dir: $rebuild_out_dir,
      deterministic_tar: {
        sort: "name",
        owner: "0",
        group: "0",
        numeric_owner: true,
        mtime: "UTC 2026-01-01"
      }
    }
  }' > "$tmp_witness"

mv "$tmp_witness" "$REBUILD_WITNESS_PATH"
(cd "$(dirname "$REBUILD_WITNESS_PATH")" && sha256sum "$(basename "$REBUILD_WITNESS_PATH")" > "$(basename "$REBUILD_WITNESS_PATH").sha256")

printf '%s\n' "$REBUILD_WITNESS_PATH"
