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
| Release artifacts | Published signed ISO, raw image, and extension artifacts do not exist yet. | Every release must publish versioned artifacts, checksums, signatures, and provenance. |
| Release provenance | No SBOM or SLSA-style provenance pipeline is wired yet. | Operators must be able to verify exactly which `mono-core` commit, Talos version, extension source, and build inputs produced the image. |
| Release channels | Dev/testnet/mainnet promotion is not defined in automation. | Each channel must pin chain config, genesis, binary version, and compatibility metadata. |
| Extension signing | The local `monarch-protocore` extension tarball is buildable but not signed or published. | Extension artifacts must be signed, checksummed, and reproducibly rebuilt. |
| `monarch` CLI extension | The CLI extension is still placeholder-level. | The CLI extension must package the released `monarch` binary or be explicitly removed from the first product scope. |
| First-boot provisioning | There is no final enrollment flow for operator identity, cluster membership, and secrets. | Provisioning must enroll the node without default secrets and must bind the node to its intended cluster/operator role. |
| Secret handling | Current service config uses environment variables as the example path. | Final provisioning must use a secure secret delivery path with rotation, recovery, and auditability. |
| Network policy | RPC/P2P/Talos exposure is documented but not enforced by a release policy. | Talos API, Protocore RPC, and P2P ports must have explicit default exposure rules and operator-network guidance. |
| Protocore health model | The extension starts `protocore`, but final health/readiness semantics are not formalized. | Desktop and automation must be able to distinguish waiting-for-config, syncing, serving RPC, degraded, and failed states. |
| OS upgrade/rollback | Upgrade and rollback flow is not documented or automated. | Operators need signed upgrade channels, rollback criteria, data migration checks, and compatibility guards. |
| State backup/recovery | No documented recovery procedure exists for node state and operator configuration. | The product needs restore, disk replacement, and disaster-recovery runbooks. |
| Desktop Talos client | Monarch Desktop has a first Talos API bridge through the official `talosctl` client; bundled/native client hardening is still missing. | Desktop must import/read `talosconfig`, verify identity, call Talos API, and surface service/log/config state. |
| Desktop RPC wiring | Desktop has live RPC hooks for some chain data, but several screens still depend on mocks or unexposed methods. | Every production screen must declare whether it is live, partially live, or intentionally unavailable until chain/RPC support lands. |
| Desktop operation execution | Existing production-style operation flows are not connected to Talos for Monarch OS nodes. | Start/stop/restart/log/config operations must execute through Talos API and require explicit approval in the Operations drawer. |
| Terminology | Existing desktop source still contains historical node-role labels and operation ids. | User-facing copy should use operator/cluster language. Internal ids can change gradually, but no released UI should expose the retired term. |
| Security posture | Host fingerprint pinning and Talos certificate lifecycle handling are not complete. | The GUI must pin node identity, warn on certificate/key mismatch, and handle expiry/rotation cleanly. |
| Test coverage | Local image boot was smoke-tested, but no repeatable CI boot/e2e suite exists. | CI must build artifacts, boot them in QEMU, apply config, verify extension state, verify RPC, and exercise Desktop connection flows. |
| Operator docs | The current docs explain local build and connectivity only. | Final docs need install, verify, enroll, operate, upgrade, rotate, recover, and incident-response guides. |

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
- Define release channels for testnet and future mainnet.

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

- Run QEMU boot tests for every release.
- Run bare-metal smoke tests before promoting a release channel.
- Test upgrade, rollback, disk replacement, secret rotation, network partition, RPC outage, and service crash scenarios.
- Publish operator runbooks and incident procedures.

Exit criteria:

- A release candidate can be installed, operated, upgraded, recovered, and audited using only published artifacts and docs.
- Remaining blocked work is limited to known mono-core or chain-policy dependencies, not OS/Desktop scaffolding.

## Immediate Next Implementation Targets

1. Update Monarch Desktop with a Talos API bridge module and keychain-backed `talosconfig` handling.
2. Add an OS e2e script that boots the raw image in QEMU, applies config, and verifies `ext-protocore`.
3. Replace the `monarch-cli` extension placeholder with either a real package build or a documented removal from v1 scope.
4. Add release metadata generation for artifact checksums, source commits, Talos version, and Protocore version.
5. Sweep Desktop user-facing terminology before any signed desktop release.
