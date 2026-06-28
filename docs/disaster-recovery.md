# Disaster Recovery Manifest

Monarch OS treats state recovery as an audited operator event, not an ad hoc file copy.
The supported preview posture is still conservative:

- archive/RPC nodes can resync from peers;
- data restores must use an offline or stopped `/var/lib/protocore` backup;
- hot copies of a running Protocore database are rejected;
- signing-node recovery requires operator-key recovery/reseal evidence before the node rejoins a cluster;
- mainnet signing-node recovery must also carry on-chain recovery executor evidence.

The local contract is `monarch-disaster-recovery/v1`, described by
[`schemas/monarch-disaster-recovery.schema.json`](../schemas/monarch-disaster-recovery.schema.json)
and checked with:

```bash
make validate-disaster-recovery \
  DISASTER_RECOVERY=./recovery.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

For mainnet rehearsals or any environment that wants chain-side evidence:

```bash
make validate-disaster-recovery \
  DISASTER_RECOVERY=./recovery.json \
  REQUIRE_ON_CHAIN_RECOVERY=true
```

The validator requires release metadata/protocore digests, chain/genesis binding,
operator approvals, explicit restore checks, and safe backup state. For
`operator-signing` nodes it also requires an operator-key recovery record (the
sealed operator-key hash), at least seven operator approvals, and post-restore
checks for the no-double-sign window and operator-key reseal.

For stopped/offline data backups, create the archive and evidence bundle locally:

```bash
make protocore-offline-backup \
  PROTOCORE_DATA_DIR=/mnt/offline-node/var/lib/protocore \
  BACKUP_RELEASE_METADATA=./target.release.json \
  BACKUP_NODE_ID=archive-001 \
  BACKUP_NODE_ROLE=archive \
  BACKUP_SERVICE_STATE=stopped \
  BACKUP_SERVICE_EVIDENCE=./ext-protocore-stopped.json
```

The backup tool rejects running/hot service states, writes a `.tar.gz` archive,
and emits `monarch-protocore-offline-backup/v1` evidence with the release
metadata hash, genesis hash, Protocore digest, service-state evidence hash, and
archive hash. Use the `disaster_recovery_manifest_fields` block as the backup
and restore input when assembling the signed DR manifest.

To restore from that evidence into a quiesced target directory:

```bash
make protocore-offline-restore \
  RESTORE_BACKUP_MANIFEST=./protocore-archive-001.backup.json \
  RESTORE_OUTPUT_DIR=/mnt/rebuilt-node/var/lib/protocore \
  RESTORE_SERVICE_STATE=stopped \
  RESTORE_SERVICE_EVIDENCE=./ext-protocore-stopped-before-restore.json
```

For a backup exported by Monarch Desktop's Talos Copy path, pass the signed OS
release metadata too, because the Desktop archive manifest intentionally does
not claim chain/genesis/release binding on its own:

```bash
make protocore-offline-restore \
  RESTORE_BACKUP_MANIFEST=./protocore-node.backup.json \
  RESTORE_RELEASE_METADATA=./target.release.json \
  RESTORE_OUTPUT_DIR=/mnt/rebuilt-node/var/lib/protocore \
  RESTORE_SERVICE_STATE=stopped \
  RESTORE_SERVICE_EVIDENCE=./ext-protocore-stopped-before-restore.json
```

The restore tool validates the backup schema, refuses hot/current running
service state, verifies the archive hash from the backup manifest, rejects
unsafe archive entries, restores only into an empty or previously marked restore
directory, and emits `monarch-protocore-offline-restore/v1` evidence containing
the restore evidence hash, extracted file count, deterministic restored-tree
hash, and DR fields bound to the release metadata. This tool does not recover a
signing node's operator key; operator-signing
restores still require an operator-key recovery record and, on mainnet,
`recoverOperatorNode` evidence.

Release metadata publishes the disaster-recovery policy and `verify-release-artifacts`
can fail a release whose metadata does not advertise the schema, validator, safe
backup rules, signing-node operator-key recovery requirement, and mainnet on-chain
executor method (`recoverOperatorNode`). When `on_chain_recovery` is present,
the validator now requires the node-registry executor contract, selector
`0xe58729e6`, the recovered operator peer id, and a SHA-256 hash of the exact
`recoverOperatorNode(peerId)` calldata bytes.
