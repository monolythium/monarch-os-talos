# Key-Share Lifecycle

Operator key-share changes must be described by a signed ceremony manifest before
the node rejoins signing duties. The local contract is versioned:

- schema id: `monarch-protocore-key-share-ceremony/v1`
- schema file: [`schemas/protocore-key-share-ceremony.schema.json`](../schemas/protocore-key-share-ceremony.schema.json)
- validator: [`scripts/validate-key-share-ceremony.sh`](../scripts/validate-key-share-ceremony.sh)
- on-chain payload id: `monarch-protocore-key-share-lifecycle-payload/v1`

Validate a ceremony before staging new shares:

```bash
make validate-key-share-ceremony \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

When the staged ceremony artifacts are available locally, add file-hash
verification:

```bash
make validate-key-share-ceremony \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  LOCAL_EVIDENCE_ROOT=/mnt/operator-node \
  VERIFY_LOCAL_FILES=true
```

`LOCAL_EVIDENCE_ROOT` maps `/var/lib/protocore/...` paths to the mounted or
copied evidence tree and verifies the DKG transcript plus all ten TPM-sealed
share output files against the ceremony manifest hashes.

## Ceremony Runner

Use the ceremony runner to turn a validated DKG/TPM ceremony into the artifacts
operators and Desktop consume:

```bash
make run-key-share-ceremony \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  KEY_SHARE_CEREMONY_RUN_OUTPUT_DIR=./_out/key-share-ceremony \
  LOCAL_EVIDENCE_ROOT=/mnt/ceremony-evidence \
  VERIFY_LOCAL_FILES=true \
  REQUIRE_TPM_SEALING_EVIDENCE=true \
  TPM_SEALING_EVIDENCE_FILES="./operator-0-tpm-seal.json ... ./operator-9-tpm-seal.json" \
  REQUIRE_DKG_RESHARE_ATTESTATION=true \
  DKG_RESHARE_INTENT_ID=7 \
  DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX=0x... \
  DKG_RESHARE_THRESHOLD_SIG_HEX=0x...
```

The runner reuses the existing validators instead of accepting a parallel
format. It validates the ceremony, validates every supplied TPM sealing evidence
bundle against that ceremony and optional enrollment manifests, renders and
validates all ten `monarch-protocore-key-share-handoff/v1` operator handoffs,
and emits `monarch-key-share-ceremony-run/v1` as a local summary. When the DKG
re-share inputs are supplied, it also writes the Desktop-importable
`monarch-dkg-reshare-attestation/v1` artifact in the output directory.

## Production DKG Orchestration

Use `make run-production-dkg-ceremony` when the DKG ceremony output should come
from the production distributed ceremony command rather than from a prebuilt
manifest:

```bash
make run-production-dkg-ceremony \
  DKG_CEREMONY_COMMAND="./run-distributed-dkg --out \"$MONARCH_DKG_OUTPUT_DIR\"" \
  DKG_CEREMONY_COMMAND_LABEL=hardware-tpm2-dkg-rotation-2026-06 \
  EXPECTED_CHAIN_PROFILE=mainnet \
  EXPECTED_CHAIN_ID=<chain-id> \
  REQUIRE_HARDWARE_TPM=true \
  REQUIRE_ON_CHAIN_LIFECYCLE=true \
  REQUIRE_TPM_SEALING_EVIDENCE=true \
  REQUIRE_DKG_RESHARE_ATTESTATION=true \
  VERIFY_LOCAL_FILES=true
