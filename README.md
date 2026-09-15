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
| `rename {displayName}` | Change the name this connection is known by, mid-session. |
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
| `report {report}` | The bridge's own report — the room's documents, peers, a divergence, a refusal, or a connection the engine gave up re-establishing. |
| `presence {cursors}` | The remote carets this replica can resolve. |

A `disconnected` report is the end of the session: the engine reconnected on its own until it
ran out of attempts, so the plugin says so and lets the documents go. The companion process is
left running, and the next `:SelvageHost` or `:SelvageJoin` reuses it.

`version` is the one thing this IPC has that an in-process adapter does not need. A remote edit
is computed against the companion's mirror of the buffer and applied to the buffer itself, and
those are two processes: a keystroke made in between is a message still in the pipe, and the
range would land on text it was not computed from. So both sides count changes — a local edit
and an applied remote edit are one each — the `applyEdit` carries the count it was computed
against, and the plugin refuses one that does not match. A refusal is not the end of the edit:
the companion knows the mirror has taken a change the front-end counted after the range was
computed, so it offers the same edit again moved through that change, and the peer's text lands
where the buffer now has the text it was computed from. A keystroke that was in the pipe stays
where the user put it and reaches the room with the peer's; only a range whose local changes
overlap it cannot be moved, and for that one the room's text is what the buffer ends on.

Setting `SELVAGE_COMPANION_LOG` to a path makes the companion append every message it sends and
receives, with the time and the process id. The two sides of this IPC are two processes, so the
order the messages actually crossed in is the one thing a log of either end alone cannot show —
which is what a convergence question turns on.

### Remote cursors

A peer's caret is drawn as a block cursor on the cell **before** the offset the room carries: the
character the caret is *in front of*, not the one it has reached. The block is filled with the
colour the bridge derived for the peer, and the character under it stays readable through the
block instead of being covered by a name. Nothing is inserted, so the line keeps its width and the
block sits against the selection fill rather than one cell away from it. A row of its own above
the line was the first shape and reads the position wrong — a virtual line starts at the text
column, not the caret's. The start of a line has no cell before it, so a caret there keeps the
block on the cell it is on, where a bar at the line's start is drawn — the one place where a
caret in front of the first character and a caret on it draw the same block; an empty line has no
cell either, and the caret is then the single block in the empty cell. A peer who has selected
something gets a second extmark over `[anchor, head)`, whichever way the range was made, filled
with the peer's colour at the alpha the bridge computed; a collapsed selection draws nothing,
because the caret is already drawn. Both ends of both marks are the room's UTF-16 offsets
converted to byte columns, and the block covers a whole character — a wide or an astral one
included — rather than one byte of it.

**A client's own caret and the block the others see are two different shapes, and this is where
that shows.** Neovim's cursor rests *on* a character, and its column is that character's byte
index, so this client publishes the offset of the character the cursor is on — the same offset a
VS Code caret sitting *in front of* that character publishes. A block over a character and a bar
between two characters are not the same shape, so one of the two readings has to move, and this
renderer is the one that moves: a peer running Neovim is shown to everyone else with the block one
cell to the left of where that peer sees their own cursor. Shifting the publisher instead —
publishing the offset after the character the cursor is on — would put a Neovim peer's block under
their own cursor, but a caret and a selection's `head` are the same published number, so it would
move the end of the selection fill with it. What a Vim visual selection should publish as its
`head` — the last cell it covers, or the position after it — is a decision about the selection,
taken on its own, and not one a renderer gets to make. The feed is what the room counts, so it is
left alone.

The sign column carries the first two characters of a peer's name, coloured with the peer's own
highlight, so two peers whose names share an initial — `pi` and `pc` — are not identical signs. The
name is never drawn over the text: the gutter is where it lives, and two cells is all `sign_text`
takes, so a peer called `thisismylongusername` is `th` there and nothing more. `:SelvagePeers`
lists every peer the room names: the sign the gutter drew beside the whole display name and room
path for the peers this client holds a document for, and the name and role alone for the ones it
does not. It prints each sign in the very highlight that peer's caret and sign are drawn with,
because a list that explains the gutter has to agree with it cell for cell.
Nothing is put over the document when a peer moves; a name over their caret would cover a line
and a half of the buffer, which is worse than the two cells it explains. Every mark is cleared
and recreated when presence changes, and every one goes when the session ends.

