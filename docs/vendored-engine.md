# The vendored engine

`vendor/` is a copy, never edited here. Refresh it with
[`scripts/sync-engine.sh`](../scripts/sync-engine.sh) from a sibling `vscode_client` checkout:

```
scripts/sync-engine.sh [path-to-vscode_client]
```

The script copies `src/engine` and `src/bridge`, removes anything the source has retired, and then
diffs the result, so a run either brings `vendor/` into agreement or says what it could not.

The copy is `vscode_client`'s `src/engine` and `src/bridge` at `c45b26b`: a reader can name the
revision this tree carries without the commit that synced it, and re-syncing against a later
checkout is what moves it. That revision is the tip of that repository's `fix/listing-walk` branch,
which is where `bridge/listing-walk.ts` is authored and from which it arrives here; re-syncing
against `main` until the branch lands describes the revision before it.

The copy carries the session layer with the rest of the engine — `vendor/engine/sealed.ts`
is `CANONICAL.md` §6.1's bytes, `vendor/engine/peer.ts` is `PROTOCOL.md` §13,
`vendor/engine/host.ts` is §7.1's producer half, the room state the host key seals and the rule for
each state that goes out, and `vendor/engine/crypto.ts` is the crypto seam a caller supplies,
because a page has neither `node:crypto` nor a synchronous one.
