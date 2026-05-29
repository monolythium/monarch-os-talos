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
   tampering is detected before the system runs). You replace this layer wholesale
   when you upgrade; you never patch it.

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
node should be set up, including which disk to install to). The relevant field is
the install disk, e.g.:

```bash
talosctl gen config monarch-node https://<node-ip>:6443 --install-disk /dev/sda
talosctl apply-config --insecure --nodes <node-ip> --file controlplane.yaml
```

(`talosctl` is the command-line client for talking to a Talos/Monarch OS node over
its API — there is no SSH.) On receiving the config, the node **installs the OS onto
the internal disk** (`/dev/sda` here) and reboots.

After that first install, **the ISO is no longer needed** — you can remove the USB
stick or detach the virtual media. The node boots from its internal disk from then on.

> A node can technically run disk-less (booted entirely into RAM over the network),
> but a validator that stores chain history should install to a disk so the data
> persists.

### 2. Run (from the internal disk)

The node now runs the installed OS from the internal disk. The blockchain node
process (`protocore`) runs as a **Talos system extension** — a sealed add-on that
ships inside the signed OS image and is supervised by the OS. Monarch OS bundles the
`monarch-protocore` extension, which runs the node binary and stores all of its state
under **`/var/lib/protocore`** (see [extensions/protocore](../extensions/protocore/README.md)).

### 3. Upgrade (new image, same data)

Upgrades **do not** mean re-flashing the ISO. When a new signed OS image is released,
the operator runs:

```bash
talosctl upgrade --nodes <node-ip> --image <new-signed-image-reference>
```

The node downloads the new image, writes it to the boot partition, and reboots into
it. Crucially, the upgrade **replaces the OS partitions but keeps the data partition
(`/var`) intact** — Talos exposes an explicit "preserve" control for exactly this, and
preserving state is the required setting for a stateful node like a validator. So
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

### 5. Disk replacement and recovery

Replacing a failed disk or rebuilding a node is a re-install (step 1) followed by
restoring node state, or re-syncing the chain from the network. The detailed
restore/disaster-recovery procedure is intentionally not yet finalized — it is tracked
in [`docs/final-product-readiness.md`](./final-product-readiness.md) under state
backup/recovery.

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
operator-facing automation around it — signed upgrade channels, rollback criteria,
data-migration/compatibility guards, and the backup/restore runbooks. Those gaps are
listed openly in [`docs/final-product-readiness.md`](./final-product-readiness.md), and
operator install / verify / upgrade / recover guides will be published at
[docs.monolythium.com](https://docs.monolythium.com) when the first signed release ships.

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
  signed hash on every boot, so tampering is detected.
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
