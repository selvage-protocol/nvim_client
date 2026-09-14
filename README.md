# Selvage for Neovim

A Neovim client for the [Selvage session protocol](https://github.com/selvage-protocol/specification):
share a link, come edit my code with me.

Status: **v1 in progress.** Hosting a file, joining by invite and bidirectional convergence are
the bar; see "What is not here yet" at the bottom for what is deliberately not done.

## Shape

The protocol's design splits a client into a **sync engine** (the CRDT, awareness, the wire) and
an **editor adapter** (buffers, paths, decorations). This repository is the adapter, and it does
not reimplement the engine in Lua:

| Part | Where | What it does |
|---|---|---|
| Sync engine + bridge | `vendor/engine`, `vendor/bridge` | Vendored from `vscode_client`. Pure TypeScript, no editor import. |
| Companion | `companion/` | A Node process holding the engine and the bridge, with a Neovim `EditorHost`. Speaks newline-delimited JSON over stdio. |
| Plugin | `lua/selvage/`, `plugin/` | Commands, `nvim_buf_attach`, `nvim_buf_set_text`, and the byte ↔ UTF-16 conversion. |

One Neovim instance runs one companion process, started on the first `:SelvageHost` or
`:SelvageJoin` and stopped on `:SelvageLeave`.

### The local IPC

The plugin and the companion speak **one JSON object per line** over the companion's stdin and
stdout, in both directions. `companion/ipc.ts` is the normative list; this is the summary.

**Every offset is a UTF-16 code unit**, counted in the document's text as Neovim holds it: the
buffer's lines joined by `\n` with a trailing `\n`. That is the unit `Y.Text` indices are counted
in and the unit `vendor/bridge/editing.ts` works in, so nothing is converted on the companion's
side; Lua converts from Neovim's byte positions, where the bytes are.

Line endings are not this adapter's business. A Neovim buffer holds lines and `fileformat`
turns them into CRLF at write time, so the companion always reports `\n`.

| Plugin → companion | |
|---|---|
| `host {serverUrl, displayName?}` | Mint a room and become its host. |
| `join {invite, displayName?}` | Join the room an invite link names. |
| `leave {}` | End the session; the process stays up. |
| `open {path, text}` | A buffer is now shared under `path` and holds `text`. |
| `close {path}` | Stop sharing it. |
| `change {path, start, end, text}` | A local edit: `[start, end)` became `text`. |
| `applied {id, ok}` | The answer to an `applyEdit`. |
| `saved {id, ok}` | The answer to a `save`. |
| `selection {path, anchor, head}` / `selectionCleared {}` | Where the caret is. |

| Companion → plugin | |
|---|---|
| `applyEdit {id, path, start, end, text, version}` | Replace `[start, end)` with `text`. Always the smallest range that gets there. |
| `save {id, path}` | Write the document. |
| `status {state, role?, roomId?, invite?, message?}` | `idle`, `connecting`, `hosting`, `joined` or `error`. |
| `report {report}` | The bridge's own report — the room's documents, peers, a divergence, a refusal. |
| `presence {cursors}` | The remote carets this replica can resolve. |

`version` is the one thing this IPC has that an in-process adapter does not need. A remote edit
is computed against the companion's mirror of the buffer and applied to the buffer itself, and
those are two processes: a keystroke made in between is a message still in the pipe, and the
range would land on text it was not computed from. So both sides count changes — a local edit
and an applied remote edit are one each — the `applyEdit` carries the count it was computed
against, and the plugin refuses one that does not match. The bridge then works the edit out
again from the mirror the local change has by that point reached.

Setting `SELVAGE_COMPANION_LOG` to a path makes the companion append every message it sends and
receives, with the time and the process id. The two sides of this IPC are two processes, so the
order the messages actually crossed in is the one thing a log of either end alone cannot show —
which is what a convergence question turns on.

### The vendored engine

`vendor/` is a copy, never edited here. Refresh it from a sibling `vscode_client` checkout:

```
scripts/sync-engine.sh [path-to-vscode_client]
```

The script copies `src/engine` and `src/bridge`, removes anything the source has retired, and
then diffs the result, so a run either brings `vendor/` into agreement or says what it could not.

## Commands

| | |
|---|---|
| `:SelvageHost <serverUrl>` | Mint a room on that server and share the current buffer. Every file buffer opened under the working directory afterwards joins the room too. |
| `:SelvageJoin <invite>` | Join the room the invite link names. The room's documents open as `selvage://<path>` buffers. |
| `:SelvageCopyInvite` | Put the invite on the clipboard and the unnamed register. |
| `:SelvageLeave` | Leave the session and stop the companion. |

`vim.g.selvage_display_name` is the name other participants see; it defaults to `$USER`.

The working directory is the grant: a host shares the file buffers under it, and nothing above
it. A guest's buffers are the room's, not files here — they have nowhere on disk to be written.

## Requirements

- Neovim 0.10 or newer (`vim.str_utfindex`/`vim.str_byteindex` with an encoding argument, with a
  fallback to the older two-value form).
- Node 22.18 or newer on `PATH`. The companion is TypeScript run directly by Node's own type
  stripping — there is no build step.
- A `selvaged` to connect to.

## Installing

Clone the repository and run `npm ci` inside it (the companion needs `yjs`, `y-protocols`,
`lib0` and `ws`), then point your plugin manager at the checkout:

```lua
-- lazy.nvim
{ dir = '/path/to/nvim_client' }

-- packadd
-- ln -s /path/to/nvim_client ~/.local/share/nvim/site/pack/selvage/opt/selvage
-- :packadd selvage
```

## Checks

```
npm run typecheck
npm test                    # the companion, against a replica with no server behind it
scripts/ci-local.sh all     # the same commands as .github/workflows/ci.yml, plus actionlint
scripts/test-lua.sh         # the offset arithmetic, in a real headless Neovim
scripts/e2e/run-two-instance.sh   # two real Neovims, a real companion each, a real selvaged
```

There is no `busted` and no plugin-test framework. Almost every rule worth testing — what enters
the replica, which change an editor is asked to apply, when a document is written — lives in the
companion, and is tested there against a fake editor. What is left on the Lua side is
translation plus one thing that is not: the conversion between Neovim's byte positions and the
protocol's UTF-16 code units. That one gets `test/lua/document.lua`, which runs in a real
headless Neovim against a real buffer and a real `on_bytes`, because a framework mocking those
would be testing the mock.

`scripts/e2e/run-two-instance.sh` is the proof end to end: two real headless Neovim processes,
each loading the real plugin and starting its own real companion, one hosting and one joining
over a real `selvaged`, converging on the same document and again after a real TCP-level blip
cuts the guest's connection. It is not part of `npm test` or CI — it needs a `nvim` and a built
`selvaged` — and `SELVAGE_E2E_RECONNECT=0` runs the convergence half alone.

## Licence

`MIT OR Apache-2.0`: `LICENSE-MIT` and `LICENSE-APACHE`.

## What is not here yet

- Remote cursors. The companion resolves them; nothing draws them as extmarks.
- Packaging and distribution beyond "clone it and `npm ci`".
- A keystroke made inside the one IPC round trip a remote edit is in flight for is superseded
  by the room rather than merged with it. The refusal above keeps the buffer from being
  mangled, which is the outcome worth preventing; merging the two would need the local edit to
  reach the replica before the remote one lands, and the bridge deliberately withholds a change
  while an apply is in flight.
- A room document whose text does not end in a newline gains one here. Neovim's line-array
  buffer cannot represent a missing final newline, so the Neovim side publishes the newline it
  has to add.
