# Rejoin after a re-genesis (recover a node stuck on an old chain)

Testnet `chain-69420` is **wipe-and-re-genesis without notice** — the published
genesis hash can change. If your node was last synced **before** the latest
re-genesis, it is stuck on an **abandoned** chain: the old committee no longer
produces blocks, so your node sits at a frozen height, fails to find peers, or
quarantines. This guide gets you back onto the current chain.

> **Current chain (2026-06-20):** genesis
> `0x363fb60abd3f481e16fe74d6a3e5afd35d6d3ba9cc26e186f27d4195cd5a7359`,
> release **`protocore v0.1.72-testnet`** (mono-core `76803f49`). The
> authoritative pin is always
> [chain-registry / `chains/testnet-69420.toml`](https://github.com/monolythium/chain-registry/blob/master/chains/testnet-69420.toml)
> (`genesis_hash`, `release_tag`, `binary_sha`). Do not hard-code the values
> below — read the registry.

## 0. Why this is needed (and why it's safe)

A Monarch OS node **resolves the genesis dynamically from the chain-registry on
every fresh boot** — the image bakes *who to trust* (the registry), not *what to
run*. It will pick up a re-genesis automatically **once its locally-cached chain
data and resolved genesis are cleared**. The node will not silently switch
chains underneath committed data, which is exactly why a stale node stays stuck
until you clear it.

So "rejoin" = **clear the stale chain data → reboot → the node re-resolves the
current genesis and re-syncs.** No re-flash of the ISO is needed.

## 1. Confirm you're actually on the wrong chain

From the node (or any reachable RPC), compare your genesis to the registry pin:

```bash
curl -s http://127.0.0.1:8545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"web3_clientVersion","params":[]}'
# stuck node reports an OLD tag, e.g. protocore/v2/v0.1.6x-testnet+<old-commit>

curl -s http://127.0.0.1:8545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"lyth_syncStatus","params":[]}'
# stuck node: height frozen, peers low/zero, not advancing
```

If your genesis hash ≠ the registry's `genesis_hash`, or your height has been
frozen while [the public explorer](https://monoscan.io) keeps advancing, you're
on the old chain and need to rejoin.

## 2. ⚠️ Protect your operator key FIRST (committee operators only)

If you run a **bonded committee seat**, your ML-DSA operator key is what owns
that seat. **A full machine wipe destroys it** — and the seat with it.

- **Do NOT** use "Wipe node data & re-provision" if you want to keep your seat —
  that flow is for a clean slate and explicitly destroys the operator key.
- **DO** use **"Re-provision with existing keys"** (Monarch Desktop) — it
  re-installs the node from your **operator mnemonic**, re-deriving the *same*
  ML-DSA key, so the bonded seat carries over to the current chain.
- Either way: make sure you still have your **operator mnemonic** (the
  `PROTOCORE_OPERATOR_MNEMONIC_FILE` seed) backed up offline before you start.
  The post-wipe first boot re-derives the key from it.

A **plain full node** (no bonded seat) has nothing to preserve — skip to §3.

## 3a. Rejoin with Monarch Desktop (recommended)

1. Open Monarch Desktop and select the stuck node.
2. **Committee operator:** Operations → **Re-provision with existing keys**.
   Supply your operator mnemonic when prompted. This clears the stale chain
   data + resolved genesis, re-derives your key, and rejoins the current chain.
3. **Plain full node:** Operations → **Wipe node data & re-provision** (no seat
   to lose), or the in-place chain-data wipe. The node clears its ephemeral
   chain DB + resolved genesis and reboots.
4. Wait for status to return to **ready / synced**. Monarch bootstraps the node
   automatically after the wipe.

The Desktop also keeps `protocore` itself current: after rejoining, use
**Apply** to move to `v0.1.72-testnet` if you aren't already on it (you do **not**
re-flash the ISO — see
[`upgrade-and-storage.md`](./upgrade-and-storage.md#updating-protocore-you-do-not-re-flash-the-iso)).

## 3b. Rejoin a manual / non-Monarch node

If you run `protocore` directly (not via Monarch OS):

```bash
# 1. Stop the node.
sudo systemctl stop protocore.service

# 2. Back up your operator key/mnemonic if you have a bonded seat (location is
#    your setup's; if it lives under the data home, copy it out NOW).

# 3. Clear the stale chain data + cached genesis (the home from your ExecStart,
#    commonly /var/lib/protocore). This removes the abandoned chain's DB and the
#    locally-resolved old genesis so the node re-resolves the current one.
sudo rm -rf /var/lib/protocore/*        # adjust to your --home path

# 4. Make sure you're on the current release (verify against the registry pin).
#    Pull the signed release from GitHub and verify its sha256 before installing:
URL=https://github.com/monolythium/protocore/releases/download/v0.1.72-testnet/protocore-v0.1.72-testnet-x86_64-linux.tar.gz
curl -fsSL -o /tmp/p71.tar.gz "$URL"
# compare against release_tarball_sha256 in chain-registry/chains/testnet-69420.toml
sha256sum /tmp/p71.tar.gz
tar xzf /tmp/p71.tar.gz -C /tmp
sudo install -m 0755 /tmp/protocore /usr/local/bin/protocore

# 5. Restart. The node re-resolves the current genesis from the chain-registry
#    and fast-syncs from a checkpoint.
sudo systemctl restart protocore.service
```

If you want the node to **refuse to boot** rather than ever fall back to a stale
baked genesis, set `PROTOCORE_GENESIS_FALLBACK=fail`.

## 4. Verify you're back on the current chain

```bash
curl -s http://127.0.0.1:8545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"web3_clientVersion","params":[]}'
# expect: protocore/v2/v0.1.72-testnet+76803f49   (match the registry release_tag)

curl -s http://127.0.0.1:8545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"lyth_syncStatus","params":[]}'
# height climbing toward the live tip; lag shrinking; state -> "synced"
```

Cross-check your genesis hash equals the registry's `genesis_hash`
(`0x363fb60a…`) and your height tracks [monoscan.io](https://monoscan.io). Once
`state` is `synced` with `lag` ~0 you're rejoined. A committee operator should
also confirm its seat is active again (the seat carries over because the key was
re-derived from your mnemonic).

## Notes

- **Data loss:** clearing the chain data discards the *abandoned* chain's local
  state only. There is nothing of value to keep on a chain that was wiped — and
  testnet carries no value by design.
- **Don't store value on testnet** — it is reset without notice.
- The only thing you must never lose is your **operator mnemonic**; the key
  (and seat) are recoverable from it, nothing else is.
