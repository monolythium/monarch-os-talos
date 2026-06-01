#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "network firewall policy test failed: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

rules_file="$tmp_dir/hcloud-rules.json"
cloud_plan="$tmp_dir/cloud-firewall-plan.json"

(
  cd "$ROOT_DIR"
  make hcloud-firewall-policy \
    TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
    RPC_ALLOWED_CIDRS=10.20.0.0/16 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
    HCLOUD_FIREWALL_RULES_OUTPUT="$rules_file" >/dev/null
)

jq -e '
  length == 3
  and .[0].direction == "in"
  and .[0].protocol == "tcp"
  and .[0].port == "50000"
  and .[0].source_ips == ["10.10.0.0/16"]
  and .[1].port == "8545"
  and .[1].source_ips == ["10.20.0.0/16"]
  and .[2].port == "29898"
  and .[2].source_ips == ["0.0.0.0/0", "::/0"]
' "$rules_file" >/dev/null || fail "unexpected hcloud firewall rules"

(
  cd "$ROOT_DIR"
  make cloud-firewall-policy \
    TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
    RPC_ALLOWED_CIDRS=10.20.0.0/16 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
    CLOUD_FIREWALL_OUTPUT="$cloud_plan" >/dev/null
)

jq -e '
  .schema_version == "monarch-cloud-firewall-plan/v1"
  and .ok == true
  and .dry_run == true
  and (.plans | keys | sort) == ["aws", "digitalocean", "gcp", "vultr"]
  and .plans.digitalocean.inbound_rules[0].ports == "50000"
  and .plans.digitalocean.inbound_rules[0].sources.addresses == ["10.10.0.0/16"]
  and .plans.aws.ingress_permissions[1].FromPort == 8545
  and .plans.aws.ingress_permissions[1].IpRanges[0].CidrIp == "10.20.0.0/16"
  and .plans.gcp.firewall_rules[2].allowed[0].ports == ["29898"]
  and .plans.gcp.firewall_rules[2].sourceRanges == ["0.0.0.0/0", "::/0"]
  and (.plans.vultr.rules[] | select(.port == "29898" and .subnet == "0.0.0.0" and .subnet_size == 0))
  and (.plans.vultr.rules[] | select(.port == "29898" and .subnet == "::" and .subnet_size == 0))
' "$cloud_plan" >/dev/null || fail "unexpected multi-cloud firewall plan"

(
  cd "$ROOT_DIR"
  make cloud-firewall-policy \
    CLOUD_FIREWALL_PROVIDER=gcp \
    TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
    RPC_ALLOWED_CIDRS=10.20.0.0/16 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
    CLOUD_FIREWALL_OUTPUT="$cloud_plan" >/dev/null
)

jq -e '
  .provider == "gcp"
  and (.plans | keys) == ["gcp"]
  and (.plans.gcp.firewall_rules | length) == 3
' "$cloud_plan" >/dev/null || fail "provider-specific cloud firewall plan changed"

if (
  cd "$ROOT_DIR"
  make hcloud-firewall-policy \
    TALOS_ALLOWED_CIDRS=0.0.0.0/0 \
    RPC_ALLOWED_CIDRS=10.20.0.0/16 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 >/dev/null 2>"$tmp_dir/public-talos.err"
); then
  fail "public Talos API CIDR was accepted"
fi
grep -F "Talos API cannot be public" "$tmp_dir/public-talos.err" >/dev/null \
  || fail "public Talos rejection reason changed"

if (
  cd "$ROOT_DIR"
  make hcloud-firewall-policy \
    TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
    RPC_ALLOWED_CIDRS=0.0.0.0/0 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 >/dev/null 2>"$tmp_dir/public-rpc.err"
); then
  fail "public Protocore RPC CIDR was accepted"
fi
grep -F "Protocore RPC cannot be public" "$tmp_dir/public-rpc.err" >/dev/null \
  || fail "public RPC rejection reason changed"

if (
  cd "$ROOT_DIR"
  make cloud-firewall-policy \
    TALOS_ALLOWED_CIDRS=0.0.0.0/0 \
    RPC_ALLOWED_CIDRS=10.20.0.0/16 \
    P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 >/dev/null 2>"$tmp_dir/cloud-public-talos.err"
); then
  fail "multi-cloud planner accepted public Talos API CIDR"
fi
grep -F "Talos API cannot be public" "$tmp_dir/cloud-public-talos.err" >/dev/null \
  || fail "cloud public Talos rejection reason changed"

printf '{"ok":true,"checked":"network-firewall-policy"}\n'
