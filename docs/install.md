# Installing a Monolythium node (Monarch OS)

Monarch OS is an immutable, signed Talos-based OS that boots straight into a Monolythium `protocore` node. This guide covers **home / bare-metal** (an old PC, NUC, or laptop) and the **top cloud providers**. Whatever the substrate, the install is: *verify the signed image → write it to a disk → boot into Talos maintenance mode → provision it in-app with Monarch Desktop → the node syncs chain-69420 as a full node*. A freshly flashed node syncs **enrollment-free** — no enrollment bundle or TPM binding is required to run a full node.

> **Artifacts** (on each [release](https://github.com/monolythium/monarch-os-talos/releases)):
> - `monarch-os-talos-<ver>-amd64.iso` — bootable installer (bare-metal / USB).
> - `monarch-os-talos-<ver>-amd64.raw.xz` — compressed raw disk image (cloud import).
> - each with `.sha256`, a cosign `.sig` + `.pem`, and an SPDX SBOM.

> **The ISO is a one-time installer — you do not re-flash it to update protocore.** The
> ISO version (`vX.Y`) and the protocore version (`vA.B-testnet`) are independent and are
> not meant to match. You flash/boot the ISO **once** to install the node onto its disk;
> after that, **all protocore upgrades happen in place** — Monarch Desktop's "Apply" swaps
> the OS image and preserves your chain data at `/var/lib/protocore`. A node installed from
> an older ISO updates to the newest protocore without a newer ISO. The full three-artifact
> model is in [`upgrade-and-storage.md` → Updating protocore](./upgrade-and-storage.md#updating-protocore-you-do-not-re-flash-the-iso).

---

## 0. Pick your substrate (and know the trust posture)

| Substrate | Boot of trust | Use it for |
|-----------|---------------|------------|
| **Home bare-metal with TPM 2.0** (old PC / NUC / laptop) | **Hardware TPM measured boot + dm-verity + signed image** — full sovereignty | **Preferred** for cluster *signing* operators; the only substrate with a hardware root of trust. Residential / NAT / dynamic IP is fine (the cluster network anchor is the stable endpoint, not your home box). |
| **Cloud VM** (Hetzner / DO / AWS / GCP / Vultr …) | Signed image + dm-verity, but **vTPM** and the **hypervisor is in your trust boundary** | **Fine for testnet** and for running full/relay nodes. For **mainnet signing**, migrate to bare-metal hardware-TPM. |

Both run the same signed image; the difference is the boot-time root of trust. Cloud/vTPM is on-policy for the testnet release candidate — just don't expect hardware-attested sovereignty from a shared VM.

---

## 1. Download + verify (always — every substrate)

Requires [`cosign`](https://github.com/sigstore/cosign) and [`gh`](https://cli.github.com/).

```bash
TAG=<release-tag>            # e.g. v0.1.3
ARCH=amd64
BASE=monarch-os-talos-v1.13.0-$ARCH

# Bare-metal uses the .iso; cloud uses the .raw.xz — verify whichever you'll install.
for ART in "$BASE.iso" "$BASE.raw.xz"; do
  gh release download "$TAG" --repo monolythium/monarch-os-talos \
    --pattern "$ART" --pattern "$ART.sha256" --pattern "$ART.sig" --pattern "$ART.pem" || continue
  sha256sum -c "$ART.sha256"
  cosign verify-blob \
    --signature "$ART.sig" --certificate "$ART.pem" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp 'https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/.*' \
    "$ART"
done
```

Both checks must pass before you write the image anywhere. (The compressed `.raw.xz` is signed directly — verify it *before* decompressing.)

---

## 2. Home / bare-metal — an old machine you have lying around

Ideal target: any 64-bit PC / NUC / mini-PC / laptop from ~2016+ (most have firmware TPM 2.0 — Intel PTT or AMD fTPM — enable it in BIOS). ~4 GB RAM minimum, an SSD/NVMe, wired ethernet preferred.

1. **Write the ISO to a USB stick** (≥1 GB):
   ```bash
   sudo dd if=monarch-os-talos-v1.13.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
   (or use balenaEtcher / Rufus.)
2. **Enable TPM 2.0 + UEFI** in the machine's BIOS (and Secure Boot if available — this is what gives the home path its hardware root of trust).
3. **Boot from USB.** The node comes up in **Talos maintenance mode** — it waits for a machine config over its API and installs nothing on its own.
4. **Provision it in-app with Monarch Desktop** (recommended — see §5): connect by IP, let Desktop detect the unprovisioned node, pick the install disk, and Desktop generates the Talos PKI + full-node config, applies it, and reboots. The node then installs to the internal disk, comes up enrollment-free, resolves the genesis from the chain-registry, and syncs chain-69420; blockchain state persists at `/var/lib/protocore`. See [`docs/upgrade-and-storage.md`](./upgrade-and-storage.md) for the disk/persistence/upgrade model. Verify with §4.

This is the substrate the protocol is designed around for signing operators — residential connectivity (NAT, dynamic IP) is supported by design, so a home box behind a normal router is fine.

---

## 3. Cloud providers — install from the signed `raw.xz`

Monarch OS **is Talos + the `monarch-protocore` extension**, so cloud import is identical to [Talos's per-cloud guides](https://www.talos.dev/latest/talos-guides/install/cloud-platforms/) — just substitute our **signed `monarch-os-talos-<ver>-amd64.raw.xz`** for the stock Talos image. Always run §1 verification on the `.raw.xz` first. (Exact CLI flags drift — cross-check the provider's current docs.)

### Hetzner Cloud
Cloud VMs can't mount a custom ISO, so use the raw → snapshot flow. Easiest is the official [`hcloud-upload-image`](https://github.com/hetznercloud/hcloud-upload-image) (it boots rescue, decompresses, `dd`s, and snapshots):
```bash
hcloud-upload-image upload --image-path monarch-os-talos-v1.13.0-amd64.raw.xz \
  --compression xz --architecture x86 --description "Monarch OS <ver>"
```
Then create servers from the resulting snapshot/image. (Manual equivalent: boot a server into **rescue**, `wget … | xz -d | dd of=/dev/sda`, power off, take a snapshot.)

Before attaching the node to production peers, apply the release-derived Hetzner
firewall in dry-run mode, review the generated rules, then set
`HCLOUD_FIREWALL_APPLY=true`:

```bash
make hcloud-firewall-policy \
  NETWORK_POLICY_METADATA=./monarch-os-talos-v1.13.0-amd64.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  HCLOUD_FIREWALL_RULES_OUTPUT=./monarch-hcloud-firewall-rules.json
```

### DigitalOcean
DO accepts compressed raw images directly. Images → **Custom Images** → upload by URL (paste the release `.raw.xz` URL), or:
```bash
doctl compute image create "Monarch OS <ver>" \
  --image-url https://github.com/monolythium/monarch-os-talos/releases/download/<TAG>/monarch-os-talos-v1.13.0-amd64.raw.xz \
  --region <slug>
```
Then create droplets from the custom image. (Cleanest of the five — native custom-image support.)

### AWS (EC2)
Decompress → upload to S3 → import as a snapshot → register an AMI:
```bash
xz -d monarch-os-talos-v1.13.0-amd64.raw.xz          # → .raw
aws s3 cp monarch-os-talos-v1.13.0-amd64.raw s3://<bucket>/
aws ec2 import-snapshot --disk-container \
  "Format=RAW,UserBucket={S3Bucket=<bucket>,S3Key=monarch-os-talos-v1.13.0-amd64.raw}"
# wait for completion → note SnapshotId, then:
aws ec2 register-image --name "monarch-os-<ver>" --architecture x86_64 \
  --root-device-name /dev/xvda --ena-support --virtualization-type hvm \
  --boot-mode uefi \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=<snap-id>}"
```
Requires the `vmimport` IAM role. Launch instances from the AMI.

### Google Cloud (GCE)
GCE wants the raw named `disk.raw` inside a gzipped tarball:
```bash
xz -d monarch-os-talos-v1.13.0-amd64.raw.xz && mv monarch-os-talos-v1.13.0-amd64.raw disk.raw
tar --format=oldgnu -czf monarch-os.tar.gz disk.raw
gsutil cp monarch-os.tar.gz gs://<bucket>/
gcloud compute images create monarch-os-<ver> \
  --source-uri gs://<bucket>/monarch-os.tar.gz --guest-os-features UEFI_COMPATIBLE
```
Create instances from the image.

### Vultr
Vultr can upload a **custom ISO by URL** and boot it directly (no snapshot dance) — point it at the release `.iso` URL under Products → ISO → Upload ISO, then deploy an instance with that ISO. (Vultr also supports custom raw images/snapshots by URL if you prefer the `.raw.xz`.)

### Others
- **Linode / Akamai** — Images → upload a gzipped raw (`.raw.gz`, ≤6 GB), then deploy from the image.
- **Azure** — needs a fixed-size **VHD** (convert: `qemu-img convert -f raw -O vpc -o subformat=fixed,force_size disk.raw disk.vhd`) → upload as a managed disk → create the VM. Heaviest path.

---

## 4. Confirm the node is real and syncing

```bash
RPC=http://<your-node-ip>:8545
curl -s $RPC -d '{"jsonrpc":"2.0","id":1,"method":"lyth_runtimeProvenance","params":[]}'
```
Check that `genesisHash` and `chainId` match the canonical [`chain-registry/chains/testnet-69420.toml`](https://github.com/monolythium/chain-registry/blob/master/chains/testnet-69420.toml) (the binding source of truth — don't hardcode the genesis, the chain re-genesises), and that `eth_blockNumber` advances over time (the node is catching up to the live tip). Peers come from the chain-registry's published libp2p multiaddrs.

---

## 5. Provision with Monarch Desktop (the in-app flow)

A freshly flashed node boots into **Talos maintenance mode** and does nothing until it is provisioned. The recommended path is **in-app provisioning** with [**Monarch Desktop**](https://github.com/monolythium/monarch-desktop/releases) (v0.0.20 or later) — operators no longer run `talosctl` by hand:

1. **Connect by IP.** Enter the node's address; Desktop auto-detects that it is an unprovisioned node in maintenance mode.
2. **Choose what it is.** Pick a **full node / relay** (the default — no enrollment, no TPM) or, if you intend to stake, an operator node, then pick the install disk.
3. **Apply.** Desktop generates the full Talos cluster PKI and a full-node machine config, applies it over the maintenance API, and reboots the node.
4. **Sync.** Desktop polls `:8545` until the node is up; it resolves the genesis from the chain-registry and syncs chain-69420 enrollment-free.

> **Manual fallback.** If you can't use Desktop, you can provision by hand with `talosctl` (`gen config` → add the `monarch-protocore` extension service config → `apply-config`); see [`monarch-desktop-connectivity.md`](./monarch-desktop-connectivity.md) and [`operator-runbooks.md`](./operator-runbooks.md). The in-app flow is preferred and is what these docs target.

---

## 6. Become an operator (opt-in)

Running a synced full node is the default and is complete on its own. **Operator-signing enrollment and TPM binding are opt-in** — they are the explicit upgrade from a plain sync-full node to a node that holds a signing seat. An operator stages the enrollment bundle, registers and bonds, and joins or forms a cluster; the extension fails closed if the release digest, TPM, or operator-key evidence the bundle pins is missing. Reminder on trust posture (§0): for **mainnet signing** you want a **bare-metal TPM-2.0** box; cloud/vTPM is fine for the testnet release candidate.

The end-to-end operator path (key, bond, register, cluster) is the welcome checklist in [`operator-setup.md`](./operator-setup.md#4-become-an-operator--the-opt-in-enrollment-path); the enrollment-bundle machinery and cluster-onboarding workflow are in [`operator-runbooks.md`](./operator-runbooks.md). Production operator docs are also published at [docs.monolythium.com](https://docs.monolythium.com).
