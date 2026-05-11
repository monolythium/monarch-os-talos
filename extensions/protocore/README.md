# protocore — Talos system extension

Talos system extension that ships the `protocore` node binary, service definition, entrypoint, and on-disk layout under `/var/lib/protocore`.

## Status

Local tarball build is wired through `scripts/build-protocore-extension.sh` and `make build`. Signed publishing is not wired yet.

## What this extension provides

- The `protocore` binary built from the local `mono-core` repository unless `PROTOCORE_BINARY` is provided.
- A Talos service definition that supervises `protocore`.
- A static entrypoint wrapper that waits for required service config before starting.
- Persistent state under `/var/lib/protocore`, mounted as a writable Talos system path.
- Optional baked testnet genesis staging from `mono-core/artifacts/cutover-2026-05-10/genesis.toml`.

## Building

```bash
make extension
```

The build writes a deterministic tarball and SHA-256 file to `_out/`.

Still missing for the final product:

- signed extension publishing
- SBOM/provenance metadata
- release-channel pinning
- production network policy
- final secret injection flow
