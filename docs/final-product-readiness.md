# Final Product Readiness

This document defines what is still missing before Monarch OS plus Monarch Desktop should be treated as a production operator product. It is intentionally forward-facing: no production plan should add new stubs, bypasses, hidden gates, default credentials, or mock-only workflows.

## Product Boundary

The final product is two pieces working together:

1. Monarch OS: immutable Talos-based node OS running `protocore` and approved operator services.
2. Monarch Desktop: workstation GUI that controls Monarch OS through Talos API mTLS and reads chain state through Protocore RPC.

Monarch Desktop must not rely on SSH for Monarch OS. SSH can remain as a development bridge for plain Linux test hosts, but production Monarch OS control goes through the Talos API on TCP `50000`.

## Missing From The Final Version

| Area | Missing | Required final behavior |
| --- | --- | --- |
| Release artifacts | Published, cosign-signed preview ISOs and `monarch-protocore` extension tarballs exist (each with `.sha256`, `.sig`, `.pem`, SPDX SBOM, and `*.release.json`); a raw/metal image was published only in an early draft, not every release. | Every release must publish versioned artifacts, checksums, signatures, and provenance — including the raw image — across all supported channels. |
| Release provenance | Each preview release ships an SPDX SBOM and a `*.release.json` provenance file; the `protocore` service can fail closed on a provisioned binary digest. The release workflow now generates GitHub artifact attestations (`actions/attest@v4`) for ISO/raw/extension/metadata/SBOM artifacts and signs/attests a deterministic `monarch-protocore` extension rebuild witness. [`provenance-and-rebuild.md`](./provenance-and-rebuild.md) and `make verify-provenance` now cover cosign signature verification, online/offline GitHub attestation verification, source-lineage checks, extension rebuild-witness verification, optional full clean rebuild comparison, and a publishable full-release rebuild witness that records ISO/raw/extension/SBOM hash and size comparisons. Testnet promotion verifies signatures/attestations, the extension rebuild witness, and offline attestation bundles; disabled mainnet policy also requires the signed/attested full-release rebuild witness plus a live clean rebuild. | Operators must be able to verify exactly which `mono-core` commit, Talos version, extension source, and build inputs produced the image. |
| Immutable substrate proof | Release metadata declares the Talos/no-SSH/no-package-manager/no-interactive-shell substrate policy, and the release verifier can reject an extension tarball that adds shell, SSH, package-manager payloads, unsafe entrypoints, or writable mounts outside `/var/lib/protocore`. Configured QEMU smoke now captures runtime substrate evidence through Talos API (`/proc/config.gz`, `/proc/mounts`, `/proc/cmdline`, `/proc/modules`, `/proc/filesystems`, `/proc/net/tcp`, `/proc/net/tcp6`) and testnet promotion requires a hashed `kernel-hardening-baseline.json`, read-only root, read-only immutable base filesystem evidence, no TCP/IPv6 TCP SSH listener on port 22, dm-verity kernel support, required kernel options, and disabled/absent attack-surface options for kernel crypto userspace APIs, KVM, Bluetooth, WLAN, and sound. Smoke records dm-verity active/root-hash evidence from kernel command line or device-mapper sysfs when the booted image exposes it, and `make dm-verity-root-hashes` extracts validated root hashes for release metadata pinning. The release workflow now attempts that extraction before writing metadata. `REQUIRE_DM_VERITY_ACTIVE=true` requires active evidence, root-hash evidence, and a runtime root hash matching `substrate.dm_verity.expected_root_hashes` in release metadata. Testnet keeps the gate observable but optional until the image exposes stable root-hash evidence; mainnet policy requires metadata-pinned root-hash matching before promotion can be enabled. | Release validation must prove the shipped artifact keeps the whitepaper substrate: no package manager, no SSH, no interactive shell, verified rootfs, and intended kernel surface. |
| Release channels | `channel-policy.json` now defines dev/testnet/mainnet promotion policy, and `scripts/check-channel-promotion.sh` enforces channel pins plus the artifact verifier flags required by each enabled channel. Mainnet remains disabled by policy until the missing mainnet gates are published. | Each channel must pin chain config, genesis, binary version, and compatibility metadata. |
| Extension signing | The `monarch-protocore` extension tarball is built and published cosign-signed alongside the ISO; channel promotion verifies signatures/attestations, exports offline bundles, and now requires a signed/attested deterministic extension rebuild witness for testnet. `make release-rebuild-witness` and `REQUIRE_RELEASE_REBUILD_WITNESS=true` extend the same model to the full ISO/raw/SBOM release set for mainnet. | Extension artifacts must be signed, checksummed, and reproducibly rebuilt. |
| `monarch` CLI extension | Removed from v1 scope: no placeholder extension is shipped. | Any future CLI extension must package a released `monarch` binary and go through the same signed-artifact pipeline as `monarch-protocore`. |
| First-boot provisioning | The extension now defaults to `PROTOCORE_NODE_MODE=operator`, writes `node.mode = "operator"` on first boot, creates a per-node keystore passphrase on the persistent state partition, and runs `protocore registry gen-operator-keys` to seal the ML-DSA operator consensus seed at `<home>/operator/consensus.key.enc`. `PROTOCORE_NODE_MODE=full` or `PROTOCORE_NO_OPERATOR=true` explicitly opts out for non-signing RPC/indexer nodes. The extension also has a fail-closed enrollment switch (`PROTOCORE_REQUIRE_ENROLLMENT`) and pinned manifest path. The release workflow builds the candidate with enrollment required, `make smoke-qemu-config` stages a QEMU-only operator-signing enrollment bundle into the Talos machine config, and `smoke-qemu` verifies through Talos API that the booted node has the manifest, release digest file, operator position, chain id, and 7-of-10 cluster shape before the same smoke run can pass. The enrollment validator now rejects operator-signing manifests unless TPM quote/event-log hashes, quote nonce, PCR policy digest, and the sealed operator-key hash are present. Hardware TPM manifests must include `tpm2_checkquote` verifier inputs (AK public key, quote signature, PCR digest, and hashes), and `make validate-tpm-attestation-evidence` verifies offline evidence hashes plus runs `tpm2_checkquote` for hardware TPM bundles by default. Mainnet manifests must use hardware TPM 2.0 and include on-chain node-registry `register(bytes32,string,bytes32,uint32,uint32,bytes,bytes,bytes)` transaction evidence with DAG round, quorum hash, selector `0xf4896df2`, calldata hash, attestation binding, and an `attestation_payload_hash` recomputed from canonical `monarch-protocore-operator-attestation-payload/v1` JSON. `make run-on-chain-enrollment` now wraps the external node-registry registration command, validates a pending manifest before submission, requires the command to write an updated `on_chain_registration` proof, recomputes the canonical attestation payload hash, optionally validates local TPM evidence, and emits `monarch-on-chain-enrollment-run/v1`; final live hardware-TPM registration rehearsal and cluster/seal-roster admission remain incomplete. | Provisioning must enroll the node without default secrets and must bind the node to its intended cluster/operator role. |
| Secret handling | The entrypoint rejects known inline secret env vars (`PROTOCORE_KEYSTORE_PASSPHRASE`, operator mnemonics/private keys), placeholder values, unreadable digest/enrollment files, and credential-bearing inline Postgres URLs. Each operator holds its own ML-DSA-65 key, and no key material is moved between operators. Release candidates now require `PROTOCORE_REQUIRE_TPM_BINDING=true` in the workflow, stage synthetic vTPM testnet quote/event-log evidence plus a TPM-sealed operator key for QEMU, and `verify-release-artifacts` rejects smoke evidence missing those TPM/operator-key file hashes or whose file hashes do not match the manifest's TPM hash claims. Release metadata now publishes the TPM quote-verification validator and the signed operator audit-trail schema/validator. `make validate-tpm-attestation-evidence` binds the sealed operator key back to the operator enrollment, verifies the quote/event-log and sealed-operator-key hashes, and runs `tpm2_checkquote` for hardware-TPM bundles. `make validate-operator-audit-trail` binds operator actions to a reason, expected-state hash, diff-vs-intent hash, receipts, evidence file hashes, signed approvals, and peer-vouched freeze evidence; for Desktop receipt evidence it also validates `monarch-desktop-operation-receipt/v1` schema/hash fields and recomputes the Desktop receipt audit hash when local evidence files are supplied. Final live hardware-TPM rehearsal, operator-key rotation/recovery execution, and on-chain/public audit publication remain missing. | Final provisioning must use a secure secret delivery path with rotation, recovery, and auditability. |
| Network policy | Talos/RPC/P2P defaults are documented in `docs/network-policy.md`, encoded in release metadata, verifiable against the shipped extension service config, and renderable as nftables or JSON perimeter rules with `make network-firewall-policy`. The renderer requires explicit Talos/RPC CIDRs and fails closed on public control-plane/data-plane exposure unless a test override is set. Hetzner Cloud application has `make hcloud-firewall-policy`, which converts the same release policy to `hcloud` firewall rules, dry-runs by default, and only creates/replaces/attaches the firewall when `HCLOUD_FIREWALL_APPLY=true`. `make cloud-firewall-policy` now renders reviewed dry-run provider plans for DigitalOcean, AWS, GCP, and Vultr from the same policy. `make test-network-firewall-policy` and the release workflow verify the hcloud rule shape, multi-cloud plan shape, and public Talos/RPC rejection path. Live non-Hetzner apply remains manual through provider credentials. | Talos API, Protocore RPC, and P2P ports must have explicit default exposure rules and operator-network guidance. |
| Protocore health model | Desktop now has a readiness probe that combines Talos `ext-protocore` service state with live Protocore JSON-RPC checks (`web3_clientVersion`, `eth_chainId`, `eth_blockNumber`, `eth_syncing`, `net_listening`) and surfaces waiting-for-config, syncing, serving-RPC, degraded, stopped, and failed states. `scripts/smoke-qemu.sh` now boots a raw image through a writable overlay, applies generated Talos smoke config, verifies `ext-protocore`, and probes Protocore RPC. CI now requires machine-config apply, service evidence, and RPC evidence for testnet promotion. | Desktop and automation must be able to distinguish waiting-for-config, syncing, serving RPC, degraded, and failed states. |
| OS upgrade/rollback | `docs/upgrade-and-storage.md` now documents the manual Talos upgrade/rollback flow and release metadata now carries explicit `channel.upgrade.state_migration` and rollback policy. `scripts/check-upgrade-readiness.sh` compares current/target release metadata for channel, chain, genesis, Desktop compatibility, substrate policy, network policy, target artifacts, state-migration requirements, and rollback support. `scripts/render-upgrade-plan.sh` turns a passed preflight plus a tagged/digested image ref into a local dry-run plan containing the Talos Upgrade API payload (`preserve=true`, `force=false`), Desktop `ota-apply` payload, target artifact hashes, rollback path, and required DR gates. `scripts/render-fleet-upgrade-plan.sh` adds a `monarch-talos-fleet-upgrade-manifest/v1` rollout contract, canary/rolling waves, per-node Talos/Desktop payloads, max-unavailable enforcement, DR gating for migration releases, and active signing-quorum protection before any operator-signing wave. Targets that declare a migration or unsupported rollback are blocked unless `ALLOW_STATE_MIGRATION=true` is set for a staged operator event with a runbook, backup requirement, validated disaster-recovery manifest, and operator approval. Final live execution of the generated fleet plan remains an operator/Desktop integration gate. | Operators need signed upgrade channels, rollback criteria, data migration checks, and compatibility guards. |
| State backup/recovery | `docs/upgrade-and-storage.md` now documents the current safe recovery posture: resync archive nodes, use only stopped/offline `/var/lib/protocore` backups, and treat signing-node restore as blocked on final enrollment/operator-key lifecycle. [`disaster-recovery.md`](./disaster-recovery.md) now adds a release-published disaster-recovery manifest/schema/validator that rejects hot backups, requires stopped/offline backup evidence, binds restore plans to chain/genesis/release digests, requires post-restore checks, and requires operator-key recovery evidence for signing-node reseals. `scripts/create-protocore-offline-backup.sh` packages a quiesced Protocore data directory into a hashed archive plus `monarch-protocore-offline-backup/v1` evidence and refuses running/hot service state. `scripts/restore-protocore-offline-backup.sh` validates that manifest/archive hash, accepts Desktop Talos Copy backup manifests only with signed OS release metadata, rejects hot/current running restore state and unsafe archive entries, restores into an empty or previously marked target directory, and emits `monarch-protocore-offline-restore/v1` evidence. mono-core now exposes `recoverOperatorNode(bytes32)` as a foundation-gated node-registry executor alias for `unjail(bytes32)`, and Monarch Desktop can submit that call when a foundation recovery signer is installed in its OS keychain. The remaining gap is the final foundation recovery runbook/live operations process for production recovery. | The product needs restore, disk replacement, and disaster-recovery runbooks. |
| Desktop Talos client | Monarch Desktop has a native Talos API bridge through `talos-rust-client`; privileged service actions require a matched trusted CA pin, a selected endpoint in the active talosconfig context, and valid CA/client certificates, Tauri no longer falls back to SSH after Talos action failure, and the Desktop readiness/e2e gates require certificate expiry-horizon evidence outside the 14-day rotation window. `make validate-talos-certificate-rotation` now adds a signed `monarch-talos-certificate-rotation/v1` operator bundle for CA/client cert rotation, canonical payload-hash approvals, next `talosconfig` hash binding, and optional Desktop post-rotation evidence. | Desktop must import/read `talosconfig`, verify identity, call Talos API, and surface service/log/config state. |
| Desktop RPC wiring | Desktop has live RPC hooks for some chain data, but several screens still depend on mocks or unexposed methods. | Every production screen must declare whether it is live, partially live, or intentionally unavailable until chain/RPC support lands. |
| Desktop operation execution | Existing production-style operation flows are not connected to Talos for Monarch OS nodes. | Start/stop/restart/log/config operations must execute through Talos API and require explicit approval in the Operations drawer. |
| Terminology | Existing desktop source still contains historical node-role labels and operation ids. | User-facing copy should use operator/cluster language. Internal ids can change gradually, but no released UI should expose the retired term. |
| Security posture | Host fingerprint pinning is enforced in Desktop through trusted Talos CA pin matching, endpoint-context checks, certificate expiry validation, and release/e2e evidence gates. Talos certificate lifecycle handling now has a local schema/validator for signed rotation manifests with next CA/client fingerprints, next `talosconfig` hash, minimum validity window, Desktop evidence binding, and ML-DSA approval payload hashes. Final production certificate issuance automation remains an operator-runbook gate. | The GUI must pin node identity, warn on certificate/key mismatch, and handle expiry/rotation cleanly. |
| Test coverage | The release workflow boots the raw image, generates a Talos smoke config, applies it through the maintenance API, requires a real `talosctl` API probe, requires enrollment/TPM/operator-key runtime evidence, requires `ext-protocore` service evidence, Protocore RPC evidence, and runtime substrate proof before signing/upload. `smoke-qemu` now exports the OS release metadata's Protocore digest for Desktop release e2e, the Desktop release workflow requires the GUI/Tauri evidence gate before tagged packaging, and OS testnet/mainnet promotion now requires a Desktop `monarch-desktop-e2e-evidence/v1` artifact resolved from a Desktop release/workflow/local path and verified against the same OS metadata digest. The OS-side verifier rejects Desktop evidence missing the audited operation receipt schema/hash fields or chat sender membership proof through `lyth_clusterStatus` plus `lyth_operatorInfo`. | CI must build artifacts, boot them in QEMU, apply config, verify extension state, verify RPC, and exercise Desktop connection flows. |
| Operator docs | The repo now has preview docs for install, artifact verification, enrollment, signed audit trails, disaster recovery, incident response, Desktop connectivity, upgrades/storage, network policy, and [`operator-runbooks.md`](./operator-runbooks.md) for operate/recover/rotate/incident flows. `make validate-operator-audit-trail` checks signed reason/evidence/receipt records and peer-vouched freeze evidence. `make validate-incident-response` checks signed runbook bundles, evidence hashes, Foundation authorization for emergency actions, mainnet on-chain action evidence, and executor contract/method/selector/calldata bindings; the validator and release metadata policy now pin `freezeAdmission` / `emergencyKeyRotation` to node-registry `0x1005` and `pauseBridgeRoute` / `rollbackBridge` to bridge `0x1008` with canonical selectors. `make validate-disaster-recovery` checks resync/offline-restore/disk-replacement/signing-node-reseal manifests with safe backup state, release/chain binding, post-restore checks, and optional on-chain recovery binding. Final published docs and live production incident/recovery rehearsals are still incomplete; `recoverOperatorNode(bytes32)` exists and Desktop has a foundation-signer submit path, but the final signed recovery runbook still needs a live production rehearsal. | Final docs need install, verify, enroll, operate, upgrade, rotate, recover, and incident-response guides. |

