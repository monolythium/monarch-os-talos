# monarch-cli — Talos system extension

Talos system extension that ships the `monarch` operator CLI for on-node administration. Operators run `monarch` directly over the Talos serial console, or remotely via the Monarch Desktop application connecting over mTLS+WireGuard.

## Status

Placeholder. The extension is not yet implemented. The CLI itself is developed elsewhere in the workspace; this extension only packages the released binary into Talos.

## What this extension provides (planned)

- The `monarch` CLI binary, statically linked.
- Shell completion files (where applicable).
- A Talos `talosctl` integration so operators can drop into a `monarch` session via the standard Talos serial console flow.

## What this extension does NOT provide

- A graphical interface. Talos has no traditional userspace; the GUI lives in `monarch-desktop`, which runs on the operator's workstation, not on the validator node.
- A SSH server. SSH is provided by a separate extension and is bound to operator keys only.

## Building

Not wired yet. Same OCI-image pattern as the `protocore` extension — see that README for the upstream Talos reference.
