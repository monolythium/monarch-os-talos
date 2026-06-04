#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
CONFIG_DIR="${SMOKE_CONFIG_DIR:-"$OUT_DIR/smoke-qemu-config"}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
ARCH="${ARCH:-amd64}"
CHAIN_PROFILE="${CHAIN_PROFILE:-testnet}"
CHAIN_ID="${CHAIN_ID:-69420}"
CLUSTER_NAME="${SMOKE_CLUSTER_NAME:-monarch-smoke}"
CLUSTER_ENDPOINT="${SMOKE_CLUSTER_ENDPOINT:-https://127.0.0.1:6443}"
TALOS_INSTALL_DISK="${TALOS_INSTALL_DISK:-/dev/vda}"
TALOS_ADDITIONAL_SANS="${TALOS_ADDITIONAL_SANS:-127.0.0.1}"
PROTOCORE_P2P_LISTEN="${PROTOCORE_P2P_LISTEN:-/ip4/0.0.0.0/tcp/29898}"
PROTOCORE_RPC_LISTEN="${PROTOCORE_RPC_LISTEN:-0.0.0.0:8545}"
PROTOCORE_DISCOVERY="${PROTOCORE_DISCOVERY:-hybrid}"
PROTOCORE_NODE_MODE="${PROTOCORE_NODE_MODE:-operator}"
PROTOCORE_REQUIRE_ENROLLMENT="${PROTOCORE_REQUIRE_ENROLLMENT:-false}"
PROTOCORE_ENROLLMENT_FILE="${PROTOCORE_ENROLLMENT_FILE:-/var/lib/protocore/enrollment/enrollment.json}"
PROTOCORE_EXPECTED_DIGEST_FILE="${PROTOCORE_EXPECTED_DIGEST_FILE:-/var/lib/protocore/enrollment/protocore.sha256}"
PROTOCORE_REQUIRE_TPM_BINDING="${PROTOCORE_REQUIRE_TPM_BINDING:-false}"
PROTOCORE_TPM_QUOTE_FILE="${PROTOCORE_TPM_QUOTE_FILE:-/var/lib/protocore/attestation/quote.bin}"
PROTOCORE_TPM_EVENT_LOG_FILE="${PROTOCORE_TPM_EVENT_LOG_FILE:-/var/lib/protocore/attestation/eventlog.bin}"
PROTOCORE_DKG_TRANSCRIPT_FILE="${PROTOCORE_DKG_TRANSCRIPT_FILE:-/var/lib/protocore/secrets/dkg-transcript.json}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc}"
PROTOCORE_TPM_SEALED_BLS_SHARE_FILE="${PROTOCORE_TPM_SEALED_BLS_SHARE_FILE:-$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE}"
SMOKE_ENROLLMENT_BUNDLE="${SMOKE_ENROLLMENT_BUNDLE:-auto}"
RELEASE_METADATA_FILE="${RELEASE_METADATA_FILE:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$CONFIG_DIR" = /* ]] || CONFIG_DIR="$ROOT_DIR/$CONFIG_DIR"
[[ "$RELEASE_METADATA_FILE" = /* ]] || RELEASE_METADATA_FILE="$ROOT_DIR/$RELEASE_METADATA_FILE"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need talosctl
need grep
need jq
need sha256sum

mkdir -p "$CONFIG_DIR"

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

expected_digest() {
  local env_digest="${MONARCH_E2E_EXPECTED_DIGEST:-}"
  local metadata_digest=""

  if [[ -f "$RELEASE_METADATA_FILE" ]]; then
    metadata_digest="$(jq -r '.sources.protocore_binary.sha256 // ""' "$RELEASE_METADATA_FILE" 2>/dev/null || true)"
  fi

  if [[ "$metadata_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
    if [[ -n "$env_digest" && "${env_digest,,}" != "${metadata_digest,,}" ]]; then
      echo "MONARCH_E2E_EXPECTED_DIGEST does not match release metadata digest" >&2
      exit 1
    fi
    printf '%s' "${metadata_digest,,}"
    return
  fi

  if [[ "$env_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s' "${env_digest,,}"
    return
  fi

  printf ''
}

remote_dirname() {
  local path="$1"
  printf '%s' "${path%/*}"
}

write_machine_file_patch_item() {
  local path="$1"
  local permissions="$2"
  local source="$3"

  cat <<EOF_FILE_ITEM
    - path: $path
      op: create
      permissions: $permissions
      content: |
EOF_FILE_ITEM
  sed 's/^/          /' "$source"
}

enrollment_bundle_required=false
if bool_true "$PROTOCORE_REQUIRE_ENROLLMENT" || bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then
  enrollment_bundle_required=true
fi
if [[ "$SMOKE_ENROLLMENT_BUNDLE" == "true" ]]; then
  enrollment_bundle_required=true
elif [[ "$SMOKE_ENROLLMENT_BUNDLE" == "false" ]]; then
  enrollment_bundle_required=false
fi

digest="$(expected_digest)"
if [[ "$enrollment_bundle_required" == "true" && ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
  echo "SMOKE_ENROLLMENT_BUNDLE requires a 64-character release digest from release metadata or MONARCH_E2E_EXPECTED_DIGEST" >&2
  exit 1
fi

enrollment_dir="$CONFIG_DIR/enrollment-bundle"
machine_files_patch="$CONFIG_DIR/enrollment-files-patch.yaml"
if [[ "$enrollment_bundle_required" == "true" ]]; then
  mkdir -p "$enrollment_dir"

  digest_file="$enrollment_dir/protocore.sha256"
  manifest_file="$enrollment_dir/enrollment.json"
  quote_file="$enrollment_dir/quote.bin"
  event_log_file="$enrollment_dir/eventlog.bin"
  operator_identity_file="$enrollment_dir/operator-identity.key"
  bls_share_file="$enrollment_dir/bls-share"
  cluster_key_share_file="$enrollment_dir/cluster-key-share"
  dkg_transcript_file="$enrollment_dir/dkg-transcript.json"
  lythiumseal_operator_key_file="$enrollment_dir/lythiumseal-operator-key.bin.enc"

  printf '%s\n' "$digest" >"$digest_file"
  printf 'monarch-smoke-vtpm-quote:%s\n' "$digest" >"$quote_file"
  printf 'monarch-smoke-vtpm-eventlog:%s\n' "$digest" >"$event_log_file"
  printf 'operator-identity-key-ref:%s\n' "$digest" >"$operator_identity_file"
  printf 'bls-share-ref:%s\n' "$digest" >"$bls_share_file"
  printf 'cluster-key-share-ref:%s\n' "$digest" >"$cluster_key_share_file"
  printf 'lythiumseal-operator-key-ref:%s\n' "$digest" >"$lythiumseal_operator_key_file"
  jq -n \
    --arg digest "$digest" \
    --arg chain_profile "$CHAIN_PROFILE" \
    --arg chain_id "$CHAIN_ID" \
    '{
      schema_version: "monarch-smoke-dkg-transcript/v1",
      chain: {profile: $chain_profile, chain_id: $chain_id},
      cluster: {id: 1, size: 10, threshold: 7, active_members: 7, standby_members: 3, dkg_epoch: 1},
      transcript_digest: $digest,
      fixture: "qemu-vtpm-testnet"
    }' >"$dkg_transcript_file"

  quote_sha256="$(sha256sum "$quote_file" | awk '{print $1}')"
  event_log_sha256="$(sha256sum "$event_log_file" | awk '{print $1}')"
  lythiumseal_operator_key_sha256="$(sha256sum "$lythiumseal_operator_key_file" | awk '{print $1}')"
  dkg_transcript_sha256="$(sha256sum "$dkg_transcript_file" | awk '{print $1}')"
  quote_nonce="$(printf 'monarch-smoke-vtpm-nonce:%s\n' "$digest" | sha256sum | awk '{print $1}')"
  pcr_policy_hash="$(
    printf 'sha256:0=%s:2=%s:4=%s:7=%s:key=lythiumseal_operator_key\n' \
      "0000000000000000000000000000000000000000000000000000000000000000" \
      "2222222222222222222222222222222222222222222222222222222222222222" \
      "4444444444444444444444444444444444444444444444444444444444444444" \
      "7777777777777777777777777777777777777777777777777777777777777777" \
      | sha256sum | awk '{print $1}'
  )"

  jq -n \
    --arg chain_profile "$CHAIN_PROFILE" \
    --arg chain_id "$CHAIN_ID" \
    --arg digest "$digest" \
    --arg enrollment_file "$PROTOCORE_ENROLLMENT_FILE" \
    --arg quote_file "$PROTOCORE_TPM_QUOTE_FILE" \
    --arg event_log_file "$PROTOCORE_TPM_EVENT_LOG_FILE" \
    --arg sealed_bls_share_file "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" \
    --arg dkg_transcript_file "$PROTOCORE_DKG_TRANSCRIPT_FILE" \
    --arg quote_sha256 "$quote_sha256" \
    --arg event_log_sha256 "$event_log_sha256" \
    --arg quote_nonce "$quote_nonce" \
    --arg pcr_policy_hash "$pcr_policy_hash" \
    --arg dkg_transcript_sha256 "$dkg_transcript_sha256" \
    --arg lythiumseal_operator_key_sha256 "$lythiumseal_operator_key_sha256" \
    --arg rpc_listen "$PROTOCORE_RPC_LISTEN" \
    --arg p2p_listen "$PROTOCORE_P2P_LISTEN" \
    --arg discovery "$PROTOCORE_DISCOVERY" \
    --arg lythiumseal_operator_key_file "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" \
    '{
      schema_version: "monarch-protocore-enrollment/v1",
      node: {
        role: "operator-signing",
        chain_profile: $chain_profile,
        chain_id: $chain_id,
        node_id: "qemu-smoke-operator-0"
      },
      operator: {
        address: "0x1111111111111111111111111111111111111111",
        position: "active",
        index: 0
      },
      cluster: {
        id: 1,
        size: 10,
        threshold: 7,
        active_members: 7,
        standby_members: 3,
        dkg_epoch: 1
      },
      endpoint_policy: {
        rpc_listen: $rpc_listen,
        p2p_listen: $p2p_listen,
        discovery: $discovery
      },
      release: {
        expected_digest: $digest
      },
      attestation: {
        tpm: {
          mode: "vtpm-testnet",
          pcr_bank: "sha256",
          pcr_values: {
            "0": "0000000000000000000000000000000000000000000000000000000000000000",
            "2": "2222222222222222222222222222222222222222222222222222222222222222",
            "4": "4444444444444444444444444444444444444444444444444444444444444444",
            "7": "7777777777777777777777777777777777777777777777777777777777777777"
          },
          quote_file: $quote_file,
          event_log_file: $event_log_file,
          quote_sha256: $quote_sha256,
          event_log_sha256: $event_log_sha256,
          quote_nonce: $quote_nonce,
          sealed_key_policy: {
            pcrs: [0, 2, 4, 7],
            key_share_refs: ["lythiumseal_operator_key"],
            policy_digest: $pcr_policy_hash,
            dkg_transcript_sha256: $dkg_transcript_sha256,
            sealed_share_sha256: $lythiumseal_operator_key_sha256
          }
        }
      },
      secret_files: {
        operator_identity_key: "/var/lib/protocore/secrets/operator-identity.key",
        bls_share: "/var/lib/protocore/secrets/bls-share",
        cluster_key_share: "/var/lib/protocore/secrets/cluster-key-share",
        dkg_transcript: $dkg_transcript_file,
        lythiumseal_operator_key: $lythiumseal_operator_key_file,
        tpm_sealed_bls_share: $sealed_bls_share_file
      }
    }' >"$manifest_file"

  EXPECTED_CHAIN_PROFILE="$CHAIN_PROFILE" EXPECTED_CHAIN_ID="$CHAIN_ID" REQUIRE_RELEASE_DIGEST=true \
    "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$manifest_file" >/dev/null

  cat >"$machine_files_patch" <<EOF_FILES_PATCH
machine:
  files:
EOF_FILES_PATCH
  write_machine_file_patch_item "$PROTOCORE_ENROLLMENT_FILE" "0o600" "$manifest_file" >>"$machine_files_patch"
  write_machine_file_patch_item "$PROTOCORE_EXPECTED_DIGEST_FILE" "0o600" "$digest_file" >>"$machine_files_patch"
  write_machine_file_patch_item "$PROTOCORE_TPM_QUOTE_FILE" "0o600" "$quote_file" >>"$machine_files_patch"
  write_machine_file_patch_item "$PROTOCORE_TPM_EVENT_LOG_FILE" "0o600" "$event_log_file" >>"$machine_files_patch"
  write_machine_file_patch_item "/var/lib/protocore/secrets/operator-identity.key" "0o600" "$operator_identity_file" >>"$machine_files_patch"
  write_machine_file_patch_item "/var/lib/protocore/secrets/bls-share" "0o600" "$bls_share_file" >>"$machine_files_patch"
  write_machine_file_patch_item "/var/lib/protocore/secrets/cluster-key-share" "0o600" "$cluster_key_share_file" >>"$machine_files_patch"
  write_machine_file_patch_item "$PROTOCORE_DKG_TRANSCRIPT_FILE" "0o600" "$dkg_transcript_file" >>"$machine_files_patch"
  write_machine_file_patch_item "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" "0o600" "$lythiumseal_operator_key_file" >>"$machine_files_patch"
  if [[ "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" != "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" ]]; then
    write_machine_file_patch_item "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE" "0o600" "$lythiumseal_operator_key_file" >>"$machine_files_patch"
  fi
else
  rm -f "$machine_files_patch"
fi

patch_file="$CONFIG_DIR/protocore-extension-service-config.yaml"
cat > "$patch_file" <<EOF_PATCH
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: protocore
environment:
  - PROTOCORE_REQUIRE_ENROLLMENT=$PROTOCORE_REQUIRE_ENROLLMENT
  - PROTOCORE_ENROLLMENT_FILE=$PROTOCORE_ENROLLMENT_FILE
$(if bool_true "$PROTOCORE_REQUIRE_ENROLLMENT" || [[ "$enrollment_bundle_required" == "true" ]]; then printf '  - PROTOCORE_EXPECTED_DIGEST_FILE=%s\n' "$PROTOCORE_EXPECTED_DIGEST_FILE"; fi)
  - PROTOCORE_REQUIRE_TPM_BINDING=$PROTOCORE_REQUIRE_TPM_BINDING
$(if bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then printf '  - PROTOCORE_TPM_QUOTE_FILE=%s\n' "$PROTOCORE_TPM_QUOTE_FILE"; fi)
$(if bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then printf '  - PROTOCORE_TPM_EVENT_LOG_FILE=%s\n' "$PROTOCORE_TPM_EVENT_LOG_FILE"; fi)
$(if bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then printf '  - PROTOCORE_TPM_SEALED_BLS_SHARE_FILE=%s\n' "$PROTOCORE_TPM_SEALED_BLS_SHARE_FILE"; fi)
$(if bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then printf '  - PROTOCORE_DKG_TRANSCRIPT_FILE=%s\n' "$PROTOCORE_DKG_TRANSCRIPT_FILE"; fi)
$(if bool_true "$PROTOCORE_REQUIRE_TPM_BINDING"; then printf '  - PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE=%s\n' "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE"; fi)
  - PROTOCORE_RPC_LISTEN=$PROTOCORE_RPC_LISTEN
  - PROTOCORE_P2P_LISTEN=$PROTOCORE_P2P_LISTEN
  - PROTOCORE_DISCOVERY=$PROTOCORE_DISCOVERY
  - PROTOCORE_NODE_MODE=$PROTOCORE_NODE_MODE
EOF_PATCH

IFS=',' read -r -a sans <<<"$TALOS_ADDITIONAL_SANS"
san_args=()
for san in "${sans[@]}"; do
  san="${san#"${san%%[![:space:]]*}"}"
  san="${san%"${san##*[![:space:]]}"}"
  [[ -n "$san" ]] || continue
  san_args+=(--additional-sans "$san")
done

config_patch_args=(--config-patch "@$patch_file")
if [[ -f "$machine_files_patch" ]]; then
  config_patch_args+=(--config-patch "@$machine_files_patch")
fi

talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
  --install-disk "$TALOS_INSTALL_DISK" \
  --talos-version "$TALOS_VERSION" \
  --with-docs=false \
  --with-examples=false \
  --force \
  --output "$CONFIG_DIR" \
  "${san_args[@]}" \
  "${config_patch_args[@]}" >/dev/null

controlplane="$CONFIG_DIR/controlplane.yaml"
talosconfig="$CONFIG_DIR/talosconfig"

[[ -f "$controlplane" ]] || {
  echo "talosctl did not write controlplane config: $controlplane" >&2
  exit 1
}
[[ -f "$talosconfig" ]] || {
  echo "talosctl did not write talosconfig: $talosconfig" >&2
  exit 1
}

grep -Fx "kind: ExtensionServiceConfig" "$controlplane" >/dev/null || {
  echo "generated controlplane config lacks ExtensionServiceConfig" >&2
  exit 1
}
grep -Fx "name: protocore" "$controlplane" >/dev/null || {
  echo "generated controlplane config lacks protocore extension service config" >&2
  exit 1
}

cat > "$CONFIG_DIR/README.txt" <<EOF_README
Generated QEMU smoke config for Monarch OS.

controlplane.yaml contains a Talos machine config plus an ExtensionServiceConfig
for ext-protocore. talosconfig contains client certificates for the smoke node.
These files are generated under _out and must not be committed.
When enrollment is enabled, enrollment-bundle/ contains synthetic QEMU-only
operator-signing inputs and controlplane.yaml stages them into /var/lib/protocore.
EOF_README

printf '%s\n' "$controlplane"
