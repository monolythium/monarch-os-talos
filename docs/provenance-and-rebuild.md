# Provenance and Rebuild Verification

Each release artifact must be traceable back to the Monarch OS workflow,
release metadata, source commits, and artifact hashes. This document covers the
operator-side checks available today and the limits of the current preview.

References:

- GitHub offline attestation verification:
  <https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/verifying-attestations-offline>
- GitHub CLI attestation verification:
  <https://cli.github.com/manual/gh_attestation_verify>

## Verify downloaded release artifacts

Download a release into a clean directory:

```bash
TAG=<release-tag>
ARTIFACT_DIR="$PWD/monarch-release-$TAG"
mkdir -p "$ARTIFACT_DIR"

gh release download "$TAG" \
  --repo monolythium/monarch-os-talos \
  --dir "$ARTIFACT_DIR"
```

Then run the provenance verifier:

```bash
OUT_DIR="$ARTIFACT_DIR" make verify-provenance
```

The default check validates:

- `*.release.json` schema and checksum;
- every artifact hash listed in release metadata;
- release metadata consistency for artifact names and digests.

## Verify cosign signatures

Release artifacts are signed by the Monarch OS GitHub Actions workflow. To
verify the adjacent `.sig` and `.pem` files:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_COSIGN_SIGNATURES=true \
make verify-provenance
```

The verifier accepts PEM certificates stored either as normal PEM text or as the
base64-encoded PEM files used by the current workflow. It enforces this
certificate identity pattern:

```text
https://github.com/monolythium/monarch-os-talos/.github/workflows/build.yml@refs/tags/.*
```

## Verify GitHub artifact attestations

For online verification through the GitHub API:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_GITHUB_ATTESTATIONS=true \
ATTESTATION_MODE=online \
make verify-provenance
```

The script verifies SLSA provenance attestations for every metadata-listed
artifact plus the release metadata file itself. When
`REQUIRE_EXTENSION_REBUILD_WITNESS=true`, it also verifies the signed and
attested extension rebuild witness.

## Prepare offline attestation material

On an online machine, download attestation bundles and a trusted root:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_GITHUB_ATTESTATIONS=true \
ATTESTATION_MODE=download \
ATTESTATION_BUNDLE_DIR="$ARTIFACT_DIR/attestations" \
TRUSTED_ROOT_FILE="$ARTIFACT_DIR/attestations/trusted_root.jsonl" \
make verify-provenance
```

Move the release artifacts, `attestations/sha256:<digest>.jsonl` files, and
`trusted_root.jsonl` to the offline environment.

Then verify without network access:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_GITHUB_ATTESTATIONS=true \
ATTESTATION_MODE=offline \
ATTESTATION_BUNDLE_DIR="$ARTIFACT_DIR/attestations" \
TRUSTED_ROOT_FILE="$ARTIFACT_DIR/attestations/trusted_root.jsonl" \
make verify-provenance
```

Generate a fresh trusted root whenever importing new signed material into the
offline environment. GitHub documents that trusted root material does not carry
a built-in expiration date, so it should be refreshed as part of each release
intake.

## Check source lineage

To require the local checkout to be exactly the Monarch OS commit recorded in
release metadata:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REQUIRE_SOURCE_MATCH=true \
make verify-provenance
```

To also require a sibling `mono-core` checkout to match the metadata:

```bash
OUT_DIR="$ARTIFACT_DIR" \
MONO_CORE_DIR=../mono-core \
REQUIRE_SOURCE_MATCH=true \
REQUIRE_MONO_CORE_SOURCE_MATCH=true \
make verify-provenance
```

Dirty source checkouts fail unless `ALLOW_DIRTY_SOURCE=true` is set.

## Rebuild and compare

The release workflow now builds a deterministic extension rebuild witness before
signing artifacts:

```bash
OUT_DIR="$ARTIFACT_DIR" \
PROTOCORE_BINARY=/path/to/release/protocore \
make extension-rebuild-witness
```

The witness rebuilds only the `monarch-protocore` Talos extension from the
release metadata, compares the rebuilt tarball hash with the metadata-listed
hash, and writes `monarch-protocore-<arch>.rebuild-witness.json` plus a
`.sha256`. Testnet promotion requires this witness and verifies its checksum,
cosign signature, GitHub SLSA attestation, metadata digest, extension digest,
extension size, and `protocore` binary digest.

The verifier can run a clean rebuild into a separate output directory and compare
any reproduced artifacts against the release metadata hashes:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REBUILD_OUT_DIR="$PWD/_out/reproducible-release" \
PROTOCORE_BINARY=/path/to/release/protocore \
RUN_REBUILD=true \
REQUIRE_REBUILD_ALL=true \
make verify-provenance
```

For a publishable full-release rebuild proof, generate a witness before signing:

```bash
OUT_DIR="$ARTIFACT_DIR" \
REBUILD_OUT_DIR="$PWD/_out/reproducible-release" \
PROTOCORE_BINARY=/path/to/release/protocore \
make release-rebuild-witness
```

This writes `monarch-os-talos-<talos-version>-<arch>.rebuild-witness.json` plus
a `.sha256`. The witness records the release metadata digest, rebuild inputs,
rebuilt metadata digest, and one hash/size comparison for every artifact listed
in the release metadata. `REQUIRE_RELEASE_REBUILD_WITNESS=true` makes
`verify-provenance` require the witness, verify its checksum, bind it to the
current metadata digest, and compare every witness artifact entry back to release
metadata. Mainnet channel policy requires this signed/attested witness in
addition to the live `RUN_REBUILD=true` clean rebuild check.

This path is intentionally opt-in because it requires the full build toolchain:
Docker, the Talos imager, `syft`, `xz`, and the exact `protocore` binary input.
It does not compare the rebuilt `*.release.json` byte-for-byte because metadata
contains a generation timestamp. It compares artifact hashes listed in the
release metadata.

Preview limitation: cosign signature verification, GitHub SLSA attestation
verification, source-lineage checks, offline attestation-bundle export, and the
deterministic extension rebuild witness are now part of testnet channel
promotion. Full ISO/raw deterministic rebuild comparison now has a publishable
witness format and is enforced by the disabled mainnet policy, but testnet keeps
that expensive full rebuild gate opt-in.
