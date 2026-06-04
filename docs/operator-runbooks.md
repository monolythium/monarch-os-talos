# Operator Runbooks

These runbooks describe the current preview operator workflow for Monarch OS.
They are written for a node that is controlled through Talos API mTLS and read
through Protocore JSON-RPC. There is no SSH path in the production model.

The non-preview release still needs a live hardware-TPM enrollment rehearsal,
live key-share rotation/recovery rehearsals, and Desktop end-to-end release
tests before this can be treated as a production operations manual. The local
on-chain enrollment and production DKG runners now exist as fail-closed wrappers
around external registration/DKG commands and the existing TPM/key-share
validators. Remaining gaps are tracked in
[`final-product-readiness.md`](./final-product-readiness.md).

## 0. Verify a release

Pick a release tag and download the complete artifact set into a clean
directory. Verify the artifact checksums before booting, importing, or writing
anything to disk.

```bash
TAG=<release-tag>
ARTIFACT_DIR="$PWD/monarch-release-$TAG"
mkdir -p "$ARTIFACT_DIR"

gh release download "$TAG" \
  --repo monolythium/monarch-os-talos \
  --dir "$ARTIFACT_DIR"

(cd "$ARTIFACT_DIR" && sha256sum -c ./*.sha256)
```

Verify GitHub artifact attestations for the boot artifact, extension tarball,
release metadata, and SBOMs:

```bash
gh attestation verify "$ARTIFACT_DIR"/monarch-os-talos-*.iso \
  -R monolythium/monarch-os-talos
gh attestation verify "$ARTIFACT_DIR"/monarch-os-talos-*.raw.xz \
  -R monolythium/monarch-os-talos
gh attestation verify "$ARTIFACT_DIR"/monarch-protocore-*.tar \
  -R monolythium/monarch-os-talos
gh attestation verify "$ARTIFACT_DIR"/*.release.json \
  -R monolythium/monarch-os-talos
gh attestation verify "$ARTIFACT_DIR"/*.spdx.json \
  -R monolythium/monarch-os-talos
```

Run the local release verifier with the same gates required for testnet
promotion. This proves the signed metadata, artifact set, configured QEMU smoke
evidence, network policy, provisioning policy, kernel/rootfs hardening baseline,
and runtime substrate proof are present.

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_SIGNATURES=true \
REQUIRE_SMOKE_QEMU=true \
REQUIRE_SMOKE_QEMU_TALOSCTL=true \
REQUIRE_SMOKE_QEMU_CONFIG_APPLY=true \
REQUIRE_SMOKE_QEMU_SERVICE=true \
REQUIRE_SMOKE_QEMU_RPC=true \
REQUIRE_SUBSTRATE_RUNTIME_PROOF=true \
REQUIRE_CHANNEL_METADATA=true \
REQUIRE_COMPLETE_ARTIFACT_SET=true \
REQUIRE_SUBSTRATE_PROOF=true \
REQUIRE_NETWORK_POLICY=true \
REQUIRE_PROVISIONING_POLICY=true \
make verify-artifacts
```

Then verify release provenance. This can check cosign signatures, online GitHub
attestations, offline attestation bundles, source checkout lineage, and optional
clean rebuild comparison:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_COSIGN_SIGNATURES=true \
REQUIRE_GITHUB_ATTESTATIONS=true \
ATTESTATION_MODE=online \
make verify-provenance
```

See [`provenance-and-rebuild.md`](./provenance-and-rebuild.md) for the offline
attestation and rebuild flows.

## 1. Install a node

Use [`install.md`](./install.md) for substrate-specific details:

- bare-metal or home machines boot the signed ISO installer;
- cloud providers import the signed `raw.xz`;
- signing operators should prefer hardware TPM 2.0 bare metal;
- cloud or vTPM nodes are acceptable for testnet rehearsal and non-signing
  infrastructure, but the hypervisor remains in the trust boundary.

Generate a Talos machine config with an install disk and a SAN that matches the
node address Monarch Desktop and `talosctl` will use:

