# protocore — Talos system extension

Talos system extension that ships the `protocore` validator binary, its systemd unit, and the on-disk layout under `/var/lib/protocore`.

## Status

Placeholder. The extension is not yet implemented. The build pipeline that produces this extension's OCI image is part of the Stage 2 work in the internal plan.

## What this extension provides (planned)

- The `protocore` binary released from the `mono-core` repository.
- A Talos service definition that supervises `protocore` with the validator-tier configuration.
- Persistent state under `/var/lib/protocore`, mounted as a writable Talos system path.
- Firewall rules locking validator P2P (`29898/tcp`) and RPC (`8545/tcp`) to the operator-defined CIDR.

## Building

Not wired yet. Talos system extensions are OCI images built from a Dockerfile that copies the binary plus a manifest into a scratch base. See upstream [Talos system extensions documentation](https://www.talos.dev/v1.8/talos-guides/configuration/system-extensions/) for the canonical pattern.
