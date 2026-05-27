#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO_CORE_DIR="${MONO_CORE_DIR:-"$ROOT_DIR/../mono-core"}"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
ARCH="${ARCH:-amd64}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.0}"
PROTOCORE_BINARY="${PROTOCORE_BINARY:-"$MONO_CORE_DIR/target/release/protocore"}"
PROTOCORE_SOURCE="${PROTOCORE_SOURCE:-local}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$MONO_CORE_DIR" = /* ]] || MONO_CORE_DIR="$ROOT_DIR/$MONO_CORE_DIR"
[[ "$PROTOCORE_BINARY" = /* ]] || PROTOCORE_BINARY="$ROOT_DIR/$PROTOCORE_BINARY"

mkdir -p "$OUT_DIR"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need git
need jq
need sha256sum
need stat

git_commit() {
  git -C "$1" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

git_dirty() {
  if [[ ! -d "$1/.git" ]]; then
    printf 'false'
    return
  fi
  if ! git -C "$1" diff --quiet --ignore-submodules -- 2>/dev/null; then
    printf 'true'
    return
  fi
  if [[ -n "$(git -C "$1" status --short --untracked-files=no 2>/dev/null)" ]]; then
    printf 'true'
    return
  fi
  printf 'false'
}

protocore_version() {
  if [[ -x "$PROTOCORE_BINARY" ]]; then
    "$PROTOCORE_BINARY" version --output json 2>/dev/null | jq -r '.version // "unknown"' || printf 'unknown'
    return
  fi
  printf 'unknown'
}

protocore_binary_sha256() {
  if [[ -x "$PROTOCORE_BINARY" ]]; then
    sha256sum "$PROTOCORE_BINARY" | awk '{print $1}'
    return
  fi
  printf 'unknown'
}

artifacts_file="$(mktemp)"
trap 'rm -f "$artifacts_file"' EXIT

find "$OUT_DIR" -maxdepth 1 -type f \
  \( -name "monarch-os-talos-$TALOS_VERSION-$ARCH.iso" \
    -o -name "monarch-os-talos-$TALOS_VERSION-$ARCH.raw" \
    -o -name "monarch-protocore-$ARCH-*.tar" \
    -o -name "monarch-*.spdx.json" \) \
  | sort \
  | while read -r artifact; do
      sha="$(sha256sum "$artifact" | awk '{print $1}')"
      size="$(stat -c '%s' "$artifact")"
      jq -n \
        --arg path "$(basename "$artifact")" \
        --arg sha256 "$sha" \
        --argjson size "$size" \
        '{path: $path, sha256: $sha256, size_bytes: $size}'
    done > "$artifacts_file"

metadata_path="$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.release.json"
repo_commit="$(git_commit "$ROOT_DIR")"
mono_core_commit="$(git_commit "$MONO_CORE_DIR")"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -s \
  --arg schema_version "monarch-os-release-metadata/v1" \
  --arg generated_at "$generated_at" \
  --arg talos_version "$TALOS_VERSION" \
  --arg arch "$ARCH" \
  --arg repo_commit "$repo_commit" \
  --argjson repo_dirty "$(git_dirty "$ROOT_DIR")" \
  --arg mono_core_commit "$mono_core_commit" \
  --argjson mono_core_dirty "$(git_dirty "$MONO_CORE_DIR")" \
  --arg protocore_version "$(protocore_version)" \
  --arg protocore_source "$PROTOCORE_SOURCE" \
  --arg protocore_binary "$(basename "$PROTOCORE_BINARY")" \
  --arg protocore_binary_sha256 "$(protocore_binary_sha256)" \
  '{
    schema_version: $schema_version,
    generated_at: $generated_at,
    talos: {
      version: $talos_version,
      arch: $arch
    },
    sources: {
      monarch_os_talos: {
        commit: $repo_commit,
        dirty: $repo_dirty
      },
      mono_core: {
        commit: $mono_core_commit,
        dirty: $mono_core_dirty,
        protocore_version: $protocore_version
      },
      protocore_binary: {
        source: $protocore_source,
        path: $protocore_binary,
        sha256: $protocore_binary_sha256
      }
    },
    artifacts: .
  }' "$artifacts_file" > "$metadata_path"

(cd "$(dirname "$metadata_path")" && sha256sum "$(basename "$metadata_path")" > "$(basename "$metadata_path").sha256")
printf '%s\n' "$metadata_path"
