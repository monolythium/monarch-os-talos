# monarch-os-talos

Monarch OS — Talos-based signed immutable OS for Monolythium v2 validator nodes.

> Part of the [Monolythium](https://monolythium.com) ecosystem — a sovereign Layer-1 for finality-first apps.

---

## What this is

Monarch OS is a custom Talos Linux distribution packaged as a signed, reproducible ISO for Monolythium v2 validator nodes. The image is immutable, API-driven, and ships with the `protocore` validator binary and the `monarch` operator CLI as first-class system extensions. It is the only supported production runtime for Monolythium v2 validators.

There is no friendly-binary path. Tier-1 exchanges and validator operators either run the signed ISO on bare metal or they do not run a validator. This is a deliberate scope choice — the precognitive operator experience lives at the OS layer, and that experience is the moat.

## Who this is for

- Validator operators running Monolythium v2 on production bare metal.
- Tier-1 exchanges and managed infra providers integrating Monolythium v2 at the substrate level.

This image is **not** for home labs, development workstations, or Cloud-virtualized testnet infrastructure. Use plain Linux with the binary release for those.

## Install

Signed ISO available on the private release track. Public release pending — no published artifacts yet.

When the release track ships:

1. Download the latest signed `monarch-os-talos-<version>.iso` from the private release feed.
2. Verify the cosign signature against the published Monarch OS public key.
3. Boot the target bare-metal machine from the ISO and follow the first-boot zero-touch provisioning flow.

## Getting started

Once a release is published, an operator runs:

```bash
# Documentation-only at this stage. The pipeline that produces this image is tracked
# in the internal Stage 2 plan.
talosctl cluster create \
  --install-image ghcr.io/monolythium-vision/monarch-os-talos:latest \
  --name monolythium-validator
```

Until the build pipeline lands, the commands above are documentation only — the container image and ISO do not yet exist.

## Documentation

Operator guides will be published at [docs.monolythium.com](https://docs.monolythium.com) once the first signed release ships.

## Building from source

```bash
make build
```

This builds local test boot artifacts at:

```bash
_out/monarch-os-talos-v1.13.0-amd64.iso
_out/monarch-os-talos-v1.13.0-amd64.raw
```

The current build includes the `protocore` binary from `../mono-core` as a Talos system extension. The service waits for a matching Talos `ExtensionServiceConfig` before starting, then initializes a testnet home under `/var/lib/protocore`, stages the baked testnet `genesis.toml`, and starts `protocore`.

Example extension-service configuration:

```bash
examples/protocore-extension-service-config.yaml
```

The OS image does not ship operator secrets or a default keystore passphrase.

The public release pipeline is still expected to add registry publishing, release signing, provenance, and release-channel promotion.

Requirements (planned):
- Docker or compatible OCI runtime.
- `talosctl` CLI.
- `cosign` for signature verification.

## Contributing

This repository is private and accepts contributions from the Monolythium core team only. External contribution policy will be published once the project is public.

## Security

Found a vulnerability? Please **do not open a public issue**. Email security@monolythium.com instead. Coordinated disclosure is required for any finding affecting a signed release.

## License

Released under the Apache License, Version 2.0. See [LICENSE](./LICENSE) for the full text.
