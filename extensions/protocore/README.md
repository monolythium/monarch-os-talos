# protocore — Talos system extension

Talos system extension that ships the `protocore` node binary, service definition, entrypoint, and on-disk layout under `/var/lib/protocore`.

## Status

Local tarball build is wired through `scripts/build-protocore-extension.sh` and `make build`. Signed publishing is not wired yet.

## What this extension provides

- The `protocore` binary built from the local `mono-core` repository unless `PROTOCORE_BINARY` is provided.
- A Talos service definition that supervises `protocore`.
- A static entrypoint wrapper that waits for required service config before starting.
- Optional fail-closed binary verification through `protocore release verify` when a release digest is provisioned.
- Persistent state under `/var/lib/protocore`, mounted as a writable Talos system path.
- Optional baked testnet genesis staging when `GENESIS_TOML=/path/to/genesis.toml` is supplied at build time.

## Building

```bash
make extension
```

The build writes a deterministic tarball and SHA-256 file to `_out/`.

Still missing for the final product:

- signed extension publishing
- SBOM/provenance publication and enforcement outside the local entrypoint
- release-channel pinning
- production network policy
- final secret injection flow
