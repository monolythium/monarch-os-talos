#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-monolythium/monarch-os-talos}"
COSIGN_OIDC_ISSUER="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_CERT_IDENTITY_REGEX="${COSIGN_CERT_IDENTITY_REGEX:-https://github.com/${GITHUB_REPOSITORY}/.github/workflows/build.yml@refs/tags/.*}"
REQUIRE_COSIGN_SIGNATURES="${REQUIRE_COSIGN_SIGNATURES:-false}"
REQUIRE_GITHUB_ATTESTATIONS="${REQUIRE_GITHUB_ATTESTATIONS:-false}"
ATTESTATION_MODE="${ATTESTATION_MODE:-online}"
ATTESTATION_BUNDLE_DIR="${ATTESTATION_BUNDLE_DIR:-"$OUT_DIR/attestations"}"
TRUSTED_ROOT_FILE="${TRUSTED_ROOT_FILE:-"$ATTESTATION_BUNDLE_DIR/trusted_root.jsonl"}"
REQUIRE_SOURCE_MATCH="${REQUIRE_SOURCE_MATCH:-false}"
REQUIRE_MONO_CORE_SOURCE_MATCH="${REQUIRE_MONO_CORE_SOURCE_MATCH:-false}"
ALLOW_DIRTY_SOURCE="${ALLOW_DIRTY_SOURCE:-false}"
RUN_REBUILD="${RUN_REBUILD:-false}"
REBUILD_OUT_DIR="${REBUILD_OUT_DIR:-"$ROOT_DIR/_out/reproducible-release"}"
REQUIRE_REBUILD_ALL="${REQUIRE_REBUILD_ALL:-false}"
RUN_RELEASE_REBUILD_WITNESS="${RUN_RELEASE_REBUILD_WITNESS:-false}"
REQUIRE_RELEASE_REBUILD_WITNESS="${REQUIRE_RELEASE_REBUILD_WITNESS:-false}"
RELEASE_REBUILD_WITNESS_PATH="${RELEASE_REBUILD_WITNESS_PATH:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.rebuild-witness.json"}"
RUN_EXTENSION_REBUILD="${RUN_EXTENSION_REBUILD:-false}"
REQUIRE_EXTENSION_REBUILD_WITNESS="${REQUIRE_EXTENSION_REBUILD_WITNESS:-false}"
REBUILD_WITNESS_PATH="${REBUILD_WITNESS_PATH:-"$OUT_DIR/monarch-protocore-$ARCH.rebuild-witness.json"}"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$ATTESTATION_BUNDLE_DIR" = /* ]] || ATTESTATION_BUNDLE_DIR="$ROOT_DIR/$ATTESTATION_BUNDLE_DIR"
[[ "$TRUSTED_ROOT_FILE" = /* ]] || TRUSTED_ROOT_FILE="$ROOT_DIR/$TRUSTED_ROOT_FILE"
[[ "$REBUILD_OUT_DIR" = /* ]] || REBUILD_OUT_DIR="$ROOT_DIR/$REBUILD_OUT_DIR"
[[ "$RELEASE_REBUILD_WITNESS_PATH" = /* ]] || RELEASE_REBUILD_WITNESS_PATH="$ROOT_DIR/$RELEASE_REBUILD_WITNESS_PATH"
[[ "$REBUILD_WITNESS_PATH" = /* ]] || REBUILD_WITNESS_PATH="$ROOT_DIR/$REBUILD_WITNESS_PATH"
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
  echo "release provenance verification failed: $*" >&2
  exit 1
}

bool_enabled() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

metadata_field() {
  jq -r "$1 // \"\"" "$metadata_path"
}

need git
need jq
need sha256sum

case "$ATTESTATION_MODE" in
  online|download|offline) ;;
  *) fail "ATTESTATION_MODE must be online, download, or offline: $ATTESTATION_MODE" ;;
esac

metadata_path="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"
[[ -f "$metadata_path" ]] || fail "missing release metadata: $metadata_path"
[[ -f "$metadata_path.sha256" ]] || fail "missing release metadata checksum: $metadata_path.sha256"
(cd "$(dirname "$metadata_path")" && sha256sum -c "$(basename "$metadata_path.sha256")" >/dev/null) \
  || fail "release metadata checksum mismatch"

schema_version="$(metadata_field '.schema_version')"
[[ "$schema_version" == "monarch-os-release-metadata/v1" ]] \
  || fail "unsupported metadata schema: $schema_version"

mapfile -t metadata_artifacts < <(jq -r '.artifacts[].path' "$metadata_path")
(( ${#metadata_artifacts[@]} > 0 )) || fail "release metadata has no artifacts"

all_artifacts=("${metadata_artifacts[@]}" "$(basename "$metadata_path")")
if bool_enabled "$REQUIRE_EXTENSION_REBUILD_WITNESS"; then
  [[ "$(cd "$(dirname "$REBUILD_WITNESS_PATH")" 2>/dev/null && pwd)" == "$OUT_DIR" ]] \
    || fail "extension rebuild witness must be in OUT_DIR for signature and attestation verification: $REBUILD_WITNESS_PATH"
  all_artifacts+=("$(basename "$REBUILD_WITNESS_PATH")")
fi
if bool_enabled "$REQUIRE_RELEASE_REBUILD_WITNESS"; then
  [[ "$(cd "$(dirname "$RELEASE_REBUILD_WITNESS_PATH")" 2>/dev/null && pwd)" == "$OUT_DIR" ]] \
    || fail "release rebuild witness must be in OUT_DIR for signature and attestation verification: $RELEASE_REBUILD_WITNESS_PATH"
  all_artifacts+=("$(basename "$RELEASE_REBUILD_WITNESS_PATH")")
fi

for path in "${metadata_artifacts[@]}"; do
  artifact="$OUT_DIR/$path"
  [[ -f "$artifact" ]] || fail "metadata references missing artifact: $path"
  expected_sha="$(jq -r --arg path "$path" '.artifacts[] | select(.path == $path) | .sha256' "$metadata_path" | head -n 1)"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || fail "metadata sha256 is invalid for: $path"
  actual_sha="$(sha256sum "$artifact" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "metadata sha256 mismatch for: $path"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

normalize_certificate() {
  local pem="$1"
  local out="$2"
  if grep -q "BEGIN CERTIFICATE" "$pem"; then
    cp "$pem" "$out"
    return
  fi
  base64 -d "$pem" > "$out" 2>/dev/null \
    || fail "signing certificate is neither PEM nor base64-encoded PEM: $pem"
}

verify_cosign_signature() {
  local file="$1"
  local sig="$file.sig"
  local pem="$file.pem"
  local cert="$tmp_dir/$(basename "$file").cert.pem"
  [[ -s "$sig" ]] || fail "missing cosign signature: $sig"
  [[ -s "$pem" ]] || fail "missing cosign certificate: $pem"
  normalize_certificate "$pem" "$cert"
  cosign verify-blob \
    --certificate "$cert" \
    --signature "$sig" \
    --certificate-identity-regexp "$COSIGN_CERT_IDENTITY_REGEX" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$file" >/dev/null
}

bundle_path_for() {
  local file="$1"
  local digest
  digest="$(sha256sum "$file" | awk '{print $1}')"
  local colon_path="$ATTESTATION_BUNDLE_DIR/sha256:$digest.jsonl"
  local dash_path="$ATTESTATION_BUNDLE_DIR/sha256-$digest.jsonl"
  if [[ -f "$colon_path" ]]; then
    printf '%s\n' "$colon_path"
  elif [[ -f "$dash_path" ]]; then
    printf '%s\n' "$dash_path"
  else
    printf ''
  fi
}

download_attestation_bundle() {
  local file="$1"
  mkdir -p "$ATTESTATION_BUNDLE_DIR"
  (cd "$ATTESTATION_BUNDLE_DIR" && gh attestation download "$file" -R "$GITHUB_REPOSITORY" >/dev/null)
}

verify_github_attestation() {
  local file="$1"
  local args=(
    attestation verify "$file"
    -R "$GITHUB_REPOSITORY"
    --predicate-type "https://slsa.dev/provenance/v1"
    --cert-identity-regex "$COSIGN_CERT_IDENTITY_REGEX"
    --cert-oidc-issuer "$COSIGN_OIDC_ISSUER"
  )

  case "$ATTESTATION_MODE" in
    download)
      mkdir -p "$ATTESTATION_BUNDLE_DIR"
      if [[ ! -f "$TRUSTED_ROOT_FILE" ]]; then
        gh attestation trusted-root > "$TRUSTED_ROOT_FILE"
      fi
      download_attestation_bundle "$file"
      ;&
    offline)
      [[ -f "$TRUSTED_ROOT_FILE" ]] || fail "missing trusted root for offline attestation verification: $TRUSTED_ROOT_FILE"
      bundle="$(bundle_path_for "$file")"
      [[ -n "$bundle" ]] || fail "missing attestation bundle for: $(basename "$file")"
      args+=(--bundle "$bundle" --custom-trusted-root "$TRUSTED_ROOT_FILE")
      ;;
    online) ;;
  esac

  gh "${args[@]}" >/dev/null
}

if bool_enabled "$REQUIRE_COSIGN_SIGNATURES"; then
  need cosign
  for path in "${all_artifacts[@]}"; do
    verify_cosign_signature "$OUT_DIR/$path"
  done
fi

if bool_enabled "$REQUIRE_GITHUB_ATTESTATIONS"; then
  need gh
  for path in "${all_artifacts[@]}"; do
    verify_github_attestation "$OUT_DIR/$path"
  done
fi

repo_commit="$(metadata_field '.sources.monarch_os_talos.commit')"
repo_dirty="$(metadata_field '.sources.monarch_os_talos.dirty')"
mono_core_commit="$(metadata_field '.sources.mono_core.commit')"
mono_core_dirty="$(metadata_field '.sources.mono_core.dirty')"

if bool_enabled "$REQUIRE_SOURCE_MATCH"; then
  [[ "$repo_commit" =~ ^[0-9a-f]{40}$ ]] || fail "metadata lacks concrete monarch-os-talos commit"
  current_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  [[ "$current_commit" == "$repo_commit" ]] \
    || fail "checkout HEAD does not match metadata source commit: $current_commit != $repo_commit"
  if [[ "$repo_dirty" == "true" ]] && ! bool_enabled "$ALLOW_DIRTY_SOURCE"; then
    fail "metadata was produced from a dirty monarch-os-talos checkout"
  fi
  if ! git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- && ! bool_enabled "$ALLOW_DIRTY_SOURCE"; then
    fail "current monarch-os-talos checkout is dirty"
  fi
fi

if bool_enabled "$REQUIRE_MONO_CORE_SOURCE_MATCH"; then
  [[ -d "$MONO_CORE_DIR/.git" ]] || fail "mono-core checkout not found: $MONO_CORE_DIR"
  [[ "$mono_core_commit" =~ ^[0-9a-f]{40}$ ]] || fail "metadata lacks concrete mono-core commit"
  current_mono_commit="$(git -C "$MONO_CORE_DIR" rev-parse HEAD)"
  [[ "$current_mono_commit" == "$mono_core_commit" ]] \
    || fail "mono-core HEAD does not match metadata source commit: $current_mono_commit != $mono_core_commit"
  if [[ "$mono_core_dirty" == "true" ]] && ! bool_enabled "$ALLOW_DIRTY_SOURCE"; then
    fail "metadata was produced from a dirty mono-core checkout"
  fi
  if ! git -C "$MONO_CORE_DIR" diff --quiet --ignore-submodules -- && ! bool_enabled "$ALLOW_DIRTY_SOURCE"; then
    fail "current mono-core checkout is dirty"
  fi
fi

run_rebuild_check() {
  need xz
  mkdir -p "$REBUILD_OUT_DIR"

  local channel chain_profile chain_id genesis_path desktop_channel desktop_min desktop_max same_channel
  local p2p_listen rpc_listen discovery enrollment_required enrollment_file digest_file tpm_required
  local tpm_quote_file tpm_event_log_file tpm_sealed_bls_share_file dkg_transcript_file
  local lythiumseal_operator_key_file generate_lythiumseal_operator_key
  local lythiumseal_operator_index lythiumseal_operator_epoch
  channel="$(metadata_field '.channel.name')"
  chain_profile="$(metadata_field '.channel.chain.profile')"
  chain_id="$(metadata_field '.channel.chain.chain_id')"
  genesis_path="$(metadata_field '.channel.chain.genesis.path')"
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
  lythiumseal_operator_key_file="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_file_path')"
  generate_lythiumseal_operator_key="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.generate_value')"
  lythiumseal_operator_index="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.operator_index')"
  lythiumseal_operator_epoch="$(metadata_field '.provisioning_policy.tpm_binding.lythiumseal_operator_key_generation.epoch')"

  [[ -n "$genesis_path" && -f "$ROOT_DIR/$genesis_path" ]] \
    || fail "metadata genesis path is not present in checkout: $genesis_path"

  env \
    TALOS_VERSION="$TALOS_VERSION" \
    ARCH="$ARCH" \
    OUT_DIR="$REBUILD_OUT_DIR" \
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
    PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="$lythiumseal_operator_key_file" \
    PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY="$generate_lythiumseal_operator_key" \
    PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX="$lythiumseal_operator_index" \
    PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH="$lythiumseal_operator_epoch" \
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
    PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="$lythiumseal_operator_key_file" \
    PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY="$generate_lythiumseal_operator_key" \
    PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX="$lythiumseal_operator_index" \
    PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH="$lythiumseal_operator_epoch" \
    MONO_CORE_DIR="$MONO_CORE_DIR" \
    make -C "$ROOT_DIR" metadata >/dev/null

  local compared=0
  local missing=()
  for path in "${metadata_artifacts[@]}"; do
    if [[ -f "$REBUILD_OUT_DIR/$path" ]]; then
      expected_sha="$(jq -r --arg path "$path" '.artifacts[] | select(.path == $path) | .sha256' "$metadata_path" | head -n 1)"
      actual_sha="$(sha256sum "$REBUILD_OUT_DIR/$path" | awk '{print $1}')"
      [[ "$actual_sha" == "$expected_sha" ]] \
        || fail "rebuild sha256 mismatch for $path: $actual_sha != $expected_sha"
      compared=$((compared + 1))
    else
      missing+=("$path")
    fi
  done

  if bool_enabled "$REQUIRE_REBUILD_ALL" && (( ${#missing[@]} > 0 )); then
    fail "rebuild did not produce all metadata artifacts: ${missing[*]}"
  fi
  (( compared > 0 )) || fail "rebuild produced no artifacts comparable to release metadata"
}

run_extension_rebuild_witness() {
  env \
    TALOS_VERSION="$TALOS_VERSION" \
    ARCH="$ARCH" \
    OUT_DIR="$OUT_DIR" \
    METADATA_PATH="$metadata_path" \
    REBUILD_OUT_DIR="${REBUILD_OUT_DIR%/}-extension-only" \
    REBUILD_WITNESS_PATH="$REBUILD_WITNESS_PATH" \
    MONO_CORE_DIR="$MONO_CORE_DIR" \
    PROTOCORE_BINARY="$PROTOCORE_BINARY" \
    "$ROOT_DIR/scripts/check-extension-rebuild-witness.sh" >/dev/null
}

run_release_rebuild_witness() {
  env \
    TALOS_VERSION="$TALOS_VERSION" \
    ARCH="$ARCH" \
    OUT_DIR="$OUT_DIR" \
    METADATA_PATH="$metadata_path" \
    REBUILD_OUT_DIR="${REBUILD_OUT_DIR%/}-release-witness" \
    RELEASE_REBUILD_WITNESS_PATH="$RELEASE_REBUILD_WITNESS_PATH" \
    MONO_CORE_DIR="$MONO_CORE_DIR" \
    PROTOCORE_BINARY="$PROTOCORE_BINARY" \
    "$ROOT_DIR/scripts/check-release-rebuild-witness.sh" >/dev/null
}

verify_extension_rebuild_witness() {
  local witness_path="$REBUILD_WITNESS_PATH"
  [[ -f "$witness_path" ]] || fail "missing extension rebuild witness: $witness_path"
  [[ -f "$witness_path.sha256" ]] || fail "missing extension rebuild witness checksum: $witness_path.sha256"
  (cd "$(dirname "$witness_path")" && sha256sum -c "$(basename "$witness_path.sha256")" >/dev/null) \
    || fail "extension rebuild witness checksum mismatch"

  local witness_schema witness_ok metadata_name metadata_sha actual_metadata_sha
  witness_schema="$(jq -r '.schema_version // ""' "$witness_path")"
  witness_ok="$(jq -r '.ok // false' "$witness_path")"
  [[ "$witness_schema" == "monarch-extension-rebuild-witness/v1" ]] \
    || fail "unsupported extension rebuild witness schema: $witness_schema"
  [[ "$witness_ok" == "true" ]] || fail "extension rebuild witness is not ok"

  metadata_name="$(jq -r '.metadata.path // ""' "$witness_path")"
  metadata_sha="$(jq -r '.metadata.sha256 // ""' "$witness_path")"
  actual_metadata_sha="$(sha256sum "$metadata_path" | awk '{print $1}')"
  [[ "$metadata_name" == "$(basename "$metadata_path")" ]] \
    || fail "extension rebuild witness metadata path mismatch: $metadata_name"
  [[ "$metadata_sha" == "$actual_metadata_sha" ]] \
    || fail "extension rebuild witness metadata sha256 mismatch"

  local extension_path expected_sha rebuilt_sha expected_size rebuilt_size matched
  extension_path="$(jq -r '.extension.path // ""' "$witness_path")"
  expected_sha="$(jq -r '.extension.expected_sha256 // ""' "$witness_path")"
  rebuilt_sha="$(jq -r '.extension.rebuilt_sha256 // ""' "$witness_path")"
  expected_size="$(jq -r '.extension.expected_size_bytes // 0' "$witness_path")"
  rebuilt_size="$(jq -r '.extension.rebuilt_size_bytes // 0' "$witness_path")"
  matched="$(jq -r '.extension.matched // false' "$witness_path")"
  [[ "$matched" == "true" ]] || fail "extension rebuild witness does not mark the extension as matched"
  [[ "$expected_sha" == "$rebuilt_sha" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
    || fail "extension rebuild witness sha256 mismatch"
  [[ "$expected_size" == "$rebuilt_size" ]] \
    || fail "extension rebuild witness size mismatch"

  local metadata_extension_sha metadata_extension_size
  metadata_extension_sha="$(jq -r --arg path "$extension_path" '.artifacts[]? | select(.path == $path) | .sha256' "$metadata_path" | head -n 1)"
  metadata_extension_size="$(jq -r --arg path "$extension_path" '.artifacts[]? | select(.path == $path) | .size_bytes // 0' "$metadata_path" | head -n 1)"
  [[ "$metadata_extension_sha" == "$expected_sha" ]] \
    || fail "extension rebuild witness does not match release metadata artifact sha256"
  [[ "$metadata_extension_size" == "$expected_size" ]] \
    || fail "extension rebuild witness does not match release metadata artifact size"

  local expected_protocore_sha actual_protocore_sha metadata_protocore_sha
  expected_protocore_sha="$(jq -r '.protocore_binary.expected_sha256 // ""' "$witness_path")"
  actual_protocore_sha="$(jq -r '.protocore_binary.actual_sha256 // ""' "$witness_path")"
  metadata_protocore_sha="$(metadata_field '.sources.protocore_binary.sha256')"
  [[ "$expected_protocore_sha" == "$actual_protocore_sha" && "$expected_protocore_sha" == "$metadata_protocore_sha" ]] \
    || fail "extension rebuild witness protocore binary sha256 mismatch"
}

verify_release_rebuild_witness() {
  local witness_path="$RELEASE_REBUILD_WITNESS_PATH"
  [[ -f "$witness_path" ]] || fail "missing release rebuild witness: $witness_path"
  [[ -f "$witness_path.sha256" ]] || fail "missing release rebuild witness checksum: $witness_path.sha256"
  (cd "$(dirname "$witness_path")" && sha256sum -c "$(basename "$witness_path.sha256")" >/dev/null) \
    || fail "release rebuild witness checksum mismatch"

  local witness_schema witness_ok metadata_name metadata_sha actual_metadata_sha
  witness_schema="$(jq -r '.schema_version // ""' "$witness_path")"
  witness_ok="$(jq -r '.ok // false' "$witness_path")"
  [[ "$witness_schema" == "monarch-release-rebuild-witness/v1" ]] \
    || fail "unsupported release rebuild witness schema: $witness_schema"
  [[ "$witness_ok" == "true" ]] || fail "release rebuild witness is not ok"

  metadata_name="$(jq -r '.metadata.path // ""' "$witness_path")"
  metadata_sha="$(jq -r '.metadata.sha256 // ""' "$witness_path")"
  actual_metadata_sha="$(sha256sum "$metadata_path" | awk '{print $1}')"
  [[ "$metadata_name" == "$(basename "$metadata_path")" ]] \
    || fail "release rebuild witness metadata path mismatch: $metadata_name"
  [[ "$metadata_sha" == "$actual_metadata_sha" ]] \
    || fail "release rebuild witness metadata sha256 mismatch"

  local witness_talos_version witness_arch artifact_count
  witness_talos_version="$(jq -r '.talos.version // ""' "$witness_path")"
  witness_arch="$(jq -r '.talos.arch // ""' "$witness_path")"
  [[ "$witness_talos_version" == "$TALOS_VERSION" ]] \
    || fail "release rebuild witness Talos version mismatch: $witness_talos_version"
  [[ "$witness_arch" == "$ARCH" ]] \
    || fail "release rebuild witness arch mismatch: $witness_arch"

  artifact_count="$(jq -r '.artifacts | length' "$witness_path")"
  [[ "$artifact_count" == "${#metadata_artifacts[@]}" ]] \
    || fail "release rebuild witness artifact count mismatch: $artifact_count != ${#metadata_artifacts[@]}"

  local path artifact expected_sha rebuilt_sha metadata_sha expected_size rebuilt_size metadata_size matched
  for path in "${metadata_artifacts[@]}"; do
    artifact="$(jq -c --arg path "$path" '.artifacts[]? | select(.path == $path)' "$witness_path" | head -n 1)"
    [[ -n "$artifact" ]] || fail "release rebuild witness missing artifact: $path"

    expected_sha="$(jq -r '.expected_sha256 // ""' <<< "$artifact")"
    rebuilt_sha="$(jq -r '.rebuilt_sha256 // ""' <<< "$artifact")"
    expected_size="$(jq -r '.expected_size_bytes // 0' <<< "$artifact")"
    rebuilt_size="$(jq -r '.rebuilt_size_bytes // 0' <<< "$artifact")"
    matched="$(jq -r '.matched // false' <<< "$artifact")"
    metadata_sha="$(jq -r --arg path "$path" '.artifacts[]? | select(.path == $path) | .sha256' "$metadata_path" | head -n 1)"
    metadata_size="$(jq -r --arg path "$path" '.artifacts[]? | select(.path == $path) | .size_bytes // 0' "$metadata_path" | head -n 1)"

    [[ "$matched" == "true" ]] || fail "release rebuild witness does not mark $path as matched"
    [[ "$expected_sha" == "$rebuilt_sha" && "$expected_sha" == "$metadata_sha" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
      || fail "release rebuild witness sha256 mismatch for $path"
    [[ "$expected_size" == "$rebuilt_size" && "$expected_size" == "$metadata_size" ]] \
      || fail "release rebuild witness size mismatch for $path"
  done
}

if bool_enabled "$RUN_REBUILD"; then
  run_rebuild_check
fi

if bool_enabled "$RUN_RELEASE_REBUILD_WITNESS"; then
  run_release_rebuild_witness
fi

if bool_enabled "$RUN_EXTENSION_REBUILD"; then
  run_extension_rebuild_witness
fi

if bool_enabled "$RUN_RELEASE_REBUILD_WITNESS" || bool_enabled "$REQUIRE_RELEASE_REBUILD_WITNESS"; then
  verify_release_rebuild_witness
fi

if bool_enabled "$RUN_EXTENSION_REBUILD" || bool_enabled "$REQUIRE_EXTENSION_REBUILD_WITNESS"; then
  verify_extension_rebuild_witness
fi

summary="$(jq -n \
  --arg metadata "$(basename "$metadata_path")" \
  --arg out_dir "$OUT_DIR" \
  --arg attestations "$REQUIRE_GITHUB_ATTESTATIONS" \
  --arg attestation_mode "$ATTESTATION_MODE" \
  --arg signatures "$REQUIRE_COSIGN_SIGNATURES" \
  --arg source_match "$REQUIRE_SOURCE_MATCH" \
  --arg rebuild "$RUN_REBUILD" \
  --arg release_rebuild "$RUN_RELEASE_REBUILD_WITNESS" \
  --arg release_rebuild_witness "$REQUIRE_RELEASE_REBUILD_WITNESS" \
  --arg extension_rebuild "$RUN_EXTENSION_REBUILD" \
  --arg extension_rebuild_witness "$REQUIRE_EXTENSION_REBUILD_WITNESS" \
  --argjson artifact_count "${#metadata_artifacts[@]}" \
  '{
    status: "ok",
    metadata: $metadata,
    out_dir: $out_dir,
    artifact_count: $artifact_count,
    cosign_signatures_checked: ($signatures == "true"),
    github_attestations_checked: ($attestations == "true"),
    attestation_mode: $attestation_mode,
    source_match_checked: ($source_match == "true"),
    rebuild_checked: ($rebuild == "true"),
    release_rebuild_witness_checked: (($release_rebuild == "true") or ($release_rebuild_witness == "true")),
    extension_rebuild_checked: ($extension_rebuild == "true"),
    extension_rebuild_witness_checked: (($extension_rebuild == "true") or ($extension_rebuild_witness == "true"))
  }')"

printf '%s\n' "$summary"
