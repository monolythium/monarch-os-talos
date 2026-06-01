#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/_out"}"
SUBSTRATE_RUNTIME_PROOF="${DM_VERITY_SUBSTRATE_PROOF:-${1:-"$OUT_DIR/smoke-qemu/substrate-runtime.json"}}"
FORMAT="${FORMAT:-lines}"

[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT_DIR/$OUT_DIR"
[[ "$SUBSTRATE_RUNTIME_PROOF" = /* ]] || SUBSTRATE_RUNTIME_PROOF="$ROOT_DIR/$SUBSTRATE_RUNTIME_PROOF"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "dm-verity-root-hashes: $*" >&2
  exit 1
}

need jq

[[ -f "$SUBSTRATE_RUNTIME_PROOF" ]] \
  || fail "substrate runtime proof not found: $SUBSTRATE_RUNTIME_PROOF"
jq -e . "$SUBSTRATE_RUNTIME_PROOF" >/dev/null \
  || fail "substrate runtime proof is not valid JSON: $SUBSTRATE_RUNTIME_PROOF"

jq -e '.status == "ok"' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null \
  || fail "substrate runtime proof status is not ok"
jq -e '.root_integrity.dm_verity.active_evidence == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null \
  || fail "substrate runtime proof does not show active dm-verity evidence"
jq -e '.root_integrity.dm_verity.root_hash_evidence == true' "$SUBSTRATE_RUNTIME_PROOF" >/dev/null \
  || fail "substrate runtime proof does not include dm-verity root-hash evidence"

hashes_json="$(jq -c '
  [.root_integrity.dm_verity.root_hashes[]?
    | ascii_downcase
    | sub("^sha256:"; "")
    | sub("^0x"; "")
  ]
  | unique
' "$SUBSTRATE_RUNTIME_PROOF")"

jq -e 'length > 0 and all(.[]; test("^[0-9a-f]{64}([0-9a-f]{64})?$"))' <<<"$hashes_json" >/dev/null \
  || fail "substrate runtime proof has no valid dm-verity root hashes"

case "$FORMAT" in
  lines)
    jq -r '.[]' <<<"$hashes_json"
    ;;
  csv)
    jq -r 'join(",")' <<<"$hashes_json"
    ;;
  env)
    printf 'DM_VERITY_EXPECTED_ROOT_HASHES=%s\n' "$(jq -r 'join(",")' <<<"$hashes_json")"
    ;;
  json)
    printf '%s\n' "$hashes_json"
    ;;
  *)
    fail "FORMAT must be lines, csv, env, or json: $FORMAT"
    ;;
esac
