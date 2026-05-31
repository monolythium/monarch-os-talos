# monarch-os-talos

> Talos-based immutable node OS for [Monolythium](https://monolythium.com) operator infrastructure. Open-sourced for auditability; the signed-release pipeline is live and publishing cosign-signed preview ISOs.

**License:** Apache-2.0 · **Status:** preview bootstrap · **Base:** [Talos Linux](https://www.talos.dev/) `v1.13.0` · **Arch:** `amd64`

---

## Status: preview bootstrap

This repository is published primarily for **auditability**. The OS recipe, the `monarch-protocore` Talos system extension entrypoint, build scripts, and the signed-release workflow shape are all here in source form. What is **not yet wired**:

- **Signed ISO/raw release automation is live, and preview artifacts are published.** The GitHub Actions workflow downloads a signed `protocore` release asset, builds ISO/raw/extension artifacts with the local Makefile, emits SPDX SBOMs, and signs outputs with cosign keyless. Published `*-preview` releases carry cosign-signed ISOs (see [Trust model + verification](#trust-model--verification)). These previews still bake an **older `protocore` testnet binary and an earlier testnet genesis** — they are for auditability and boot testing, not production operation.
- **External `make build` needs either a prebuilt `protocore` binary or a sibling core checkout.** The easiest public path is `PROTOCORE_BINARY=/path/to/protocore make build`.
- **`monarch-cli` extension is not part of the current image.** The node service is operated through Talos API and Monarch Desktop.
- **First-boot operator enrollment, secret injection, network policy enforcement, upgrade/rollback automation, SBOM/provenance publishing, release-channel promotion, and the bundled Monarch Desktop Talos client are all listed as missing** in [`docs/final-product-readiness.md`](./docs/final-product-readiness.md).

Watch this repo for the first non-preview tag before treating any output as production-grade.

---

## What this is

Monarch OS is a custom [Talos Linux](https://www.talos.dev/) distribution for Monolythium operator nodes. Talos is itself an API-driven immutable Linux that has no SSH, no shell, no package manager, and no traditional userspace; Monarch OS extends that base with two purpose-built Talos system extensions:

- **`monarch-protocore`** — packages the `protocore` node binary, supervises it, optionally verifies its on-disk digest before start, stages a Monolythium testnet genesis, and persists node state at `/var/lib/protocore`.
- **`monarch-cli`** — reserved extension slot; not packaged in the current image.

Operators interact with a running Monarch OS node from a separate workstation through:

- **Talos API on TCP `50000`**, authenticated with Talos client certificates from `talosconfig` (control plane).
- **Protocore JSON-RPC on TCP `8545`**, exposed by the `monarch-protocore` extension service once secrets are provisioned (data plane).

See [`docs/monarch-desktop-connectivity.md`](./docs/monarch-desktop-connectivity.md) for the full provisioning flow.

## Why a custom node OS

Monolythium operator infrastructure is the target of a much more aggressive threat model than a typical Linux server. Talos was chosen because the attack surface available to a remote adversary is structurally smaller than any general-purpose distribution:

- **No SSH, no shell, no `apt`, no multi-user system, no writable rootfs.** Every action is an authenticated Talos API call.
- **Minimized kernel configuration.** Subsystems irrelevant to node operation (audio, wireless, virtualization extensions, AF_ALG, etc.) are compiled out.
- **In-process Rust crypto** in the `protocore` binary — chain signing never touches kernel cryptographic sockets.
- **Reproducible, signed images.** Operators can verify exactly which Talos version + `mono-core` commit + extension source produced the binary they're booting.

This image is **not** for home labs, development workstations, or virtualized testnet infrastructure — use a regular Linux + the release binary for those. Monarch OS is the production runtime for tier-1 operator seats.

## Repo layout

```
monarch-os-talos/
├── Makefile                     # build / iso / metal / extension / metadata / smoke-qemu / sbom / clean
├── scripts/                     # build pipeline (one shell script per target)
│   ├── build-iso.sh
│   ├── build-metal.sh
│   ├── build-protocore-extension.sh
│   ├── write-release-metadata.sh
│   └── smoke-qemu.sh
├── extensions/
│   ├── protocore/               # monarch-protocore Talos system extension
│   │   ├── README.md
│   │   └── src/protocore-entrypoint.c
│   └── monarch-cli/             # reserved extension slot
│       └── README.md
├── examples/
│   └── protocore-extension-service-config.yaml
├── docs/
│   ├── final-product-readiness.md      # what's missing before this is production-ready
│   ├── monarch-desktop-connectivity.md # operator workstation → node provisioning
│   └── upgrade-and-storage.md          # how nodes install, persist data, and upgrade
└── .github/workflows/build.yml  # signed-release pipeline (live; publishes signed preview ISOs)
```

## Prerequisites

To inspect and audit the source: a clone and a text editor — no toolchain required.

To run `make build` locally:

- **Docker** or another OCI runtime (the build uses `ghcr.io/siderolabs/imager:v1.13.0`).
- **`git`** and **`jq`** on PATH.
- **`cargo`** (Rust) — only if you need the extension build to compile `protocore` from source. If you set `PROTOCORE_BINARY=/path/to/prebuilt` it isn't invoked.
- A sibling core checkout at `../mono-core`, `MONO_CORE_DIR` pointing at one, or a prebuilt `protocore` binary supplied through `PROTOCORE_BINARY=/path/to/protocore`.

To run the QEMU smoke test:

- **`qemu-system-x86_64`** on PATH (only `amd64` is supported today).

## Quick start

For external readers — the most useful actions today are auditing the recipe and inspecting the workflow:

```bash
git clone https://github.com/monolythium/monarch-os-talos.git
cd monarch-os-talos

# Read the build script that assembles the Talos ISO
less scripts/build-iso.sh

# Read the system-extension entrypoint that supervises protocore
less extensions/protocore/src/protocore-entrypoint.c

# Read the readiness gap list — what's missing for production
less docs/final-product-readiness.md
```

If you have access to a core checkout or a prebuilt `protocore` binary:

```bash
# Default: assumes ../mono-core sibling checkout
make build

# Or point at any other mono-core location
make build MONO_CORE_DIR=/path/to/mono-core

# Or skip cargo by supplying a prebuilt binary.
PROTOCORE_BINARY=/path/to/protocore make build
```

Output lands under `_out/`:

```
_out/monarch-os-talos-v1.13.0-amd64.iso
_out/monarch-os-talos-v1.13.0-amd64.raw
_out/monarch-os-talos-v1.13.0-amd64.release.json   # via `make metadata`
_out/monarch-os-talos-v1.13.0-amd64.iso.spdx.json  # via `make sbom`
```

## Build targets

| Target | Output | Notes |
|---|---|---|
| `make build` | iso + metal | Default. Calls `iso` and `metal` in sequence. |
| `make iso` | `_out/*.iso` | Bootable Talos installer ISO. |
| `make metal` | `_out/*.raw` | Bare-metal raw disk image. |
| `make extension` | `_out/monarch-protocore-*.tar` | Just the `monarch-protocore` system-extension tarball. |
| `make metadata` | `_out/*.release.json` | Release metadata: protocore version, mono-core commit, Talos version, arch. |
| `make sbom` | `_out/*.spdx.json` | SBOM via `syft`. Requires `syft` on PATH. |
| `make smoke-qemu` | `_out/smoke-qemu/result.json` | Boots the raw image, holds 20 s, optionally probes Talos API. Requires `qemu-system-x86_64`. |
| `make clean` | — | Removes `_build/` and `_out/`. |

Environment knobs:

| Variable | Default | Purpose |
|---|---|---|
| `TALOS_VERSION` | `v1.13.0` | Talos imager image tag. |
| `ARCH` | `amd64` | Target architecture. |
| `MONO_CORE_DIR` | `../mono-core` | Where to find `mono-core` for the protocore build. |
| `PROTOCORE_BINARY` | `$MONO_CORE_DIR/target/release/protocore` | Path to prebuilt binary; if executable, cargo is skipped. |
| `OUT_DIR` | `_out` | Build output directory. |
| `REQUIRE_TALOSCTL_PROBE` | `false` | When `true`, `smoke-qemu` also runs `talosctl version --insecure`. |

## Trust model + verification

The signed-release pipeline is live. Published `*-preview` releases on
[**`monolythium/monarch-os-talos`**](https://github.com/monolythium/monarch-os-talos/releases)
ship a cosign-signed ISO. Each release artifact carries:

- A **cosign keyless signature** (Sigstore via GitHub OIDC) — the `.sig` + `.pem`
  pair next to each artifact, verifiable with the `cosign verify-blob` flow below.
- An **SBOM in SPDX format** generated by [`syft`](https://github.com/anchore/syft) (the `.spdx.json` file).
- A **release metadata JSON** (`*.release.json`) identifying the exact `protocore` version,
  `mono-core` commit, Talos version, and architecture that produced the image.

> **Preview, not production.** The current preview ISOs bake an older `protocore`
> testnet binary and an earlier testnet genesis (see the `sources.protocore_binary`
> field in the `*.release.json`). They are published for auditability and boot
> testing. A non-preview ISO rebuilt on the live testnet binary + genesis is the
> next milestone — treat preview output accordingly.

### cosign certificate identity

Every Monarch OS ISO is signed keyless by this repository's release workflow. The
Fulcio certificate binds to:

- **Identity (SAN):** `https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/<tag>`
- **OIDC issuer:** `https://token.actions.githubusercontent.com`

### Verify a published ISO

Requires [`cosign`](https://github.com/sigstore/cosign) and the [`gh`](https://cli.github.com/) CLI.

```bash
TAG=v0.0.4-preview
ISO=monarch-os-talos-v1.13.0-amd64.iso

# 1. Download the ISO, its checksum, signature, and signing certificate.
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
  --certificate-identity-regexp 'https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/.*' \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "$ISO"
# => Verified OK
```

Pin the exact tag instead of the regexp with
`--certificate-identity "https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/$TAG"`.
The same pattern verifies the `*.raw` and `monarch-protocore-*.tar` artifacts —
swap `$ISO` for the artifact name. The embedded `protocore` binary is itself
cosign-signed by [`monolythium/protocore`](https://github.com/monolythium/protocore)
(identity `…/protocore/.github/workflows/release.yml@refs/tags/<tag>`, same OIDC issuer).

## Documentation

- [`docs/install.md`](./docs/install.md) — install a node on **home / bare-metal** (old PC, NUC, laptop — the hardware-TPM sovereignty path) or the **top cloud providers** (Hetzner, DigitalOcean, AWS, GCP, Vultr) from the signed ISO / `raw.xz`. Verify → write → boot → sync, plus the cloud-vs-bare-metal trust posture.
- [`docs/monarch-desktop-connectivity.md`](./docs/monarch-desktop-connectivity.md) — how an operator workstation provisions a Monarch OS node over Talos API mTLS + Protocore JSON-RPC; what the OS image does *not* ship (no SSH, no operator keystore passphrases, no default node identity).
- [`docs/upgrade-and-storage.md`](./docs/upgrade-and-storage.md) — how a node installs from the ISO to an internal disk, where blockchain data is stored (`/var/lib/protocore` on the persistent partition), and how upgrades swap the OS image while preserving node state. Buzzwords explained.
- [`docs/final-product-readiness.md`](./docs/final-product-readiness.md) — comprehensive gap list. What's missing across release artifacts, provisioning, secret handling, network policy, health model, upgrade/rollback, recovery, desktop client, security posture, test coverage, and operator docs. Followed by a phased build plan.

Operator install / verify / enroll / upgrade / recover runbooks will be published at [docs.monolythium.com](https://docs.monolythium.com) once the first signed release ships.

## Release pipeline status

`.github/workflows/build.yml` defines the shape of the signed-release flow:

1. Checkout, install `cosign` and `syft`, set up Docker buildx.
2. Log in to `ghcr.io` (uses the runner's automatic `GITHUB_TOKEN`).
3. Download the selected `protocore` Linux release asset and verify its `.sha256`.
4. Run `make build metadata sbom`.
5. Sign ISO/raw/extension artifacts with `cosign sign-blob` (Sigstore keyless via GitHub OIDC).
6. Upload the contents of `_out/` as a workflow artifact.
7. On tag push (`v*`) or manual dispatch with a tag, create a draft GitHub Release with the artifacts attached.

This pipeline has shipped: the `*-preview` releases were published from it, each with a cosign-signed ISO, SPDX SBOM, and release metadata. Releases are cut as drafts and then promoted to pre-release; the non-preview milestone is the first ISO rebuilt on the live testnet binary + genesis.

## Related projects

- [**monolythium.com**](https://monolythium.com) — protocol home, whitepaper, ecosystem links.
- [**`monolythium/mono-studio`**](https://github.com/monolythium/mono-studio) — public native builder shell for MRV contracts and MRC assets; the developer-side companion to this operator OS.
- **`monolythium/protocore`** — signed release binaries embedded into the `monarch-protocore` extension.
- **`monolythium/monarch-desktop`** — operator workstation app for Talos API control and live node inspection.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. **Don't commit build output.** `_build/`, `_out/`, and other generated artifacts are already covered by `.gitignore` — keep them out of the diff.
2. **Run the affected scripts locally** before declaring it ready. The release workflow runs on tag pushes and manual dispatch; local script coverage still matters for review.
3. **If your change touches the `protocore` extension, the reserved CLI extension slot, the build workflow, or the signed-release pipeline**, call out the affected release surface in your PR description.

For substantive changes — new Talos system extensions, changes to the trust boundary, secret-injection / provisioning model, network-policy model, or anything affecting how operators interact with a running node — open an issue first so we can align on the design before the work lands.

## Security

If you find a vulnerability, please **do not open a public issue**. Email `security@monolythium.com` instead. Coordinated disclosure is required for any finding that would affect a signed release.

## License

Released under the Apache License, Version 2.0. See [`LICENSE`](./LICENSE) for the full text.