```bash
talosctl gen config monarch-node https://<node-ip>:6443 \
  --install-disk /dev/sda \
  --additional-sans <node-ip> \
  --output ./cluster-config
```

Merge the `monarch-protocore` extension service config into the generated
machine config. Start from
[`examples/protocore-extension-service-config.yaml`](../examples/protocore-extension-service-config.yaml).
Do not place passphrases, mnemonics, private keys, key shares,
or credential-bearing database URLs directly in `environment:`.

Apply the config through the Talos maintenance API:

```bash
talosctl apply-config \
  --nodes <node-ip> \
  --endpoints <node-ip> \
  --insecure \
  --file ./cluster-config/controlplane.yaml
```

After the node reboots, confirm Talos and the extension are reachable:

```bash
talosctl --nodes <node-ip> --endpoints <node-ip> version
talosctl --nodes <node-ip> --endpoints <node-ip> service ext-protocore
talosctl --nodes <node-ip> --endpoints <node-ip> logs ext-protocore
```

## 2. Enroll the node

Enrollment binds the node to its intended chain, operator role, cluster
position, release digest, and TPM/key-share evidence. Validate the enrollment
manifest before copying it to the node:

```bash
make validate-enrollment-manifest \
  ENROLLMENT_MANIFEST=./enrollment.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  REQUIRE_RELEASE_DIGEST=true
```

For offline TPM evidence bundles, also verify that the staged files hash to the
manifest values and, for hardware TPM bundles, that the PCR quote verifies:

```bash
make validate-tpm-attestation-evidence \
  ENROLLMENT_MANIFEST=./enrollment.json \
  LOCAL_EVIDENCE_ROOT=./attestation-bundle \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

For production operator-signing enrollment, submit the pending manifest through
the node-registry registration command and validate the updated proof before
staging it on the node:

```bash
make run-on-chain-enrollment \
  ENROLLMENT_MANIFEST=./enrollment.pending.json \
  ENROLLMENT_ON_CHAIN_COMMAND='./ops/register-operator.sh' \
  ENROLLMENT_ON_CHAIN_OUTPUT_DIR=./enrollment-run \
  LOCAL_EVIDENCE_ROOT=./attestation-bundle \
  EXPECTED_CHAIN_PROFILE=mainnet \
  EXPECTED_CHAIN_ID=69420
