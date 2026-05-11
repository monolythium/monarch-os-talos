#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
API_HOST_PORT="${API_HOST_PORT:-50000}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-90}"
BOOT_HOLD_SECONDS="${BOOT_HOLD_SECONDS:-20}"
REQUIRE_TALOSCTL_PROBE="${REQUIRE_TALOSCTL_PROBE:-false}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"

RAW_IMAGE="${RAW_IMAGE:-"$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.raw"}"
LOG_DIR="$OUT_DIR/smoke-qemu"
SERIAL_LOG="$LOG_DIR/serial.log"
PID_FILE="$LOG_DIR/qemu.pid"

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

mkdir -p "$LOG_DIR"
rm -f "$SERIAL_LOG" "$PID_FILE"

"$QEMU_BIN" \
  -m "${QEMU_MEMORY:-2048}" \
  -smp "${QEMU_CPUS:-2}" \
  -machine accel=kvm:tcg \
  -cpu "${QEMU_CPU:-max}" \
  -drive "file=$RAW_IMAGE,format=raw,if=virtio,readonly=on" \
  -netdev "user,id=net0,hostfwd=tcp::${API_HOST_PORT}-:50000" \
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

deadline=$((SECONDS + TIMEOUT_SECONDS))
boot_ready=false
talosctl_probe_status="not_required"
TALOS_VERSION_LOG="$LOG_DIR/talos-version.txt"

probe_talos_api() {
  if ! (echo >"/dev/tcp/127.0.0.1/${API_HOST_PORT}") >/dev/null 2>&1; then
    return 1
  fi

  if ! command -v talosctl >/dev/null 2>&1; then
    printf 'talosctl not installed; TCP probe only\n' > "$TALOS_VERSION_LOG"
    return 0
  fi

  timeout 8 talosctl \
    --nodes 127.0.0.1 \
    --endpoints 127.0.0.1 \
    version \
    --insecure \
    --short >"$TALOS_VERSION_LOG.tmp" 2>&1 || return 1
  mv "$TALOS_VERSION_LOG.tmp" "$TALOS_VERSION_LOG"
  return 0
}

while (( SECONDS < deadline )); do
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "QEMU exited before the smoke test completed" >&2
    tail -80 "$SERIAL_LOG" >&2 || true
    exit 1
  fi

  if probe_talos_api; then
    boot_ready=true
    talosctl_probe_status="ok"
    break
  fi

  if [[ "$REQUIRE_TALOSCTL_PROBE" != "true" && "$SECONDS" -ge "$BOOT_HOLD_SECONDS" ]]; then
    boot_ready=true
    talosctl_probe_status="not_required"
    if [[ -s "$TALOS_VERSION_LOG.tmp" ]]; then
      cp "$TALOS_VERSION_LOG.tmp" "$TALOS_VERSION_LOG"
    else
      printf 'talosctl probe not required for boot smoke\n' > "$TALOS_VERSION_LOG"
    fi
    break
  fi

  sleep 2
done

if [[ "$boot_ready" != "true" ]]; then
  echo "Monarch OS image did not pass QEMU smoke within ${TIMEOUT_SECONDS}s" >&2
  echo "serial log: $SERIAL_LOG" >&2
  cat "$TALOS_VERSION_LOG.tmp" >&2 2>/dev/null || true
  tail -80 "$SERIAL_LOG" >&2 || true
  exit 1
fi

cat > "$LOG_DIR/result.json" <<EOF_RESULT
{
  "status": "ok",
  "raw_image": "$(basename "$RAW_IMAGE")",
  "qemu_pid": "$(cat "$PID_FILE")",
  "talos_api_forward": "127.0.0.1:${API_HOST_PORT}",
  "talosctl_probe": "$talosctl_probe_status",
  "talos_version_log": "$TALOS_VERSION_LOG",
  "serial_log": "$SERIAL_LOG"
}
EOF_RESULT

printf '%s\n' "$LOG_DIR/result.json"
