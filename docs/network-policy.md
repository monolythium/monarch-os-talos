# Monarch OS Network Policy

Monarch OS uses Talos API mTLS for control and Protocore for chain data. SSH is not part of the production control plane.

## Default Listeners

| Surface | Default | Purpose | Exposure |
| --- | --- | --- | --- |
| Talos API | TCP `50000` | Operator control plane, mTLS authenticated by `talosconfig`. | Operator network only. |
| Protocore JSON-RPC | TCP `8545` (`PROTOCORE_RPC_LISTEN=0.0.0.0:8545`) | Chain data plane for Desktop and operator tooling. | Operator/data-plane network; front with firewall policy. |
| Protocore P2P | TCP `29898` (`PROTOCORE_P2P_LISTEN=/ip4/0.0.0.0/tcp/29898`) | Chain peer connectivity. | Public or peer allow-list, depending on operator role. |

## Prohibited Surfaces

Release artifacts must not add:

- SSH server/client tooling as a production control path.
- Interactive shells in the `monarch-protocore` extension payload.
- Package-manager executables or package-manager state directories.
- Writable mounts outside `/var/lib/protocore` from the `protocore` service.

## Release Enforcement

`make verify-artifacts` supports `REQUIRE_NETWORK_POLICY=true` and `REQUIRE_SUBSTRATE_PROOF=true`. The release workflow enables both. The verifier reads `*.release.json`, opens the shipped `monarch-protocore-*.tar`, and fails if the service config does not pin the expected RPC/P2P listeners or if the extension payload adds a prohibited surface.

## Firewall Policy Rendering

Operators can render a perimeter firewall policy from release metadata and the
CIDRs they intend to expose:

```bash
make network-firewall-policy \
  NETWORK_POLICY_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  NETWORK_FIREWALL_OUTPUT=_out/monarch-node.nft
```

The renderer supports `NETWORK_FIREWALL_FORMAT=nftables` and
`NETWORK_FIREWALL_FORMAT=json`. It fails closed when Talos API or Protocore RPC
is opened to `0.0.0.0/0` or `::/0`; those public-control-plane overrides require
`ALLOW_PUBLIC_TALOS=true` or `ALLOW_PUBLIC_RPC=true` and should only be used for
explicit test fixtures.

## Hetzner Cloud Firewall Application

For Hetzner Cloud, the same release policy can be converted into `hcloud`
firewall rules. The target is dry-run by default and writes the exact rule file
that would be sent to Hetzner:

```bash
make hcloud-firewall-policy \
  NETWORK_POLICY_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  HCLOUD_FIREWALL_NAME=monarch-node \
  HCLOUD_FIREWALL_RULES_OUTPUT=_out/monarch-hcloud-firewall-rules.json
```

After reviewing the generated rules, apply them by setting
`HCLOUD_FIREWALL_APPLY=true` and targeting servers by name/id or a server label
selector:

```bash
make hcloud-firewall-policy \
  NETWORK_POLICY_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  HCLOUD_FIREWALL_NAME=monarch-node \
  HCLOUD_FIREWALL_APPLY=true \
  HCLOUD_FIREWALL_SERVERS=monarch-a,monarch-b
```

The apply target creates the firewall when missing, replaces its rules when it
already exists, and attaches it to each selected server. It intentionally refuses
public Talos API or Protocore RPC CIDRs through the same checks as the local
renderer.

## Multi-Cloud Firewall Plans

For DigitalOcean, AWS, GCP, and Vultr, render provider-specific dry-run plans
from the same release policy:

```bash
make cloud-firewall-policy \
  NETWORK_POLICY_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  CLOUD_FIREWALL_OUTPUT=_out/monarch-cloud-firewall-plan.json
```

The plan schema is `monarch-cloud-firewall-plan/v1`. It emits DigitalOcean
firewall API payloads, AWS EC2 security-group ingress permissions, GCP
firewall-rule objects, and Vultr firewall rules. Use
`CLOUD_FIREWALL_PROVIDER=digitalocean|aws|gcp|vultr` to render only one provider.
These non-Hetzner plans are intentionally dry-run artifacts: review the generated
provider payloads before applying them with provider credentials. The same
fail-closed public Talos/RPC CIDR checks run before any provider plan is written.
