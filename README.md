# monarch-os-talos

Monarch OS — Talos-based signed immutable OS for Monolythium v4.0 operator nodes.

> Part of the [Monolythium](https://monolythium.com) ecosystem — a sovereign Layer-1 for autonomous-economy settlement.

---

## What this is

Monarch OS is a custom Talos Linux distribution packaged as a signed, reproducible ISO for Monolythium v4.0 operator nodes. The image is immutable, API-driven, and ships with the `protocore` node binary and the `monarch` operator CLI as first-class system extensions. It is the intended production runtime for Monolythium v4.0 operator infrastructure.

There is no friendly-binary path for production operator seats. Tier-1 exchanges and node operators run the signed ISO on bare metal, with operations driven through Monarch Desktop over authenticated control and data-plane channels.

## Who this is for

- Node operators running Monolythium v4.0 on production bare metal.
- Tier-1 exchanges and managed infra providers integrating Monolythium v4.0 at the substrate level.

This image is **not** for home labs, development workstations, or Cloud-virtualized testnet infrastructure. Use plain Linux with the binary release for those.

## Install

Signed ISO available on the private release track once release automation lands. Public release pending — no published signed artifacts yet.

When the release track ships:

1. Download the latest signed `monarch-os-talos-<version>.iso` from the private release feed.
2. Verify the cosign signature against the published Monarch OS public key.
3. Boot the target bare-metal machine from the ISO and follow the first-boot zero-touch provisioning flow.

## Getting started

For local test builds, run:

```bash
make build
```

This produces a local ISO and raw image under `_out/`.

Once a signed release channel exists, an operator flow will look like:

```bash
talosctl cluster create \
  --install-image ghcr.io/monolythium-vision/monarch-os-talos:latest \
  --name monolythium-operator
```

The published registry image, release signing, provenance, and channel promotion still need to be completed before this is the canonical production path.

## Documentation

Operator guides will be published at [docs.monolythium.com](https://docs.monolythium.com) once the first signed release ships.

Local docs:

- [Monarch Desktop connectivity](./docs/monarch-desktop-connectivity.md) — how the desktop app connects to a Monarch OS node over Talos API mTLS plus Protocore RPC.
- [Final product readiness](./docs/final-product-readiness.md) — what is still missing before Monarch OS plus Monarch Desktop can be treated as a production operator product.

## Building from source

```bash
make build
```

This builds local test boot artifacts at:

```bash
_out/monarch-os-talos-v1.13.0-amd64.iso
_out/monarch-os-talos-v1.13.0-amd64.raw
_out/monarch-os-talos-v1.13.0-amd64.release.json
```

The current build includes the `protocore` binary from `../mono-core` as a Talos system extension. The service waits for a matching Talos `ExtensionServiceConfig` before starting, then initializes a testnet home under `/var/lib/protocore`, stages the baked testnet `genesis.toml`, and starts `protocore`.

Example extension-service configuration:

```bash
examples/protocore-extension-service-config.yaml
```

The OS image does not ship operator secrets or a default keystore passphrase.

The public release pipeline is still expected to add registry publishing, release signing, provenance, and release-channel promotion.

Local QEMU smoke test:

```bash
make smoke-qemu
```

This boots the raw image, forwards the Talos API to `127.0.0.1:50000`, confirms QEMU holds the image through the boot window, then shuts QEMU down and writes `_out/smoke-qemu/result.json`.

Set `REQUIRE_TALOSCTL_PROBE=true` to require an insecure `talosctl version` probe during the smoke test. The default mode only checks that QEMU can boot and hold the image because a configured Talos API requires the machine config/talosconfig flow.

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
