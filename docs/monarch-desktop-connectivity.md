# Monarch Desktop Connectivity

Monarch OS is a Talos-based node image. It does not expose SSH and it does not run the Monarch Desktop GUI locally. Monarch Desktop runs on the operator workstation and connects to the node over two separate channels:

1. Talos API on TCP `50000`, authenticated with Talos client certificates from `talosconfig`.
2. Protocore JSON-RPC on TCP `8545`, exposed by the `protocore` extension service after operator secrets are provisioned.

## Trust Model

The Talos API is the control plane. Monarch Desktop must use the generated `talosconfig` client certificate/key pair and CA bundle; unauthenticated discovery is not part of the production path.

The chain RPC endpoint is the data plane. Monarch Desktop can read status, blocks, balances, cluster state, and logs once the `protocore` service is running. Transaction signing remains wallet/keychain-bound on the operator workstation.

The OS image intentionally ships without:

- operator keystore passphrases
- operator key material
- default SSH access
- a default writable node identity

## Provisioning Flow

1. Build or download a signed Monarch OS artifact.

   ```bash
   make build
   ```

2. Boot the ISO or raw image on the target machine.

3. Generate a Talos machine config for the node.

   ```bash
   talosctl gen config monarch-node https://<node-ip>:6443 \
     --install-disk /dev/sda \
     --additional-sans <node-ip> \
     --output ./cluster-config
   ```

4. Add the `protocore` extension service config to the Talos machine config. Start from:

   ```bash
   examples/protocore-extension-service-config.yaml
   ```

   Replace the placeholder passphrase and any network-specific values through the private provisioning flow. Do not commit real secrets.

5. Apply the machine config.

   ```bash
   talosctl apply-config \
     --nodes <node-ip> \
     --endpoints <node-ip> \
     --insecure \
     --file ./cluster-config/controlplane.yaml
   ```

6. Confirm the Monarch extension is present.

   ```bash
   talosctl --nodes <node-ip> --endpoints <node-ip> get extensions
   ```

7. Confirm the service is waiting for config or running.

   ```bash
   talosctl --nodes <node-ip> --endpoints <node-ip> service ext-protocore
   talosctl --nodes <node-ip> --endpoints <node-ip> logs ext-protocore
   ```

8. Point Monarch Desktop at:

   - the node Talos endpoint: `https://<node-ip>:50000`
   - the generated `talosconfig`
   - the Protocore RPC endpoint: `http://<node-ip>:8545` or the private tunnel/WireGuard address used by the operator network

## Persistence and Upgrades

The ISO is an installer, not the running system: step 2 boots it, and step 5 installs Monarch OS onto the node's internal disk (`--install-disk`), after which the node runs from disk and the ISO can be removed. The immutable OS image and the node's writable data are kept on separate partitions — the entire blockchain database, configuration, and keys live under `/var/lib/protocore` on the persistent `/var` partition, never inside the OS image. Upgrades are applied with `talosctl upgrade` against a new signed image (not by re-flashing the ISO): the OS partitions are replaced while the data partition is preserved, so node state carries across upgrades at the same fixed path, and `talosctl rollback` reverts a bad upgrade without touching the data.

See [Upgrades and persistent storage](./upgrade-and-storage.md) for the full lifecycle (install → run → upgrade → rollback → recovery), the disk-layout table, the TPM-sealed-key consideration, and a glossary of terms.

## Current Implementation Status

Implemented in this repository:

- local ISO build
- local preinstalled raw image build
- `monarch-protocore` Talos system extension
- `protocore` service entrypoint
- baked testnet genesis staging
- service gating on `ExtensionServiceConfig`

Still required before a production operator release:

- signed artifact publishing
- provenance/SBOM release workflow
- bundled/native Talos API client hardening in Monarch Desktop
- secret injection through the final provisioning flow
- production network policy for RPC/P2P exposure
- replacement of testnet genesis with release-channel genesis artifacts

See [Final product readiness](./final-product-readiness.md) for the full gap list and build plan.
