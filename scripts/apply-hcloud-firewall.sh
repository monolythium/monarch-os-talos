#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HCLOUD_FIREWALL_NAME="${HCLOUD_FIREWALL_NAME:-monarch-node}"
HCLOUD_FIREWALL_APPLY="${HCLOUD_FIREWALL_APPLY:-false}"
HCLOUD_FIREWALL_RULES_OUTPUT="${HCLOUD_FIREWALL_RULES_OUTPUT:-}"
HCLOUD_FIREWALL_SERVERS="${HCLOUD_FIREWALL_SERVERS:-}"
HCLOUD_FIREWALL_SERVER_SELECTOR="${HCLOUD_FIREWALL_SERVER_SELECTOR:-}"
HCLOUD_FIREWALL_LABELS="${HCLOUD_FIREWALL_LABELS:-app=monarch-os,component=protocore}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "hcloud-firewall: $*" >&2
  exit 1
}

bool_enabled() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

csv_to_lines() {
  local raw="$1"
  local item
  IFS=',' read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

write_rules_output() {
  local rules="$1"
  local tmp
  if [[ -z "$HCLOUD_FIREWALL_RULES_OUTPUT" ]]; then
    return
  fi
  mkdir -p "$(dirname "$HCLOUD_FIREWALL_RULES_OUTPUT")"
  tmp="$(mktemp "$HCLOUD_FIREWALL_RULES_OUTPUT.XXXXXX")"
  printf '%s\n' "$rules" > "$tmp"
  mv "$tmp" "$HCLOUD_FIREWALL_RULES_OUTPUT"
}

policy_to_hcloud_rules() {
  jq '
    def description:
      if .surface == "talos_api" then "Monarch Talos API mTLS"
      elif .surface == "protocore_rpc" then "Protocore JSON-RPC"
      elif .surface == "protocore_p2p" then "Protocore P2P"
      else .surface end;

    [
      .allow[]
      | {
          direction: "in",
          protocol: .proto,
          port: (.port | tostring),
          source_ips: .cidrs,
          description: description
        }
    ]
  '
}

create_label_args() {
  local label
  while IFS= read -r label; do
    printf '%s\0%s\0' "--label" "$label"
  done < <(csv_to_lines "$HCLOUD_FIREWALL_LABELS")
}

resolve_servers() {
  csv_to_lines "$HCLOUD_FIREWALL_SERVERS"
  if [[ -n "$(trim "$HCLOUD_FIREWALL_SERVER_SELECTOR")" ]]; then
    hcloud server list -o json -l "$HCLOUD_FIREWALL_SERVER_SELECTOR" \
      | jq -r '.[] | .name // (.id | tostring)'
  fi
}

need jq
[[ -n "$(trim "$HCLOUD_FIREWALL_NAME")" ]] || fail "HCLOUD_FIREWALL_NAME is required"

policy_json="$(
  env NETWORK_FIREWALL_FORMAT=json NETWORK_FIREWALL_OUTPUT="" \
    "$ROOT_DIR/scripts/render-network-firewall.sh"
)"
rules_json="$(printf '%s\n' "$policy_json" | policy_to_hcloud_rules)"
write_rules_output "$rules_json"

if ! bool_enabled "$HCLOUD_FIREWALL_APPLY"; then
  jq -n \
    --arg firewall "$HCLOUD_FIREWALL_NAME" \
    --arg rules_file "$HCLOUD_FIREWALL_RULES_OUTPUT" \
    --argjson rules "$rules_json" \
    '{
      ok: true,
      dry_run: true,
      firewall: $firewall,
      rules_file: ($rules_file | select(length > 0)),
      rules: $rules,
      apply_hint: "set HCLOUD_FIREWALL_APPLY=true to create/replace the Hetzner firewall"
    }'
  exit 0
fi

need hcloud
rules_file="$(mktemp)"
trap 'rm -f "$rules_file"' EXIT
printf '%s\n' "$rules_json" > "$rules_file"

if hcloud firewall describe "$HCLOUD_FIREWALL_NAME" >/dev/null 2>&1; then
  hcloud firewall replace-rules "$HCLOUD_FIREWALL_NAME" --rules-file "$rules_file"
else
  label_args=()
  while IFS= read -r -d '' part; do
    label_args+=("$part")
  done < <(create_label_args)
  hcloud firewall create \
    --name "$HCLOUD_FIREWALL_NAME" \
    --rules-file "$rules_file" \
    "${label_args[@]}"
fi

mapfile -t servers < <(resolve_servers | awk 'NF' | sort -u)
for server in "${servers[@]}"; do
  hcloud firewall apply-to-resource "$HCLOUD_FIREWALL_NAME" --type server --server "$server"
done

if (( ${#servers[@]} > 0 )); then
  applied_servers_json="$(printf '%s\n' "${servers[@]}" | jq -R . | jq -s .)"
else
  applied_servers_json="[]"
fi

jq -n \
  --arg firewall "$HCLOUD_FIREWALL_NAME" \
  --argjson applied_servers "$applied_servers_json" \
  '{
    ok: true,
    dry_run: false,
    firewall: $firewall,
    applied_servers: $applied_servers
  }'