```

The runner exports `MONARCH_DKG_OUTPUT_DIR`,
`MONARCH_DKG_CEREMONY_MANIFEST`, `MONARCH_DKG_EVIDENCE_ROOT`, and
`MONARCH_DKG_DKG_RESHARE_ATTESTATION` for the external command. The command
must write the `monarch-protocore-key-share-ceremony/v1` manifest, staged
`/var/lib/protocore/secrets/...` evidence files under the evidence root, and
the Desktop-importable `monarch-dkg-reshare-attestation/v1` artifact. The
runner then calls `run-key-share-ceremony`, which validates local transcript and
sealed-share hashes, validates any supplied TPM sealing bundles, renders all ten
handoffs, and writes a `monarch-production-dkg-ceremony-run/v1` summary. The
full shell command is intentionally not copied into the summary; operators
should put the stable command/runbook id in `DKG_CEREMONY_COMMAND_LABEL`.
`PRODUCTION_DKG_STRICT=true` is the default and forces hardware TPM,
on-chain lifecycle evidence, TPM sealing evidence, DKG attestation, and local
file-hash verification even if the generic validator defaults are looser. Use
`PRODUCTION_DKG_STRICT=false` only for testnet rehearsal fixtures.

For production ceremonies, keep `VERIFY_LOCAL_FILES=true`,
`REQUIRE_TPM_SEALING_EVIDENCE=true`, `REQUIRE_DKG_RESHARE_ATTESTATION=true`,
and, for mainnet or hardware rehearsals, `REQUIRE_HARDWARE_TPM=true` plus
`REQUIRE_ON_CHAIN_LIFECYCLE=true`. Those flags make the runner fail closed when
the external DKG output, TPM-sealed shares, hardware quote verification, or
node-registry lifecycle evidence is missing.

For each operator share, validate the TPM sealing evidence before rendering or
importing the handoff:

```bash
make validate-tpm-sealing-evidence \
  TPM_SEALING_EVIDENCE=./operator-2-tpm-seal.json \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  ENROLLMENT_MANIFEST=./operator-2-enrollment.json \
  LOCAL_EVIDENCE_ROOT=/mnt/operator-node \
  VERIFY_LOCAL_FILES=true
```

The sealing evidence binds the operator, DKG epoch, release digest, quote/event
log hashes, PCR policy digest, DKG transcript hash, sealed-share hash, TPM2
public/private/context object hashes, and a successful unseal validation into a
canonical signed payload. Mainnet evidence must use `hardware-tpm2` and include
the `tpm2_checkquote` verifier files.

The manifest covers `initial-dkg`, `operator-rotation`, `share-reseal`,
`recovery`, and `emergency-revocation` ceremonies. It must bind:

- chain profile and chain id;
- cluster id, 10-member roster, 7-of-10 threshold, and DKG epoch transition;
- the full active/standby operator roster with TPM mode, PCR quote hash,
  PCR event-log hash, and the sealed-share PCR policy hash;
- key-transcript input/output hashes, transcript commitment hash,
  participant-commitment bundle hash, encrypted-share bundle hash, and the
  cluster's 1952-byte ML-DSA-65 consensus public key (there is no shared
  threshold group key: consensus is per-operator ML-DSA-65 and a round
  certificate is a 7-of-10 bitmap multisig);
- one TPM-sealed share output for each operator index `0` through `9`, with
  each output bound back to that operator's TPM mode, PCR quote/event-log
  hashes, sealed-share policy hash, DKG transcript hash, and DKG epoch;
- at least seven ML-DSA-65 operator approvals over the ceremony payload;
- release metadata and Protocore binary digests.

Mainnet ceremonies are stricter: every operator must use `hardware-tpm2`, and
the manifest must include `on_chain_lifecycle` with the registry contract,
cluster id, next DKG epoch, ceremony transaction hash, attestation transaction
hash, DAG round, quorum certificate hash, method names, function selectors,
calldata hashes, and a lifecycle payload hash. The validator recomputes that
payload hash from canonical sorted JSON, so the submitted registry evidence is
bound to the exact cluster roster, DKG transition, release digests, TPM evidence,
sealed-share outputs, and operator approvals in the manifest. Testnet can
rehearse the same contract with `REQUIRE_ON_CHAIN_LIFECYCLE=true` and
`REQUIRE_HARDWARE_TPM=true`.

The on-chain lifecycle contract fields are:

- `ceremony_method`: `submitPendingChange`
- `ceremony_function_selector`: `0x7d09426c`
- `ceremony_calldata_hash`: SHA-256 hash of the ceremony calldata
- `attestation_method`: `attestDkgReshare`
- `attestation_function_selector`: `0x36e34030`
- `attestation_calldata_hash`: SHA-256 hash of the attestation calldata
- `lifecycle_payload_hash`: SHA-256 of canonical
  `monarch-protocore-key-share-lifecycle-payload/v1` JSON

## DKG Re-Share Attestation Artifact

When the external roster-update ceremony produces the participant ML-DSA-65
public keys and the per-signer signature set for `attestDkgReshare`, render a
Desktop-importable artifact:

```bash
make render-dkg-reshare-attestation \
  DKG_RESHARE_INTENT_ID=7 \
  DKG_RESHARE_CONSENSUS_PUBLIC_KEYS_HEX=0x... \
  DKG_RESHARE_THRESHOLD_SIG_HEX=0x... \
  DKG_RESHARE_ATTESTATION=./dkg-reshare-attestation.json
