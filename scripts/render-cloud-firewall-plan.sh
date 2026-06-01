#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLOUD_FIREWALL_PROVIDER="${CLOUD_FIREWALL_PROVIDER:-all}"
CLOUD_FIREWALL_NAME="${CLOUD_FIREWALL_NAME:-monarch-node}"
CLOUD_FIREWALL_OUTPUT="${CLOUD_FIREWALL_OUTPUT:-}"
DIGITALOCEAN_DROPLET_IDS="${DIGITALOCEAN_DROPLET_IDS:-}"
DIGITALOCEAN_TAGS="${DIGITALOCEAN_TAGS:-monarch-os}"
AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID:-}"
AWS_SECURITY_GROUP_NAME="${AWS_SECURITY_GROUP_NAME:-monarch-node}"
AWS_VPC_ID="${AWS_VPC_ID:-}"
GCP_NETWORK="${GCP_NETWORK:-default}"
GCP_TARGET_TAGS="${GCP_TARGET_TAGS:-monarch-os}"
VULTR_FIREWALL_GROUP_ID="${VULTR_FIREWALL_GROUP_ID:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "cloud-firewall: $*" >&2
  exit 1
}

csv_json() {
  jq -nc --arg raw "$1" '
    $raw
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  '
}

write_output() {
  local tmp
  if [[ -z "$CLOUD_FIREWALL_OUTPUT" ]]; then
    cat
    return
  fi
  mkdir -p "$(dirname "$CLOUD_FIREWALL_OUTPUT")"
  tmp="$(mktemp "$CLOUD_FIREWALL_OUTPUT.XXXXXX")"
  cat > "$tmp"
  mv "$tmp" "$CLOUD_FIREWALL_OUTPUT"
  printf '{"ok":true,"path":"%s"}\n' "$CLOUD_FIREWALL_OUTPUT"
}

need date
need jq

case "$CLOUD_FIREWALL_PROVIDER" in
  all|digitalocean|aws|gcp|vultr) ;;
  *) fail "CLOUD_FIREWALL_PROVIDER must be all, digitalocean, aws, gcp, or vultr" ;;
esac
[[ -n "$CLOUD_FIREWALL_NAME" ]] || fail "CLOUD_FIREWALL_NAME is required"