```

The command receives `MONARCH_ENROLLMENT_INPUT_MANIFEST` and must write
`MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST` with the real registration transaction,
DAG round, quorum hash, calldata hash, and canonical attestation payload hash.
The default strict runner also requires hardware TPM and local TPM evidence.

For operator nodes, the manifest must describe a 10-member cluster with
a 7-of-10 signing threshold, an active or standby operator index, a key
transcript epoch, TPM PCR quote references, quote/event-log hashes, PCR policy
hash, and file references under `/var/lib/protocore` for the operator consensus
key, key transcript, LythiumSeal operator key, and TPM-sealed operator key.
Hardware TPM manifests must also include `tpm2_checkquote` verifier inputs.
Mainnet operator-signing
manifests must use hardware TPM 2.0, not the testnet vTPM mode, and must include
`on_chain_registration` binding the registry contract, operator, cluster,
enrollment transaction, attestation transaction, DAG round, quorum certificate
hash, registry method names, function selectors, calldata hashes, and
the canonical attestation payload hash to the manifest.

The service config should pin these startup gates:

```yaml
- PROTOCORE_NODE_MODE=operator
- PROTOCORE_EXPECTED_DIGEST_FILE=/var/lib/protocore/enrollment/protocore.sha256
- PROTOCORE_REQUIRE_ENROLLMENT=true
- PROTOCORE_ENROLLMENT_FILE=/var/lib/protocore/enrollment/enrollment.json
```

Use `PROTOCORE_NODE_MODE=full` only for a non-signing RPC/indexer node. The default operator mode creates and seals the node's ML-DSA operator consensus identity on first boot.

For signing nodes with TPM-bound operator keys, enable:

```yaml
- PROTOCORE_REQUIRE_TPM_BINDING=true
- PROTOCORE_TPM_QUOTE_FILE=/var/lib/protocore/attestation/quote.bin
- PROTOCORE_TPM_EVENT_LOG_FILE=/var/lib/protocore/attestation/eventlog.bin
- PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE=/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc
- PROTOCORE_TPM_SEALED_BLS_SHARE_FILE=/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc
- PROTOCORE_KEY_TRANSCRIPT_FILE=/var/lib/protocore/secrets/key-transcript.json
- PROTOCORE_DKG_TRANSCRIPT_FILE=/var/lib/protocore/secrets/key-transcript.json
- PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE=/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc
```

Startup is expected to fail closed when the manifest, digest, TPM evidence, or
secret file references are missing. `PROTOCORE_TPM_SEALED_BLS_SHARE_FILE` and
`PROTOCORE_DKG_TRANSCRIPT_FILE` remain compatibility aliases for older release
tooling.

Release QEMU smoke rehearses this gate with synthetic testnet-only material:
`make smoke-qemu-config` stages an operator-signing enrollment manifest, digest
file, vTPM quote/event-log, TPM-sealed LythiumSeal operator key, and key
transcript into the generated Talos machine config. The release verifier requires
`REQUIRE_ENROLLMENT_RUNTIME_PROOF=true` and
`REQUIRE_TPM_BINDING_RUNTIME_PROOF=true` for testnet promotion, so the same
smoke run must prove enrollment and TPM/key-transcript file evidence before the
Protocore RPC probe is accepted.

## 3. Connect Monarch Desktop

Monarch Desktop uses two channels:

- Talos API on TCP `50000` for privileged OS control;
- Protocore JSON-RPC on TCP `8545` for chain and node state.

Import or reference the generated `talosconfig`, pin the Talos CA fingerprint,
and select a node endpoint that appears in the active talosconfig context.
Desktop privileged actions should remain blocked when the CA pin does not
match, the selected endpoint is outside the active context, or the CA/client
certificates are expired or not yet valid.

Before distributing a rotated `talosconfig`, validate the signed certificate
rotation bundle and bind it to Desktop evidence when available:

```bash
make validate-talos-certificate-rotation \
  TALOS_CERTIFICATE_ROTATION=./talos-certificate-rotation.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  REQUIRE_DESKTOP_EVIDENCE=true
```

The manifest signs the canonical
`monarch-talos-certificate-rotation-payload/v1` hash and proves the next
Talos CA/client fingerprints, expiry horizon, next `talosconfig` hash, and
post-rotation Desktop CA pin/endpoint evidence.

Use the Hardware and Talos settings views to inspect `ext-protocore` service
state, logs, and the combined Protocore readiness probe. A healthy node should
move from waiting for config or syncing into serving RPC once `web3_clientVersion`,
`eth_chainId`, `eth_blockNumber`, `eth_syncing`, and `net_listening` respond.

## 4. Operate the node

Routine operator actions go through Talos API and should leave local Desktop
receipts:

```bash
talosctl --nodes <node-ip> --endpoints <node-ip> service ext-protocore
talosctl --nodes <node-ip> --endpoints <node-ip> logs ext-protocore
```

Allowed service actions are start, stop, and restart of `ext-protocore` after
explicit operator approval. Do not add SSH, an on-node shell, a package manager,
or writable paths outside `/var/lib/protocore` to make operations easier; that
breaks the Monarch OS substrate policy.

Use [`network-policy.md`](./network-policy.md) for exposure defaults. Talos API
should stay on the operator control network. Protocore RPC and P2P exposure must
match the release metadata and service config.

Before opening network paths, render the perimeter firewall policy from the
release metadata and the operator's actual control/data-plane CIDRs:

```bash
make network-firewall-policy \
  NETWORK_POLICY_METADATA=./target.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  NETWORK_FIREWALL_OUTPUT=./monarch-node.nft