## Build Plan

### Phase 1: Make The Current Artifact Honest

- Update all stale README text so it matches the actual local build state.
- Keep the OS image secret-free by default.
- Keep `protocore` gated on explicit `ExtensionServiceConfig`.
- Document every non-production edge directly in the repo.
- Remove or rewrite historical placeholder language that implies unimplemented work is already product-ready.

Exit criteria:

- `make build` produces local ISO/raw/extension artifacts.
- Documentation clearly separates local test artifacts from signed release artifacts.
- No README claims a production release exists before signed publishing is built.

### Phase 2: Production Release Pipeline

- Publish versioned OS artifacts from CI.
- Sign ISO/raw/extension artifacts.
- Generate checksums, SBOM, and provenance.
- Pin Talos version, `mono-core` commit, extension version, and chain-registry version.
- Keep `channel-policy.json` as the release-channel source of truth for testnet and future mainnet.

Exit criteria:

- A clean machine can verify and boot a signed artifact without local workspace state.
- Release metadata is sufficient for exchanges and operators to audit the binary lineage.

### Phase 3: Secure Provisioning

- Define the final operator enrollment model: cluster id, operator id, node identity, RPC exposure, and key material.
- Replace example passphrase env vars with the final secret injection mechanism.
- Add rotation and recovery procedures.
- Add machine-config templates for single operator node, 7-operator cluster, and 10-operator cluster layouts.

