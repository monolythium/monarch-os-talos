# monarch-os-talos

> Talos-based immutable node OS for [Monolythium](https://monolythium.com) operator infrastructure. Open-sourced for auditability; signed release pipeline is in flight.

**License:** Apache-2.0 · **Status:** preview (Stage 0 bootstrap) · **Base:** [Talos Linux](https://www.talos.dev/) `v1.13.0` · **Arch:** `amd64`

---

## Status: preview (Stage 0 bootstrap)

This repository is published primarily for **auditability**. The OS recipe, the `monarch-protocore` Talos system extension entrypoint, build scripts, and the signed-release workflow shape are all here in source form. What is **not yet wired**:

- **No published signed ISO, raw image, or extension OCI artifacts.** The GitHub Actions workflow exists but the build step is a no-op stub (`echo "TODO: wire Makefile targets"`); it does not yet call the local `make` targets. There is no `ghcr.io/monolythium/monarch-os-talos:latest` to pull today.
- **External `make build` is blocked on access to `mono-core`.** The `monarch-protocore` extension bakes the `protocore` node binary built from the (currently private) [`monolythium/mono-core`](https://github.com/monolythium/mono-core) repository. Without that source, build fails unless you supply a pre-built binary via `PROTOCORE_BINARY=/path/to/protocore`.
- **`monarch-cli` extension is placeholder-only.** No build is wired (see [`extensions/monarch-cli/README.md`](./extensions/monarch-cli/README.md)).
- **First-boot operator enrollment, secret injection, network policy enforcement, upgrade/rollback automation, SBOM/provenance publishing, release-channel promotion, and the bundled Monarch Desktop Talos client are all listed as missing** in [`docs/final-product-readiness.md`](./docs/final-product-readiness.md).

Watch this repo for the first non-preview tag before treating any output as production-grade.

---

## What this is

Monarch OS is a custom [Talos Linux](https://www.talos.dev/) distribution for Monolythium operator nodes. Talos is itself an API-driven immutable Linux that has no SSH, no shell, no package manager, and no traditional userspace; Monarch OS extends that base with two purpose-built Talos system extensions:

- **`monarch-protocore`** — packages the `protocore` node binary, supervises it, optionally verifies its on-disk digest before start, stages a Monolythium testnet genesis, and persists node state at `/var/lib/protocore`.
- **`monarch-cli`** (placeholder) — will package the `monarch` operator CLI for on-node administration.

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
│   └── monarch-cli/             # placeholder — not yet wired
│       └── README.md
├── examples/
│   └── protocore-extension-service-config.yaml
├── docs/
│   ├── final-product-readiness.md      # what's missing before this is production-ready
│   └── monarch-desktop-connectivity.md # operator workstation → node provisioning
└── .github/workflows/build.yml  # signed-release shape (artifact build still TODO)
```

## Prerequisites

To inspect and audit the source: a clone and a text editor — no toolchain required.

To run `make build` locally:

- **Docker** or another OCI runtime (the build uses `ghcr.io/siderolabs/imager:v1.13.0`).
- **`git`** and **`jq`** on PATH.
- **`cargo`** (Rust) — only if you need the extension build to compile `protocore` from source. If you set `PROTOCORE_BINARY=/path/to/prebuilt` it isn't invoked.
- A sibling **`mono-core` checkout** at `../mono-core`, or `MONO_CORE_DIR` pointing at one. **`monolythium/mono-core` is currently a private repository**, so this step gates external full-build attempts on either a prebuilt binary or future public access.

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

If you have access to `mono-core` (or a prebuilt `protocore` binary):

```bash
# Default: assumes ../mono-core sibling checkout
make build

# Or point at any other mono-core location
make build MONO_CORE_DIR=/path/to/mono-core

# Or skip cargo by supplying a prebuilt binary
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

When the signed release pipeline lands, every published artifact will carry:

- A **cosign keyless signature** (Sigstore via GitHub OIDC — verifiable with the standard `cosign verify-blob` flow against the certificate identity).
- An **SBOM in SPDX format** generated by [`syft`](https://github.com/anchore/syft).
- A **release metadata JSON** identifying the exact `protocore` version, `mono-core` commit, Talos version, and architecture that produced the image.

Verification commands and the published cosign certificate identity will be documented here once the first signed release ships. Until then, do not run any binary that claims to be Monarch OS — there is no canonical published binary today.

## Documentation

- [`docs/monarch-desktop-connectivity.md`](./docs/monarch-desktop-connectivity.md) — how an operator workstation provisions a Monarch OS node over Talos API mTLS + Protocore JSON-RPC; what the OS image does *not* ship (no SSH, no operator keystore passphrases, no default node identity).
- [`docs/final-product-readiness.md`](./docs/final-product-readiness.md) — comprehensive gap list. What's missing across release artifacts, provisioning, secret handling, network policy, health model, upgrade/rollback, recovery, desktop client, security posture, test coverage, and operator docs. Followed by a phased build plan.

Operator install / verify / enroll / upgrade / recover runbooks will be published at [docs.monolythium.com](https://docs.monolythium.com) once the first signed release ships.

## Release pipeline status

`.github/workflows/build.yml` defines the shape of the signed-release flow:

1. Checkout, install `cosign` and `syft`, set up Docker buildx.
2. Log in to `ghcr.io` (uses the runner's automatic `GITHUB_TOKEN`).
3. Run the build step — **currently a stub** (`echo "TODO: wire Makefile targets" > _out/PENDING`).
4. If ISO/raw artifacts exist, sign them with `cosign sign-blob` (Sigstore keyless via GitHub OIDC).
5. If an ISO exists, generate an SPDX SBOM with `syft`.
6. Upload the contents of `_out/` as a workflow artifact.
7. On tag push (`v*`) or manual dispatch with a tag, create a draft GitHub Release with the artifacts attached.

Wiring step 3 to call `make iso extension metadata sbom` is the immediate next pipeline task. Until that lands, the workflow runs to completion and produces an empty release.

## Related projects

- [**monolythium.com**](https://monolythium.com) — protocol home, whitepaper, ecosystem links.
- [**`monolythium/mono-studio`**](https://github.com/monolythium/mono-studio) — public native builder shell for MRV contracts and MRC assets; the developer-side companion to this operator OS.
- **`monolythium/mono-core`** *(private)* — the chain itself, source of the `protocore` binary baked into the `monarch-protocore` extension.
- **`monolythium/desktop-wallet`** *(private)* — the Monolythium wallet; the Monarch Desktop operator workstation app referenced in the connectivity doc lives in this ecosystem.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. **Don't commit build output.** `_build/`, `_out/`, and other generated artifacts are already covered by `.gitignore` — keep them out of the diff.
2. **Run the affected scripts locally** before declaring it ready. There is no CI workflow that runs the local build today (the GH workflow only runs on tag pushes + manual dispatch and the build step itself is a stub), so the burden is on the PR author.
3. **If your change touches the `protocore` extension, the `monarch-cli` placeholder, the build workflow, or the signed-release pipeline**, link the matching entry in [`docs/final-product-readiness.md`](./docs/final-product-readiness.md) in your PR description.

For substantive changes — new Talos system extensions, changes to the trust boundary, secret-injection / provisioning model, network-policy model, or anything affecting how operators interact with a running node — open an issue first so we can align on the design before the work lands.

## Security

If you find a vulnerability, please **do not open a public issue**. Email `security@monolythium.com` instead. Coordinated disclosure is required for any finding that would affect a signed release.

## License

Released under the Apache License, Version 2.0. See [`LICENSE`](./LICENSE) for the full text.
