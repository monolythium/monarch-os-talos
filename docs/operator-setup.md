# Run a Monolythium operator node

This is the canonical end-to-end guide for standing up a Monolythium **operator** — from a blank machine to a signing seat in a live **cluster** on the public testnet (chain-69420).

Terminology used throughout (and everywhere else in the Monolythium docs):

| Term | Meaning |
|---|---|
| **Operator** | One node, run by one party, with its own ML-DSA-65 consensus key and its own 5,000 LYTH self-bond. |
| **Cluster** | A consensus seat shared by **10 operators** (7 active + 3 standby) signing under a **7-of-10** threshold. |
| **Relay** | A non-consensus node that serves RPC and relays gossip. |

The path is: **verify and boot the signed Monarch OS image (boots into Talos maintenance mode) → provision it in-app with Monarch Desktop (the node syncs as a full node) → opt in to operator-signing enrollment → join or form a cluster.** A freshly flashed node needs **no enrollment bundle and no TPM binding** to sync; operator duty is an explicit upgrade you stage later.

> **Honest caveats before you start**
>
> - **This is a testnet.** The chain may be reset (re-genesis). Monarch OS resolves its genesis dynamically from the public [chain-registry](https://github.com/monolythium/chain-registry) on first boot, so a freshly booted node always picks up the current chain — but an already-synced node does not follow a reset automatically and will need its state re-initialized after one.
> - **There is no public faucet.** The 5,000 LYTH operator bond is dispensed by the Foundation to testnet operators during onboarding. Step 4 of the checklist will show you the funding address to hand over.
> - Testnet LYTH carries no value. Cloud/vTPM substrates are acceptable for testnet; mainnet signing targets bare-metal hardware TPM (see the trust-posture table in [`install.md`](./install.md#0-pick-your-substrate-and-know-the-trust-posture)).

---

## 1. Download and verify the signed image

Releases ship from [**github.com/monolythium/monarch-os-talos/releases**](https://github.com/monolythium/monarch-os-talos/releases). `v0.1.7` is the current signed release: it bakes the signed `protocore v0.2.2-testnet` node binary, boots **enrollment-free**, resolves the live genesis from the chain-registry, and syncs as a full node. Every artifact carries a SHA-256 checksum, a cosign keyless signature (`.sig` + `.pem`), an SPDX SBOM, and a GitHub artifact attestation.

Verify before you flash — every substrate, every time. Requires [`cosign`](https://github.com/sigstore/cosign) and the [`gh`](https://cli.github.com/) CLI:

```bash
TAG=v0.1.7
ISO=monarch-os-talos-v1.13.0-amd64.iso     # bare-metal / USB
RAW=monarch-os-talos-v1.13.0-amd64.raw.xz  # cloud import — verify whichever you'll use

# 1. Download the artifact, its checksum, signature, and signing certificate.
gh release download "$TAG" --repo monolythium/monarch-os-talos \
  --pattern "$ISO" --pattern "$ISO.sha256" \
  --pattern "$ISO.sig" --pattern "$ISO.pem"

# 2. Confirm the content hash.
sha256sum -c "$ISO.sha256"

# 3. The published .pem is base64-encoded — decode it to the PEM certificate.
base64 -d "$ISO.pem" > "$ISO.cert.pem"

# 4. Verify the keyless signature against this repo's release workflow identity.
cosign verify-blob \
  --certificate "$ISO.cert.pem" \
  --signature "$ISO.sig" \
  --certificate-identity "https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/$TAG" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "$ISO"
# => Verified OK
```

The same four steps verify the `.raw.xz` (swap `$ISO` for `$RAW`) and the `monarch-protocore-*.tar` extension tarball. The compressed `.raw.xz` is signed directly — verify it **before** decompressing. The embedded `protocore` binary is itself cosign-signed by [`monolythium/protocore`](https://github.com/monolythium/protocore); the `*.release.json` metadata pins the exact binary digest and source commit the image was built from.

> **ISO version vs protocore version — they are different on purpose.** The ISO here is `v0.1.7`; it bakes `protocore v0.2.2-testnet`. **These two numbers are not meant to match, and you never re-flash the ISO to update protocore.** The ISO is a one-time installer; after the install, all protocore upgrades happen **in place** via Monarch Desktop's "Apply" (which swaps the OS image and keeps your chain data). An operator who installed from an older ISO updates protocore to the latest release without a newer ISO. Full model — the three artifacts and their independent version schemes — is in [`upgrade-and-storage.md` → Updating protocore](./upgrade-and-storage.md#updating-protocore-you-do-not-re-flash-the-iso).

## 2. Flash and boot

Two common substrates — full per-provider detail (DigitalOcean, AWS, GCP, Vultr, firewall policy) lives in [`install.md`](./install.md).

### Bare-metal (old PC / NUC / laptop — the hardware-TPM path)

1. Write the verified ISO to a USB stick (≥1 GB):
   ```bash
   sudo dd if=monarch-os-talos-v1.13.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
2. Enable **TPM 2.0 + UEFI** in the BIOS (Secure Boot too, if available).
3. Boot from USB. The node comes up in **Talos maintenance mode** — it does nothing but wait for a machine config over its API. Monarch Desktop installs it to disk for you in-app (§3); after that it reboots into the immutable OS and syncs. Residential connectivity (NAT, dynamic IP) is supported by design.

### Hetzner Cloud (raw-image path)

Cloud VMs can't mount a custom ISO, so import the verified `.raw.xz` as a snapshot with the official [`hcloud-upload-image`](https://github.com/hetznercloud/hcloud-upload-image):

```bash
hcloud-upload-image upload --image-path monarch-os-talos-v1.13.0-amd64.raw.xz \
  --compression xz --architecture x86 --description "Monarch OS v0.1.7"
```

Then create servers from the resulting snapshot. (Manual equivalent: boot the server into **rescue**, `wget … | xz -d | dd of=/dev/sda`, power off, snapshot.) Review and apply the release-derived firewall policy before attaching the node to production peers — see [`install.md`](./install.md#hetzner-cloud) and [`network-policy.md`](./network-policy.md). The p2p port must stay open to the world; Talos API and RPC should not be.

## 3. Provision in-app with Monarch Desktop

Monarch Desktop is the operator console, and it provisions the node for you — no `talosctl` by hand. Download a signed build for macOS, Windows, or Linux from [**github.com/monolythium/monarch-desktop/releases**](https://github.com/monolythium/monarch-desktop/releases) (v0.0.20 or later). It talks to your node over two channels: the Talos API (mTLS, TCP `50000`, control plane) and `protocore` JSON-RPC (TCP `8545`, data plane) — see [`monarch-desktop-connectivity.md`](./monarch-desktop-connectivity.md).

In-app provisioning flow:

1. **Connect by IP.** Enter the freshly flashed node's address. Desktop detects that it is an unprovisioned node sitting in Talos maintenance mode.
2. **Pick what it is and which disk to install to.** Choose **full node / relay** (the default) or, if you intend to stake later, an operator node — and select the install disk. Desktop generates the full Talos cluster PKI and a full-node machine config, applies it over the maintenance API, and reboots the node.
3. **The node syncs enrollment-free.** Desktop polls `:8545` until the node is up. The `monarch-protocore` extension needs **no enrollment bundle and no TPM binding** to run as a full node — it just resolves the genesis and syncs.

You don't configure a chain. Once provisioned the extension:

- **Resolves the genesis dynamically from the public chain-registry.** The image bakes *who to trust* (the registry location), not *what to run* (no hard-coded genesis): the node fetches the published genesis for `testnet-69420` over in-process TLS, verifies its hash against the registry pin, writes it locally, and loads the registry's published peer multiaddrs. A chain reset is therefore picked up automatically on any fresh boot. If resolution fails (registry unreachable, hash mismatch), the node falls back **loudly** to the baked genesis — which may be stale — unless `PROTOCORE_GENESIS_FALLBACK=fail` is set, in which case it refuses to boot. **Already stuck on an old chain after a re-genesis?** See [`rejoin-after-regenesis.md`](./rejoin-after-regenesis.md) — clear the stale chain data (preserving your operator key) and the node re-resolves the current genesis and re-syncs.
- **Starts `protocore` and syncs chain-69420.** The current testnet runs 2 clusters × 10 operators (7-of-10 threshold each) plus 2 relays. The genesis hash, binary digest, and public RPC/peer endpoints are pinned in [`chain-registry/chains/testnet-69420.toml`](https://github.com/monolythium/chain-registry/blob/master/chains/testnet-69420.toml) — the binding source of truth (don't hardcode them; the chain re-genesises).

Confirm it's real and syncing:

```bash
RPC=http://<your-node-ip>:8545
curl -s $RPC -d '{"jsonrpc":"2.0","id":1,"method":"lyth_runtimeProvenance","params":[]}'
```

Check that `genesisHash` and `chainId` match the chain-registry entry and that the block number advances. A **relay** stops here — it serves RPC and gossip and needs nothing further. To run an **operator**, continue with the opt-in enrollment below.

## 4. Become an operator — the opt-in enrollment path

Syncing a full node (above) is the default and needs nothing more. **Operator-signing enrollment and TPM binding are opt-in:** this section is the explicit upgrade from a plain sync-full node to one that holds a signing seat. Skip it entirely if you only want to run a relay/full node.

Desktop opens the **welcome screen**: a nine-step checklist whose state is **detected from your node and the chain, not remembered** — you can close the app at any point and resume later; done steps stay done because they are re-probed, not ticked. The checklist is the authoritative flow; the items below explain what each step does so you know what you're agreeing to.

1. **Flash and provision the Monarch OS node.** Sections 1–3 of this guide. The checklist links the signed releases page; the step shows done once your in-app-provisioned node is reachable and syncing.

2. **Pair Monarch with your node.** Desktop generated the Talos cluster PKI during in-app provisioning; the checklist confirms the Talos control channel and the RPC handshake on the Install page. Desktop pins the Talos CA fingerprint so later sessions fail closed on identity change.

3. **Create or import your operator key.** Generate a new 24-word PQM-1 mnemonic in-app — it is shown **once**, with a re-entry confirmation before it is stored in the OS keychain — or paste an existing one. This single key is your wallet key, your chat identity, and your registered consensus key. Write it down; there is no recovery path for a lost mnemonic.

4. **Fund the 5,000 LYTH bond.** The step displays the `mono1…` address derived from your key and tracks the live balance against the 5,000 LYTH minimum. On testnet the bond is dispensed by the Foundation — hand this address to your onboarding contact; there is no public faucet.

5. **Register your operator.** Locks the 5,000 LYTH self-bond and writes your node into the on-chain operator registry so clusters can admit you. The Operations drawer previews the exact transaction, checks your balance, and warns on duplicate registration before you authorize.

6. **Set your operator name.** Publishes a human-readable moniker so other operators recognise your node in directories, chat, and the ceremony room.

7. **Publish your chat peers.** Publishes your node's chat bootstrap multiaddrs on-chain so other operators can reach you in the signed operator chat. This is also the meshing precondition for the cluster **ceremony room**.

8. **Join or form a cluster.** The fork in the road — see the next section.

9. **DKG attestation.** After you hold a seat, the cluster key ceremony attestation confirms your seat is live. It is verified per rotate intent.

## 5. Join a cluster — or form one

**Join an existing cluster.** Submit a *request-cluster-join* from the Operations drawer; the cluster's existing members then vote *vote-cluster-admit*, and admission passes at a 2f+1 supermajority of the cluster. Your seat activates after the protocol notice period (measured in epochs).

**Form a new cluster.** Gather ten registered operators in Monarch Desktop's **Ceremony Room**: one operator proposes the 10-seat roster (7 active + 3 standby) and the terms, everyone claims a seat over the signed ceremony channel, the roster freezes, and all ten members sign a single consent digest that binds the exact configuration — then one active member submits the `formCluster` transaction. The full guide, including the cluster charter (per-member reward shares and the delegator share), walk-away semantics, and the offline JSON fallback, is in the Monarch Desktop repo: [`docs/ceremony.md`](https://github.com/monolythium/monarch-desktop/blob/master/docs/ceremony.md).

Either way, once your seat activates your node proposes and signs as part of its cluster's 7-of-10 threshold, and the checklist shows nine of nine.

## Where to go next

- [`install.md`](./install.md) — per-provider install detail and trust posture.
- [`upgrade-and-storage.md`](./upgrade-and-storage.md) — where node state lives and how upgrades work.
- [`operator-runbooks.md`](./operator-runbooks.md) — verify / operate / upgrade / recover / incident runbooks.
- [`monarch-desktop-connectivity.md`](./monarch-desktop-connectivity.md) — the workstation ↔ node provisioning flow.
- [`disaster-recovery.md`](./disaster-recovery.md) — backup and restore contracts.