Exit criteria:

- A new node can be provisioned without default credentials.
- A provisioned node can be audited from Desktop.
- Secrets can be rotated without rebuilding the OS image.

### Phase 4: Desktop-To-OS Control Plane

- Add a native Talos API client to Monarch Desktop.
- Import or reference `talosconfig` securely through the OS keychain.
- Verify Talos CA, client certificate, node endpoint, and certificate expiry.
- Read extension/service state for `ext-protocore`.
- Stream logs through Talos API, not SSH.
- Execute approved operations through Talos API with Operations drawer confirmation.

Exit criteria:

- Monarch Desktop can connect to a booted Monarch OS image without SSH.
- Service state, logs, and approved service actions are live.
- A certificate mismatch or endpoint mismatch is visible and blocks privileged actions.

### Phase 5: Chain Data And Operator UX

- Wire every available Protocore RPC method into Desktop.
- Keep unavailable mono-core features visible as explicit blocked items, not silent mocks.
- Replace historical user-facing wording with operator/cluster terminology.
- Add release-grade views for cluster health, operator node health, block/round state, RPC status, and signing activity once exposed by mono-core.

Exit criteria:

- Every production screen is either live or explicitly blocked by a named missing mono-core/RPC feature.
- No final UI relies on undisclosed fixtures.

