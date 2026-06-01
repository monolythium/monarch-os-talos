#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NETWORK_POLICY_METADATA="${NETWORK_POLICY_METADATA:-${1:-}}"
NETWORK_FIREWALL_FORMAT="${NETWORK_FIREWALL_FORMAT:-nftables}"
NETWORK_FIREWALL_OUTPUT="${NETWORK_FIREWALL_OUTPUT:-}"
TALOS_ALLOWED_CIDRS="${TALOS_ALLOWED_CIDRS:-}"
RPC_ALLOWED_CIDRS="${RPC_ALLOWED_CIDRS:-}"
P2P_ALLOWED_CIDRS="${P2P_ALLOWED_CIDRS:-0.0.0.0/0,::/0}"
ALLOW_PUBLIC_TALOS="${ALLOW_PUBLIC_TALOS:-false}"
ALLOW_PUBLIC_RPC="${ALLOW_PUBLIC_RPC:-false}"

talos_port="${TALOS_API_PORT:-50000}"
rpc_port="${PROTOCORE_RPC_PORT:-8545}"
p2p_port="${PROTOCORE_P2P_PORT:-29898}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "network-firewall: $*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

bool_enabled() {
  case "$1" in
    true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

csv_to_json() {
  jq -nc --arg raw "$1" '
    $raw
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  '
}

csv_to_nft_set() {
  local raw="$1"
  local family="$2"
  local out=()
  local item trimmed
  IFS=',' read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    trimmed="$(trim "$item")"
    [[ -n "$trimmed" ]] || continue
    if [[ "$family" == "ip6" && "$trimmed" == *:* ]]; then
      out+=("$trimmed")
    elif [[ "$family" == "ip" && "$trimmed" != *:* ]]; then
      out+=("$trimmed")
    fi
  done
  if (( ${#out[@]} == 0 )); then
    return 1
  fi
  local joined="${out[0]}"
  for item in "${out[@]:1}"; do
    joined+=", $item"
  done
  printf '%s' "$joined"
}

contains_public_cidr() {
  local raw="$1"
  local item trimmed
  IFS=',' read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    trimmed="$(trim "$item")"
    case "$trimmed" in
      0.0.0.0/0|::/0|0/0) return 0 ;;
    esac
  done
  return 1
}

load_metadata_ports() {
  local metadata="$1"
  [[ -f "$metadata" ]] || fail "metadata not found: $metadata"
  jq -e '.schema_version == "monarch-os-release-metadata/v1"' "$metadata" >/dev/null \
    || fail "unsupported release metadata schema"

  talos_port="$(jq -r '.network_policy.talos_api.port // 50000' "$metadata")"
  rpc_port="$(jq -r '.network_policy.protocore_rpc.port // 8545' "$metadata")"
  p2p_port="$(jq -r '.network_policy.protocore_p2p.port // 29898' "$metadata")"
}

validate_policy() {
  [[ "$talos_port" =~ ^[0-9]+$ ]] || fail "invalid Talos API port: $talos_port"
  [[ "$rpc_port" =~ ^[0-9]+$ ]] || fail "invalid Protocore RPC port: $rpc_port"
  [[ "$p2p_port" =~ ^[0-9]+$ ]] || fail "invalid Protocore P2P port: $p2p_port"
  [[ -n "$(trim "$TALOS_ALLOWED_CIDRS")" ]] || fail "TALOS_ALLOWED_CIDRS is required"
  [[ -n "$(trim "$RPC_ALLOWED_CIDRS")" ]] || fail "RPC_ALLOWED_CIDRS is required"
  [[ -n "$(trim "$P2P_ALLOWED_CIDRS")" ]] || fail "P2P_ALLOWED_CIDRS is required"

  if contains_public_cidr "$TALOS_ALLOWED_CIDRS" && ! bool_enabled "$ALLOW_PUBLIC_TALOS"; then
    fail "Talos API cannot be public; set ALLOW_PUBLIC_TALOS=true only for an explicit test"
  fi
  if contains_public_cidr "$RPC_ALLOWED_CIDRS" && ! bool_enabled "$ALLOW_PUBLIC_RPC"; then
    fail "Protocore RPC cannot be public; set ALLOW_PUBLIC_RPC=true only for an explicit test"
  fi
}

render_json() {
  jq -n \
    --arg schema "monarch-os-network-firewall/v1" \
    --arg source_metadata "${NETWORK_POLICY_METADATA:-}" \
    --argjson talos_port "$talos_port" \
    --argjson rpc_port "$rpc_port" \
    --argjson p2p_port "$p2p_port" \
    --argjson talos_cidrs "$(csv_to_json "$TALOS_ALLOWED_CIDRS")" \
    --argjson rpc_cidrs "$(csv_to_json "$RPC_ALLOWED_CIDRS")" \
    --argjson p2p_cidrs "$(csv_to_json "$P2P_ALLOWED_CIDRS")" \
    '{
      schema_version: $schema,
      source_metadata: $source_metadata,
      default_input_policy: "drop",
      allow: [
        {surface: "talos_api", proto: "tcp", port: $talos_port, cidrs: $talos_cidrs},
        {surface: "protocore_rpc", proto: "tcp", port: $rpc_port, cidrs: $rpc_cidrs},
        {surface: "protocore_p2p", proto: "tcp", port: $p2p_port, cidrs: $p2p_cidrs}
      ],
      deny: [
        {surface: "ssh", proto: "tcp", port: 22, cidrs: ["0.0.0.0/0", "::/0"]}
      ]
    }'
}

render_nft_rule() {
  local label="$1"
  local port="$2"
  local cidrs="$3"
  local v4_set v6_set

  if v4_set="$(csv_to_nft_set "$cidrs" ip)"; then
    printf '    ip saddr { %s } tcp dport %s accept comment "%s"\n' "$v4_set" "$port" "$label"
  fi
  if v6_set="$(csv_to_nft_set "$cidrs" ip6)"; then
    printf '    ip6 saddr { %s } tcp dport %s accept comment "%s"\n' "$v6_set" "$port" "$label"
  fi
}

render_nftables() {
  cat <<EOF
# monarch-os-network-firewall/v1
# Source metadata: ${NETWORK_POLICY_METADATA:-defaults}
# Apply only at the operator perimeter or a host where nftables ownership is clear.
table inet monarch_node {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
EOF
  render_nft_rule "Monarch Talos API mTLS" "$talos_port" "$TALOS_ALLOWED_CIDRS"
  render_nft_rule "Protocore JSON-RPC" "$rpc_port" "$RPC_ALLOWED_CIDRS"
  render_nft_rule "Protocore P2P" "$p2p_port" "$P2P_ALLOWED_CIDRS"
  cat <<EOF
    tcp dport 22 drop comment "Monarch OS exposes no SSH"
  }
}
EOF
}

write_output() {
  local tmp
  if [[ -z "$NETWORK_FIREWALL_OUTPUT" ]]; then
    cat
    return
  fi
  mkdir -p "$(dirname "$NETWORK_FIREWALL_OUTPUT")"
  tmp="$(mktemp "$NETWORK_FIREWALL_OUTPUT.XXXXXX")"
  cat > "$tmp"
  mv "$tmp" "$NETWORK_FIREWALL_OUTPUT"
  printf '{"ok":true,"path":"%s"}\n' "$NETWORK_FIREWALL_OUTPUT"
}

need jq
if [[ -n "$NETWORK_POLICY_METADATA" ]]; then
  load_metadata_ports "$NETWORK_POLICY_METADATA"
fi
validate_policy

case "$NETWORK_FIREWALL_FORMAT" in
  json) render_json | write_output ;;
  nft|nftables) render_nftables | write_output ;;
  *) fail "unsupported NETWORK_FIREWALL_FORMAT: $NETWORK_FIREWALL_FORMAT" ;;
esac
