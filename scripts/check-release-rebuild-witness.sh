#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
METADATA_PATH="${METADATA_PATH:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"}"
REBUILD_OUT_DIR="${REBUILD_OUT_DIR:-"$OUT_DIR/rebuild-release"}"
REBUILD_BUILD_DIR="${REBUILD_BUILD_DIR:-"$REBUILD_OUT_DIR/build"}"
RELEASE_REBUILD_WITNESS_PATH="${RELEASE_REBUILD_WITNESS_PATH:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.rebuild-witness.json"}"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$METADATA_PATH" = /* ]] || METADATA_PATH="$ROOT_DIR/$METADATA_PATH"
[[ "$REBUILD_OUT_DIR" = /* ]] || REBUILD_OUT_DIR="$ROOT_DIR/$REBUILD_OUT_DIR"
[[ "$REBUILD_BUILD_DIR" = /* ]] || REBUILD_BUILD_DIR="$ROOT_DIR/$REBUILD_BUILD_DIR"
[[ "$RELEASE_REBUILD_WITNESS_PATH" = /* ]] || RELEASE_REBUILD_WITNESS_PATH="$ROOT_DIR/$RELEASE_REBUILD_WITNESS_PATH"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
if [[ -n "$PROTOCORE_BINARY" && "$PROTOCORE_BINARY" != /* ]]; then
  PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "release rebuild witness failed: $*" >&2
  exit 1
}

metadata_field() {
  jq -r "$1 // \"\"" "$METADATA_PATH"
}

need jq
need make
need sha256sum
need stat
need xz

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

mapfile -t metadata_artifacts < <(jq -r '.artifacts[]?.path' "$METADATA_PATH")
(( ${#metadata_artifacts[@]} > 0 )) || fail "release metadata has no artifacts"
for path in "${metadata_artifacts[@]}"; do
  [[ "$path" == "$(basename "$path")" ]] \
    || fail "artifact path must be a basename: $path"
done

channel="$(metadata_field '.channel.name')"
chain_profile="$(metadata_field '.channel.chain.profile')"
chain_id="$(metadata_field '.channel.chain.chain_id')"
genesis_path="$(metadata_field '.channel.chain.genesis.path')"
genesis_sha="$(metadata_field '.channel.chain.genesis.sha256')"
kernel_baseline_path="$(metadata_field '.substrate.kernel_hardening_baseline.path')"
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
tpm_sealed_operator_key_file="$(metadata_field '.provisioning_policy.tpm_binding.sealed_operator_key_file_path')"
lythiumseal_operator_key_file="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_file_path')"
generate_lythiumseal_operator_key="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.generate_value')"
lythiumseal_operator_index="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.operator_index')"
lythiumseal_operator_epoch="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.epoch')"
repo_commit="$(metadata_field '.sources.monarch_os_talos.commit')"
mono_core_commit="$(metadata_field '.sources.mono_core.commit')"
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
kernel_baseline_file_env=""
if [[ -n "$kernel_baseline_path" && "$kernel_baseline_path" != "unknown" && "$kernel_baseline_path" != "none" ]]; then
  [[ -f "$ROOT_DIR/$kernel_baseline_path" ]] \
    || fail "metadata kernel baseline path is not present in checkout: $kernel_baseline_path"
  kernel_baseline_file_env="$ROOT_DIR/$kernel_baseline_path"
fi
[[ "$expected_protocore_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "metadata lacks concrete protocore binary sha256"

rm -rf "$REBUILD_OUT_DIR"
mkdir -p "$REBUILD_OUT_DIR" "$REBUILD_BUILD_DIR" "$(dirname "$RELEASE_REBUILD_WITNESS_PATH")"

env \
  TALOS_VERSION="$TALOS_VERSION" \
  ARCH="$ARCH" \
  OUT_DIR="$REBUILD_OUT_DIR" \
  BUILD_DIR="$REBUILD_BUILD_DIR" \
  RELEASE_CHANNEL="$channel" \
  CHAIN_PROFILE="$chain_profile" \
  CHAIN_ID="$chain_id" \
  GENESIS_TOML="$ROOT_DIR/$genesis_path" \
  KERNEL_BASELINE_FILE="$kernel_baseline_file_env" \
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
  PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE="$tpm_sealed_operator_key_file" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="$lythiumseal_operator_key_file" \
  PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY="$generate_lythiumseal_operator_key" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX="$lythiumseal_operator_index" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH="$lythiumseal_operator_epoch" \
  PROTOCORE_SOURCE="$protocore_source" \
  PROTOCORE_BINARY="$PROTOCORE_BINARY" \
  MONO_CORE_DIR="$MONO_CORE_DIR" \
  make -C "$ROOT_DIR" iso metal extension sbom >/dev/null

shopt -s nullglob
for raw in "$REBUILD_OUT_DIR"/*.raw; do
  xz -T0 -9 -c "$raw" > "$raw.xz"
  rm -f "$raw"
  (cd "$(dirname "$raw")" && sha256sum "$(basename "$raw").xz" > "$(basename "$raw").xz.sha256")
done

env \
  TALOS_VERSION="$TALOS_VERSION" \
  ARCH="$ARCH" \
  OUT_DIR="$REBUILD_OUT_DIR" \
  BUILD_DIR="$REBUILD_BUILD_DIR" \
  RELEASE_CHANNEL="$channel" \
  CHAIN_PROFILE="$chain_profile" \
  CHAIN_ID="$chain_id" \
  GENESIS_TOML="$ROOT_DIR/$genesis_path" \
  KERNEL_BASELINE_FILE="$kernel_baseline_file_env" \
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
  PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE="$tpm_sealed_operator_key_file" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="$lythiumseal_operator_key_file" \
  PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY="$generate_lythiumseal_operator_key" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX="$lythiumseal_operator_index" \
  PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH="$lythiumseal_operator_epoch" \
  PROTOCORE_SOURCE="$protocore_source" \
  PROTOCORE_BINARY="$PROTOCORE_BINARY" \
  MONO_CORE_DIR="$MONO_CORE_DIR" \
  make -C "$ROOT_DIR" metadata >/dev/null

comparisons_file="$(mktemp)"
trap 'rm -f "$comparisons_file"' EXIT

for path in "${metadata_artifacts[@]}"; do
  rebuilt="$REBUILD_OUT_DIR/$path"
  [[ -f "$rebuilt" ]] || fail "rebuild did not produce metadata artifact: $path"

  expected_sha="$(jq -r --arg path "$path" '.artifacts[] | select(.path == $path) | .sha256' "$METADATA_PATH" | head -n 1)"
  expected_size="$(jq -r --arg path "$path" '.artifacts[] | select(.path == $path) | .size_bytes // 0' "$METADATA_PATH" | head -n 1)"
  rebuilt_sha="$(sha256sum "$rebuilt" | awk '{print $1}')"
  rebuilt_size="$(stat -c '%s' "$rebuilt")"

  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
    || fail "metadata sha256 is invalid for $path"
  [[ "$rebuilt_sha" == "$expected_sha" ]] \
    || fail "rebuild sha256 mismatch for $path: $rebuilt_sha != $expected_sha"
  [[ "$rebuilt_size" == "$expected_size" ]] \
    || fail "rebuild size mismatch for $path: $rebuilt_size != $expected_size"

  jq -n \
    --arg path "$path" \
    --arg expected_sha "$expected_sha" \
    --arg rebuilt_sha "$rebuilt_sha" \
    --argjson expected_size "$expected_size" \
    --argjson rebuilt_size "$rebuilt_size" \
    '{
      path: $path,
      expected_sha256: $expected_sha,
      rebuilt_sha256: $rebuilt_sha,
      expected_size_bytes: $expected_size,
      rebuilt_size_bytes: $rebuilt_size,
      matched: true
    }' >> "$comparisons_file"
done

metadata_sha="$(sha256sum "$METADATA_PATH" | awk '{print $1}')"
rebuilt_metadata_path="$REBUILD_OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"
rebuilt_metadata_sha=""
if [[ -f "$rebuilt_metadata_path" ]]; then
  rebuilt_metadata_sha="$(sha256sum "$rebuilt_metadata_path" | awk '{print $1}')"
fi
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
tmp_witness="$(mktemp)"

jq -s \
  --arg schema_version "monarch-release-rebuild-witness/v1" \
  --arg generated_at "$generated_at" \
  --arg metadata_path "$(basename "$METADATA_PATH")" \
  --arg metadata_sha "$metadata_sha" \
  --arg rebuilt_metadata_path "$(basename "$rebuilt_metadata_path")" \
  --arg rebuilt_metadata_sha "$rebuilt_metadata_sha" \
  --arg talos_version "$TALOS_VERSION" \
  --arg arch "$ARCH" \
  --arg channel "$channel" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --arg genesis_path "$genesis_path" \
  --arg genesis_sha "$genesis_sha" \
  --arg kernel_baseline_path "$kernel_baseline_path" \
  --arg p2p_listen "$p2p_listen" \
  --arg rpc_listen "$rpc_listen" \
  --arg discovery "$discovery" \
  --arg enrollment_required "$enrollment_required" \
  --arg enrollment_file "$enrollment_file" \
  --arg tpm_required "$tpm_required" \
  --arg repo_commit "$repo_commit" \
  --arg mono_core_commit "$mono_core_commit" \
  --arg protocore_source "$protocore_source" \
  --arg expected_protocore_sha "$expected_protocore_sha" \
  --arg command "make iso metal extension sbom metadata" \
  --arg rebuild_out_dir "$REBUILD_OUT_DIR" \
  --arg rebuild_build_dir "$REBUILD_BUILD_DIR" \
  --argjson artifact_count "${#metadata_artifacts[@]}" \
  '{
    schema_version: $schema_version,
    generated_at: $generated_at,
    ok: true,
    metadata: {
      path: $metadata_path,
      sha256: $metadata_sha
    },
    rebuilt_metadata: {
      path: $rebuilt_metadata_path,
      sha256: $rebuilt_metadata_sha,
      note: "Release metadata has a generation timestamp, so artifact hashes are compared instead of requiring byte-for-byte metadata equality."
    },
    talos: {
      version: $talos_version,
      arch: $arch
    },
    inputs: {
      channel: $channel,
      chain_profile: $chain_profile,
      chain_id: $chain_id,
      genesis: {
        path: $genesis_path,
        sha256: $genesis_sha
      },
      kernel_hardening_baseline: {
        path: $kernel_baseline_path
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
      },
      sources: {
        monarch_os_talos_commit: $repo_commit,
        mono_core_commit: $mono_core_commit,
        protocore_source: $protocore_source,
        protocore_binary_sha256: $expected_protocore_sha
      }
    },
    rebuild: {
      command: $command,
      out_dir: $rebuild_out_dir,
      build_dir: $rebuild_build_dir,
      raw_compression: {
        command: "xz -T0 -9"
      },
      metadata_artifact_count: $artifact_count
    },
    artifacts: .
  }' "$comparisons_file" > "$tmp_witness"

mv "$tmp_witness" "$RELEASE_REBUILD_WITNESS_PATH"
(cd "$(dirname "$RELEASE_REBUILD_WITNESS_PATH")" && sha256sum "$(basename "$RELEASE_REBUILD_WITNESS_PATH")" > "$(basename "$RELEASE_REBUILD_WITNESS_PATH").sha256")

printf '%s\n' "$RELEASE_REBUILD_WITNESS_PATH"
