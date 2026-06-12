# Upgrades and persistent storage

How a Monarch OS node is installed, where it keeps the blockchain data, and what
happens to that data when a new OS image is released. This is a common question
because Monarch OS ships as an **ISO** (a single bootable disk image), and it is
not obvious from "here is an ISO" how a long-running node with gigabytes of chain
history actually upgrades without losing state.

Short version: **the ISO is only an installer.** The node installs itself onto an
internal disk, runs from that disk, keeps its data on a separate partition that the
OS never overwrites, and upgrades by swapping the OS image while leaving that data
partition in place. None of this requires manual disk management.

Monarch OS is built on [Talos Linux](https://www.talos.dev), an immutable,
API-managed operating system, so most of the behaviour below is Talos behaviour
that Monarch OS inherits. Where Monarch OS adds something specific, it is called out.

---

## The two layers

A running node is made of two clearly separated layers:

1. **The OS image — immutable and read-only.** "Immutable" means the operating
   system files cannot be changed after the image is built: there is no package
   manager, no shell, and no way to edit system files in place. The root filesystem
   is verified on every boot with **dm-verity** (a kernel feature that
   cryptographically checks the disk blocks against a signed hash tree, so any
   tampering is detected before the system runs). Configured QEMU smoke records
   read-only root evidence and, when the booted image exposes it, the active
   dm-verity root hash. Channels that require active dm-verity also require the
   runtime root hash to match the hash pinned in release metadata. You replace
   this layer wholesale when you upgrade; you never patch it.

2. **The data partition — writable and persistent.** Everything that must survive a
   reboot or an upgrade — the node's configuration, keys, and the entire blockchain
   history — lives on a separate writable partition, **not** inside the OS image.

Keeping these apart is the whole trick: you can throw away and replace layer 1 at
will, because layer 2 is never touched.

---

## Lifecycle

### 1. Install (ISO → internal disk)

You boot a machine from the ISO (burned to a USB stick, mounted via IPMI/BMC virtual
media, or booted over the network). The ISO comes up in **maintenance mode** — a
minimal state where the node does nothing except wait for a configuration over its
API.

You then send the node a **machine config** (a YAML document that declares how the
node should be set up, including which disk to install to). The recommended way is
**in-app with Monarch Desktop** — connect by IP, pick the install disk, and Desktop
generates the Talos PKI + full-node config, applies it, and reboots the node (see
[`monarch-desktop-connectivity.md`](./monarch-desktop-connectivity.md)). The manual
equivalent declares the install disk directly:

```bash
talosctl gen config monarch-node https://<node-ip>:6443 --install-disk /dev/sda
talosctl apply-config --insecure --nodes <node-ip> --file controlplane.yaml
```

(`talosctl` is the command-line client for talking to a Talos/Monarch OS node over
its API — there is no SSH.) On receiving the config, the node **installs the OS onto
the internal disk** (`/dev/sda` here) and reboots, then boots enrollment-free and
syncs as a full node.

After that first install, **the ISO is no longer needed** — you can remove the USB
stick or detach the virtual media. The node boots from its internal disk from then on.

> A node can technically run disk-less (booted entirely into RAM over the network),
> but a node that stores chain history should install to a disk so the data
> persists.

### 2. Run (from the internal disk)

The node now runs the installed OS from the internal disk. The blockchain node
process (`protocore`) runs as a **Talos system extension** — a sealed add-on that
ships inside the signed OS image and is supervised by the OS. Monarch OS bundles the
`monarch-protocore` extension, which runs the node binary and stores all of its state
under **`/var/lib/protocore`** (see [extensions/protocore](../extensions/protocore/README.md)).

### 3. Upgrade (new image, same data)

Upgrades **do not** mean re-flashing the ISO. When a new signed OS image is released,
the operator first verifies the target artifact and compares the current and target
release metadata:

```bash
make check-channel-promotion \
  PROMOTION_METADATA=./target.release.json

make check-upgrade-readiness \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json
```

Those checks are deliberately conservative. The channel-promotion check applies
`channel-policy.json`, enforces the verifier flags required for the release channel,
and currently blocks mainnet promotion by policy. The upgrade-readiness check then
fails if the target changes release channel when same-channel upgrades are required,
changes chain profile or chain id, changes genesis hash without
`ALLOW_GENESIS_CHANGE=true`, lacks a concrete `protocore` version or Desktop
compatibility range, drops the no-SSH/no-package-manager substrate policy, or lacks
the raw image / `monarch-protocore` extension artifact in release metadata.

After the preflight passes, the operator upgrades through the Talos API:

```bash
make upgrade-plan \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json \
  UPGRADE_IMAGE_REF=ghcr.io/monolythium/monarch-os:<release-tag-or-digest> \
  UPGRADE_PLAN_OUTPUT=./upgrade-plan.json
```

The plan is a local dry-run artifact: it binds the current and target metadata
hashes, target raw/extension artifacts, Desktop upgrade payload, Talos Upgrade
request (`preserve=true`, `force=false`), rollback path, and any required
disaster-recovery manifest. It refuses mutable `latest` image refs and refuses
migration/unsupported-rollback targets unless the operator supplies a validated
DR manifest for that staged event.

For multi-node rollouts, render a fleet plan from an explicit fleet manifest:

```bash
make fleet-upgrade-plan \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json \
  FLEET_MANIFEST=./fleet-upgrade.json \
  UPGRADE_IMAGE_REF=ghcr.io/monolythium/monarch-os:<release-tag-or-digest> \
  FLEET_PLAN_OUTPUT=./fleet-upgrade-plan.json
```

The fleet manifest schema is `monarch-talos-fleet-upgrade-manifest/v1`. The
renderer reuses the same release-readiness checks as the single-node plan,
splits nodes into canary/rolling waves, writes per-node Talos/Desktop payloads,
and rejects any wave that exceeds `fleet.max_unavailable`. For operator-signing
nodes it also checks active signing capacity: by default, no wave may take enough
active operators down to drop below `fleet.operator_signing_quorum` (normally 7).
If a 7-active cluster has no spare active signing capacity, promote/rotate
through the key-share lifecycle first rather than rolling an active signer below
quorum.

```bash
talosctl upgrade --nodes <node-ip> --image <new-signed-image-reference>
```

The node downloads the new image, writes it to the boot partition, and reboots into
it. Crucially, the upgrade **replaces the OS partitions but keeps the data partition
(`/var`) intact** — Talos exposes an explicit "preserve" control for exactly this, and
preserving state is the required setting for a stateful node like an operator. So
`/var/lib/protocore` — config, keys, and the full chain database — is carried across
the upgrade untouched.

Because the partition layout and mount points are fixed and identical in every image
(see the table below), the new OS finds the data **at the same path it has always
been**. There is no "discovery" step and, for a normal version bump, no migration: the
node simply starts the new `protocore` extension against the existing
`/var/lib/protocore`.

### 4. Rollback

Talos keeps the previous OS image available so a bad upgrade can be reverted:

```bash
talosctl rollback --nodes <node-ip>
```

The node boots back into the prior image. The data partition is, again, untouched —
so rollback restores the previous OS without rewinding the chain data.

Rollback is safe only when the previous `protocore` can read the current
`/var/lib/protocore` database. If a release includes a one-way state migration, that
release must say so in metadata and operator notes before promotion. Release
metadata now carries an explicit state-migration policy under
`channel.upgrade.state_migration`, plus rollback support under
`channel.upgrade.rollback`. `make check-upgrade-readiness` blocks any target that
declares a migration or unsupported rollback unless `ALLOW_STATE_MIGRATION=true`
is set for a staged operator event. Migration releases must also name a runbook and
require a backup, disaster-recovery manifest, and operator approval.

### 5. Disk replacement and recovery

Replacing a failed disk or rebuilding a node is a re-install (step 1), then either:

1. re-sync from the network using the same chain profile/genesis, or
2. restore an operator-approved offline backup of `/var/lib/protocore` taken while the
   service was stopped.

There is no supported in-place hot backup command in the current preview. Do not copy
`/var/lib/protocore` while `ext-protocore` is running and call that a disaster-recovery
backup; it can capture an inconsistent database. For now, the honest recovery posture is:

- archive nodes can rebuild by re-syncing from peers;
- signing/operator nodes need the final first-boot enrollment and key-share lifecycle
  before a production restore runbook is complete;
- disk-image snapshots are acceptable only when the VM or bare-metal disk is quiesced,
  the release digest is recorded, and the restore is verified against the same
  chain/genesis metadata before the node rejoins a cluster.

The local disaster-recovery manifest contract is now documented in
[`docs/disaster-recovery.md`](./disaster-recovery.md). `make validate-disaster-recovery`
fails hot backups, requires stopped/offline evidence for data restores, binds the
manifest to chain/genesis/release digests, and requires key-share recovery evidence
for signing-node reseals before a node rejoins a cluster. The final automated
backup path now includes a local stopped/offline archive packager,
`make protocore-offline-backup`, which refuses running service state and emits
backup evidence for the signed DR manifest. `make protocore-offline-restore`
then validates that backup manifest and archive hash, also accepts Desktop
Talos Copy exports when signed release metadata is supplied, refuses hot/current
running restore state, rejects unsafe archive entries, restores into a quiesced
target directory, and emits restore evidence for the signed DR manifest. The
chain-side `recoverOperatorNode(bytes32)` executor now exists in mono-core as a
foundation-gated node-registry alias of `unjail(bytes32)`, and Monarch Desktop
can submit it when a foundation recovery signer is installed in the OS keychain.
The remaining production gap is the final foundation recovery runbook and live
operations process tracked in [`docs/final-product-readiness.md`](./final-product-readiness.md)
under state backup/recovery.

---

## Disk layout

On install, the OS partitions the target disk automatically — operators never create
or manage partitions by hand. The layout uses fixed labels and mount points, which is
what makes upgrades predictable:

| Partition  | Purpose                                                    | Survives reboot? | Survives upgrade? |
|------------|------------------------------------------------------------|:----------------:|:-----------------:|
| `EFI` / `BIOS` | Bootloader.                                            | yes              | replaced          |
| `BOOT`     | The OS image (kernel + immutable root filesystem).         | yes              | **replaced**      |
| `META`     | Small OS metadata used during install/upgrade.             | yes              | preserved         |
| `STATE`    | The node's machine config and identity.                    | yes              | preserved         |
| `EPHEMERAL` (`/var`) | **All writable node data**, including `/var/lib/protocore`. | yes   | **preserved**     |

The name "ephemeral" is a Talos convention — it means "not part of the immutable
image," **not** "temporary." Despite the name, `/var` persists across reboots and
upgrades; it is only wiped if an operator explicitly resets the node.

---

## Where the node data lives

| Data                            | Location                          |
|---------------------------------|-----------------------------------|
| Node configuration              | `/var/lib/protocore` (generated on first boot) |
| Genesis file                    | `/var/lib/protocore` (staged on first boot) |
| Blockchain database / history   | `/var/lib/protocore`              |

All of it sits on the `EPHEMERAL` partition, outside the OS image, at a path that is
identical across every OS version. That is the direct answer to "will a new image know
where the persistent data is" — yes, by construction, because the path and partition
are fixed, not discovered.

---

## A note on the sealed signing key

Monarch OS uses the machine's **TPM** (Trusted Platform Module — a tamper-resistant
security chip on the motherboard) for **measured boot**: as the machine boots, the
firmware, bootloader, kernel, and OS image are each hashed into the TPM's **PCRs**
(Platform Configuration Registers — write-once-per-boot registers that record exactly
what code ran). A node's signing key share can be **sealed** to those measurements,
meaning the key is only usable if the machine booted the exact, expected software.