```

The generator refuses public Talos API or Protocore RPC CIDRs unless an explicit
test override is set. Treat the rendered policy as the source for perimeter or
cloud security-group rules; do not expose Talos API directly to the public
internet.

For Hetzner Cloud nodes, convert and apply the same policy through `hcloud`.
First review the dry-run rule file:

```bash
make hcloud-firewall-policy \
  NETWORK_POLICY_METADATA=./target.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  HCLOUD_FIREWALL_NAME=monarch-node \
  HCLOUD_FIREWALL_RULES_OUTPUT=./monarch-hcloud-firewall-rules.json
```

Then apply only after reviewing the generated JSON:

```bash
make hcloud-firewall-policy \
  NETWORK_POLICY_METADATA=./target.release.json \
  TALOS_ALLOWED_CIDRS=10.10.0.0/16 \
  RPC_ALLOWED_CIDRS=10.20.0.0/16 \
  P2P_ALLOWED_CIDRS=0.0.0.0/0,::/0 \
  HCLOUD_FIREWALL_NAME=monarch-node \
  HCLOUD_FIREWALL_APPLY=true \
  HCLOUD_FIREWALL_SERVERS=monarch-a,monarch-b
```

## 5. Upgrade and rollback

Before a node upgrade, compare the current and target release metadata:

```bash
make check-upgrade-readiness \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json
```

The check blocks unexpected channel changes, chain-profile changes, chain-id
changes, genesis changes without `ALLOW_GENESIS_CHANGE=true`, target releases
that declare a state migration or unsupported rollback without
`ALLOW_STATE_MIGRATION=true`, missing Desktop compatibility, missing
raw/extension artifacts, and weakened substrate/network or provisioning policy.

Then render the exact dry-run upgrade plan for the signed image reference you
intend to submit:

```bash
make upgrade-plan \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json \
  UPGRADE_IMAGE_REF=ghcr.io/monolythium/monarch-os:<release-tag-or-digest> \
  TALOS_NODES=<node-ip> \
  TALOS_ENDPOINTS=<node-ip> \
  UPGRADE_PLAN_OUTPUT=./upgrade-plan.json
```

The plan is not an executor. It records the metadata hashes, target artifacts,
Talos Upgrade API payload with `preserve=true`, Monarch Desktop `ota-apply`
payload, rollback command, and the readiness/DR gates that must be accepted
before execution. If the target declares a state migration or unsupported
rollback, `make upgrade-plan` requires `ALLOW_STATE_MIGRATION=true` plus a
validated `DISASTER_RECOVERY=./recovery.json` manifest before it will produce a
plan.

For a fleet, define the nodes and rollout limits first:

```json
{
  "schema_version": "monarch-talos-fleet-upgrade-manifest/v1",
  "fleet": {
    "id": "testnet-operators-a",
    "max_unavailable": 1,
    "canary_count": 1,
    "operator_signing_quorum": 7
  },
  "nodes": [
    {
      "node_id": "operator-0",
      "role": "operator-signing",
      "cluster_id": "C-001",
      "operator_index": 0,
      "cluster_position": "active",
      "talos_node": "10.0.0.10",
      "talos_endpoint": "10.0.0.10"
    }
  ]
}
```

Then render the deterministic fleet rollout:

```bash
make fleet-upgrade-plan \
  UPGRADE_CURRENT_METADATA=./current.release.json \
  UPGRADE_TARGET_METADATA=./target.release.json \
  FLEET_MANIFEST=./fleet-upgrade.json \
  UPGRADE_IMAGE_REF=ghcr.io/monolythium/monarch-os:<release-tag-or-digest> \
  FLEET_PLAN_OUTPUT=./fleet-upgrade-plan.json
```

The fleet plan is also a dry-run artifact. It batches nodes into canary/rolling
waves, emits the Talos Upgrade API and Desktop operation payload for each node,
requires the same DR manifest gate for migration releases, and fails if a wave
would reduce active operator-signing nodes below quorum. A 7-active signing
cluster must rotate/promote capacity through the key-share lifecycle before
taking an active signer down.

When the preflight passes, upgrade through Talos API:

```bash
talosctl upgrade --nodes <node-ip> --endpoints <node-ip> \
  --image <new-signed-image-reference>
