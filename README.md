# monarch-os-talos

> Talos-based immutable node OS for [Monolythium](https://monolythium.com) operator infrastructure. Open-sourced for auditability; the signed-release pipeline is live and publishing cosign-signed production ISOs.

**License:** Apache-2.0 · **Status:** `v0.1.3` — signed testnet release · **Base:** [Talos Linux](https://www.talos.dev/) `v1.13.0` · **Arch:** `amd64`

---

## Status: v0.1.3 — signed testnet release

[`v0.1.3`](https://github.com/monolythium/monarch-os-talos/releases) is a cosign-verified ISO/raw image that bakes the signed `protocore v0.1.70-testnet` node binary, boots **enrollment-free**, **resolves the live genesis dynamically from the public [chain-registry](https://github.com/monolythium/chain-registry)** on first boot, and syncs as a full node on testnet chain-69420 (genesis `0x6c76fe49`; the chain-registry pin is the binding source of truth for the genesis and binary digest). The end-to-end path from a blank machine to a signing cluster seat is documented in [`docs/operator-setup.md`](./docs/operator-setup.md).

Honest scope notes:

- **Enrollment-free by default.** A freshly flashed node boots into Talos maintenance mode, is provisioned in-app by Monarch Desktop, and syncs as a full node with **no enrollment bundle and no TPM binding required**. Operator-signing enrollment and TPM binding are an explicit **opt-in** staged later by an operator — see [`docs/operator-setup.md`](./docs/operator-setup.md).
- **Testnet channel.** Mainnet promotion gates (hardware-TPM enrollment requirements, dm-verity root-hash pinning, full release rebuild witness) remain ahead — see [`docs/release-channels.md`](./docs/release-channels.md).
- **External `make build` needs either a prebuilt `protocore` binary or a sibling core checkout.** The easiest public path is `PROTOCORE_BINARY=/path/to/protocore make build`.
- **No `monarch-cli` extension is shipped in v1.** The node service is operated through Talos API and Monarch Desktop; any future on-node CLI package must be introduced as a real released extension, not a reserved placeholder.
- **Remaining gaps are tracked openly** in [`docs/final-product-readiness.md`](./docs/final-product-readiness.md). The image syncs as a full node out of the box; admission and cluster membership are separate, opt-in chain/desktop flows.

---

## What this is

Monarch OS is a custom [Talos Linux](https://www.talos.dev/) distribution for Monolythium operator nodes. Talos is itself an API-driven immutable Linux that has no SSH, no shell, no package manager, and no traditional userspace; Monarch OS extends that base with two purpose-built Talos system extensions:

- **`monarch-protocore`** — packages the `protocore` node binary, supervises it, optionally verifies its on-disk digest before start, resolves the live genesis from the public chain-registry on first boot (falling back loudly to the baked genesis), boots **enrollment-free** as a full node, and persists node state at `/var/lib/protocore`. Operator-signing enrollment (a sealed per-node operator consensus identity, TPM binding) is an explicit opt-in staged later.
- **No on-node Monarch CLI** — v1 intentionally keeps operator control in Monarch Desktop and the Talos API.

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
├── Makefile                     # build / iso / metal / extension / metadata / promotion / smoke-qemu / sbom / clean
├── channel-policy.json          # machine-checkable dev/testnet/mainnet promotion policy
├── kernel-hardening-baseline.json # required kernel/rootfs runtime proof baseline
├── scripts/                     # build pipeline (one shell script per target)
│   ├── build-iso.sh
│   ├── build-metal.sh
│   ├── build-protocore-extension.sh
│   ├── check-channel-promotion.sh
│   ├── check-upgrade-readiness.sh
│   ├── gen-qemu-smoke-config.sh
│   ├── render-cloud-firewall-plan.sh
│   ├── render-fleet-upgrade-plan.sh
│   ├── render-upgrade-plan.sh
│   ├── resolve-desktop-e2e-evidence.sh
│   ├── validate-enrollment-manifest.sh
│   ├── validate-key-share-ceremony.sh
│   ├── validate-talos-certificate-rotation.sh
│   ├── validate-incident-response.sh
│   ├── verify-desktop-e2e-evidence.sh
│   ├── verify-release-artifacts.sh
│   ├── write-release-metadata.sh
│   └── smoke-qemu.sh
├── extensions/
│   └── protocore/               # monarch-protocore Talos system extension
│       ├── README.md
│       └── src/protocore-entrypoint.c
├── examples/
│   └── protocore-extension-service-config.yaml
├── schemas/
│   ├── protocore-enrollment-manifest.schema.json
│   ├── protocore-key-share-ceremony.schema.json
│   ├── monarch-fleet-upgrade-manifest.schema.json
│   ├── talos-certificate-rotation.schema.json
│   ├── monarch-incident-response.schema.json
│   └── monarch-disaster-recovery.schema.json
├── docs/
│   ├── install.md                      # substrate install guide for signed ISO/raw.xz
│   ├── enrollment-manifest.md          # enrollment schema and validator contract
│   ├── key-share-lifecycle.md          # DKG / rotation / recovery ceremony contract
│   ├── talos-certificate-lifecycle.md  # Talos CA/client cert rotation contract
│   ├── incident-response.md            # signed emergency/incident runbook contract
│   ├── disaster-recovery.md            # stopped/offline backup + restore manifest contract
│   ├── release-channels.md             # dev/testnet/mainnet promotion policy
│   ├── network-policy.md               # Talos/RPC/P2P exposure policy
│   ├── provenance-and-rebuild.md       # signature, attestation, and rebuild checks
│   ├── final-product-readiness.md      # what's missing before this is production-ready
│   ├── operator-runbooks.md            # preview verify / install / enroll / operate / incident runbooks
│   ├── monarch-desktop-connectivity.md # operator workstation → node provisioning
│   └── upgrade-and-storage.md          # how nodes install, persist data, and upgrade
└── .github/workflows/build.yml  # signed-release pipeline (live; publishes signed ISOs)
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
- **`talosctl`** only when using the configured smoke path that applies a machine config or checks `ext-protocore`.
- **`qemu-img`** only when using the configured smoke path; the script boots through a writable qcow2 overlay so the release raw image is not modified.

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
| `make verify-registry-match` | pass/fail | Asserts the staged genesis, embedded protocore binary, release tag, and chain id all match the `chain-registry` entry (the source of truth). Order-only prerequisite of `iso`/`metal`/`extension`/`metadata`, so a drifted build cannot start. Set `GENESIS_ONLY=1` to check only the genesis; `REGISTRY_DIR=../chain-registry` for an offline check. |
| `make sync-genesis-from-registry` | updated `$(GENESIS_TOML)` | Fetches the canonical genesis `chain-registry` pins for `$(REGISTRY_NETWORK)`, verifies its keccak against `genesis_hash`, and copies it into the staged path. This is the one operator action at re-genesis time — it replaces hand-editing the staged genesis. |
| `make test-verify-registry-match` | self-test report | Runs the hermetic 5-case self-test for the release-drift guard. |
| `make dm-verity-root-hashes` | root hashes | Extracts validated dm-verity root hashes from configured QEMU substrate proof for `DM_VERITY_EXPECTED_ROOT_HASHES`. |
| `make extension-rebuild-witness` | `_out/*.rebuild-witness.json` | Rebuilds the extension from release metadata and records the deterministic hash comparison. |
| `make release-rebuild-witness` | `_out/monarch-os-talos-*.rebuild-witness.json` | Rebuilds ISO/raw/extension/SBOM artifacts from release metadata and records per-artifact hash/size comparisons. |
| `make verify-artifacts` | verification report | Checks metadata checksums, artifact hashes, optional signatures, optional QEMU smoke output, channel metadata, substrate policy, network policy, and provisioning policy. |
| `make verify-provenance` | provenance report | Checks release metadata hashes and optional cosign signatures, GitHub artifact attestations, source commit match, rebuild witnesses, and clean rebuild comparison. |
| `make verify-desktop-e2e` | JSON verification report | Checks a Monarch Desktop `monarch-desktop-e2e-evidence/v1` artifact against this OS release metadata. |
| `make resolve-desktop-e2e` | evidence path | Resolves or downloads the Desktop e2e artifact required by testnet/mainnet promotion. |
| `make check-upgrade-readiness` | JSON compatibility report | Compares current and target `*.release.json` files before an operator upgrade. |
| `make upgrade-plan` | JSON dry-run plan | Runs upgrade readiness checks and renders the Talos Upgrade/Desktop payload for a tagged or digested image reference. Requires DR evidence for staged migration/unsupported-rollback targets. |
| `make fleet-upgrade-plan` | JSON dry-run plan | Renders a canary/rolling fleet upgrade plan from a `monarch-talos-fleet-upgrade-manifest/v1` manifest, with max-unavailable, DR, and signing-quorum gates. |
| `make check-channel-promotion` | JSON promotion report | Applies `channel-policy.json` to a release metadata file and runs the required artifact/provenance verifier flags for that channel. |
| `make validate-enrollment-manifest` | JSON validation report | Validates a first-boot enrollment manifest before placing it on a node. Requires `jq`. |
| `make validate-tpm-attestation-evidence` | JSON validation report | Verifies enrollment TPM/DKG evidence file hashes and, for hardware TPM manifests, runs `tpm2_checkquote` unless disabled. |
| `make run-on-chain-enrollment` | enrollment run summary | Runs an external node-registry registration command through `ENROLLMENT_ON_CHAIN_COMMAND`, requires it to write an updated manifest with `on_chain_registration`, then validates the canonical registration evidence and optional TPM evidence. |
| `make validate-key-share-ceremony` | JSON validation report | Validates a DKG/key-share rotation, recovery, reseal, or revocation ceremony manifest. Requires `jq`. |
| `make run-production-dkg-ceremony` | DKG run summary + handoffs | Runs a real external DKG/sealing command through `DKG_CEREMONY_COMMAND`, requires it to materialize the key-share manifest/evidence/DKG attestation, then feeds the existing key-share runner and validators. |
| `make test-on-chain-enrollment-runner` | JSON test report | Verifies the on-chain enrollment runner accepts valid registration proof and rejects missing external commands, missing proofs, and strict vTPM enrollment. |
| `make test-enrollment-and-key-share-validators` | JSON test report | Verifies enrollment and key-share validator positive/negative cases, including TPM evidence hash binding. |
| `make validate-talos-certificate-rotation` | JSON validation report | Validates a signed Talos CA/client certificate rotation bundle and optional Desktop post-rotation evidence. |
| `make test-talos-certificate-rotation` | JSON test report | Verifies Talos certificate rotation payload binding, Desktop-evidence requirement, expiry-window rejection, and unchanged-identity rejection. |
| `make validate-incident-response` | JSON validation report | Validates a signed incident/freeze/recovery runbook bundle and binds emergency on-chain evidence to the canonical executor contract, method, and selector. Requires `jq`. |
| `make test-incident-response` | JSON test report | Verifies incident-response validator positive/negative cases for freeze, bridge pause/rollback, and emergency key-rotation executor bindings. |
| `make validate-disaster-recovery` | JSON validation report | Validates a resync, stopped/offline restore, disk replacement, or signing-node reseal manifest. On-chain recovery evidence must bind the node-registry contract, `recoverOperatorNode(bytes32)` selector, peer id, and calldata SHA-256. Requires `jq`; on-chain evidence also requires `sha256sum` and `xxd`. |
| `make test-disaster-recovery` | JSON test report | Verifies disaster-recovery validator positive/negative cases, including required on-chain recovery evidence and `recoverOperatorNode(peerId)` calldata hash binding. |
| `make protocore-offline-backup` | `.tar.gz` + evidence JSON | Packages a stopped/offline `/var/lib/protocore` copy, rejects hot/running state, and emits backup evidence for the DR manifest. Requires `tar`, `gzip`, and `jq`. |
| `make protocore-offline-restore` | restored tree + evidence JSON | Validates a `monarch-protocore-offline-backup/v1` archive or a Desktop-exported `monarch-desktop-protocore-backup/v1` archive plus release metadata, rejects unsafe restore state and tar entries, restores into an empty/marked directory, and emits restore evidence for the DR manifest. Requires `tar`, `gzip`, and `jq`. |
| `make network-firewall-policy` | nftables or JSON policy | Renders operator perimeter firewall rules from release metadata and explicit Talos/RPC/P2P CIDRs. Fails closed on public Talos/RPC exposure unless explicitly overridden. |
| `make hcloud-firewall-policy` | Hetzner firewall rules/apply result | Converts the same network policy to `hcloud` firewall rules. Dry-run by default; set `HCLOUD_FIREWALL_APPLY=true` to create/replace and attach the firewall. |
| `make cloud-firewall-policy` | JSON dry-run plan | Renders DigitalOcean, AWS, GCP, and Vultr firewall payloads from the same network policy. Non-Hetzner plans are review artifacts, not live apply commands. |
| `make test-network-firewall-policy` | JSON test report | Verifies dry-run Hetzner firewall rule rendering and the fail-closed public Talos/RPC guards. |
| `make test-upgrade-plan` | JSON test report | Verifies upgrade-plan rendering, required image refs, and DR gating for migration upgrades. |
| `make test-fleet-upgrade-plan` | JSON test report | Verifies fleet rollout rendering, duplicate-node rejection, signing-quorum protection, and DR gating for migration upgrades. |
| `make test-protocore-offline-backup` | JSON test report | Verifies stopped/offline backup packaging and hot-backup rejection. |
| `make test-protocore-offline-restore` | JSON test report | Verifies offline restore evidence, archive hash validation, hot-restore rejection, non-empty target rejection, and unsafe tar entry rejection. |
| `make smoke-qemu-config` | `_out/smoke-qemu-config/` | Generates a Talos control-plane config and matching `talosconfig` for configured QEMU smoke. Requires `talosctl`. |
| `make sbom` | `_out/*.spdx.json` | SBOM via `syft`. Requires `syft` on PATH. |
| `make smoke-qemu` | `_out/smoke-qemu/result.json` | Boots the raw image, optionally probes Talos API, and can apply a supplied Talos machine config plus verify `ext-protocore`. Requires `qemu-system-x86_64`. |
| `make clean` | — | Removes `_build/` and `_out/`. |

Environment knobs:

| Variable | Default | Purpose |
|---|---|---|
| `TALOS_VERSION` | `v1.13.0` | Talos imager image tag. |
| `ARCH` | `amd64` | Target architecture. |
| `MONO_CORE_DIR` | `../mono-core` | Where to find `mono-core` for the protocore build. |
| `PROTOCORE_BINARY` | `$MONO_CORE_DIR/target/release/protocore` | Path to prebuilt binary; if executable, cargo is skipped. |
| `OUT_DIR` | `_out` | Build output directory. |
| `KERNEL_BASELINE_FILE` | `kernel-hardening-baseline.json` | Kernel/rootfs hardening baseline hashed in release metadata and enforced by runtime substrate proof. |
| `DM_VERITY_EXPECTED_ROOT_HASHES` | unset | Comma-separated dm-verity root hashes to pin in release metadata. Required to match runtime evidence when `REQUIRE_DM_VERITY_ACTIVE=true` or the baseline requires active dm-verity. |
| `DM_VERITY_SUBSTRATE_PROOF` / `DM_VERITY_ROOT_HASH_FORMAT` | `_out/smoke-qemu/substrate-runtime.json` / `lines` | Input proof and output format (`lines`, `csv`, `env`, or `json`) for `make dm-verity-root-hashes`. |
| `STATE_MIGRATION_REQUIRED` / `STATE_MIGRATION_MODE` | `false` / `none` | State migration policy written into release metadata. Modes are `none`, `backward-compatible`, or `one-way`; non-`none` migrations require a runbook id. |
| `STATE_MIGRATION_RUNBOOK_ID` / `ROLLBACK_SUPPORTED` | unset / `true` | Required runbook id for staged migrations and whether the target release supports Talos rollback after upgrade. |
| `PROTOCORE_NODE_MODE` | `operator` | First-boot node mode written to `config.toml`. Use `full` only for a non-signing RPC/indexer node. |
| `PROTOCORE_NO_OPERATOR` | `false` | Compatibility opt-out. When truthy and `PROTOCORE_NODE_MODE` is unset, first boot uses full-node mode and skips operator consensus key generation. |
| `PROTOCORE_REQUIRE_ENROLLMENT` | `false` | When `true`, the entrypoint refuses to start unless the enrollment manifest and release digest are present. |
| `PROTOCORE_ENROLLMENT_FILE` | `/var/lib/protocore/enrollment/enrollment.json` | Enrollment manifest path checked by the entrypoint and release verifier. |
| `PROTOCORE_EXPECTED_DIGEST_FILE` | unset | Release digest file path for fail-closed enrollment. The release workflow uses `/var/lib/protocore/enrollment/protocore.sha256`. |
| `PROTOCORE_REQUIRE_TPM_BINDING` | `false` | When `true`, the entrypoint requires TPM quote/event-log evidence, a TPM-sealed share, and a DKG transcript. |
| `PROTOCORE_TPM_QUOTE_FILE` / `PROTOCORE_TPM_EVENT_LOG_FILE` | unset | TPM quote and event-log evidence paths. The QEMU smoke config can stage synthetic vTPM testnet fixtures for these paths. |
| `PROTOCORE_TPM_SEALED_BLS_SHARE_FILE` / `PROTOCORE_DKG_TRANSCRIPT_FILE` | unset | Legacy-named TPM-sealed share and DKG transcript paths required by TPM-bound operator nodes. |
| `LOCAL_EVIDENCE_ROOT` | unset | Local root used by `make validate-tpm-attestation-evidence` to resolve `/var/lib/protocore/...` evidence paths from an offline bundle. |
| `REQUIRE_TPM2_CHECKQUOTE` | `auto` | `auto` runs `tpm2_checkquote` for `hardware-tpm2` manifests, `true` always requires it, and `false` verifies hashes only. |
| `REQUIRE_TALOS_API_PROBE` / `REQUIRE_TALOSCTL_PROBE` | `false` | When `true`, `smoke-qemu` must prove Talos API reachability; it uses `talosctl version --insecure` when `talosctl` is installed and falls back to TCP-only evidence otherwise. |
| `TALOS_MACHINE_CONFIG_FILE` | unset | Optional machine config to apply during `smoke-qemu`. When set, QEMU boots through a writable qcow2 overlay and the script runs `talosctl apply-config --insecure`. The config should include the required `ExtensionServiceConfig` for `protocore`. |
| `TALOSCONFIG_FILE` | unset | Talos client config used after `TALOS_MACHINE_CONFIG_FILE` is applied. Required when checking `ext-protocore`. Generate it with a SAN that matches the smoke endpoint, usually `127.0.0.1`. |
| `REQUIRE_EXTENSION_SERVICE_CHECK` | `false` | When `true`, `smoke-qemu` waits for `talosctl service ext-protocore` to succeed and stores service/log evidence under `_out/smoke-qemu/`. |
| `REQUIRE_PROTOCORE_RPC_PROBE` | `false` | When `true`, `smoke-qemu` probes `web3_clientVersion` through forwarded host port `18545`. |
| `SMOKE_CONFIG_DIR` | `_out/smoke-qemu-config` | Output directory for `make smoke-qemu-config`; contains generated Talos secrets and must not be committed. |
| `SMOKE_CLUSTER_ENDPOINT` | `https://127.0.0.1:6443` | Kubernetes endpoint encoded by `talosctl gen config` for QEMU smoke. |
| `TALOS_INSTALL_DISK` | `/dev/vda` | Install disk encoded in the generated smoke machine config. |
| `TALOS_ADDITIONAL_SANS` | `127.0.0.1` | Comma-separated SANs added to generated Talos certs for smoke tests. |
| `REQUIRE_SUBSTRATE_PROOF` | `false` | When `true`, `verify-artifacts` rejects extension tarballs that add shell, SSH, package-manager payloads, unsafe entrypoints, or unexpected writable mounts. |
| `REQUIRE_NETWORK_POLICY` | `false` | When `true`, `verify-artifacts` checks release metadata and extension service config agree on Talos/Protocore network exposure policy. |
| `REQUIRE_PROVISIONING_POLICY` | `false` | When `true`, `verify-artifacts` checks no default/inline secret env is shipped and enrollment policy is pinned. |
| `REQUIRE_DISASTER_RECOVERY_POLICY` | `false` | When `true`, `verify-artifacts` checks release metadata publishes the disaster-recovery schema, validator, safe backup rules, signing-node key-share recovery requirement, and mainnet recovery executor binding. |
| `REQUIRE_COSIGN_SIGNATURES` | `false` | When `true`, `verify-provenance` verifies adjacent `.sig` and `.pem` files with cosign. |
| `REQUIRE_GITHUB_ATTESTATIONS` | `false` | When `true`, `verify-provenance` verifies GitHub SLSA provenance attestations for release artifacts. |
| `ATTESTATION_MODE` | `online` | `verify-provenance` mode: `online`, `download`, or `offline`. Download mode writes attestation bundles and trusted roots for offline use. |
| `ATTESTATION_BUNDLE_DIR` | `$OUT_DIR/attestations` | Where downloaded/offline attestation bundles live. |
| `TRUSTED_ROOT_FILE` | `$ATTESTATION_BUNDLE_DIR/trusted_root.jsonl` | Trusted root used for offline GitHub attestation verification. |
| `REQUIRE_SOURCE_MATCH` | `false` | When `true`, `verify-provenance` requires the local Monarch OS checkout to match release metadata. |
| `REQUIRE_MONO_CORE_SOURCE_MATCH` | `false` | When `true`, `verify-provenance` also requires `MONO_CORE_DIR` to match release metadata. |
| `REQUIRE_EXTENSION_REBUILD_WITNESS` | `false` | When `true`, `verify-provenance` requires the signed/attested `monarch-protocore` rebuild witness and checks it against release metadata. |
| `RUN_EXTENSION_REBUILD` | `false` | When `true`, `verify-provenance` regenerates the extension rebuild witness before validating it. |
| `REBUILD_WITNESS_PATH` | `$OUT_DIR/monarch-protocore-$ARCH.rebuild-witness.json` | Extension rebuild witness path. Required witnesses must live in `OUT_DIR` so signatures and attestations can be verified. |
| `REQUIRE_RELEASE_REBUILD_WITNESS` | `false` | When `true`, `verify-provenance` requires a signed/attested full release rebuild witness and checks every metadata-listed artifact hash/size. |
| `RUN_RELEASE_REBUILD_WITNESS` | `false` | When `true`, `verify-provenance` regenerates the full release rebuild witness before validating it. Usually use `make release-rebuild-witness` before signing instead. |
| `RELEASE_REBUILD_WITNESS_PATH` | `$OUT_DIR/monarch-os-talos-$TALOS_VERSION-$ARCH.rebuild-witness.json` | Full release rebuild witness path. Required witnesses must live in `OUT_DIR` so signatures and attestations can be verified. |
| `RUN_REBUILD` | `false` | When `true`, `verify-provenance` rebuilds into `REBUILD_OUT_DIR` and compares reproduced artifact hashes. |
| `REBUILD_OUT_DIR` | `_out/reproducible-release` | Isolated output directory for `RUN_REBUILD=true`. |
| `REQUIRE_SMOKE_QEMU_CONFIG_APPLY` | `false` | When `true`, `verify-artifacts` requires smoke output proving a Talos machine config was applied. |
| `REQUIRE_SMOKE_QEMU_SERVICE` | `false` | When `true`, `verify-artifacts` requires smoke output proving `ext-protocore` was queried through Talos API. |
| `REQUIRE_SMOKE_QEMU_RPC` | `false` | When `true`, `verify-artifacts` requires smoke output proving Protocore RPC answered. |
| `REQUIRE_SMOKE_QEMU_TALOSCTL` | `false` | When `true`, `verify-artifacts` requires the QEMU smoke result to come from a real `talosctl` API probe, not TCP-only reachability. |
| `REQUIRE_ENROLLMENT_RUNTIME_PROOF` | `false` | When `true`, `smoke-qemu` reads the staged enrollment manifest and release digest through Talos API and verifies the operator-signing, 7-of-10, chain, digest, and mainnet on-chain registration call-binding contract. |
| `REQUIRE_TPM_BINDING_RUNTIME_PROOF` | `false` | When `true`, `smoke-qemu` also verifies TPM quote/event-log, TPM-sealed share, and DKG transcript file evidence. |
| `REQUIRE_SUBSTRATE_RUNTIME_PROOF` | `false` | When `true`, `smoke-qemu` reads `/proc/config.gz`, `/proc/mounts`, `/proc/cmdline`, `/proc/modules`, and `/proc/filesystems` through Talos API and `verify-artifacts` requires proof that root is read-only, an immutable base filesystem is mounted read-only, required kernel options are enabled, and required attack-surface options are disabled or absent. |
| `REQUIRE_DM_VERITY_ACTIVE` | `false` | When `true`, `verify-artifacts` requires runtime proof of active dm-verity, root-hash evidence from the booted image, and a runtime hash matching `substrate.dm_verity.expected_root_hashes` in release metadata. Mainnet policy sets this to `true`; current testnet keeps it observable but not required until the Talos artifact exposes a stable root hash. |
| `KEEP_QEMU_ALIVE` | `false` | When `true`, `smoke-qemu` writes `_out/smoke-qemu/live-env.sh` with Desktop e2e settings, including the expected Protocore digest from release metadata when available, and keeps the QEMU VM running until the smoke process is stopped. |
| `UPGRADE_CURRENT_METADATA` / `UPGRADE_TARGET_METADATA` | unset | Inputs for `make check-upgrade-readiness`. |
| `UPGRADE_IMAGE_REF` | unset | Tagged or `@sha256:` digested registry image reference for `make upgrade-plan`. `latest` is rejected. |
| `UPGRADE_STAGE` / `UPGRADE_REBOOT_MODE` | `false` / `default` | Upgrade-plan Talos API fields. `UPGRADE_REBOOT_MODE` accepts `default` or `powercycle`. |
| `UPGRADE_PLAN_OUTPUT` | unset | Optional path to write the rendered `monarch-talos-upgrade-plan/v1` JSON plan. |
| `FLEET_MANIFEST` | unset | Input `monarch-talos-fleet-upgrade-manifest/v1` for `make fleet-upgrade-plan`. |
| `FLEET_PLAN_OUTPUT` | unset | Optional path to write the rendered `monarch-talos-fleet-upgrade-plan/v1` JSON plan. |
| `ALLOW_SIGNING_QUORUM_RISK` | `false` | Test/staged-event override for fleet plans that would reduce active operator-signing nodes below quorum. Keep false for normal operations. |
| `TALOS_NODES` / `TALOS_ENDPOINTS` | unset | Optional comma-separated Talos nodes/endpoints rendered into the dry-run upgrade and rollback commands. |
| `PROMOTION_METADATA` | unset | Input metadata file for `make check-channel-promotion`. |
| `RELEASE_METADATA` | `$(PROMOTION_METADATA)` | Input metadata file for `make verify-desktop-e2e`. |
| `CHANNEL_POLICY_FILE` | `channel-policy.json` | Promotion policy file for `make check-channel-promotion`. |
| `RUN_ARTIFACT_VERIFIER` / `RUN_PROVENANCE_VERIFIER` | `true` | When `false`, `check-channel-promotion` skips artifact or provenance verifier execution for metadata-only dry runs. |
| `DESKTOP_E2E_EVIDENCE` | unset | Desktop `monarch-desktop-e2e-evidence/v1` JSON. Testnet/mainnet promotion requires it and verifies it against the OS metadata. |
| `DESKTOP_E2E_REPO` | `monolythium/monarch-desktop` | Repository used by `make resolve-desktop-e2e` when downloading evidence. |
| `DESKTOP_E2E_RELEASE_TAG` | unset | Monarch Desktop release tag containing `monarch-desktop-e2e-evidence.json`. |
| `DESKTOP_E2E_ARTIFACT_RUN_ID` / `DESKTOP_E2E_ARTIFACT_NAME` | unset / `monarch-desktop-e2e-evidence` | Workflow run id and artifact name used to download Desktop e2e evidence. |
| `DESKTOP_E2E_EVIDENCE_URL` | unset | Direct URL to a Desktop e2e evidence JSON artifact. |
| `ENROLLMENT_MANIFEST` | unset | Input manifest for `make validate-enrollment-manifest`. |
| `ENROLLMENT_ON_CHAIN_COMMAND` | unset | External command used by `make run-on-chain-enrollment` to submit node-registry registration and write `MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST`. |
| `ENROLLMENT_ON_CHAIN_STRICT` | `true` | When `true`, the on-chain enrollment runner requires release digest, hardware TPM, local TPM evidence, and validated on-chain registration proof. |
| `ENROLLMENT_ON_CHAIN_OUTPUT_DIR` / `ENROLLMENT_ON_CHAIN_MANIFEST` | `_out/on-chain-enrollment` / `<output>/enrollment.on-chain.json` | Output directory and updated manifest path for `make run-on-chain-enrollment`. |
| `REQUIRE_ON_CHAIN_REGISTRATION` / `ALLOW_PENDING_ON_CHAIN_REGISTRATION` | `false` / `false` | Enrollment validator controls for final on-chain proof and pre-registration mainnet manifests. The runner uses pending mode only for its input manifest and requires proof on output. |
| `KEY_SHARE_CEREMONY` | unset | Input manifest for `make validate-key-share-ceremony`. |
| `REQUIRE_ON_CHAIN_LIFECYCLE` | `false` | When `true`, the key-share ceremony validator requires on-chain lifecycle tx, DAG round, quorum, method/selector, calldata-hash, and canonical payload-hash evidence even outside mainnet. |
| `REQUIRE_HARDWARE_TPM` | `false` | When `true`, the key-share ceremony validator rejects vTPM entries even outside mainnet. |
| `TALOS_CERTIFICATE_ROTATION` | unset | Input manifest for `make validate-talos-certificate-rotation`. |
| `REQUIRE_DESKTOP_EVIDENCE` | `false` | When `true`, Talos certificate rotation validation requires post-rotation Desktop e2e evidence bound to the next CA fingerprint and endpoint. |
| `MIN_CERT_VALIDITY_DAYS` | `30` | Minimum validity horizon required for next Talos CA/client certificates in rotation manifests. |
| `INCIDENT_RESPONSE` | unset | Input manifest for `make validate-incident-response`. |
| `REQUIRE_FOUNDATION_AUTHORIZATION` | `false` | When `true`, incident response validation requires Foundation threshold authorization for emergency actions even outside mainnet. |
| `REQUIRE_ON_CHAIN_ACTION` | `false` | When `true`, incident response validation requires tx hash, DAG round, quorum evidence, and executor call binding for emergency actions even outside mainnet. |
| `DISASTER_RECOVERY` | unset | Input manifest for `make validate-disaster-recovery`. |
| `REQUIRE_ON_CHAIN_RECOVERY` | `false` | When `true`, disaster recovery validation requires the on-chain recovery transaction, DAG round, quorum hash, and `recoverOperatorNode` executor call binding even outside mainnet. |
| `PROTOCORE_DATA_DIR` | unset | Offline/stopped Protocore data directory for `make protocore-offline-backup`. This should be a quiesced copy of `/var/lib/protocore`, not a live running database. |
| `BACKUP_RELEASE_METADATA` | unset | Release metadata used by `make protocore-offline-backup` to bind the backup to chain, genesis, and Protocore digest. |
| `RESTORE_BACKUP_MANIFEST` | unset | Input `monarch-protocore-offline-backup/v1` manifest for `make protocore-offline-restore`. |
| `RESTORE_RELEASE_METADATA` | unset | Required only when `RESTORE_BACKUP_MANIFEST` is a Desktop-exported `monarch-desktop-protocore-backup/v1`; binds the archive to chain, genesis, channel, and Protocore digest during restore. |
| `RESTORE_OUTPUT_DIR` | unset | Local restore directory for the validated Protocore archive. It must be empty unless it was created by a previous restore marker and `RESTORE_OVERWRITE=true` is set. |
| `RESTORE_SERVICE_STATE` / `RESTORE_SERVICE_EVIDENCE` | unset | Proof that the target Protocore service is stopped/offline before restore. Running/currently hot restore state is rejected. |
| `RESTORE_EVIDENCE_OUTPUT` / `RESTORE_OVERWRITE` | sibling restore JSON / `false` | Optional restore evidence path and guarded overwrite flag for replacing a previously marked restore tree/evidence. |
| `BACKUP_NODE_ID` / `BACKUP_NODE_ROLE` | unset / `archive` | Node identity included in the backup evidence. Role must be `archive`, `operator-signing`, `rpc`, or `bridge`. |
| `BACKUP_SERVICE_STATE` / `BACKUP_SERVICE_EVIDENCE` | unset | Must prove the backup source was `stopped` or `offline`; running/hot states are rejected. Evidence can be Talos service output or provider snapshot proof. |
| `BACKUP_OUTPUT_DIR` | `_out/protocore-backups` | Output directory for the backup archive, manifest, and manifest checksum. |
| `NETWORK_POLICY_METADATA` | unset | Release metadata file used by `make network-firewall-policy` to derive Talos/RPC/P2P ports. Defaults are used when unset. |
| `NETWORK_FIREWALL_FORMAT` | `nftables` | Firewall output format: `nftables` or `json`. |
| `NETWORK_FIREWALL_OUTPUT` | unset | Optional output path for the generated firewall policy; stdout is used when unset. |
| `TALOS_ALLOWED_CIDRS` / `RPC_ALLOWED_CIDRS` | unset | Required comma-separated CIDRs allowed to reach Talos API and Protocore RPC. Public CIDRs are rejected by default. |
| `P2P_ALLOWED_CIDRS` | `0.0.0.0/0,::/0` | Comma-separated CIDRs allowed to reach Protocore P2P. |
| `ALLOW_PUBLIC_TALOS` / `ALLOW_PUBLIC_RPC` | `false` | Explicit test-only overrides for public Talos/RPC firewall rules. |
| `HCLOUD_FIREWALL_NAME` | `monarch-node` | Hetzner firewall name for `make hcloud-firewall-policy`. |
| `HCLOUD_FIREWALL_APPLY` | `false` | Dry-run safety switch. Set to `true` only after reviewing the generated Hetzner rule JSON. |
| `HCLOUD_FIREWALL_RULES_OUTPUT` | unset | Optional path for the generated `hcloud` rules JSON. |
| `HCLOUD_FIREWALL_SERVERS` / `HCLOUD_FIREWALL_SERVER_SELECTOR` | unset | Hetzner server names/ids or label selector to attach the firewall when `HCLOUD_FIREWALL_APPLY=true`. |
| `CLOUD_FIREWALL_PROVIDER` | `all` | Provider plan to render with `make cloud-firewall-policy`: `all`, `digitalocean`, `aws`, `gcp`, or `vultr`. |
| `CLOUD_FIREWALL_NAME` / `CLOUD_FIREWALL_OUTPUT` | `monarch-node` / unset | Firewall name and optional output path for the multi-cloud dry-run plan. |
| `DIGITALOCEAN_DROPLET_IDS` / `DIGITALOCEAN_TAGS` | unset / `monarch-os` | DigitalOcean target selectors included in the dry-run firewall payload. |
| `AWS_SECURITY_GROUP_ID` / `AWS_SECURITY_GROUP_NAME` / `AWS_VPC_ID` | unset / `monarch-node` / unset | AWS security-group target fields included in the dry-run ingress payload. |
| `GCP_NETWORK` / `GCP_TARGET_TAGS` | `default` / `monarch-os` | GCP network and target tags included in generated firewall-rule objects. |
| `VULTR_FIREWALL_GROUP_ID` | unset | Existing Vultr firewall group id to include in the dry-run rule plan. |
| `ALLOW_GENESIS_CHANGE` | `false` | Permit a target genesis hash change only for a staged chain upgrade. |
| `ALLOW_STATE_MIGRATION` | `false` | Permit target releases that declare a state migration or unsupported rollback only for a staged operator event. |

Configured QEMU smoke is intentionally opt-in because it needs a generated Talos
machine config and matching client `talosconfig`:

```bash
make smoke-qemu-config

make smoke-qemu-artifact \
  TALOS_MACHINE_CONFIG_FILE=_out/smoke-qemu-config/controlplane.yaml \
  TALOSCONFIG_FILE=_out/smoke-qemu-config/talosconfig \
  REQUIRE_TALOS_API_PROBE=true \
  REQUIRE_EXTENSION_SERVICE_CHECK=true \
  REQUIRE_PROTOCORE_RPC_PROBE=true \
  REQUIRE_SUBSTRATE_RUNTIME_PROOF=true
```

The release workflow enables `REQUIRE_PROTOCORE_RPC_PROBE=true` for testnet
and `REQUIRE_SUBSTRATE_RUNTIME_PROOF=true` for testnet promotion, so configured
smoke must prove `web3_clientVersion` answers through guest port `8545`, root is
mounted read-only, and the locked kernel attack-surface options are disabled or
absent before artifacts are signed/uploaded.

For local Desktop GUI e2e, run the configured smoke command with
`KEEP_QEMU_ALIVE=true`, then in another shell source
`_out/smoke-qemu/live-env.sh` before running Monarch Desktop's
`pnpm run e2e:tauri`. Monarch Desktop also provides `pnpm run e2e:monarch`,
which wraps those steps: it generates smoke config, starts this keepalive smoke
process, passes the release-metadata-derived expected Protocore digest to the
Tauri app when present, drives the Tauri app, and stops QEMU when the Desktop
harness exits.

## Release-drift guard

`chain-registry` is the single source of truth for the live chain. Its
`chains/<network>.toml` entry pins the canonical genesis (`genesis_sha256`,
`genesis_hash`), the signed protocore release (`release_tag`,
`binary_release_sha256`), and the `chain_id`. The release-drift guard
(`scripts/verify-release-matches-registry.sh`) asserts that the staged genesis,
the embedded protocore binary, the release tag, and the chain id all agree with
that entry. It is fail-closed: any fetch error, missing pin, or mismatch prints
a `DRIFT:` line and exits non-zero.

The guard runs in three places, so a drifted image cannot ship:

- **Build** — it is an order-only prerequisite of `iso`, `metal`, `extension`,
  and `metadata`, so `make` refuses to start a drifted build.
- **CI** — `.github/workflows/build.yml` runs it on every build (both tag pushes
  and `workflow_dispatch`), once against the freshly downloaded signed binary +
  staged genesis and once against the generated `*.release.json`.
- **Commit** — the optional pre-commit hook checks the staged genesis whenever a
  commit touches `defaults/*/genesis.toml` or the build workflow. Enable it with:

  ```bash
  git config core.hooksPath .githooks
  ```

  The hook runs in `GENESIS_ONLY` offline mode against a sibling
  `../chain-registry` checkout; if none is present it warns and passes (CI still
  enforces the full guard).

At re-genesis time the only operator action is `make sync-genesis-from-registry`,
which pulls the canonical genesis `chain-registry` pins and stages it — no more
hand-editing the staged genesis.

## Trust model + verification

The signed-release pipeline is live. Published releases on
[**`monolythium/monarch-os-talos`**](https://github.com/monolythium/monarch-os-talos/releases)
(`v0.1.3` and the earlier signed series) ship a cosign-signed ISO.
Each release artifact carries:

- A **cosign keyless signature** (Sigstore via GitHub OIDC) — the `.sig` + `.pem`
  pair next to each artifact, verifiable with the `cosign verify-blob` flow below.
- An **SBOM in SPDX format** generated by [`syft`](https://github.com/anchore/syft) (the `.spdx.json` file).
- A **release metadata JSON** (`*.release.json`) identifying the exact `protocore` version,
  `mono-core` commit, Talos version, architecture, channel pins, and substrate policy that produced the image.
- A **GitHub artifact attestation** generated with `actions/attest@v4` for the ISO,
  compressed raw image, extension tarball, release metadata, and SBOM files. Operators
  can verify it with `gh attestation verify <artifact> -R monolythium/monarch-os-talos`.
- A CI verifier gate that can require the `monarch-protocore` extension tarball to
  contain no shell, SSH server/client tools, package-manager payloads, unsafe service
  entrypoint, or writable mount outside `/var/lib/protocore`.
- A runtime substrate proof from configured QEMU smoke, captured through
  `talosctl read`, that records `/proc/config.gz`, root mount state, kernel command
  line, loaded modules, filesystems, TCP listener state, a hashed kernel hardening
  baseline, immutable rootfs evidence, no SSH listener on TCP port 22, dm-verity
  kernel support, and dm-verity root-hash evidence. Channels that set
  `REQUIRE_DM_VERITY_ACTIVE=true` must also pin `DM_VERITY_EXPECTED_ROOT_HASHES`
  so runtime evidence is bound back to release metadata. The release workflow now
  attempts to extract those pins from `_out/smoke-qemu/substrate-runtime.json`
  before writing metadata; operators can run `make dm-verity-root-hashes
  DM_VERITY_ROOT_HASH_FORMAT=csv` to inspect or reuse the same value locally.
- A provisioning-policy gate that rejects shipped inline secret environment variables,
  placeholder values, and unpinned enrollment manifest settings.
- A Desktop e2e evidence verifier that checks `monarch-desktop-e2e-evidence/v1`
  against this OS release metadata: same raw image metadata, same Protocore
  digest, healthy Talos/Protocore readiness, successful Talos restart receipt,
  and verified two-operator chat exchange.

> **Always check the release metadata.** Check the `sources.protocore_binary`
> and genesis fields in the `*.release.json` before using a build against a live
> testnet. `v0.1.3` and later are signed releases for the testnet channel;
> `*-preview` tags remain auditability/boot-testing builds.

### cosign certificate identity

Every Monarch OS ISO is signed keyless by this repository's release workflow. The
Fulcio certificate binds to:

- **Identity (SAN):** `https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/<tag>`
- **OIDC issuer:** `https://token.actions.githubusercontent.com`

### Verify a published ISO

Requires [`cosign`](https://github.com/sigstore/cosign) and the [`gh`](https://cli.github.com/) CLI.

```bash
TAG=v0.1.3
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

- [`docs/operator-setup.md`](./docs/operator-setup.md) — **the canonical "run a Monolythium operator node" guide**: verify the signed ISO, flash/boot (bare-metal or cloud), first-boot dynamic genesis resolution, install Monarch Desktop, the ten-step welcome checklist, and join-vs-form-a-cluster.
- [`docs/install.md`](./docs/install.md) — install a node on **home / bare-metal** (old PC, NUC, laptop — the hardware-TPM sovereignty path) or the **top cloud providers** (Hetzner, DigitalOcean, AWS, GCP, Vultr) from the signed ISO / `raw.xz`. Verify → write → boot → sync, plus the cloud-vs-bare-metal trust posture.
- [`docs/enrollment-manifest.md`](./docs/enrollment-manifest.md) — first-boot enrollment manifest schema and local validator.
- [`docs/key-share-lifecycle.md`](./docs/key-share-lifecycle.md) — DKG/key-share rotation, recovery, reseal, and revocation ceremony schema and validator.
- [`docs/talos-certificate-lifecycle.md`](./docs/talos-certificate-lifecycle.md) — Talos CA/client certificate rotation schema, payload binding, and Desktop evidence gate.
- [`docs/incident-response.md`](./docs/incident-response.md) — signed incident/freeze/recovery runbook schema and validator.
- [`docs/disaster-recovery.md`](./docs/disaster-recovery.md) — resync, stopped/offline restore, disk replacement, and signing-node reseal manifest schema and validator.
- [`docs/release-channels.md`](./docs/release-channels.md) — dev/testnet/mainnet promotion policy and the local promotion check.
- [`docs/network-policy.md`](./docs/network-policy.md) — default Talos/Protocore ports, prohibited production surfaces, and release verifier enforcement.
- [`docs/provenance-and-rebuild.md`](./docs/provenance-and-rebuild.md) — operator-side signature checks, GitHub attestation verification, offline attestation bundles, source lineage checks, and clean rebuild comparison.
- [`docs/monarch-desktop-connectivity.md`](./docs/monarch-desktop-connectivity.md) — how Monarch Desktop provisions a Monarch OS node in-app (connect by IP → pick disk → apply → sync) over Talos API mTLS + Protocore JSON-RPC, with a manual `talosctl` fallback; what the OS image does and does not ship: no SSH, no operator keystore passphrases, no shipped key material; the node boots enrollment-free as a full node and operator-signing identity is opt-in.
- [`docs/upgrade-and-storage.md`](./docs/upgrade-and-storage.md) — how a node installs from the ISO to an internal disk, where blockchain data is stored (`/var/lib/protocore` on the persistent partition), and how upgrades swap the OS image while preserving node state. Buzzwords explained. Includes [**Updating protocore (you do NOT re-flash the ISO)**](./docs/upgrade-and-storage.md#updating-protocore-you-do-not-re-flash-the-iso) — the ISO / installer-image / protocore-release version model, and why those three version numbers are independent and not meant to match.
- [`docs/operator-runbooks.md`](./docs/operator-runbooks.md) — preview operator runbooks for verifying artifacts, installing, enrolling, connecting Desktop, operating, upgrading, recovering, rotating, and responding to incidents.
- [`docs/final-product-readiness.md`](./docs/final-product-readiness.md) — comprehensive gap list. What's missing across release artifacts, provisioning, secret handling, network policy, health model, upgrade/rollback, recovery, desktop client, security posture, test coverage, and operator docs. Followed by a phased build plan.

Operator docs are also published at
[docs.monolythium.com](https://docs.monolythium.com); the repo docs above remain
the source-adjacent reference.

## Release pipeline status

`.github/workflows/build.yml` defines the shape of the signed-release flow:

1. Checkout, install `cosign`, `syft`, QEMU, and `talosctl`, then set up Docker buildx.
2. Log in to `ghcr.io` (uses the runner's automatic `GITHUB_TOKEN`).
3. Download the selected `protocore` Linux release asset and verify its `.sha256`.
4. Build ISO/raw/extension artifacts with enrollment and TPM binding required, generate SBOMs, generate Talos smoke config with a QEMU-only enrollment/TPM/DKG bundle, boot the raw image in QEMU, apply the config, require a real `talosctl` API probe plus enrollment proof, TPM/DKG/key-share proof, `ext-protocore`, Protocore RPC, runtime substrate evidence, incident-response policy, and disaster-recovery policy, compress the raw image, write release metadata, and generate the deterministic extension rebuild witness. Production enrollment uses `make run-on-chain-enrollment` to invoke the external node-registry registration command and validate the updated on-chain manifest proof; production key-share transitions use `make run-production-dkg-ceremony` to invoke the external distributed DKG/sealing command and validate the resulting transcript, TPM-sealed shares, Desktop attestation, and operator handoffs. Mainnet promotion additionally requires the full release rebuild witness.
5. Sign ISO/raw/extension/metadata/SBOM/rebuild-witness artifacts with `cosign sign-blob` (Sigstore keyless via GitHub OIDC).
6. Generate GitHub build provenance attestations for the release artifacts and extension rebuild witness.
7. Resolve Monarch Desktop GUI/Tauri e2e evidence from a Desktop release, workflow artifact, direct URL, or local path; verify the complete artifact set and run `make check-channel-promotion` against `channel-policy.json`. Testnet promotion also verifies Desktop two-party chat evidence, enrollment/TPM smoke evidence, signatures/attestations, the extension rebuild witness, and exports offline attestation bundles.
8. Upload the contents of `_out/` as a workflow artifact. `smoke-qemu` can also
   hold the VM for a downstream Desktop GUI e2e run when invoked with
   `KEEP_QEMU_ALIVE=true`.
9. On tag push (`v*`) or manual dispatch with a tag, create a draft GitHub Release with the artifacts attached.

This pipeline has shipped: `v0.1.3` — built on the signed `protocore v0.1.70-testnet` binary, booting enrollment-free, and resolving the live genesis from the chain-registry — alongside the earlier signed series, each with a cosign-signed ISO, SPDX SBOM, and release metadata.

## Related projects

- [**monolythium.com**](https://monolythium.com) — protocol home, whitepaper, ecosystem links.
- [**`monolythium/mono-studio`**](https://github.com/monolythium/mono-studio) — public native builder shell for MRV contracts and MRC assets; the developer-side companion to this operator OS.
- **`monolythium/protocore`** — signed release binaries embedded into the `monarch-protocore` extension.
- **`monolythium/monarch-desktop`** — operator workstation app for Talos API control and live node inspection.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. **Don't commit build output.** `_build/`, `_out/`, and other generated artifacts are already covered by `.gitignore` — keep them out of the diff.
2. **Run the affected scripts locally** before declaring it ready. The release workflow runs on tag pushes and manual dispatch; local script coverage still matters for review.
3. **If your change touches the `protocore` extension, build workflow, signed-release pipeline, or introduces a new on-node CLI extension**, call out the affected release surface in your PR description.

For substantive changes — new Talos system extensions, changes to the trust boundary, secret-injection / provisioning model, network-policy model, or anything affecting how operators interact with a running node — open an issue first so we can align on the design before the work lands.

## Security

If you find a vulnerability, please **do not open a public issue**. Email `security@monolythium.com` instead. Coordinated disclosure is required for any finding that would affect a signed release.

## License

Released under the Apache License, Version 2.0. See [`LICENSE`](./LICENSE) for the full text.