This user's own caret is published from the events that move it — `CursorMoved`, `ModeChanged`,
entering a buffer — coalesced into one `selection` per 100 ms, and `selectionCleared` goes out
when there is no shared document in front of the user.

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
| `:SelvageHost [serverUrl]` | Mint a room on that server and share the current buffer. Every file buffer opened under the working directory afterwards joins the room too. With no argument the address is asked for, starting from the one last used, and `vim.g.selvage_server_url` answers it without asking. |
| `:SelvageJoin [invite]` | Join the room the invite link names. The first of the room's documents opens in the current window; any others become `selvage://<path>` buffers reachable with `:SelvageOpen`. With no argument the invite is asked for, starting from the clipboard when it holds a link that names a room. |
| `:SelvageDisplayName [name]` | Set the name other participants see: sent to the room now when a session is live, and used by the next host or join. With no name it reports the one in force, or says there is none. |
| `:SelvageOpen [path]` | Put one of the session's documents in the current window. With no argument it opens the only document, or asks which when there are several. `path` completes over the session's documents and may be the room path or any suffix of it: `:SelvageOpen README.md` reaches `workspace/README.md`. A host is refused: its own files are already in its buffer list. |
| `:SelvageCopyInvite` | Put the invite on the clipboard and the unnamed register. |
| `:SelvageLeave` | Leave the session and stop the companion. With no session it says so, rather than claiming to have left one. |
| `:SelvagePeers` | List the room's participants: each peer the room names, with the sign, whole display name and room path of the ones the gutter drew, in the colour their caret is drawn in. |

`:SelvageHost` and `:SelvageJoin` open a session and never end one. Hosting while hosting reaches
for the invite link instead of minting a second room, and a `:SelvageHost` while a guest or a
`:SelvageJoin` while in a session asks first, naming the room and what leaving it does, and
does nothing at all when the answer is no. A process with nobody to answer the question cannot be
asked, so it says what the command would have done and leaves the session alone.

The name other participants see is resolved when a session starts, in this order:
`vim.g.selvage_display_name`, then the `SELVAGE_DISPLAY_NAME` environment variable, then a
`vim.ui.input` prompt pre-filled with the login name. The pre-fill is a suggestion and nothing
more: a cancelled or emptied prompt refuses the session rather than seating a room under a name
nobody chose, and a process with nobody to ask refuses it too, saying how to configure one. The
login name is never a name of its own, and `require('selvage').display_name()` is `nil` until one
is set, so a script can tell that the next host or join will ask. `:SelvageDisplayName` sets the
global and the prompt remembers its answer there, so the same Neovim is not asked again. The name
rides in the `host`/`join` handshake, and a change made while a session is live is sent as
`session.rename`: the room answers with `peer.renamed`, and the sign and `:SelvagePeers` re-label
from that event, so the session goes on under the new name. Setting
`vim.g.selvage_display_name` directly mid-session does not send anything — Neovim has no
configuration-change event to watch — so only `:SelvageDisplayName` renames a live session; a
direct write is picked up by the next host or join.
A name is at most **32 UTF-16 code units** — the unit the protocol counts, so an astral
character costs two — and one over that is refused rather than shortened, because a room must
see the name its owner chose or none at all. A name typed at the prompt that is too long says
how long it is and asks again; one that arrived from the global or the environment has nobody
to re-ask, so the session is not started and the refusal names the setting to change.
`vim.g.selvage_open_on_join = false` keeps the join from changing the window, while still
opening the room's documents as buffers `:SelvageOpen` reaches.
`vim.g.selvage_auto_save = false` keeps the room's changes out of the files on disk: a host
writes a document the room changed by default, as the other client's `selvage.autoSave` does, and
a guest's buffers have nowhere to write either way. Both are read when a session starts, so a
change to either applies to the next host or join. `vim.g.selvage_server_url` is the address
`:SelvageHost` does not have to ask for.

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

With `nix`, `nix run .#nvim` gives a Neovim that already has the plugin on its runtime path and
Node on `PATH`, built from the flake. It sits beside the route above rather than replacing it:
same plugin, assembled from the store instead of from a checkout, and no `npm ci` needed for it.

## Checks

```
npm run typecheck
npm test                    # the companion, against a replica with no server behind it
scripts/ci-local.sh all     # the same commands as .github/workflows/ci.yml, plus actionlint
scripts/test-lua.sh         # the Lua side, in a real headless Neovim
scripts/e2e/run-two-instance.sh   # two real Neovims, a real companion each, a real selvaged

nix flake check             # the same three suites, in a sandbox
nix develop                 # Node 22 and a Neovim of a named version; no git hooks
```