```

Rollback is also a Talos API operation:

```bash
talosctl rollback --nodes <node-ip> --endpoints <node-ip>
```

Rollback is safe only if the previous `protocore` can read the current
`/var/lib/protocore` database. A release with one-way state migration must be
handled as a staged operator event, not an unattended channel update. Such a
release must set `STATE_MIGRATION_REQUIRED=true`, a non-`none`
`STATE_MIGRATION_MODE`, and `STATE_MIGRATION_RUNBOOK_ID` in release metadata, and
operators must have a validated disaster-recovery manifest before proceeding.

## 6. Backup and recovery

There is no supported hot backup command in the preview release. The current
safe posture is:

- archive or relay nodes can be rebuilt from a fresh install and resynced from
  peers;
- backups of `/var/lib/protocore` must be taken while `ext-protocore` is stopped
  or while the disk is otherwise quiesced;
- signing-node restore remains blocked for production until the final
  enrollment, DKG, TPM-sealed key-share, rotation, and recovery ceremonies are
  wired end to end;
- any restore must be checked against the same release digest, chain profile,
  chain id, and genesis metadata before the node rejoins a cluster.

Never recover a signing node by copying raw key shares between machines outside
the enrollment and TPM-binding flow.

Before a restored node rejoins a cluster, write and validate a disaster-recovery
manifest:

```bash
make validate-disaster-recovery \
  DISASTER_RECOVERY=./recovery.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

For signing-node reseal/recovery the manifest must include key-share recovery
evidence and at least seven approvals. For mainnet rehearsals, add
`REQUIRE_ON_CHAIN_RECOVERY=true` so the validator also requires the
`recoverOperatorNode` executor transaction, DAG round, quorum hash,
node-registry contract, selector `0xe58729e6`, recovered operator peer id, and
matching calldata hash.

For a stopped/offline data backup, package only a quiesced `/var/lib/protocore`
copy and bind it to release metadata:

```bash
make protocore-offline-backup \
  PROTOCORE_DATA_DIR=/mnt/offline-node/var/lib/protocore \
  BACKUP_RELEASE_METADATA=./target.release.json \
  BACKUP_NODE_ID=archive-001 \
  BACKUP_NODE_ROLE=archive \
  BACKUP_SERVICE_STATE=stopped \
  BACKUP_SERVICE_EVIDENCE=./ext-protocore-stopped.json
```

The command refuses running service state and writes both an archive and a
`monarch-protocore-offline-backup/v1` evidence JSON file. Copy the
`disaster_recovery_manifest_fields` values into the signed DR manifest before
restore. It is intentionally not a hot backup path.

## 7. Rotate keys or operator membership

The current local tooling validates both the enrollment bundle and the
key-share ceremony. The ceremony manifest describes the cluster roster, DKG
epoch transition, TPM PCR quote hashes, TPM-sealed output shares, release
digests, and at least seven ML-DSA-65 approvals. Mainnet ceremonies also require
on-chain lifecycle evidence: registry contract, transaction hashes, DAG round,
quorum certificate hash, `submitPendingChange`/`attestDkgReshare`
method names, function selectors, calldata hashes, and a canonical
`monarch-protocore-key-share-lifecycle-payload/v1` hash.

Until that protocol flow is rehearsed against a live release candidate, treat
rotation as a planned maintenance event:

1. run the distributed DKG/sealing command through
   `make run-production-dkg-ceremony` so the tool materializes the ceremony
   manifest, local evidence tree, Desktop DKG attestation, and validated
   operator handoffs in one auditable output directory;
2. validate the generated key-share ceremony with
   `make validate-key-share-ceremony`, using
   `LOCAL_EVIDENCE_ROOT` and `VERIFY_LOCAL_FILES=true` when the staged DKG
   transcript and sealed-share output files are available for hash
   verification;