This interacts with upgrades in one specific way worth understanding: a new OS image
changes the measured boot values (a different kernel/root filesystem hashes
differently). A **coordinated, signed upgrade** is expected to account for this so the
node can keep signing after the upgrade. An **unannounced** change in those
measurements is treated as a tamper signal rather than a routine event. In short,
upgrades on a signing node are deliberate and verifiable — not silent — which is a
security property, not an inconvenience. The protocol-level treatment of node
attestation is described in the [Monolythium whitepaper](https://monolythium.com).

---

## Current status

The mechanism above is standard, well-tested Talos behaviour that Monarch OS inherits,
so the *storage and upgrade model* is sound today. What is **not yet finished** is the
operator-facing automation around it — the final foundation recovery operations
runbook and live execution of the generated rollout plan. The signed channel policy,
migration-aware upgrade preflight, single-node dry-run upgrade plan, fleet
rollout plan, stopped/offline backup packager, promotion check, and
disaster-recovery manifest validator now exist, and mono-core now exposes the
foundation-gated `recoverOperatorNode(bytes32)` node-registry executor. Monarch
Desktop can submit that executor from a foundation recovery keychain entry; the
remaining recovery gap is exercising and publishing the final foundation
runbook. Those gaps are listed openly in
[`docs/final-product-readiness.md`](./final-product-readiness.md).
The current preview operator workflow is in
[`docs/operator-runbooks.md`](./operator-runbooks.md); the final docs-site version
will be published when the first non-preview signed release ships.

---

## Glossary

- **ISO** — a single bootable disk-image file. Here it is used only as an installer; it
  is not where the node runs from long-term.
- **Talos Linux** — the immutable, API-managed Linux distribution Monarch OS is built
  on. No shell, no SSH, no package manager; everything is done over an API with
  `talosctl`.
- **Immutable OS** — the operating system files cannot be modified after build; you
  replace the whole image to change it.
- **dm-verity** — a Linux kernel feature that verifies the root filesystem against a
  signed hash on every boot, so tampering is detected. Monarch release smoke records
  dm-verity support and can gate promotion on active root-hash evidence that matches
  release metadata.
- **System extension** — a sealed add-on packaged inside the signed OS image. The node
  software (`protocore`) ships as the `monarch-protocore` extension.
- **Maintenance mode** — the temporary state the ISO boots into, waiting to receive a
  machine config before installing.
- **Machine config** — the YAML document that tells a node how to configure itself,
  including which disk to install to.
- **`talosctl`** — the command-line client used to provision, inspect, upgrade, and
  roll back nodes over the Talos API.
- **`EPHEMERAL` / `STATE` / `META` partitions** — the fixed partitions Talos creates;
  `EPHEMERAL` (mounted at `/var`) holds all persistent node data despite its name.
- **TPM** — Trusted Platform Module, a tamper-resistant chip used for measured boot and
  for sealing keys to the booted software.
- **Measured boot / PCRs** — the boot process records hashes of each component it runs
  into the TPM's Platform Configuration Registers, producing a verifiable record of
  exactly what software booted.
- **Sealing** — binding a secret (such as a signing key share) so it is only usable when
  the machine booted the expected, measured software.
