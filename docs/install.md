# Installing a Monolythium node (Monarch OS)

Monarch OS is an immutable, signed Talos-based OS that boots straight into a Monolythium `protocore` node. This guide covers **home / bare-metal** (an old PC, NUC, or laptop) and the **top cloud providers**. Whatever the substrate, the install is: *verify the signed image → write it to a disk → boot → the node syncs chain-69420*.

> **Artifacts** (on each [release](https://github.com/monolythium/monarch-os-talos/releases)):
> - `monarch-os-talos-<ver>-amd64.iso` — bootable installer (bare-metal / USB).
> - `monarch-os-talos-<ver>-amd64.raw.xz` — compressed raw disk image (cloud import).
> - each with `.sha256`, a cosign `.sig` + `.pem`, and an SPDX SBOM.

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
TAG=<release-tag>            # e.g. v0.0.5-preview
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
3. **Boot from USB.** Talos installs to the internal disk and reboots into the immutable OS; blockchain state persists at `/var/lib/protocore`. See [`docs/upgrade-and-storage.md`](./upgrade-and-storage.md) for the disk/persistence/upgrade model.
4. The node comes up, stages the baked testnet genesis, and starts syncing chain-69420. Verify with §4.

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
Check that `genesisHash` and `chainId` match the canonical [`chain-registry/chains/testnet-69420.toml`](https://github.com/monolythium/chain-registry/blob/master/chains/testnet-69420.toml), and that `eth_blockNumber` advances over time (the node is catching up to the live tip). Peers come from the chain-registry's published libp2p multiaddrs.

---

## 5. Become an operator

Running a synced node is step one. To **register as an operator** (BLS proof-of-possession + self-bond) and participate in a cluster, use **Monarch desktop** (Operator → register) or the `protocore registry register` CLI. Reminder on trust posture (§0): for **mainnet signing** you want a **bare-metal TPM-2.0** box; cloud/vTPM is fine for the testnet release candidate.

Operator enrollment / cluster-onboarding runbooks are published at [docs.monolythium.com](https://docs.monolythium.com).