3. seal each operator share to the node TPM policy and validate the seal record
   with `make validate-tpm-sealing-evidence`;
4. render one per-operator import bundle with `make render-key-share-handoff`;
5. validate it with `make validate-key-share-handoff`, using
   `LOCAL_EVIDENCE_ROOT` when the staged `/var/lib/protocore` files are
   available for hash verification;
6. create a new enrollment manifest for the target role, cluster position, DKG
   epoch, and release digest;
7. validate it with `make validate-enrollment-manifest`;
8. stage the enrollment bundle and sealed key-share files under `/var/lib/protocore`;
9. restart `ext-protocore` through Talos API and confirm startup gates pass;
10. keep the node out of production signing until the chain roster and quorum
   state reflect the intended membership.

## 8. Record an Audit Trail

Every production-facing operator action should have a signed audit record that
binds the reason, intended state delta, evidence hashes, receipts, and approvals:

```bash
make validate-operator-audit-trail \
  OPERATOR_AUDIT_TRAIL=./operator-audit.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

Use `LOCAL_EVIDENCE_ROOT` and `VERIFY_LOCAL_FILES=true` when the referenced
evidence bundle is available locally. High-risk actions require two approvals,
and freeze/kill-switch actions require two peer vouches before the validator
accepts the record.

## 9. Respond to incidents

Create a signed incident bundle before publishing or executing a recovery action:

```bash
make validate-incident-response \
  INCIDENT_RESPONSE=./incident-response.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

The bundle must name the incident, chain, response scope, signed runbook,
release metadata digest, and evidence hashes. Mainnet emergency actions
(`freeze-admission`, `pause-bridge-route`, `rollback-bridge`,
`emergency-key-rotation`) must include Foundation threshold authorization plus
on-chain transaction, DAG round, quorum certificate evidence, executor contract,
action-specific executor method, function selector, and calldata hash.

Use these first actions before deeper debugging:

| Incident | First response |
| --- | --- |
| Talos CA pin mismatch | Stop privileged Desktop actions. Verify the operator selected the intended `talosconfig`, endpoint, and certificate chain before reconnecting. Require a validated Talos certificate rotation bundle before trusting a changed CA. |
| Talos certificate expired or not yet valid | Treat privileged control as unavailable. Rotate certificates through the approved Talos lifecycle, validate `monarch-talos-certificate-rotation/v1`, and re-run Desktop CA pin/e2e evidence before restarting services. |
| `ext-protocore` crash loop | Inspect `talosctl service ext-protocore` and `talosctl logs ext-protocore`. Check enrollment, digest, TPM evidence, and secret-file paths before restart. |
| Protocore RPC down | Keep Talos control available, inspect service logs, and verify `web3_clientVersion`, `eth_chainId`, `eth_blockNumber`, `eth_syncing`, and `net_listening` through the configured RPC endpoint. |
| Runtime substrate proof failure | Isolate the node, stop `ext-protocore`, preserve QEMU/Talos evidence, compare it to `kernel-hardening-baseline.json`, and do not promote the artifact or rejoin signing until a signed replacement release explains the drift. |
| TPM PCR drift or quote mismatch | Treat as tamper or unplanned software change. Stop signing duties, preserve quote/event-log evidence, and require a new signed release plus enrollment bundle before returning the node. |
| Network partition | Keep node state intact, verify peer/RPC exposure against `network-policy.md`, and avoid manual database edits. |

The incident validator makes freeze and recovery actions reviewable and
machine-checkable down to the intended executor call. It now pins each
emergency action to its canonical precompile address and selector:
`freezeAdmission(bytes32)` and `emergencyKeyRotation(bytes,uint64,uint64)` on
node-registry `0x1005`, plus `pauseBridgeRoute(bytes32,bytes32)` and
`rollbackBridge(bytes32,bytes32)` on bridge `0x1008`. The remaining production
gap is exercising signed bundles against a live release-candidate incident
rehearsal and publishing the final operator evidence, not shipping placeholder
executors.