### Phase 6: Mainnet Readiness

- Run QEMU boot tests for every release, with machine-config apply and `ext-protocore` verification.
- Run bare-metal smoke tests before promoting a release channel.
- Test upgrade, rollback, disk replacement, secret rotation, network partition, RPC outage, and service crash scenarios.
- Publish operator runbooks and incident procedures.

Exit criteria:

- A release candidate can be installed, operated, upgraded, recovered, and audited using only published artifacts and docs.
- Remaining blocked work is limited to known mono-core or chain-policy dependencies, not OS/Desktop scaffolding.

## Immediate Next Implementation Targets

1. Replace the QEMU-only vTPM enrollment fixtures with the final hardware-TPM/on-chain enrollment flow. The on-chain enrollment runner, registry calls, and Desktop import artifact are wired, but the hardware-TPM rehearsal and live registration run still need to produce production evidence.
2. Keep release-candidate Desktop e2e evidence available as a signed/release artifact for each OS promotion, including the audited operation receipt hash, live peer chat proof, and cluster inputs; the OS policy now requires it for testnet and mainnet.
3. Promote the first channel whose Talos artifact exposes stable active dm-verity root-hash evidence; the extraction helper and release workflow metadata pinning are wired, and required dm-verity channels fail unless runtime evidence matches metadata.
4. Exercise the full-release rebuild witness in the first mainnet candidate pipeline; the verifier and disabled mainnet policy now require it, while testnet keeps the expensive full rebuild opt-in.
5. Exercise signed incident-response bundles in the first mainnet candidate pipeline; the schema/validator, release policy, canonical executor address/selector bindings, and chain-side emergency executors now exist, but a live release-candidate rehearsal still needs to produce the final operator evidence.