```

The artifact is versioned as `monarch-dkg-reshare-attestation/v1`. The renderer
rejects zero or out-of-range intent ids, malformed key material, duplicate
participant pubkeys, signer counts outside `5..7`, public keys that are not
1952-byte ML-DSA-65 keys, and signature sets that are not one 3309-byte
ML-DSA-65 signature per signer. Monarch Desktop can import this JSON into the
Rotate operation, then submit the operator-signed
`attestDkgReshare(uint64,bytes,bytes)` tx.

## Operator handoff/import bundle

After a ceremony is validated, render one handoff bundle for each operator that
will import a new sealed share:

```bash
make render-key-share-handoff \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  OPERATOR_INDEX=2 \
  KEY_SHARE_HANDOFF=./operator-2-handoff.json
```

The handoff bundle is versioned as
`monarch-protocore-key-share-handoff/v1` and is validated by
[`scripts/validate-key-share-handoff.sh`](../scripts/validate-key-share-handoff.sh):

```bash
make validate-key-share-handoff \
  KEY_SHARE_HANDOFF=./operator-2-handoff.json \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

The validator first revalidates the ceremony manifest, checks the handoff's
ceremony manifest SHA-256, then proves the selected operator, TPM mode, PCR
quote/event-log hashes, sealed-share policy hash, DKG transcript hash, DKG
epoch, release digests, and import paths match the same operator row and
sealed-share output in the ceremony. The import contract pins the Protocore
service paths for `PROTOCORE_TPM_SEALED_BLS_SHARE_FILE` and
`PROTOCORE_DKG_TRANSCRIPT_FILE` and requires `PROTOCORE_REQUIRE_TPM_BINDING=true`.

When the staged files are available locally, run the same validation with local
file checks:

```bash
make validate-key-share-handoff \
  KEY_SHARE_HANDOFF=./operator-2-handoff.json \
  KEY_SHARE_CEREMONY=./key-share-ceremony.json \
  LOCAL_EVIDENCE_ROOT=/mnt/operator-node \
  VERIFY_LOCAL_FILES=true
```

`LOCAL_EVIDENCE_ROOT` maps `/var/lib/protocore/...` paths to the mounted or
copied evidence tree and verifies the imported TPM-sealed BLS share and DKG
transcript hashes before the node is allowed back into signing duty.

The validators prove the ceremony manifest is structurally safe, the operator
share was sealed to a TPM policy evidence bundle, and the handoff import bundle
is bound to that ceremony. They do not submit the final on-chain roster update
or perform DKG. Until that protocol path ships, signing-node recovery remains a
planned maintenance operation: generate a ceremony, seal the new shares to TPM
policy, validate the seal evidence plus canonical lifecycle hash, render and
validate the operator handoff, stage the resulting enrollment/key-share files,
and keep the node out of production signing until the chain registry reflects
the same cluster epoch.
