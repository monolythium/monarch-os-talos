#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
CHAIN_PROFILE="${CHAIN_PROFILE:-testnet}"
CHAIN_ID="${CHAIN_ID:-69420}"
KERNEL_BASELINE_FILE="${KERNEL_BASELINE_FILE:-"$ROOT_DIR/kernel-hardening-baseline.json"}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_IMG_BIN="${QEMU_IMG_BIN:-qemu-img}"
API_HOST_PORT="${API_HOST_PORT:-50000}"
PROTOCORE_RPC_HOST_PORT="${PROTOCORE_RPC_HOST_PORT:-18545}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-90}"
BOOT_HOLD_SECONDS="${BOOT_HOLD_SECONDS:-20}"
REQUIRE_TALOS_API_PROBE="${REQUIRE_TALOS_API_PROBE:-${REQUIRE_TALOSCTL_PROBE:-false}}"
TALOS_MACHINE_CONFIG_FILE="${TALOS_MACHINE_CONFIG_FILE:-${TALOS_APPLY_CONFIG_FILE:-}}"
TALOSCONFIG_FILE="${TALOSCONFIG_FILE:-${TALOSCONFIG:-}}"
TALOS_NODE="${TALOS_NODE:-127.0.0.1}"
TALOS_ENDPOINT="${TALOS_ENDPOINT:-127.0.0.1:${API_HOST_PORT}}"
APPLY_CONFIG_TIMEOUT_SECONDS="${APPLY_CONFIG_TIMEOUT_SECONDS:-60}"
POST_APPLY_TIMEOUT_SECONDS="${POST_APPLY_TIMEOUT_SECONDS:-180}"
EXTENSION_SERVICE_NAME="${EXTENSION_SERVICE_NAME:-ext-protocore}"
EXTENSION_SERVICE_TIMEOUT_SECONDS="${EXTENSION_SERVICE_TIMEOUT_SECONDS:-120}"
EXTENSION_SERVICE_REQUIRED_STATE="${EXTENSION_SERVICE_REQUIRED_STATE:-}"
REQUIRE_EXTENSION_SERVICE_CHECK="${REQUIRE_EXTENSION_SERVICE_CHECK:-false}"
REQUIRE_PROTOCORE_RPC_PROBE="${REQUIRE_PROTOCORE_RPC_PROBE:-false}"
PROTOCORE_RPC_TIMEOUT_SECONDS="${PROTOCORE_RPC_TIMEOUT_SECONDS:-120}"
REQUIRE_ENROLLMENT_RUNTIME_PROOF="${REQUIRE_ENROLLMENT_RUNTIME_PROOF:-false}"
REQUIRE_TPM_BINDING_RUNTIME_PROOF="${REQUIRE_TPM_BINDING_RUNTIME_PROOF:-false}"
PROTOCORE_ENROLLMENT_FILE="${PROTOCORE_ENROLLMENT_FILE:-/var/lib/protocore/enrollment/enrollment.json}"
PROTOCORE_EXPECTED_DIGEST_FILE="${PROTOCORE_EXPECTED_DIGEST_FILE:-/var/lib/protocore/enrollment/protocore.sha256}"
PROTOCORE_TPM_QUOTE_FILE="${PROTOCORE_TPM_QUOTE_FILE:-/var/lib/protocore/attestation/quote.bin}"
PROTOCORE_TPM_EVENT_LOG_FILE="${PROTOCORE_TPM_EVENT_LOG_FILE:-/var/lib/protocore/attestation/eventlog.bin}"
PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE="${PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE:-/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc}"
PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE="${PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE:-$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE}"
REQUIRE_SUBSTRATE_RUNTIME_PROOF="${REQUIRE_SUBSTRATE_RUNTIME_PROOF:-false}"
REQUIRE_DM_VERITY_ACTIVE="${REQUIRE_DM_VERITY_ACTIVE:-false}"
KEEP_QEMU_ALIVE="${KEEP_QEMU_ALIVE:-false}"
RELEASE_METADATA_FILE="${RELEASE_METADATA_FILE:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$RELEASE_METADATA_FILE" = /* ]] || RELEASE_METADATA_FILE="$ROOT_DIR/$RELEASE_METADATA_FILE"

RAW_IMAGE="${RAW_IMAGE:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.raw"}"
LOG_DIR="$OUT_DIR/smoke-qemu"
SERIAL_LOG="$LOG_DIR/serial.log"
PID_FILE="$LOG_DIR/qemu.pid"
OVERLAY_IMAGE="$LOG_DIR/disk-overlay.qcow2"
TALOS_VERSION_LOG="$LOG_DIR/talos-version.txt"
APPLY_CONFIG_LOG="$LOG_DIR/apply-config.txt"
SERVICE_LOG="$LOG_DIR/${EXTENSION_SERVICE_NAME}-service.txt"
SERVICE_LOGS="$LOG_DIR/${EXTENSION_SERVICE_NAME}.log"
RPC_LOG="$LOG_DIR/protocore-rpc.txt"
ENROLLMENT_MANIFEST_LOG="$LOG_DIR/enrollment-manifest.json"
ENROLLMENT_DIGEST_LOG="$LOG_DIR/protocore-digest.txt"
ENROLLMENT_RUNTIME_PROOF="$LOG_DIR/enrollment-runtime.json"
ENROLLMENT_FILE_HASHES="$LOG_DIR/enrollment-file-hashes.json"
KERNEL_CONFIG_GZ="$LOG_DIR/proc-config.gz"
KERNEL_CONFIG_TXT="$LOG_DIR/proc-config.txt"
CMDLINE_LOG="$LOG_DIR/proc-cmdline.txt"
MOUNTS_LOG="$LOG_DIR/proc-mounts.txt"
MODULES_LOG="$LOG_DIR/proc-modules.txt"
FILESYSTEMS_LOG="$LOG_DIR/proc-filesystems.txt"
TCP_LOG="$LOG_DIR/proc-net-tcp.txt"
TCP6_LOG="$LOG_DIR/proc-net-tcp6.txt"
ROOT_DM_NAME_LOG="$LOG_DIR/root-dm-name.txt"
ROOT_DM_UUID_LOG="$LOG_DIR/root-dm-uuid.txt"
DM_VERITY_ROOT_HASHES="$LOG_DIR/dm-verity-root-hashes.txt"
SUBSTRATE_RUNTIME_PROOF="$LOG_DIR/substrate-runtime.json"
LIVE_ENV_FILE="$LOG_DIR/live-env.sh"

if [[ "$ARCH" != "amd64" ]]; then
  echo "smoke-qemu currently supports ARCH=amd64 only" >&2
  exit 1
fi

if [[ ! -f "$RAW_IMAGE" ]]; then
  echo "raw image not found: $RAW_IMAGE" >&2
  echo "run: make metal" >&2
  exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "missing qemu binary: $QEMU_BIN" >&2
  exit 1
fi

if [[ -n "$TALOS_MACHINE_CONFIG_FILE" ]]; then
  [[ "$TALOS_MACHINE_CONFIG_FILE" = /* ]] || TALOS_MACHINE_CONFIG_FILE="$ROOT_DIR/$TALOS_MACHINE_CONFIG_FILE"
  [[ -f "$TALOS_MACHINE_CONFIG_FILE" ]] || {
    echo "Talos machine config not found: $TALOS_MACHINE_CONFIG_FILE" >&2
    exit 1
  }
fi

if [[ -n "$TALOSCONFIG_FILE" ]]; then
  [[ "$TALOSCONFIG_FILE" = /* ]] || TALOSCONFIG_FILE="$ROOT_DIR/$TALOSCONFIG_FILE"
  [[ -f "$TALOSCONFIG_FILE" ]] || {
    echo "talosconfig not found: $TALOSCONFIG_FILE" >&2
    exit 1
  }
fi
if [[ -n "$KERNEL_BASELINE_FILE" && "$KERNEL_BASELINE_FILE" != /* ]]; then
  KERNEL_BASELINE_FILE="$ROOT_DIR/$KERNEL_BASELINE_FILE"
fi

if [[ "$REQUIRE_EXTENSION_SERVICE_CHECK" == "true" && -z "$TALOSCONFIG_FILE" ]]; then
  echo "REQUIRE_EXTENSION_SERVICE_CHECK=true requires TALOSCONFIG_FILE" >&2
  exit 1
fi

if [[ -n "$TALOS_MACHINE_CONFIG_FILE" || "$REQUIRE_EXTENSION_SERVICE_CHECK" == "true" || "$REQUIRE_PROTOCORE_RPC_PROBE" == "true" ]]; then
  if ! command -v talosctl >/dev/null 2>&1; then
    echo "configured QEMU smoke requires talosctl on PATH" >&2
    exit 1
  fi
fi

if [[ "$REQUIRE_TPM_BINDING_RUNTIME_PROOF" == "true" ]]; then
  REQUIRE_ENROLLMENT_RUNTIME_PROOF=true
fi

if [[ "$REQUIRE_ENROLLMENT_RUNTIME_PROOF" == "true" ]]; then
  if [[ -z "$TALOSCONFIG_FILE" ]]; then
    echo "REQUIRE_ENROLLMENT_RUNTIME_PROOF=true requires TALOSCONFIG_FILE" >&2
    exit 1
  fi
  if ! command -v talosctl >/dev/null 2>&1; then
    echo "REQUIRE_ENROLLMENT_RUNTIME_PROOF=true requires talosctl on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "REQUIRE_ENROLLMENT_RUNTIME_PROOF=true requires jq on PATH" >&2
    exit 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "REQUIRE_ENROLLMENT_RUNTIME_PROOF=true requires sha256sum on PATH" >&2
    exit 1
  fi
fi

if [[ "$REQUIRE_SUBSTRATE_RUNTIME_PROOF" == "true" ]]; then
  if [[ -z "$TALOSCONFIG_FILE" ]]; then
    echo "REQUIRE_SUBSTRATE_RUNTIME_PROOF=true requires TALOSCONFIG_FILE" >&2
    exit 1
  fi
  if ! command -v talosctl >/dev/null 2>&1; then
    echo "REQUIRE_SUBSTRATE_RUNTIME_PROOF=true requires talosctl on PATH" >&2
    exit 1
  fi
  if ! command -v gzip >/dev/null 2>&1; then
    echo "REQUIRE_SUBSTRATE_RUNTIME_PROOF=true requires gzip on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "REQUIRE_SUBSTRATE_RUNTIME_PROOF=true requires jq on PATH" >&2
    exit 1
  fi
  [[ -f "$KERNEL_BASELINE_FILE" ]] || {
    echo "kernel hardening baseline not found: $KERNEL_BASELINE_FILE" >&2
    exit 1
  }
  jq -e . "$KERNEL_BASELINE_FILE" >/dev/null || {
    echo "kernel hardening baseline is not valid JSON: $KERNEL_BASELINE_FILE" >&2
    exit 1
  }
fi

mkdir -p "$LOG_DIR"
rm -f "$SERIAL_LOG" "$PID_FILE" "$TALOS_VERSION_LOG" "$TALOS_VERSION_LOG.tmp" \
  "$APPLY_CONFIG_LOG" "$SERVICE_LOG" "$SERVICE_LOGS" "$RPC_LOG" "$OVERLAY_IMAGE" \
  "$ENROLLMENT_MANIFEST_LOG" "$ENROLLMENT_DIGEST_LOG" "$ENROLLMENT_RUNTIME_PROOF" \
  "$ENROLLMENT_FILE_HASHES" \
  "$KERNEL_CONFIG_GZ" "$KERNEL_CONFIG_TXT" "$CMDLINE_LOG" "$MOUNTS_LOG" \
  "$MODULES_LOG" "$FILESYSTEMS_LOG" "$TCP_LOG" "$TCP6_LOG" "$ROOT_DM_NAME_LOG" \
  "$ROOT_DM_UUID_LOG" "$DM_VERITY_ROOT_HASHES" "$SUBSTRATE_RUNTIME_PROOF" \
  "$LIVE_ENV_FILE"

BOOT_IMAGE="$RAW_IMAGE"
BOOT_FORMAT="raw"
BOOT_READONLY="on"

if [[ -n "$TALOS_MACHINE_CONFIG_FILE" ]]; then
  if ! command -v "$QEMU_IMG_BIN" >/dev/null 2>&1; then
    echo "configured QEMU smoke requires qemu-img on PATH" >&2
    exit 1
  fi
  "$QEMU_IMG_BIN" create -q -f qcow2 -F raw -b "$RAW_IMAGE" "$OVERLAY_IMAGE"
  BOOT_IMAGE="$OVERLAY_IMAGE"
  BOOT_FORMAT="qcow2"
  BOOT_READONLY="off"
fi

"$QEMU_BIN" \
  -m "${QEMU_MEMORY:-2048}" \
  -smp "${QEMU_CPUS:-2}" \
  -machine accel=kvm:tcg \
  -cpu "${QEMU_CPU:-max}" \
  -drive "file=$BOOT_IMAGE,format=$BOOT_FORMAT,if=virtio,readonly=$BOOT_READONLY" \
  -netdev "user,id=net0,hostfwd=tcp::${API_HOST_PORT}-:50000,hostfwd=tcp::${PROTOCORE_RPC_HOST_PORT}-:8545" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -monitor none \
  -serial "file:$SERIAL_LOG" \
  -pidfile "$PID_FILE" \
  -daemonize

cleanup() {
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

talos_api_probe_status="not_required"
machine_config_applied="false"
extension_service_check="not_required"
protocore_rpc_probe="not_required"
enrollment_runtime_proof="not_required"
substrate_runtime_proof="not_required"

probe_talos_api_insecure() {
  if ! (echo >"/dev/tcp/127.0.0.1/${API_HOST_PORT}") >/dev/null 2>&1; then
    return 1
  fi

  if ! command -v talosctl >/dev/null 2>&1; then
    printf 'talosctl not installed; TCP probe only\n' > "$TALOS_VERSION_LOG"
    talos_api_probe_status="tcp_only"
    return 0
  fi

  timeout 8 talosctl \
    --nodes "$TALOS_NODE" \
    --endpoints "$TALOS_ENDPOINT" \
    version \
    --insecure \
    --short >"$TALOS_VERSION_LOG.tmp" 2>&1 || return 1
  mv "$TALOS_VERSION_LOG.tmp" "$TALOS_VERSION_LOG"
  talos_api_probe_status="talosctl_ok"
  return 0
}

probe_talos_api_secure() {
  if ! (echo >"/dev/tcp/127.0.0.1/${API_HOST_PORT}") >/dev/null 2>&1; then
    return 1
  fi
  [[ -n "$TALOSCONFIG_FILE" ]] || return 1
  timeout 8 talosctl \
    --talosconfig "$TALOSCONFIG_FILE" \
    --nodes "$TALOS_NODE" \
    --endpoints "$TALOS_ENDPOINT" \
    version \
    --short >"$TALOS_VERSION_LOG.tmp" 2>&1 || return 1
  mv "$TALOS_VERSION_LOG.tmp" "$TALOS_VERSION_LOG"
  talos_api_probe_status="talosctl_secure_ok"
  return 0
}

wait_for_initial_boot() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "QEMU exited before the smoke test completed" >&2
      tail -80 "$SERIAL_LOG" >&2 || true
      exit 1
    fi

    if probe_talos_api_insecure; then
      return 0
    fi

    if [[ "$REQUIRE_TALOS_API_PROBE" != "true" && "$SECONDS" -ge "$BOOT_HOLD_SECONDS" ]]; then
      talos_api_probe_status="not_required"
      if [[ -s "$TALOS_VERSION_LOG.tmp" ]]; then
        cp "$TALOS_VERSION_LOG.tmp" "$TALOS_VERSION_LOG"
      else
        printf 'talosctl probe not required for boot smoke\n' > "$TALOS_VERSION_LOG"
      fi
      return 0
    fi

    sleep 2
  done

  echo "Monarch OS image did not pass QEMU smoke within ${TIMEOUT_SECONDS}s" >&2
  echo "serial log: $SERIAL_LOG" >&2
  cat "$TALOS_VERSION_LOG.tmp" >&2 2>/dev/null || true
  tail -80 "$SERIAL_LOG" >&2 || true
  exit 1
}

wait_for_post_apply_api() {
  local deadline=$((SECONDS + POST_APPLY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "QEMU exited before the configured smoke test completed" >&2
      tail -80 "$SERIAL_LOG" >&2 || true
      exit 1
    fi

    if [[ -n "$TALOSCONFIG_FILE" ]]; then
      if probe_talos_api_secure; then
        return 0
      fi
    elif (echo >"/dev/tcp/127.0.0.1/${API_HOST_PORT}") >/dev/null 2>&1; then
      printf 'post-apply Talos API TCP probe succeeded; no TALOSCONFIG_FILE supplied\n' > "$TALOS_VERSION_LOG"
      talos_api_probe_status="post_apply_tcp_only"
      return 0
    fi

    sleep 2
  done

  echo "Talos API did not return after config apply within ${POST_APPLY_TIMEOUT_SECONDS}s" >&2
  cat "$TALOS_VERSION_LOG.tmp" >&2 2>/dev/null || true
  tail -80 "$SERIAL_LOG" >&2 || true
  exit 1
}

apply_machine_config() {
  [[ -n "$TALOS_MACHINE_CONFIG_FILE" ]] || return 0

  timeout "$APPLY_CONFIG_TIMEOUT_SECONDS" talosctl \
    --nodes "$TALOS_NODE" \
    --endpoints "$TALOS_ENDPOINT" \
    apply-config \
    --insecure \
    --file "$TALOS_MACHINE_CONFIG_FILE" >"$APPLY_CONFIG_LOG" 2>&1 || {
      echo "talosctl apply-config failed" >&2
      cat "$APPLY_CONFIG_LOG" >&2 || true
      exit 1
    }
  if [[ ! -s "$APPLY_CONFIG_LOG" ]]; then
    printf 'talosctl apply-config succeeded\n' > "$APPLY_CONFIG_LOG"
  fi

  machine_config_applied="true"
  wait_for_post_apply_api
}

check_extension_service() {
  if [[ "$REQUIRE_EXTENSION_SERVICE_CHECK" != "true" ]]; then
    return 0
  fi

  local deadline=$((SECONDS + EXTENSION_SERVICE_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if timeout 10 talosctl \
      --talosconfig "$TALOSCONFIG_FILE" \
      --nodes "$TALOS_NODE" \
      --endpoints "$TALOS_ENDPOINT" \
      service "$EXTENSION_SERVICE_NAME" >"$SERVICE_LOG.tmp" 2>&1; then
      if [[ -z "$EXTENSION_SERVICE_REQUIRED_STATE" ]] || grep -E "$EXTENSION_SERVICE_REQUIRED_STATE" "$SERVICE_LOG.tmp" >/dev/null; then
        mv "$SERVICE_LOG.tmp" "$SERVICE_LOG"
        extension_service_check="ok"
        timeout 10 talosctl \
          --talosconfig "$TALOSCONFIG_FILE" \
          --nodes "$TALOS_NODE" \
          --endpoints "$TALOS_ENDPOINT" \
          logs "$EXTENSION_SERVICE_NAME" >"$SERVICE_LOGS" 2>&1 || true
        return 0
      fi
    fi
    sleep 3
  done

  extension_service_check="failed"
  echo "Talos service check failed for ${EXTENSION_SERVICE_NAME}" >&2
  cat "$SERVICE_LOG.tmp" >&2 2>/dev/null || true
  exit 1
}

probe_protocore_rpc() {
  if [[ "$REQUIRE_PROTOCORE_RPC_PROBE" != "true" ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "REQUIRE_PROTOCORE_RPC_PROBE=true requires curl on PATH" >&2
    exit 1
  fi

  local deadline=$((SECONDS + PROTOCORE_RPC_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl -fsS \
      -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"web3_clientVersion","params":[]}' \
      "http://127.0.0.1:${PROTOCORE_RPC_HOST_PORT}" >"$RPC_LOG.tmp" 2>&1; then
      if grep -F '"result"' "$RPC_LOG.tmp" >/dev/null; then
        mv "$RPC_LOG.tmp" "$RPC_LOG"
        protocore_rpc_probe="ok"
        return 0
      fi
    fi
    sleep 3
  done

  protocore_rpc_probe="failed"
  echo "Protocore RPC probe failed on 127.0.0.1:${PROTOCORE_RPC_HOST_PORT}" >&2
  cat "$RPC_LOG.tmp" >&2 2>/dev/null || true
  if [[ -s "$SERVICE_LOGS" ]]; then
    echo "recent ${EXTENSION_SERVICE_NAME} logs:" >&2
    tail -120 "$SERVICE_LOGS" >&2 || true
  fi
  exit 1
}

talos_read_file() {
  local path="$1"
  local out="$2"
  timeout 10 talosctl \
    --talosconfig "$TALOSCONFIG_FILE" \
    --nodes "$TALOS_NODE" \
    --endpoints "$TALOS_ENDPOINT" \
    read "$path" >"$out.tmp" 2>"$out.err" || return 1
  mv "$out.tmp" "$out"
  rm -f "$out.err"
}

remote_file_hash_json() {
  local label="$1"
  local path="$2"
  local out
  out="$(mktemp "$LOG_DIR/${label}.XXXXXX")"
  if ! talos_read_file "$path" "$out"; then
    enrollment_runtime_proof="failed"
    echo "failed to read enrollment proof file through Talos API: $path" >&2
    cat "$out.err" >&2 2>/dev/null || true
    rm -f "$out" "$out.err" "$out.tmp"
    exit 1
  fi

  local sha size
  sha="$(sha256sum "$out" | awk '{print $1}')"
  size="$(wc -c <"$out" | tr -d '[:space:]')"
  rm -f "$out"
  jq -n \
    --arg label "$label" \
    --arg path "$path" \
    --arg sha256 "$sha" \
    --argjson size_bytes "$size" \
    '{label: $label, path: $path, sha256: $sha256, size_bytes: $size_bytes}'
}

require_hash_match() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local expected_norm actual_norm

  expected_norm="$(tr '[:upper:]' '[:lower:]' <<<"${expected#0x}")"
  actual_norm="$(tr '[:upper:]' '[:lower:]' <<<"${actual#0x}")"
  if [[ "$expected_norm" != "$actual_norm" ]]; then
    enrollment_runtime_proof="failed"
    echo "$label hash mismatch: manifest=$expected actual=$actual" >&2
    exit 1
  fi
}

prove_enrollment_runtime() {
  if [[ "$REQUIRE_ENROLLMENT_RUNTIME_PROOF" != "true" ]]; then
    return 0
  fi

  local expected_digest
  expected_digest="$(expected_protocore_digest)"
  if [[ ! "$expected_digest" =~ ^[0-9a-f]{64}$ ]]; then
    enrollment_runtime_proof="failed"
    echo "enrollment runtime proof requires a release metadata or MONARCH_E2E_EXPECTED_DIGEST SHA-256 digest" >&2
    exit 1
  fi

  talos_read_file "$PROTOCORE_ENROLLMENT_FILE" "$ENROLLMENT_MANIFEST_LOG" || {
    enrollment_runtime_proof="failed"
    echo "failed to read enrollment manifest through Talos API: $PROTOCORE_ENROLLMENT_FILE" >&2
    cat "$ENROLLMENT_MANIFEST_LOG.err" >&2 2>/dev/null || true
    exit 1
  }
  jq -e . "$ENROLLMENT_MANIFEST_LOG" >/dev/null || {
    enrollment_runtime_proof="failed"
    echo "enrollment manifest read from node is not valid JSON" >&2
    exit 1
  }

  jq -e \
    --arg chain_profile "$CHAIN_PROFILE" \
    --arg chain_id "$CHAIN_ID" \
    --arg digest "$expected_digest" \
    '
      . as $m
      | $m.schema_version == "monarch-protocore-enrollment/v1"
      and $m.node.role == "operator-signing"
      and $m.node.chain_profile == $chain_profile
      and (($m.node.chain_id | tostring) == $chain_id)
      and (($m.release.expected_digest | ascii_downcase) == $digest)
      and ($m.operator.index | type == "number" and . >= 0 and . <= 9)
      and ($m.operator.position == "active" or $m.operator.position == "standby")
      and $m.cluster.size == 10
      and $m.cluster.threshold == 7
      and $m.cluster.active_members == 7
      and $m.cluster.standby_members == 3
      and ($m.cluster.roster_epoch | type == "number")
      and ($m.attestation.tpm.mode == "hardware-tpm2" or $m.attestation.tpm.mode == "vtpm-testnet")
      and ($m.attestation.tpm.pcr_bank == "sha256" or $m.attestation.tpm.pcr_bank == "sha384")
      and ([0,2,4,7] | all(. as $p | ($p | tostring) as $k | (($m.attestation.tpm.pcr_values[$k] // "") | test("^[0-9a-fA-F]{64}([0-9a-fA-F]{32})?$"))))
      and ([0,2,4,7] | all(. as $p | ($m.attestation.tpm.sealed_key_policy.pcrs // []) | index($p)))
      and ($m.attestation.tpm.quote_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and ($m.attestation.tpm.event_log_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and ($m.attestation.tpm.quote_nonce | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (($m.attestation.tpm.sealed_key_policy.operator_key_refs // []) | index("lythiumseal_operator_key"))
      and ($m.attestation.tpm.sealed_key_policy.policy_digest | test("^(0x)?[0-9a-fA-F]{64}$"))
      and ($m.attestation.tpm.sealed_key_policy.sealed_operator_key_sha256 | test("^(0x)?[0-9a-fA-F]{64}$"))
      and (($m.secret_files.operator_consensus_key // $m.secret_files.operator_identity_key) | type == "string")
      and ($m.secret_files.lythiumseal_operator_key | type == "string")
      and ($m.secret_files.tpm_sealed_operator_key | type == "string")
    ' "$ENROLLMENT_MANIFEST_LOG" >/dev/null || {
      enrollment_runtime_proof="failed"
      echo "enrollment manifest does not match required QEMU operator-signing contract" >&2
      jq '{schema_version, node, operator, cluster, release, attestation: .attestation.tpm}' "$ENROLLMENT_MANIFEST_LOG" >&2
      exit 1
    }

  EXPECTED_CHAIN_PROFILE="$CHAIN_PROFILE" EXPECTED_CHAIN_ID="$CHAIN_ID" REQUIRE_RELEASE_DIGEST=true \
    "$ROOT_DIR/scripts/validate-enrollment-manifest.sh" "$ENROLLMENT_MANIFEST_LOG" >/dev/null || {
      enrollment_runtime_proof="failed"
      echo "enrollment manifest failed local validator during runtime proof" >&2
      exit 1
    }

  if [[ "$CHAIN_PROFILE" == "mainnet" ]]; then
    jq -e '.attestation.tpm.mode == "hardware-tpm2"' "$ENROLLMENT_MANIFEST_LOG" >/dev/null || {
      enrollment_runtime_proof="failed"
      echo "mainnet enrollment runtime proof must use hardware-tpm2" >&2
      exit 1
    }
    jq -e '
      . as $m
      | ($m.on_chain_registration.registry_contract | test("^0x[0-9a-fA-F]{40}$"))
      and $m.on_chain_registration.operator_address == $m.operator.address
      and (($m.on_chain_registration.cluster_id | tostring) == ($m.cluster.id | tostring))
      and $m.on_chain_registration.operator_index == $m.operator.index
      and ($m.on_chain_registration.registration_tx_hash | test("^0x[0-9a-fA-F]{64}$"))
      and (($m.on_chain_registration.dag_round | tostring) | test("^[0-9]+$"))
      and ($m.on_chain_registration.quorum_certificate_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
      and $m.on_chain_registration.registration_method == "register"
      and (($m.on_chain_registration.registration_function_selector | ascii_downcase) == "0xf4896df2")
      and ($m.on_chain_registration.registration_calldata_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
      and $m.on_chain_registration.attestation_embedded_in_registration == true
      and (($m.on_chain_registration.release_expected_digest | ascii_downcase | ltrimstr("0x")) == ($m.release.expected_digest | ascii_downcase | ltrimstr("0x")))
      and (($m.on_chain_registration.quote_sha256 | ascii_downcase | ltrimstr("0x")) == ($m.attestation.tpm.quote_sha256 | ascii_downcase | ltrimstr("0x")))
      and (($m.on_chain_registration.event_log_sha256 | ascii_downcase | ltrimstr("0x")) == ($m.attestation.tpm.event_log_sha256 | ascii_downcase | ltrimstr("0x")))
      and (($m.on_chain_registration.pcr_policy_hash | ascii_downcase | ltrimstr("0x")) == ($m.attestation.tpm.sealed_key_policy.policy_digest | ascii_downcase | ltrimstr("0x")))
      and (($m.on_chain_registration.sealed_operator_key_sha256 | ascii_downcase | ltrimstr("0x")) == ($m.attestation.tpm.sealed_key_policy.sealed_operator_key_sha256 | ascii_downcase | ltrimstr("0x")))
      and ($m.on_chain_registration.attestation_payload_hash | test("^(0x)?[0-9a-fA-F]{64}$"))
    ' "$ENROLLMENT_MANIFEST_LOG" >/dev/null || {
      enrollment_runtime_proof="failed"
      echo "mainnet enrollment runtime proof requires on-chain registration call evidence" >&2
      exit 1
    }
  fi

  talos_read_file "$PROTOCORE_EXPECTED_DIGEST_FILE" "$ENROLLMENT_DIGEST_LOG" || {
    enrollment_runtime_proof="failed"
    echo "failed to read expected digest file through Talos API: $PROTOCORE_EXPECTED_DIGEST_FILE" >&2
    cat "$ENROLLMENT_DIGEST_LOG.err" >&2 2>/dev/null || true
    exit 1
  }
  local digest_file_value
  digest_file_value="$(tr -d '[:space:]' <"$ENROLLMENT_DIGEST_LOG" | tr '[:upper:]' '[:lower:]')"
  [[ "$digest_file_value" == "$expected_digest" ]] || {
    enrollment_runtime_proof="failed"
    echo "expected digest file does not match release metadata digest" >&2
    exit 1
  }

  : >"$ENROLLMENT_FILE_HASHES.items"
  remote_file_hash_json expected_digest "$PROTOCORE_EXPECTED_DIGEST_FILE" >>"$ENROLLMENT_FILE_HASHES.items"

  if [[ "$REQUIRE_TPM_BINDING_RUNTIME_PROOF" == "true" ]]; then
    local quote_path event_log_path sealed_path quote_hash_json event_log_hash_json sealed_hash_json
    local quote_hash event_log_hash sealed_hash
    quote_path="$(jq -r '.attestation.tpm.quote_file // ""' "$ENROLLMENT_MANIFEST_LOG")"
    event_log_path="$(jq -r '.attestation.tpm.event_log_file // ""' "$ENROLLMENT_MANIFEST_LOG")"
    sealed_path="$(jq -r '.secret_files.lythiumseal_operator_key // .secret_files.tpm_sealed_operator_key // ""' "$ENROLLMENT_MANIFEST_LOG")"

    [[ "$quote_path" == "$PROTOCORE_TPM_QUOTE_FILE" ]] || {
      enrollment_runtime_proof="failed"
      echo "TPM quote path mismatch: manifest=$quote_path env=$PROTOCORE_TPM_QUOTE_FILE" >&2
      exit 1
    }
    [[ "$event_log_path" == "$PROTOCORE_TPM_EVENT_LOG_FILE" ]] || {
      enrollment_runtime_proof="failed"
      echo "TPM event-log path mismatch: manifest=$event_log_path env=$PROTOCORE_TPM_EVENT_LOG_FILE" >&2
      exit 1
    }
    [[ "$sealed_path" == "$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" ]] || {
      enrollment_runtime_proof="failed"
      echo "LythiumSeal operator key path mismatch: manifest=$sealed_path env=$PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE" >&2
      exit 1
    }

    quote_hash_json="$(remote_file_hash_json tpm_quote "$quote_path")"
    event_log_hash_json="$(remote_file_hash_json tpm_event_log "$event_log_path")"
    sealed_hash_json="$(remote_file_hash_json lythiumseal_operator_key "$sealed_path")"
    printf '%s\n' "$quote_hash_json" >>"$ENROLLMENT_FILE_HASHES.items"
    printf '%s\n' "$event_log_hash_json" >>"$ENROLLMENT_FILE_HASHES.items"
    printf '%s\n' "$sealed_hash_json" >>"$ENROLLMENT_FILE_HASHES.items"

    quote_hash="$(jq -r '.sha256' <<<"$quote_hash_json")"
    event_log_hash="$(jq -r '.sha256' <<<"$event_log_hash_json")"
    sealed_hash="$(jq -r '.sha256' <<<"$sealed_hash_json")"
    require_hash_match "TPM quote" "$(jq -r '.attestation.tpm.quote_sha256' "$ENROLLMENT_MANIFEST_LOG")" "$quote_hash"
    require_hash_match "TPM event log" "$(jq -r '.attestation.tpm.event_log_sha256' "$ENROLLMENT_MANIFEST_LOG")" "$event_log_hash"
    require_hash_match "LythiumSeal operator key" "$(jq -r '.attestation.tpm.sealed_key_policy.sealed_operator_key_sha256' "$ENROLLMENT_MANIFEST_LOG")" "$sealed_hash"
  fi

  while IFS=$'\t' read -r key path; do
    [[ -n "$key" && -n "$path" ]] || continue
    remote_file_hash_json "secret_${key}" "$path" >>"$ENROLLMENT_FILE_HASHES.items"
  done < <(jq -r '.secret_files // {} | to_entries[] | [.key, .value] | @tsv' "$ENROLLMENT_MANIFEST_LOG")

  jq -s '.' "$ENROLLMENT_FILE_HASHES.items" >"$ENROLLMENT_FILE_HASHES"
  rm -f "$ENROLLMENT_FILE_HASHES.items"

  jq -n \
    --arg raw_image "$(basename "$RAW_IMAGE")" \
    --arg source "talosctl-read" \
    --arg manifest_path "$PROTOCORE_ENROLLMENT_FILE" \
    --arg digest_file_path "$PROTOCORE_EXPECTED_DIGEST_FILE" \
    --arg expected_digest "$expected_digest" \
    --arg manifest_log "$ENROLLMENT_MANIFEST_LOG" \
    --arg digest_log "$ENROLLMENT_DIGEST_LOG" \
    --arg file_hashes_log "$ENROLLMENT_FILE_HASHES" \
    --argjson require_tpm "$([[ "$REQUIRE_TPM_BINDING_RUNTIME_PROOF" == "true" ]] && printf true || printf false)" \
    --slurpfile manifest "$ENROLLMENT_MANIFEST_LOG" \
    --argjson file_hashes "$(cat "$ENROLLMENT_FILE_HASHES")" \
    '{
      status: "ok",
      raw_image: $raw_image,
      source: $source,
      manifest_path: $manifest_path,
      manifest_log: $manifest_log,
      digest_file_path: $digest_file_path,
      digest_log: $digest_log,
      expected_digest: $expected_digest,
      digest_match: (($manifest[0].release.expected_digest | ascii_downcase) == $expected_digest),
      operator: $manifest[0].operator,
      chain: ($manifest[0].node | {profile: .chain_profile, chain_id: (.chain_id | tostring), role: .role}),
      cluster: $manifest[0].cluster,
      on_chain_registration: ($manifest[0].on_chain_registration // null),
      tpm: {
        required: $require_tpm,
        mode: $manifest[0].attestation.tpm.mode,
        pcr_bank: $manifest[0].attestation.tpm.pcr_bank,
        pcrs: $manifest[0].attestation.tpm.sealed_key_policy.pcrs,
        quote_sha256: $manifest[0].attestation.tpm.quote_sha256,
        event_log_sha256: $manifest[0].attestation.tpm.event_log_sha256,
        quote_nonce: $manifest[0].attestation.tpm.quote_nonce,
        pcr_policy_hash: $manifest[0].attestation.tpm.sealed_key_policy.policy_digest,
        sealed_operator_key_sha256: $manifest[0].attestation.tpm.sealed_key_policy.sealed_operator_key_sha256,
        quote_file: $manifest[0].attestation.tpm.quote_file,
        event_log_file: $manifest[0].attestation.tpm.event_log_file,
        lythiumseal_operator_key_file: $manifest[0].secret_files.lythiumseal_operator_key,
        sealed_operator_key_file: $manifest[0].secret_files.tpm_sealed_operator_key
      },
      file_hashes_log: $file_hashes_log,
      file_hashes: $file_hashes
    }' >"$ENROLLMENT_RUNTIME_PROOF"

  enrollment_runtime_proof="ok"
  return 0
}

kernel_option_disabled() {
  local option="$1"
  if grep -Eq "^${option}=(y|m)$" "$KERNEL_CONFIG_TXT"; then
    printf false
    return
  fi
  printf true
}

kernel_option_enabled() {
  local option="$1"
  if grep -Eq "^${option}=(y|m)$" "$KERNEL_CONFIG_TXT"; then
    printf true
    return
  fi
  printf false
}

kernel_option_map() {
  local mode="$1"
  local output="$2"
  : >"$output.items"
  while read -r option; do
    [[ -n "$option" ]] || continue
    local ok
    if [[ "$mode" == "enabled" ]]; then
      ok="$(kernel_option_enabled "$option")"
    else
      ok="$(kernel_option_disabled "$option")"
    fi
    jq -n --arg option "$option" --argjson ok "$ok" '{($option): $ok}' >>"$output.items"
  done
  jq -s 'add // {}' "$output.items" >"$output"
  rm -f "$output.items"
}

mounts_with_filesystems() {
  local output="$1"
  : >"$output"
  while read -r fs; do
    [[ -n "$fs" ]] || continue
    awk -v fs="$fs" '$3 == fs {print}' "$MOUNTS_LOG" >>"$output"
  done
}

collect_dm_verity_root_hashes() {
  local output="$1"
  shift
  : >"$output"
  for file in "$@"; do
    [[ -s "$file" ]] || continue
    awk '
      {
        for (i = 1; i <= NF; i++) {
          token = $i
          lower = tolower(token)
          if (lower !~ /(verity|roothash|root_hash|usrhash|dm-mod\.create)/) {
            continue
          }
          while (match(token, /(sha256:|0x)?[0-9A-Fa-f]{64,128}/)) {
            hash = substr(token, RSTART, RLENGTH)
            hash = tolower(hash)
            sub(/^sha256:/, "", hash)
            sub(/^0x/, "", hash)
            print hash
            token = substr(token, RSTART + RLENGTH)
          }
        }
      }
    ' "$file"
  done | sort -u >"$output"
}

tcp_listener_ports_json() {
  local file="$1"
  local output="$2"
  if [[ ! -s "$file" ]]; then
    printf '[]\n' >"$output"
    return
  fi

  awk 'NR > 1 && $4 == "0A" { split($2, a, ":"); print a[2] }' "$file" \
    | while read -r port_hex; do
        [[ -n "$port_hex" ]] || continue
        printf '%d\n' "0x$port_hex"
      done \
    | sort -nu \
    | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)' >"$output"
}

tcp_no_ssh_listener() {
  local file
  for file in "$@"; do
    [[ -s "$file" ]] || continue
    if awk '
      NR > 1 && $4 == "0A" {
        split($2, a, ":")
        if (tolower(a[2]) == "0016") found = 1
      }
      END { exit found ? 0 : 1 }
    ' "$file"; then
      printf false
      return
    fi
  done
  printf true
}

prove_substrate_runtime() {
  if [[ "$REQUIRE_SUBSTRATE_RUNTIME_PROOF" != "true" ]]; then
    return 0
  fi

  talos_read_file /proc/config.gz "$KERNEL_CONFIG_GZ" || {
    substrate_runtime_proof="failed"
    echo "failed to read /proc/config.gz through Talos API" >&2
    cat "$KERNEL_CONFIG_GZ.err" >&2 2>/dev/null || true
    exit 1
  }
  gzip -dc "$KERNEL_CONFIG_GZ" >"$KERNEL_CONFIG_TXT" || {
    substrate_runtime_proof="failed"
    echo "failed to decompress /proc/config.gz" >&2
    exit 1
  }
  talos_read_file /proc/cmdline "$CMDLINE_LOG" || {
    substrate_runtime_proof="failed"
    echo "failed to read /proc/cmdline through Talos API" >&2
    cat "$CMDLINE_LOG.err" >&2 2>/dev/null || true
    exit 1
  }
  talos_read_file /proc/mounts "$MOUNTS_LOG" || {
    substrate_runtime_proof="failed"
    echo "failed to read /proc/mounts through Talos API" >&2
    cat "$MOUNTS_LOG.err" >&2 2>/dev/null || true
    exit 1
  }
  talos_read_file /proc/modules "$MODULES_LOG" || printf '' >"$MODULES_LOG"
  talos_read_file /proc/filesystems "$FILESYSTEMS_LOG" || printf '' >"$FILESYSTEMS_LOG"
  talos_read_file /proc/net/tcp "$TCP_LOG" || {
    substrate_runtime_proof="failed"
    echo "failed to read /proc/net/tcp through Talos API" >&2
    cat "$TCP_LOG.err" >&2 2>/dev/null || true
    exit 1
  }
  talos_read_file /proc/net/tcp6 "$TCP6_LOG" || printf 'sl local_address rem_address st\n' >"$TCP6_LOG"

  local root_line root_device root_fs root_options root_read_only kernel_config_sha cmdline_sha mounts_sha modules_sha filesystems_sha tcp_sha tcp6_sha
  root_line="$(awk '$2 == "/" {print; exit}' "$MOUNTS_LOG")"
  root_device="$(awk '$2 == "/" {print $1; exit}' "$MOUNTS_LOG")"
  root_fs="$(awk '$2 == "/" {print $3; exit}' "$MOUNTS_LOG")"
  root_options="$(awk '$2 == "/" {print $4; exit}' "$MOUNTS_LOG")"
  if [[ ",$root_options," == *,ro,* ]]; then
    root_read_only=true
  else
    root_read_only=false
  fi

  kernel_config_sha="$(sha256sum "$KERNEL_CONFIG_TXT" | awk '{print $1}')"
  cmdline_sha="$(sha256sum "$CMDLINE_LOG" | awk '{print $1}')"
  mounts_sha="$(sha256sum "$MOUNTS_LOG" | awk '{print $1}')"
  modules_sha="$(sha256sum "$MODULES_LOG" | awk '{print $1}')"
  filesystems_sha="$(sha256sum "$FILESYSTEMS_LOG" | awk '{print $1}')"
  tcp_sha="$(sha256sum "$TCP_LOG" | awk '{print $1}')"
  tcp6_sha="$(sha256sum "$TCP6_LOG" | awk '{print $1}')"

  local baseline_sha baseline_schema baseline_talos baseline_arch
  baseline_sha="$(sha256sum "$KERNEL_BASELINE_FILE" | awk '{print $1}')"
  baseline_schema="$(jq -r '.schema_version // ""' "$KERNEL_BASELINE_FILE")"
  baseline_talos="$(jq -r '.talos_version // ""' "$KERNEL_BASELINE_FILE")"
  baseline_arch="$(jq -r '.arch // ""' "$KERNEL_BASELINE_FILE")"

  local required_enabled_json required_disabled_json immutable_fs_json immutable_mounts immutable_base_present tcp_ports_json tcp6_ports_json no_ssh_listener
  required_enabled_json="$LOG_DIR/kernel-required-enabled.json"
  required_disabled_json="$LOG_DIR/kernel-required-disabled-or-absent.json"
  immutable_fs_json="$LOG_DIR/immutable-filesystems.json"
  immutable_mounts="$LOG_DIR/immutable-base-mounts.txt"
  tcp_ports_json="$LOG_DIR/tcp-listen-ports.json"
  tcp6_ports_json="$LOG_DIR/tcp6-listen-ports.json"

  jq -r '.required_kernel_options.enabled[]?' "$KERNEL_BASELINE_FILE" \
    | kernel_option_map enabled "$required_enabled_json"
  jq -r '.required_kernel_options.disabled_or_absent[]?' "$KERNEL_BASELINE_FILE" \
    | kernel_option_map disabled "$required_disabled_json"
  jq -r '.rootfs.immutable_filesystems[]?' "$KERNEL_BASELINE_FILE" >"$immutable_fs_json.lines"
  mounts_with_filesystems "$immutable_mounts" <"$immutable_fs_json.lines"
  jq -R -s 'split("\n") | map(select(length > 0))' "$immutable_fs_json.lines" >"$immutable_fs_json"
  if awk '{ if ($4 ~ /(^|,)ro(,|$)/) found=1 } END { exit found ? 0 : 1 }' "$immutable_mounts"; then
    immutable_base_present=true
  else
    immutable_base_present=false
  fi
  rm -f "$immutable_fs_json.lines"
  tcp_listener_ports_json "$TCP_LOG" "$tcp_ports_json"
  tcp_listener_ports_json "$TCP6_LOG" "$tcp6_ports_json"
  no_ssh_listener="$(tcp_no_ssh_listener "$TCP_LOG" "$TCP6_LOG")"

  local root_dm_block=""
  if [[ "$root_device" =~ ^/dev/dm-[0-9]+$ ]]; then
    root_dm_block="${root_device#/dev/}"
    talos_read_file "/sys/block/${root_dm_block}/dm/name" "$ROOT_DM_NAME_LOG" || printf '' >"$ROOT_DM_NAME_LOG"
    talos_read_file "/sys/block/${root_dm_block}/dm/uuid" "$ROOT_DM_UUID_LOG" || printf '' >"$ROOT_DM_UUID_LOG"
  else
    printf '' >"$ROOT_DM_NAME_LOG"
    printf '' >"$ROOT_DM_UUID_LOG"
  fi

  collect_dm_verity_root_hashes "$DM_VERITY_ROOT_HASHES" "$CMDLINE_LOG" "$ROOT_DM_NAME_LOG" "$ROOT_DM_UUID_LOG"

  local dm_verity_kernel_support dm_verity_cmdline dm_verity_mount dm_verity_module dm_verity_active dm_verity_root_hash_evidence
  dm_verity_kernel_support="$(kernel_option_enabled CONFIG_DM_VERITY)"
  if grep -Eiq '(^|[[:space:]])((dm_verity|dm-verity|verity)([=[:space:]]|$)|dm-mod\.create=)' "$CMDLINE_LOG"; then
    dm_verity_cmdline=true
  else
    dm_verity_cmdline=false
  fi
  if grep -Eiq 'dm-[0-9]+|/dev/mapper|verity' "$MOUNTS_LOG"; then
    dm_verity_mount=true
  else
    dm_verity_mount=false
  fi
  if grep -Eiq '(^|[[:space:]])dm_verity([[:space:]]|$)' "$MODULES_LOG"; then
    dm_verity_module=true
  else
    dm_verity_module=false
  fi
  if [[ "$dm_verity_cmdline" == "true" || "$dm_verity_mount" == "true" || "$dm_verity_module" == "true" ]]; then
    dm_verity_active=true
  else
    dm_verity_active=false
  fi
  if [[ -s "$DM_VERITY_ROOT_HASHES" ]]; then
    dm_verity_root_hash_evidence=true
  else
    dm_verity_root_hash_evidence=false
  fi

  jq -n \
    --arg raw_image "$(basename "$RAW_IMAGE")" \
    --arg baseline_path "${KERNEL_BASELINE_FILE#"$ROOT_DIR/"}" \
    --arg baseline_schema "$baseline_schema" \
    --arg baseline_talos "$baseline_talos" \
    --arg baseline_arch "$baseline_arch" \
    --arg baseline_sha "$baseline_sha" \
    --arg kernel_config_sha "$kernel_config_sha" \
    --arg cmdline_sha "$cmdline_sha" \
    --arg mounts_sha "$mounts_sha" \
    --arg modules_sha "$modules_sha" \
    --arg filesystems_sha "$filesystems_sha" \
    --arg tcp_sha "$tcp_sha" \
    --arg tcp6_sha "$tcp6_sha" \
    --arg root_line "$root_line" \
    --arg root_device "$root_device" \
    --arg root_fs "$root_fs" \
    --arg root_options "$root_options" \
    --arg kernel_config_log "$KERNEL_CONFIG_TXT" \
    --arg cmdline_log "$CMDLINE_LOG" \
    --arg mounts_log "$MOUNTS_LOG" \
    --arg modules_log "$MODULES_LOG" \
    --arg filesystems_log "$FILESYSTEMS_LOG" \
    --arg tcp_log "$TCP_LOG" \
    --arg tcp6_log "$TCP6_LOG" \
    --arg root_dm_name_log "$ROOT_DM_NAME_LOG" \
    --arg root_dm_uuid_log "$ROOT_DM_UUID_LOG" \
    --arg root_hashes_log "$DM_VERITY_ROOT_HASHES" \
    --argjson root_read_only "$root_read_only" \
    --argjson required_enabled "$(cat "$required_enabled_json")" \
    --argjson required_disabled "$(cat "$required_disabled_json")" \
    --argjson immutable_filesystems "$(cat "$immutable_fs_json")" \
    --rawfile immutable_mounts "$immutable_mounts" \
    --argjson immutable_base_present "$immutable_base_present" \
    --argjson tcp_listen_ports "$(cat "$tcp_ports_json")" \
    --argjson tcp6_listen_ports "$(cat "$tcp6_ports_json")" \
    --argjson no_ssh_listener "$no_ssh_listener" \
    --argjson dm_verity_kernel_support "$dm_verity_kernel_support" \
    --argjson dm_verity_cmdline "$dm_verity_cmdline" \
    --argjson dm_verity_mount "$dm_verity_mount" \
    --argjson dm_verity_module "$dm_verity_module" \
    --argjson dm_verity_active "$dm_verity_active" \
    --argjson dm_verity_root_hash_evidence "$dm_verity_root_hash_evidence" \
    --rawfile dm_verity_root_hashes "$DM_VERITY_ROOT_HASHES" \
    '{
      status: "ok",
      raw_image: $raw_image,
      source: "talosctl-read",
      kernel_baseline: {
        path: $baseline_path,
        schema: $baseline_schema,
        talos_version: $baseline_talos,
        arch: $baseline_arch,
        sha256: $baseline_sha
      },
      root_mount: {
        line: $root_line,
        device: $root_device,
        filesystem: $root_fs,
        options: $root_options,
        read_only: $root_read_only
      },
      root_integrity: {
        read_only_root: $root_read_only,
        immutable_filesystems: $immutable_filesystems,
        immutable_base_mount_present: $immutable_base_present,
        immutable_base_mounts: ($immutable_mounts | split("\n") | map(select(length > 0))),
        dm_verity: {
          kernel_support: $dm_verity_kernel_support,
          active_evidence: $dm_verity_active,
          root_hash_evidence: $dm_verity_root_hash_evidence,
          root_hashes: ($dm_verity_root_hashes | split("\n") | map(select(length > 0))),
          cmdline_evidence: $dm_verity_cmdline,
          mount_evidence: $dm_verity_mount,
          module_evidence: $dm_verity_module,
          root_dm_name_log: $root_dm_name_log,
          root_dm_uuid_log: $root_dm_uuid_log,
          root_hashes_log: $root_hashes_log
        }
      },
      kernel_config: {
        sha256: $kernel_config_sha,
        log: $kernel_config_log,
        required_enabled: $required_enabled,
        required_disabled_or_absent: $required_disabled
      },
      runtime_network: {
        no_ssh_listener: $no_ssh_listener,
        tcp_listen_ports: $tcp_listen_ports,
        tcp6_listen_ports: $tcp6_listen_ports,
        tcp_log: $tcp_log,
        tcp6_log: $tcp6_log
      },
      proc_evidence: {
        cmdline_sha256: $cmdline_sha,
        mounts_sha256: $mounts_sha,
        modules_sha256: $modules_sha,
        filesystems_sha256: $filesystems_sha,
        tcp_sha256: $tcp_sha,
        tcp6_sha256: $tcp6_sha,
        cmdline_log: $cmdline_log,
        mounts_log: $mounts_log,
        modules_log: $modules_log,
        filesystems_log: $filesystems_log,
        tcp_log: $tcp_log,
        tcp6_log: $tcp6_log
      }
    }' >"$SUBSTRATE_RUNTIME_PROOF"

  if [[ "$root_read_only" != "true" ]]; then
    substrate_runtime_proof="failed"
    echo "runtime substrate proof failed: root mount is not read-only" >&2
    cat "$SUBSTRATE_RUNTIME_PROOF" >&2
    exit 1
  fi
  if ! jq -e '.kernel_config.required_enabled | to_entries | all(.value == true)' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
    substrate_runtime_proof="failed"
    echo "runtime substrate proof failed: required kernel options are not enabled" >&2
    jq '.kernel_config.required_enabled' "$SUBSTRATE_RUNTIME_PROOF" >&2
    exit 1
  fi
  if ! jq -e '.kernel_config.required_disabled_or_absent | to_entries | all(.value == true)' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
    substrate_runtime_proof="failed"
    echo "runtime substrate proof failed: required kernel options are enabled" >&2
    jq '.kernel_config.required_disabled_or_absent' "$SUBSTRATE_RUNTIME_PROOF" >&2
    exit 1
  fi
  if ! jq -e '.runtime_network.no_ssh_listener == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
    substrate_runtime_proof="failed"
    echo "runtime substrate proof failed: SSH listener detected on TCP port 22" >&2
    jq '.runtime_network' "$SUBSTRATE_RUNTIME_PROOF" >&2
    exit 1
  fi
  local baseline_requires_immutable baseline_requires_dm_kernel baseline_requires_active
  baseline_requires_immutable="$(jq -r '.rootfs.requires_immutable_base_mount // false' "$KERNEL_BASELINE_FILE")"
  baseline_requires_dm_kernel="$(jq -r '.rootfs.requires_dm_verity_kernel_support // false' "$KERNEL_BASELINE_FILE")"
  baseline_requires_active="$(jq -r '.rootfs.dm_verity_active_evidence_required // false' "$KERNEL_BASELINE_FILE")"
  if [[ "$baseline_requires_immutable" == "true" || "$REQUIRE_DM_VERITY_ACTIVE" == "true" || "$baseline_requires_active" == "true" ]]; then
    if ! jq -e '.root_integrity.immutable_base_mount_present == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
      substrate_runtime_proof="failed"
      echo "runtime substrate proof failed: no read-only immutable base filesystem mount found" >&2
      jq '.root_integrity' "$SUBSTRATE_RUNTIME_PROOF" >&2
      exit 1
    fi
  fi
  if [[ "$baseline_requires_dm_kernel" == "true" || "$REQUIRE_DM_VERITY_ACTIVE" == "true" || "$baseline_requires_active" == "true" ]]; then
    if ! jq -e '.root_integrity.dm_verity.kernel_support == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
      substrate_runtime_proof="failed"
      echo "runtime substrate proof failed: dm-verity kernel support is missing" >&2
      jq '.root_integrity.dm_verity' "$SUBSTRATE_RUNTIME_PROOF" >&2
      exit 1
    fi
  fi
  if [[ "$REQUIRE_DM_VERITY_ACTIVE" == "true" || "$baseline_requires_active" == "true" ]]; then
    if ! jq -e '.root_integrity.dm_verity.active_evidence == true and .root_integrity.dm_verity.root_hash_evidence == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null; then
      substrate_runtime_proof="failed"
      echo "runtime substrate proof failed: dm-verity active evidence is missing" >&2
      jq '.root_integrity.dm_verity' "$SUBSTRATE_RUNTIME_PROOF" >&2
      exit 1
    fi
  fi

  substrate_runtime_proof="ok"
  return 0
}

expected_protocore_digest() {
  local env_digest="${MONARCH_E2E_EXPECTED_DIGEST:-}"
  local metadata_digest=""
  if [[ -f "$RELEASE_METADATA_FILE" && "$(command -v jq || true)" ]]; then
    metadata_digest="$(jq -r '.sources.protocore_binary.sha256 // ""' "$RELEASE_METADATA_FILE" 2>/dev/null || true)"
  fi

  if [[ "$metadata_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
    if [[ -n "$env_digest" && "${env_digest,,}" != "${metadata_digest,,}" ]]; then
      echo "MONARCH_E2E_EXPECTED_DIGEST does not match release metadata digest" >&2
      return 1
    fi
    printf '%s' "${metadata_digest,,}"
    return 0
  fi

  if [[ "$env_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s' "${env_digest,,}"
  fi
}

wait_for_initial_boot
apply_machine_config
prove_enrollment_runtime
check_extension_service
probe_protocore_rpc
prove_substrate_runtime
expected_digest="$(expected_protocore_digest)"

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
  echo "QEMU exited before the smoke test completed" >&2
  tail -80 "$SERIAL_LOG" >&2 || true
  exit 1
fi

cat > "$LOG_DIR/result.json" <<EOF_RESULT
{
  "status": "ok",
  "raw_image": "$(basename "$RAW_IMAGE")",
  "qemu_binary": "$QEMU_BIN",
  "qemu_pid": "$(cat "$PID_FILE")",
  "talos_api_forward": "127.0.0.1:${API_HOST_PORT}",
  "protocore_rpc_forward": "127.0.0.1:${PROTOCORE_RPC_HOST_PORT}",
  "talos_api_probe": "$talos_api_probe_status",
  "require_talos_api_probe": "$REQUIRE_TALOS_API_PROBE",
  "machine_config_applied": "$machine_config_applied",
  "talos_machine_config_file": "$(basename "${TALOS_MACHINE_CONFIG_FILE:-}")",
  "talosconfig_file": "$(basename "${TALOSCONFIG_FILE:-}")",
  "extension_service_name": "$EXTENSION_SERVICE_NAME",
  "extension_service_check": "$extension_service_check",
  "protocore_rpc_probe": "$protocore_rpc_probe",
  "enrollment_runtime_proof": "$enrollment_runtime_proof",
  "substrate_runtime_proof": "$substrate_runtime_proof",
  "release_metadata": "$(basename "$RELEASE_METADATA_FILE")",
  "expected_protocore_digest": "$expected_digest",
  "timeout_seconds": "$TIMEOUT_SECONDS",
  "boot_hold_seconds": "$BOOT_HOLD_SECONDS",
  "post_apply_timeout_seconds": "$POST_APPLY_TIMEOUT_SECONDS",
  "talos_version_log": "$TALOS_VERSION_LOG",
  "apply_config_log": "$APPLY_CONFIG_LOG",
  "extension_service_log": "$SERVICE_LOG",
  "extension_logs": "$SERVICE_LOGS",
  "protocore_rpc_log": "$RPC_LOG",
  "enrollment_runtime_proof_log": "$ENROLLMENT_RUNTIME_PROOF",
  "substrate_runtime_proof_log": "$SUBSTRATE_RUNTIME_PROOF",
  "serial_log": "$SERIAL_LOG"
}
EOF_RESULT

cat > "$LIVE_ENV_FILE" <<EOF_LIVE_ENV
export MONARCH_OS_SMOKE_RESULT="$LOG_DIR/result.json"
export MONARCH_E2E_TALOS_ENDPOINT="https://127.0.0.1:${API_HOST_PORT}"
export MONARCH_E2E_TALOSCONFIG="${TALOSCONFIG_FILE:-}"
export MONARCH_E2E_RPC_ENDPOINT="http://127.0.0.1:${PROTOCORE_RPC_HOST_PORT}"
export MONARCH_E2E_EXPECTED_DIGEST="$expected_digest"
EOF_LIVE_ENV

printf '%s\n' "$LOG_DIR/result.json"

if [[ "$KEEP_QEMU_ALIVE" == "true" ]]; then
  printf 'QEMU smoke VM is still running; source %s for Desktop e2e settings. Stop this process to terminate QEMU.\n' "$LIVE_ENV_FILE" >&2
  while [[ -f "$PID_FILE" ]]; do
    pid="$(cat "$PID_FILE")"
    [[ -n "$pid" ]] || break
    kill -0 "$pid" >/dev/null 2>&1 || break
    sleep 5
  done
fi
