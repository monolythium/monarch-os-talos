# monarch-cli — Talos system extension

Talos system extension that ships the `monarch` operator CLI for on-node administration. Operators run `monarch` through approved Talos service/debug flows, or use Monarch Desktop from the operator workstation over Talos API mTLS plus the operator-network data plane.

## Status

Placeholder. The extension is not yet implemented. The CLI itself is developed elsewhere in the workspace; this extension only packages the released binary into Talos.

## What this extension provides (planned)

- The `monarch` CLI binary, statically linked.
- Shell completion files (where applicable).
- A Talos `talosctl` integration so operators can drop into a `monarch` session via the standard Talos serial console flow.

## What this extension does NOT provide

- A graphical interface. Talos has no traditional userspace; the GUI lives in `monarch-desktop`, which runs on the operator's workstation, not on the operator node.
- An SSH server. Monarch OS production control is through Talos API mTLS, not SSH.

## Building

Not wired yet. Same OCI-image pattern as the `protocore` extension — see that README for the upstream Talos reference.