policy_json="$(
  env NETWORK_FIREWALL_FORMAT=json NETWORK_FIREWALL_OUTPUT="" \
    "$ROOT_DIR/scripts/render-network-firewall.sh"
)"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg generated_at "$generated_at" \
  --arg provider "$CLOUD_FIREWALL_PROVIDER" \
  --arg name "$CLOUD_FIREWALL_NAME" \
  --arg aws_group_id "$AWS_SECURITY_GROUP_ID" \
  --arg aws_group_name "$AWS_SECURITY_GROUP_NAME" \
  --arg aws_vpc_id "$AWS_VPC_ID" \
  --arg gcp_network "$GCP_NETWORK" \
  --arg vultr_group_id "$VULTR_FIREWALL_GROUP_ID" \
  --argjson policy "$policy_json" \
  --argjson do_droplet_ids "$(csv_json "$DIGITALOCEAN_DROPLET_IDS")" \
  --argjson do_tags "$(csv_json "$DIGITALOCEAN_TAGS")" \
  --argjson gcp_tags "$(csv_json "$GCP_TARGET_TAGS")" \
  '
    def want($p): $provider == "all" or $provider == $p;
    def provider_name($surface):
      if $surface == "talos_api" then "talos-api"
      elif $surface == "protocore_rpc" then "protocore-rpc"
      elif $surface == "protocore_p2p" then "protocore-p2p"
      else $surface end;
    def v4cidrs($cidrs): $cidrs | map(select(contains(":") | not));
    def v6cidrs($cidrs): $cidrs | map(select(contains(":")));
    def cidr_ip($cidr): $cidr | split("/")[0];
    def cidr_size($cidr): ($cidr | split("/")[1] // (if contains(":") then "128" else "32" end) | tonumber);
    def compact_nulls:
      with_entries(select(.value != null and .value != "" and .value != []));

    def digitalocean:
      {
        provider: "digitalocean",
        dry_run: true,
        firewall_name: $name,
        target: {
          droplet_ids: $do_droplet_ids,
          tags: $do_tags
        },
        inbound_rules: [
          $policy.allow[]
          | {
              protocol: .proto,
              ports: (.port | tostring),
              sources: {addresses: .cidrs},
              description: provider_name(.surface)
            }
        ],
        api_payload: {
          name: $name,
          droplet_ids: $do_droplet_ids,
          tags: $do_tags,
          inbound_rules: [
            $policy.allow[]
            | {
                protocol: .proto,
                ports: (.port | tostring),
                sources: {addresses: .cidrs}
              }
          ],
          outbound_rules: [
            {
              protocol: "tcp",
              ports: "1-65535",
              destinations: {addresses: ["0.0.0.0/0", "::/0"]}
            },
            {
              protocol: "udp",
              ports: "1-65535",
              destinations: {addresses: ["0.0.0.0/0", "::/0"]}
            },
            {
              protocol: "icmp",
              destinations: {addresses: ["0.0.0.0/0", "::/0"]}
            }
          ]
        }
      };

    def aws:
      {
        provider: "aws",
        dry_run: true,
        security_group: ({
          group_id: $aws_group_id,
          group_name: $aws_group_name,
          vpc_id: $aws_vpc_id
        } | compact_nulls),
        ingress_permissions: [
          $policy.allow[] as $rule
          | {
              IpProtocol: $rule.proto,
              FromPort: $rule.port,
              ToPort: $rule.port,
              IpRanges: (v4cidrs($rule.cidrs) | map({CidrIp: ., Description: provider_name($rule.surface)})),
              Ipv6Ranges: (v6cidrs($rule.cidrs) | map({CidrIpv6: ., Description: provider_name($rule.surface)}))
            }
        ],
        api_payload: {
          GroupId: (if $aws_group_id == "" then null else $aws_group_id end),
          GroupName: (if $aws_group_id == "" then $aws_group_name else null end),
          IpPermissions: [
            $policy.allow[] as $rule
            | {
                IpProtocol: $rule.proto,
                FromPort: $rule.port,
                ToPort: $rule.port,
                IpRanges: (v4cidrs($rule.cidrs) | map({CidrIp: ., Description: provider_name($rule.surface)})),
                Ipv6Ranges: (v6cidrs($rule.cidrs) | map({CidrIpv6: ., Description: provider_name($rule.surface)}))
              }
          ]
        } | compact_nulls
      };

    def gcp:
      {
        provider: "gcp",
        dry_run: true,
        network: $gcp_network,
        target_tags: $gcp_tags,
        firewall_rules: [
          $policy.allow[]
          | {
              name: ($name + "-" + provider_name(.surface)),
              network: $gcp_network,
              direction: "INGRESS",
              action: "ALLOW",
              priority: 1000,
              sourceRanges: .cidrs,
              targetTags: $gcp_tags,
              allowed: [{IPProtocol: .proto, ports: [(.port | tostring)]}]
            }
        ]
      };

    def vultr:
      {
        provider: "vultr",
        dry_run: true,
        firewall_group_id: (if $vultr_group_id == "" then null else $vultr_group_id end),
        firewall_group_description: $name,
        rules: [
          $policy.allow[] as $rule
          | $rule.cidrs[]
          | {
              ip_type: (if contains(":") then "v6" else "v4" end),
              protocol: $rule.proto,
              port: ($rule.port | tostring),
              subnet: cidr_ip(.),
              subnet_size: cidr_size(.),
              notes: provider_name($rule.surface)
            }
        ]
      };

    {
      schema_version: "monarch-cloud-firewall-plan/v1",
      generated_at: $generated_at,
      ok: true,
      dry_run: true,
      provider: $provider,
      source_policy: $policy,
      plans: (
        {}
        + (if want("digitalocean") then {digitalocean: digitalocean} else {} end)
        + (if want("aws") then {aws: aws} else {} end)
        + (if want("gcp") then {gcp: gcp} else {} end)
        + (if want("vultr") then {vultr: vultr} else {} end)
      ),
      apply_note: "Review the provider plan before applying with provider CLI/API credentials. Hetzner has a guarded apply target; non-Hetzner plans are intentionally dry-run artifacts."
    }
  ' | write_output