`nix flake check` runs `typecheck`, the companion suite and the four files under `test/lua/` —
each in its own Neovim — with no network and no editor session. The two-instance proof is not
one of them: it needs a `selvaged` from the sibling `reference_server` checkout, which a
sandboxed build cannot see, so `SELVAGE_SELVAGED` is the seam. `nix run .#e2e` runs that proof
with the flake's Node and Neovim and whatever `SELVAGE_SELVAGED` names, from the checkout in the
working directory:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged nix run .#e2e
```

The two-instance proof (`scripts/e2e/run-two-instance.sh`, or `nix run .#e2e`) needs a built
`selvaged`, and finds one through `SELVAGE_SELVAGED` when that is
set and otherwise under `../reference_server/target/{debug,release}` — a path relative to this
checkout. From a git worktree under `.worktrees/` that sibling does not exist, so point it at
the main checkout's binary:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged scripts/e2e/run-two-instance.sh
```

There is no `busted` and no plugin-test framework. Almost every rule worth testing — what enters
the replica, which change an editor is asked to apply, when a document is written — lives in the
companion, and is tested there against a fake editor. `test/bridge.test.ts` takes the vendored
bridge directly — this adapter's `NvimEditorHost` in front of it, a fake replica behind — because
a guest document the room has not sent the text for is a case the companion's own deferral never
lets the bridge see, and the copy's rule for it is still worth pinning. What is left on the Lua
side is translation, the wiring around one session, and one rule of the editor's own: the
conversion between Neovim's byte positions and the protocol's UTF-16 code units. The first two get
`test/lua/document.lua` and `test/lua/session.lua`, which run in a real headless Neovim — the
first against a real buffer and a real `on_bytes`, because a framework mocking those would be
testing the mock; the second against a stubbed companion, because what it checks is the wiring
around a session — which buffers it shares, that it lets them go when the session ends, and
that a caret is published and a peer's caret and selection are drawn at the peer's position.
`test/lua/commands.lua` is the commands' own policy, through the real command definitions rather
than the Lua functions behind them: what `:SelvageHost`, `:SelvageJoin` and `:SelvageOpen` ask
for, refuse and never do. `test/lua/leave.lua` starts a real job, one that ignores its stdin, to
check what `:SelvageLeave` does to a companion that does not go on its own.

`scripts/e2e/run-two-instance.sh` is the proof end to end: two real headless Neovim processes,
each loading the real plugin and starting its own real companion, one hosting and one joining
over a real `selvaged`, converging on the same document and again after a real TCP-level blip
cuts the guest's connection. It is not part of `npm test` or CI — it needs a `nvim` and a built
`selvaged` — and `SELVAGE_E2E_RECONNECT=0` runs the convergence half alone. The guest reaches
the server through a relay the orchestrator can cut, and that holds the guest's own bytes back
by `SELVAGE_E2E_LAG_MS` (300 by default). On loopback the window between the handshake naming the
room's documents and their text arriving is about a millisecond, and the guest's driver makes a
keystroke in that window every run — which it can only do if the relay is what widens it.

## Licence

`MIT OR Apache-2.0`: `LICENSE-MIT` and `LICENSE-APACHE`.

## What is not here yet

- Packaging and distribution beyond "clone it and `npm ci`".
- An edit that lands on the same characters a peer's edit is landing on is superseded by the
  room rather than merged with it. A keystroke elsewhere in the document is moved rather than
  lost ("The local IPC" above); when the two are about the same text there is no position to
  move it to, and the room's text is what the buffer ends on. What it cannot do is mangle the
  buffer.
- A guest's buffer is created and shown as soon as the handshake names the room's documents,
  which is before the sync carrying their text. A keystroke made in that window is superseded by
  the room's text: the two are counted together once it lands, so nothing is mangled, but the
  room's text is what the buffer ends on and the keystroke is in neither the buffer nor the room.
- A join shows only the room's first document. A room with several leaves the rest as buffers
  for `:SelvageOpen` rather than opening a window each, and a document the host opens after the
  join gets a buffer but never takes the guest's window.
- A room document whose text does not end in a newline gains one here. Neovim's line-array
  buffer cannot represent a missing final newline, so the Neovim side publishes the newline it
  has to add.
- A peer's selection is the colour blended with the editor's background rather than a real
  translucent fill: a buffer highlight has no alpha, and a float would cost per-window
  bookkeeping on every scroll and edit for less than the block cursor gives at the same place.
- A host wiping a shared buffer releases the path in the room; a guest's `selvage://` buffers
  are not released that way, and neither is a path the room stops naming, because this
  client's document set only grows within a session.
