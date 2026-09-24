# Selvage for Neovim

A Neovim client for the [Selvage session protocol](https://github.com/selvage-protocol/specification):
share a link, come edit my code with me.

Status: v1 in progress. Hosting, joining by invite and editing together work today; the gaps
are listed under "What is not here yet".

## Get it working

You need:

- Neovim 0.12 or newer.
- A `git` executable: the plugin managers below fetch the repository with it.
- Node 22.18 or newer on `PATH`, with the companion's dependencies installed by `npm ci` in the
  plugin directory. A guest needs both too: the sync engine runs at each end, so joining takes the
  same Node and the same install as hosting.
- A `selvaged` to connect to. Start one and note the address it prints; a guest needs the invite
  link the host sends and nothing else from the server side.

Install with your plugin manager. The one built into Neovim 0.12 and newer needs no third-party
plugin and no install hook:

```lua
-- vim.pack (Neovim 0.12+), following the 0.4.x range; 0.4.2 is current
vim.pack.add({
  {
    src = 'https://github.com/selvage-protocol/nvim_client',
    version = vim.version.range('0.4'),
  },
})
```

Run `npm ci` in the plugin directory once; `vim.pack.update()` keeps it current after that.

Any other manager works. These run `npm ci` for you:

```lua
-- lazy.nvim
{ 'selvage-protocol/nvim_client', build = 'npm ci' }
```

```vim
" vim-plug
Plug 'selvage-protocol/nvim_client', { 'do': 'npm ci' }
```

```lua
-- packer (archived, kept for its form)
use { 'selvage-protocol/nvim_client', run = 'npm ci' }
```

Or clone the repository, run `npm ci` inside it, and point your plugin manager at the checkout:

```lua
-- lazy.nvim
{ dir = '/path/to/nvim_client' }

-- packadd
-- ln -s /path/to/nvim_client ~/.local/share/nvim/site/pack/selvage/opt/selvage
-- :packadd selvage
```

### With Nix

`nix run github:selvage-protocol/nvim_client#nvim` gives a Neovim with the plugin on its runtime
path and Node on `PATH`; `nix run .#nvim` does the same from a checkout. Nothing here runs `npm ci`:
the companion's dependencies are built from `package-lock.json`, and the plugin declares the Node it
needs.

In Home Manager, add the flake as an input and take the plugin straight from it:

```nix
# flake.nix
inputs.nvim-client.url = "github:selvage-protocol/nvim_client";
```

```nix
programs.neovim.plugins = [
  inputs.nvim-client.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

`overlays.default` gives the same plugin the name `pkgs.vimPlugins.selvage`. An overlay belongs
wherever the package set is built, which on NixOS is `nixpkgs.overlays`:

```nix
nixpkgs.overlays = [ inputs.nvim-client.overlays.default ];

programs.neovim.plugins = [ pkgs.vimPlugins.selvage ];
```

A Neovim you wrap yourself takes it in `configure.packages`:

```nix
environment.systemPackages = [
  (pkgs.neovim.override {
    configure.packages.selvage.start = [
      inputs.nvim-client.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
  })
];
```

A wrapper built with runtime-dependency wrapping puts the plugin's `nodejs_22` on the wrapped
Neovim's `PATH`, which is why none of this asks for a Node of your own. One built without it leaves
the companion nowhere to find Node, which says so (`node is not on PATH`); add `pkgs.nodejs_22`
alongside the plugin, the way that wrapper takes packages.

There is no `setup()` call.

A first session:

1. Start `selvaged` and note the address it prints.
2. `:SelvageHost` shares the current buffer. Answer its one question with that address (the host
   alone is enough, since `selvage-demo.dontblameme.dev` means `wss://selvage-demo.dontblameme.dev`), and
   the invite link goes on the clipboard as the room opens.
3. Send the link. The other person runs `:SelvageJoin <invite>`, which joins the room and opens its
   first document.
4. Both edit the same file, and each sees the other's text and caret as they type.

## Shape

The protocol's design splits a client into a sync engine (the CRDT, awareness, the wire) and an
editor adapter (buffers, paths, decorations). This repository is the adapter:

| Part | Where | What it does |
|---|---|---|
| Sync engine + bridge | `vendor/engine`, `vendor/bridge` | Vendored from `vscode_client`. Pure TypeScript, no editor import. |
| Companion | `companion/` | A Node process holding the engine and the bridge, with a Neovim `EditorHost`. Speaks newline-delimited JSON over stdio. |
| Plugin | `lua/selvage/`, `plugin/` | Commands, `nvim_buf_attach`, `nvim_buf_set_text`, and the byte ↔ UTF-16 conversion. |

One Neovim instance runs one companion process, started on the first `:SelvageHost` or
`:SelvageJoin` and stopped on `:SelvageLeave`.

### The local IPC

The plugin and the companion speak one JSON object per line over the companion's stdin and
stdout, in both directions. `companion/ipc.ts` is the normative list; this is the summary.

Every offset is a UTF-16 code unit, counted in the document's text as Neovim holds it: the
buffer's lines joined by `\n`, one newline between lines and none after the last. A buffer whose
last line is empty therefore ends in a newline, and a buffer of one empty line is the empty
string. That text is byte for byte what the room holds, and it is the unit `Y.Text` indices are
counted in and the unit `vendor/bridge/editing.ts` works in, so nothing is converted on the
companion's side; Lua converts from Neovim's byte positions, where the bytes are.

Line endings are not this adapter's business. A Neovim buffer holds lines and `fileformat` turns
them into CRLF at write time, so the companion always reports `\n`.

| Plugin → companion | |
|---|---|
| `host {serverUrl, displayName?, autoSave?, root?}` | Mint a room and become its host. Refused while a session is live: see `refused`. `root` is the folder the session shares: the room's listing is sealed from it when the room is minted, the host republishes it when the folder changes, and serves a path from it when a peer asks. |
| `join {invite, displayName?, autoSave?}` | Join the room an invite link names. Refused while a session is live: see `refused`. |
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
| `status {state, role?, roomId?, invite?, message?, code?}` | `idle`, `connecting`, `hosting`, `joined` or `error`. `role` is the role the room's state assigns this connection (`§13.4`) as far as the session can read it at that moment, which at the seat is the `guest` a key no state has committed yet is read as. `code` is the protocol's own code for a failure the server named, or the one refusal this process decides itself: `invite_refused` for an invite whose fragment it will not read, made before it dials anything. It is absent for a failure nothing named. |
| `refused {what, roomId}` | A `host` or `join` this process did not carry out, because a session is live and ending it is the front-end's to ask about; the room named is the one still standing. |
| `report {report}` | The bridge's own report: the room's documents, its grant (with `unsafe` naming the listed paths the grant's rules would never let a host publish, which a guest's mirror does not put on disk), peers, a divergence, a refusal, a dropped socket being retried (`reconnecting`), or a connection the engine gave up re-establishing — and one of this process's own, `role {role}`, sent when the room's state gives this connection a different role than the seat's status carried. |
| `presence {cursors}` | The remote carets this replica can resolve. |

A `reconnecting` report is a dropped socket the engine is re-dialling (`§9.1`): the row says so
while it lasts, and the re-seat's own documents and peers reports are what end it.

A `disconnected` report is the end of the session. The engine reconnected on its own until it ran
out of attempts — except for a host, which this client never re-dials, because `§9.1`'s host return
is a fresh room state signed by the host key and this client writes no host store — so the plugin
says which of the two it was and lets the documents go. The companion process is left running, and
the next `:SelvageHost` or `:SelvageJoin` reuses it.

`version` is the document version the range was computed against, counted on each side. A remote
edit is computed against the companion's mirror of the buffer and applied to the buffer itself, and
those are two processes: a keystroke made in between is a message still in the pipe, so the range
would land on text it was not computed from. Both sides therefore count changes, one for a local
edit and one for an applied remote edit; the `applyEdit` carries the count it was computed
against, and the plugin refuses one that does not match. A refusal does not end the edit: the
companion knows the mirror has taken a change the front-end counted after the range was computed,
so it offers the same edit again moved through that change, and the peer's text lands where the
buffer now has the text it was computed from. A keystroke that was in the pipe stays where the
user put it; only a range whose local changes overlap it cannot be moved, and for that one the
room's text is what the buffer ends on.

Setting `SELVAGE_COMPANION_LOG` to a path makes the companion append every message it sends and
receives, with the time and the process id. The plugin and the companion are two processes, so one
end's log cannot show the order the messages crossed in. An invite's fragment is not in
the file: `§5.1` has the room key and the host key travel there, a client **MUST NOT** log them, and
the invite is written without it — the address and the token stay, which is what the log is for.
A line the companion refuses is said on stderr the same way: the warning names the member that was
wrong through the same redaction, rather than quoting the line it read, so the fragment has no more
of a way out there than into the log.

### Remote cursors

A peer's caret is drawn as a block cursor on the cell before the offset the room carries: the
character the caret is in front of, not the one it has reached. The block is filled with the
colour the bridge derived for the peer, and the character under it stays readable through the
block instead of being covered by a name. Nothing is inserted, so the line keeps its width and the
block sits against the selection fill. The start of a line has no cell before it, so a caret there
keeps the block on the cell it is on, where a bar at the line's start is drawn. That is the one
place where a caret in front of the first character and a caret on it draw the same block. An
empty line has no cell either, and the caret is then the single block in the empty cell. A peer
who has selected something gets a second extmark over `[anchor, head)`, whichever way the range
was made, filled with the peer's colour at the alpha the bridge computed; a collapsed selection
draws nothing, because the caret is already drawn. Both ends of both marks are the room's UTF-16
offsets converted to byte columns, and the block covers a whole character, a wide or an astral one
included, rather than one byte of it.

A client's own caret and the block the others see are two different shapes. Neovim's cursor rests
on a character and its column is that character's byte index, so this client publishes the offset
of the character the cursor is on, the same offset a VS Code caret sitting in front of that
character publishes. A block over a character and a bar between two characters are not the same
shape, so a peer running Neovim is shown to everyone else with the block one cell to the left of
where that peer sees their own cursor.

The sign column carries the first two characters of a peer's name, coloured with the peer's own
highlight, so two peers whose names share an initial, `pi` and `pc`, are not identical signs. Two
cells is all `sign_text` takes, so a peer called `thisismylongusername` is `th` there and the
gutter cannot say who that is: the name reads from `vim.g.selvage_file_peers` and from
`:SelvagePeers` (below), which lists every peer the room names: the sign the gutter drew beside the
whole display name and room path for the peers this client holds a document for, and the name and
role alone for the ones it does not. It prints each sign in the very highlight that peer's caret
and sign are drawn with. Nothing is put over the document when a peer moves. Every mark is cleared
and recreated when presence changes, and every one goes when the session ends.

This user's own caret is published from the events that move it (`CursorMoved`, `ModeChanged`,
entering a buffer), coalesced into one `selection` per 100 ms, and once more when the room's own
edit lands in the buffer: a buffer for a room document exists before the document's text does, so
the caret published in between is one the companion had no document for, and a write the room
makes fires no `TextChanged` to publish it again. `selectionCleared` goes out when there is no
shared document in front of the user.

Following moves the follower's caret: Neovim has no viewport-only state that survives a redraw, so
being where a peer is means the cursor is there, and the next keystroke lands there too. That is
why a local edit of a shared document ends the follow, saying `stopped following <name>.`, while a
remote edit only re-lands it. Going somewhere deliberately ends one the same way, the peer's
leaving ends it with their name on it, and a rename keeps it. While a follow stands, the window
shows a `winbar` row naming the peer and the command that stops it, in the peer's own colour;
clicking the row stops the follow too, where the editor takes a mouse. Every buffer's own row is
saved as the indicator arrives and put back as it leaves, so re-targeting across documents leaves
nothing behind. `vim.g.selvage_following` holds the followed peer's id meanwhile, and
`%{v:lua.require'selvage'.statusline()}` is the snippet for whoever wants the same words in their
own statusline. A typed jump to a peer in no document waits for the frame that draws them; the
picker refuses its own rows where the row says they are in no document. A host opens a peer's
document only when it resolves to a readable file inside the shared folder, never creating it;
anything else says `could not open <path> from the room: <reason>`.

The session is on screen without any statusline configuration: the window's `winbar`, standing for
as long as a session does and saying what the VS Code client's status bar says. A host alone reads
`Selvage: hosting — 1 person in the room` before anyone joins, a guest reads
`Selvage: guest — 2 people in the room`, and the states that are not a healthy session say so on
the same row: a connection being made (`Selvage: connecting…`), one being retried
(`Selvage: reconnecting…`), the host away, and a file whose content has not been fetched
(`[not fetched]`). `vim.g.selvage_indicator = 'changes'` keeps the row for those alone and never
for the standing line; `vim.g.selvage_indicator = false` (or `'never'`) leaves the row off, and
the statusline snippet with it.

While the host is absent the row says who left and what is at stake, with the seconds the server
has left counted down from its deadline: `Selvage: Host disconnected.
<name> left — if they return within <n>s the session continues, otherwise this room closes and
your local copy is kept.` It is the sentence the VS Code client shows, and the copy it names is
the mirror directory the room-gone teardown keeps, at the path the notice gives. The same
sentence is announced once when the absence begins, and `<name> is back — the session
continues.` when the host returns. The row is window-local and the person's own
row is saved and put back as it arrives and leaves, as the follow's own row is, and a follow's row
wins while one stands.
`%{v:lua.require'selvage'.statusline()}` returns those words for a statusline that wants them
somewhere else, and with the file itself in front of it: one holding no fetched content has the
row say `[not fetched]`, so a search over the mirror reads as the partial thing it is.

Whose caret is in the file in front of the person is the gutter's fact and not the row's: the
caret wears a block in the peer's own colour, the sign column their initials, and `:SelvagePeers`
names them in full with the document they are in. The same peers are published for everyone else as
`vim.g.selvage_file_peers`, a map of room path to
`{ initials, colour, label, peerId }`, with a `User SelvagePresence` autocmd fired whenever it
changes. netrw, oil.nvim, nvim-tree, telescope, lualine and heirline each decorate from that one
table, and this client depends on none of them.

### The vendored engine

`vendor/` is a copy, never edited here. Refresh it from a sibling `vscode_client` checkout:

```
scripts/sync-engine.sh [path-to-vscode_client]
```

The script copies `src/engine` and `src/bridge`, removes anything the source has retired, and then
diffs the result, so a run either brings `vendor/` into agreement or says what it could not.

The copy carries the session layer with the rest of the engine — `vendor/engine/sealed.ts`
is `CANONICAL.md` §6.1's bytes, `vendor/engine/peer.ts` is `PROTOCOL.md` §13, `vendor/engine/host.ts`
is §7.1's producer half, the room state the host key seals and the rule for each state that goes out,
and `vendor/engine/crypto.ts` is the crypto seam a caller supplies, because a page has neither
`node:crypto` nor a synchronous one.

### The companion's session

`companion/relay.ts` is small on purpose: the socket wiring lives in `vendor/engine/relay.ts`, the
adapter's own vocabulary in `vendor/bridge/peer-engine.ts`, and what is left for this repository is
its own socket (`ws`) and its own listing. `companion/session.ts` drives it through the
`EngineFactory` seam, and the crypto seam is the engine's default, WebCrypto — Node 22.18 has it
globally, so this repository carries no Node-only crypto of its own.

What a person does:

- **Host.** `:SelvageHost <address>` mints the room on that server, with the folder this window is
  in as the room's listing. The address, the folder and the invite are otherwise unchanged.
- **Join.** Paste the link. The invite carries the room key and the host key on its fragment, and a
  room seats no connection that cannot read them, so the link is what a join is: a link without a
  fragment is refused locally, before a socket is opened.
- **Copy the invite.** Unchanged: the page link this client hands on is the same room, token and two
  keys as the connection's own wire invite.
- **Everything else** — `:SelvageOpen`, the mirror, `:SelvageFetch`, `:SelvagePeers`, follow,
  cursors — is the same code over the same bridge.

**A viewer's editor is read-only.** The room's state assigns roles (`§13.4`), and a
connection seated as `viewer` gets the room's documents with `modifiable` off: `§13.9` has a viewer
publish no content, so a buffer that accepted a keystroke would show text the room never receives.
The role is read where it is used rather than remembered from the join — the state that commits this
connection's key is published after the seat, so a viewer learns what it is from a report of its
own — and what the room itself applies is written through the flag, because what a viewer receives
is not refused. Leaving gives each buffer back the `modifiable` it had. This client declares no role
and is seated as `guest`: what a host does with the state is a later phase's, and a client that
could ask to be a viewer would be inventing a request the protocol does not have.

**What is not carried.** The listing a host publishes is sealed into the room state by
its host key, so it is lost when the process ends; this client runs no resume (`§9.1`), so there is
no returning host to continue the `issued` series from and no `HostStore` is written. §13.11's
per-receiver caps are unimplemented, as they are in the reference client.

## Commands

Hosting starts outside the editor: start `selvaged`, note the address it prints, and give that
address to `:SelvageHost`, or set `vim.g.selvage_server_url` to always use it. The address is asked
for once and remembered across restarts, so later bare `:SelvageHost` calls reuse it without asking.
With none of the three, the one question starts from the demo server
`selvage-demo.dontblameme.dev` — a domain on its own, which the completion below reads as
`wss://selvage-demo.dontblameme.dev`.
`:SelvageChangeServer` reports or changes the address without hosting first.

Everywhere a *server* address is typed — the argument, the question's answer, the setting, a
remembered one — the host on its own is enough, and it means the published shape: a bare host is
completed to `wss://<host>`, because the room is dialled over TLS. The `/session` path every
Selvage server answers belongs to the engine, which adds it to whatever base it is given:
`wss://host` and `wss://host/session` both reach `wss://host/session`, and any other path is kept.
An invite link is not a server address: its query and fragment are the room, its token and its
key, so a link given wherever an address is asked for is refused and nothing is remembered.

| | |
|---|---|
| `:SelvageHost [serverUrl]` | Mint a room on that server and share the current buffer. Opening the room puts the page invite on the clipboard and says so; `:SelvageCopyInvite` is for later copies, and a clipboard this Neovim cannot reach says why, with the link left in the unnamed register. A bare hostname in `serverUrl` is completed as everywhere else. The folder the session was started in is its root: its files are published to the room as the grant, every file buffer opened under it joins the room too (a buffer whose file's bytes are not text is refused rather than transliterated, once per path), and a path a peer asks for is read from it. With no argument the remembered address is reused without asking (the demo default `selvage-demo.dontblameme.dev` until one is used), and `vim.g.selvage_server_url` answers it without asking. |
| `:SelvageChangeServer [serverUrl]` | Report the server the next host uses, and set it, without hosting first. With no argument it reports the address in force and, where there is somebody to ask, opens the same box `:SelvageHost`'s first question does, prefilled with it. While `vim.g.selvage_server_url` is set that global outranks the remembered address, so the command says so and changes nothing. Either way the write reaches the next host only, never a room already open. |
| `:SelvageJoin [invite]` | Join the room the invite link names. The first of the room's documents opens in the current window, in the mirror's copy of it; any others become buffers reachable with `:SelvageOpen`. With no argument the invite is asked for, starting from the clipboard when it holds a link that names a room. Accepts the page link the host copies, whose origin is the server the room lives on; a `ws://` link joins as it stands, which is how a room whose server serves no page is handed on. A value that is not an invite link, typed or pasted, is refused at once. |
| `:SelvageDisplayName [name]` | Set the name other participants see: sent to the room now when a session is live, and used by the next host or join. With no name it reports the one in force, or says there is none. |
| `:SelvageOpen [path]` | Put one of the room's documents in the current window. With no argument it opens the only one the room offers, or asks which when there are several. `path` completes over what the room offers, its grant and the documents it holds, and may be the room path or any suffix of it: `:SelvageOpen README.md` reaches `workspace/README.md`. A path nobody has opened yet is offered too, and opening it is what makes the host read that file. A host is refused: its own files are already in its buffer list. |
| `:SelvageFetch [path]` | Download a file from the room: the path, every path under it, or the whole listing. A path nobody has fetched is an empty file, and a project-wide search is partial until the paths it covers have been fetched; this is the one command that fills them in. Fetching *opens* what it names in the room, so every peer receives those paths and materialises them: a whole-listing fetch shares a whole project, and the command says so before it does it. A host is refused: the room's files are already on its disk. |
| `:SelvageCopyInvite` | Put the session's invite on the clipboard and the unnamed register. A session the server gave no invite to says so, and a clipboard that refuses the link says why. A host copies the page its own server serves, carrying the room and its token: one address for the page and the socket both. A guest holds the token it joined with, because the invite *is* the permission, so it copies the link it joined by: that same page link, or the `ws://` link where that is how the room was reached. The unnamed register (and register `0`) is cleared of the link when the session ends or Neovim quits, unless something else was yanked since, and a link typed into `:SelvageJoin` or its prompt is removed from the command-line and input histories once read: ShaDa writes both to disk, and an invite is the room's permission and its key (`PROTOCOL.md` §12). |
| `:SelvageLeave` | Leave the session and stop the companion. With no session it says so. |
| `:SelvagePeers` | List the room's participants: each peer the room names, with the sign, whole display name and room path of the ones the gutter drew, in the colour their caret is drawn in. |
| `:SelvageGoTo [name]` | Go to a participant: show their document and put the cursor on their caret. With no name it goes to the only participant, or asks which when there are several. `name` completes over display names and may be a peer id; a name two peers share is refused with both told apart, and a typed name whose caret has not arrived yet waits for it. |
| `:SelvageFollow [name]` | Follow a participant: land where they are and keep landing there as they move, across documents, until something ends it. Typing in a shared document stops it. Takes its name the way `:SelvageGoTo` does. |
| `:SelvageStopFollowing` | Stop following, or say there is nothing to stop. |

`:SelvageHost` and `:SelvageJoin` open a session and never end one. Hosting while hosting reaches
for the invite link instead of minting a second room, and a `:SelvageHost` while a guest or a
`:SelvageJoin` while in a session asks first, naming what leaving it does, and does nothing at all
when the answer is no. A process with nobody to answer the question cannot be asked, so it says
what the command would have done and leaves the session alone.

The name other participants see is resolved when a session starts, in this order:
`vim.g.selvage_display_name`, the `SELVAGE_DISPLAY_NAME` environment variable, the remembered
answer, then a prompt pre-filled with the login name. The pre-fill is a suggestion: a cancelled or
emptied prompt refuses the session, and a process with nobody to ask refuses it too, saying how to
configure one.
`require('selvage').display_name()` is `nil` until one is set or remembered. `:SelvageDisplayName`
sets the global and writes it down, and a prompted answer is written down too, so neither this
Neovim nor the next one asks again. It renames a live session; a direct write to the global is
picked up by the next host or join. A name is at most **32 UTF-16 code units**, the unit the
protocol counts, so an astral character costs two, and one over that is refused rather than
shortened. A name typed at the prompt that is too long says how long it is and asks again; one that
arrived from the global or the environment has nobody to re-ask, so the session is not started and
the refusal names the setting to change.

`vim.g.selvage_open_on_join = false` keeps the join from changing the window, while still opening
the room's documents as buffers `:SelvageOpen` reaches.

`vim.g.selvage_auto_save = false` keeps the room's changes out of the files on disk: a host writes
a document the room changed by default, while a guest's mirror is not refreshed either way, so a
save in it is refused and the file keeps what it last held. `vim.g.selvage_open_on_join` and this
are read when a session starts, so a change to either applies to the next host or join.
`vim.g.selvage_server_url` is the address `:SelvageHost` does not have to ask for, completed the
same way an argument is, so a domain on its own there is enough and means `wss://<host>`. The page
a copied invite links to is the room's own server, over the scheme a browser speaks (`wss://` as
`https://`, `ws://` as `http://`). A server started with `--page <dir>` serves the guest page from
its own origin.
`vim.g.selvage_fetch_timeout_ms` bounds how long a fetch waits for the room to answer.

### Pickers

`:SelvageOpen`, `:SelvageGoTo` and `:SelvageFollow` ask through `vim.ui.select`, the editor's own
chooser, so no picker plugin is ever required. Whatever overrides `vim.ui.select` is what opens
(fzf-lua, telescope-ui-select, dressing.nvim, mini.pick, snacks.nvim, or any other provider, in
whatever order that override resolves); with none installed, Neovim's builtin numbered list asks
instead. `test/lua/pickers.lua` pins both halves: no fzf or picker reference in the shipped code,
and every chooser completing on plain `vim.ui.select`.

A join says one summary sentence plus errors: `joined the room`, then `opening <path>; <n> more in
the room.` The exception is a room that had nothing open at the join and grants files afterwards:
that guest landed no document and has no tree to read, so the listing is said once. The mirror's
location is `require('selvage').session().mirror`. Pinned by `test/lua/join.lua` (listing first),
`test/lua/joinorder.lua` (documents first) and `test/lua/granted.lua` (a listing after an empty
join).

The folder a session was started in is its root: a host publishes the listing of the files under
it to the room, and nothing outside it is ever served. The root is fixed for the session, so a
`:cd`, `:lcd` or `:tcd` afterwards moves where Neovim looks, not what the room can see, and
opening a file outside it earns a warning.

That listing is the room's **grant** (`DESIGN.md` §4.2, `PROTOCOL.md` §5): files and never content,
replaced wholesale. A host reads its own working copy when the session starts and writes the files
it holds: no directories, ascending by UTF-16 code unit, with dependency and build trees and
environment files left out, a file whose own name declares a format a room cannot carry left out
with them, and nothing over the 1 MiB a listing will carry
(`MAX_GRANT_FILE_BYTES`). It reads the folder again while it hosts, so a file created, deleted or
renamed under it reaches the room as the new listing. A guest keeps the listing beside the
documents it holds, so `:SelvageOpen` completes over a path nobody has opened yet and opens it
through the same hold as any other document. Opening it is what makes the host read that one file
out of its working copy, and the host refuses anything that is not a readable text file inside its
root rather than sharing an empty document; a refusal is reported.

## The mirror

A guest keeps the room's documents and materialises the room as a real directory, so that the
tools a person already uses (fzf and Telescope, ripgrep, ctags, a language server, a tree plugin,
`fd`, `:find`) see the room as a project. Those programs are separate processes; they read the
filesystem and cannot see a buffer name, a URI scheme or an in-process source.

The **shape** is materialised, the **content** is not. Every path the room's listing names exists
in the mirror, with the directories on the way to it, so a tree plugin walks the whole room; a
path whose content has not been fetched is present and empty. A listing replaces the one before
it, so a path it no longer names loses its file, and the directories that become empty with it go
too. Only a path the previous listing named is removed, and nothing outside the mirror is touched.
The listing's bounds (the most paths it may carry, and the longest name in it) are applied where
those files are made, and a listing past either is refused and reported with the paths that could
not be written. Content arrives when something needs it: a file opened in the editor, or
`:SelvageFetch`, which takes one path, a directory of them or the whole listing. A project-wide
search is therefore partial until the paths it covers have been fetched, and `:SelvageFetch` is
the one command that answers that. A buffer holding no fetched content has `[not fetched]` on its
row. `require('selvage').session().mirror` is where the directory is, for a plugin that has to be
pointed at it.

A fetch holds what it names: those paths join the room's open-document set, so every peer
receives them and a peer with a mirror materialises them. A file, two of them or a directory is
one thing; `:SelvageFetch` alone is a whole project published to the room, and the notification
before it happens says so.

A listed path's buffer is the mirror's file, a real path on disk rather than a `selvage://`
buffer, so a language server gets a `file://` URI and ctags and ripgrep read the file being
edited. A document the room holds and its listing does not name (a listing can be truncated by the
host's own bounds) keeps the `selvage://` buffer, the fallback for everything the mirror cannot
name. The buffer is a real file with a real name, so the
editor's own filetype detection answers for it: a listed path with a known extension carries that
filetype (`lua`, `markdown`, `rust`), and `'syntax'` and an ftplugin hook onto it as they do for
any other file the person opened. Detection is asked for by name rather than left to the `BufRead`
autocmds, which this client suppresses while it fills the buffer. Icons come from the person's own
devicons or mini.icons, as they do in their own project. A listing that arrives after the room has
already named a document moves that document's buffer to the file the listing names for it; its
text comes with it.

A path that leaves the listing loses its mirror file too, and a buffer already open on it is
not taken away: the listing and the room's open-document set are two facts (`PROTOCOL.md` §5, §6),
so the document stays open in the same buffer, with the same text and the same name. A save in it
writes the file back, and makes the file's directory again when the removal took it with the file:
the room already has the text, because a guest's edits travel as they are typed, and the file is
only this session's cache of it, so a `:w` is a save and not `E212` over a buffer left modified.
The file that comes back is not in the room's listing. While the session still holds the document,
entering its name again routes to the buffer that already holds it and nothing is said. If the
buffer was wiped or the session is over, a fresh buffer for the path is refused like any other file
in the mirror the room does not list, once per path.

The directory is a cache of the room and never a source of truth. It lives under
`stdpath('cache')/selvage/<room>/`, never a temporary directory (`/tmp` is RAM-backed on some
hosts) and never inside the person's project, one directory per session inside the room's, named
for the process that owns it. The session that made it removes it on the way out, and a directory
a crashed session left behind is pruned by the next one: only a directory whose process is gone is
removed, so a second Neovim mirroring the same room keeps its own. The one ending that keeps the
directory is a room closing under a guest, with a sentence saying where it is.

A room that dies under a guest does not leave its buffers in the window: `roomGone`, and the
connection the engine gave up on, land every window showing one on a fresh empty buffer, wipe the
room's buffers that hold nothing the person changed, and keep the ones that do, saying how many,
and keep the mirror itself with the sentence `The room closed. Your copy is kept at <path>.` A
host is left alone: its buffers, and its files, are its own. Pinned by `test/lua/session.lua`.

A save in the mirror is routed: the editor does not run its write path for `:w` in a mirror
buffer, and this client writes the file from the buffer as the save the room is told about.
`:[range]w {file}` and `:w >> {file}` naming a file inside the mirror are
refused the same way. A file outside the mirror is the person's own and stays the editor's to
write. The room's own change to a document is written into the mirror the same way, once the
room settles.

Four things the mirror does not do, all deliberately:

- A write that runs no autocommands, which is what a `:w` from inside another autocommand is
  (`:noautocmd write` by hand is the same). The editor writes the file and the session is not
  told; the text is still in the room, because a guest's changes travel as they are typed. What is
  skipped is the save this client would have sent.
- A buffer that has drifted from the room. A routed save writes the buffer, which is what a person
  pressing `:w` expects, so a buffer holding text the room has not accepted (an edit the editor
  refused to apply, a session that ended) can put that text into the file. The companion puts the
  room's copy back into such a buffer, and the next save writes that.
- A tool that writes to a mirror file behind the client's back. The room's copy replaces it the
  next time the path is fetched or opened, and a fetch of a path this session already holds writes
  the file from what the client holds. A cache that disagrees with the room is corrected, not
  merged.
- A file in the mirror the room does not list. A tool that creates one has made a file on this
  disk and it is not the room's; opening it says so, once per path, and saving it is refused,
  with the buffer left holding the edit.

Create, rename and delete are not implemented as document operations: the protocol has no
frame for them and `DESIGN.md` §11 keeps them out of v1. A file created in the mirror is not
shared; a file deleted or renamed in it does not reach the room, and the room's copy comes back
the next time the path is fetched. Trying one says so where it happens: creating a file in the
mirror, renaming a buffer onto a mirror name, or deleting a listed file's cache each say
`The room carries no file mutations yet.`, once per path. What does follow a host's folder is its
**listing**: a file the host creates, deletes or renames under the folder it shares is republished
as the room's grant, and a guest's mirror gains a file for a path that appeared and loses one for
a path that went. The mirror is where a person reads and edits what the room holds.

In Neovim the room is a directory that ripgrep and a language server read for themselves, so it
has to be filled, which is what `:SelvageFetch` does. The VS Code client has the twin command
(`Selvage: Fetch a path from the room`).

## Checks

```
npm run typecheck
npm test                    # the companion, against a replica with no server behind it
scripts/ci-local.sh all     # the workflow's commands, plus actionlint and the proof below
scripts/test-lua.sh         # the Lua side, in a real headless Neovim (not in `all`: see below)
scripts/e2e/run-two-instance.sh   # two real Neovims, a real companion each, a real selvaged

nix flake check             # the same three suites, plus the built package, in a sandbox
nix develop                 # Node 22 and a Neovim of a named version; no git hooks
```

`scripts/ci-local.sh checks` is what the workflow runs; `scripts/ci-local.sh all` adds actionlint
and the end-to-end proof, which needs a real Neovim and a built `selvaged` and so cannot run on a
runner. `scripts/test-lua.sh` is not in `all`: it needs a Neovim too, and `nix flake check` runs the
same files in a sandbox. Run it by hand after changing `lua/` — it also reads the plugin the machine
has installed, and says so rather than testing that one instead when the two are not the same.

`nix flake check` runs `typecheck`, the companion suite and the thirteen files under `test/lua/`,
each in its own Neovim, with no network and no editor session, and then the `plugin` check, which is
the only one that starts Neovim against the built package rather than a checkout: the plugin that
`packages.<system>.default` is, on the runtime path of the wrapped Neovim that
`packages.<system>.neovim-selvage` is, with the real companion started from it. The two-instance
proof is not one of them: it needs a `selvaged` from the sibling `reference_server` checkout, which
a sandboxed build cannot see, so `SELVAGE_SELVAGED` is the seam. `nix run .#e2e` runs that proof
with the flake's Node and Neovim and whatever `SELVAGE_SELVAGED` names, from the checkout in the
working directory:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged nix run .#e2e
```

The two-instance proof (`scripts/e2e/run-two-instance.sh`, or `nix run .#e2e`) needs a built
`selvaged`, and finds one through `SELVAGE_SELVAGED` when that is set and otherwise under
`../reference_server/target/{debug,release}`, a path relative to this checkout. From a git
worktree under `.worktrees/` that sibling does not exist, so point it at the main checkout's
binary:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged scripts/e2e/run-two-instance.sh
```

There is no `busted` or plugin-test framework here: almost every rule worth testing (what enters
the replica, which change an editor is asked to apply, when a document is written) lives in the
companion, and is tested there against a fake editor. `test/bridge.test.ts` takes the vendored
bridge directly (this adapter's `NvimEditorHost` in front of it, a fake replica behind) because a
guest document the room has not sent the text for is a case the companion's own deferral never
lets the bridge see. `test/grant.test.ts` is the host's side of the room's listing on a real
directory tree: which files a listing carries and
in what order, and how far a path a peer named may reach, including the symbolic links that make a
guess about a path interesting. What is left on the Lua side is translation, the wiring around one
session, and one rule of the editor's own: the conversion between Neovim's byte positions and the
protocol's UTF-16 code units. The first two get `test/lua/document.lua` and
`test/lua/session.lua`, which run in a real headless Neovim. The first is against a real buffer
and a real `on_bytes` rather than a mock; the second is against a stubbed companion, and checks
the wiring around a session: which buffers it shares, that it lets them go when the session ends,
and that a caret is published and a peer's caret and selection are drawn at the peer's position.
`test/lua/commands.lua` is the commands' own policy, through the real command definitions: what
`:SelvageHost`, `:SelvageJoin` and `:SelvageOpen` ask for, refuse and never do.
`test/lua/granted.lua` is the room's grant on the front-end's side: what the room offers, the
completion and the chooser over it, and opening a path nobody has opened without counting it as
held. `test/lua/mirror.lua` is the mirror, against a stub companion that answers holds the way the
room does: where the directory is and how long it lives, what a listing materialises and what it
refuses to, what a listing that loses a path removes, keeps and leaves open, which buffer a room
path is opened in, how content reaches the file, what a save does and what a write the room knows
nothing about does, and `:SelvageFetch` over one path, a directory and the whole listing.
`test/lua/vocabulary.lua` pins the words rather than the behaviour, as the other client's
`test/vocabulary.test.ts` does: the phrase each command is described by, and every sentence the
front-end notifies, with the level it notifies it at. Both clients say the same sentence at a
moment and keep only the presentation around it to themselves, so a reworded sentence fails this
suite here rather than drifting away from the other editor's. `test/lua/leave.lua` starts a real
job, one that ignores its stdin, to check what `:SelvageLeave` does to a companion that does not
go on its own, and reads the framing of what the companion writes off the same object: a line
arriving in pieces, and one past the bound being shed to the newline that ends it.

`scripts/e2e/run-two-instance.sh` is the proof end to end: two real headless Neovim processes, each
loading the real plugin and starting its own real companion, one minting a room on a real `selvaged`
and the other joining the link it hands on. It proves what a session is: the page link carries
`§5.1`'s fragment, the guest reads the room and its own role out of the state the host signed, an
edit made in either window ends up in both, the host's working copy on disk holds the guest's own
edit, and the companion's trace of that run holds the invite with its fragment redacted out. It also
opens a granted path the host's own window never opened, so the text can only be the host's working
copy read on the guest's hold, and — unless `SELVAGE_E2E_RECONNECT=0` — cuts the guest's socket and
checks that both windows re-converge once it has re-established. It is not part of `npm test` or CI,
because it needs a `nvim` and a built `selvaged`.

## Licence

`MIT OR Apache-2.0`: `LICENSE-MIT` and `LICENSE-APACHE`.

## What is not here yet

- Packaging and distribution beyond Nix and "clone it and `npm ci`": no nixpkgs entry, no release
  bundle.
- An edit that lands on the same characters a peer's edit is landing on is superseded by the
  room rather than merged with it. A keystroke elsewhere in the document is moved rather than
  lost ("The local IPC" above); when the two are about the same text there is no position to
  move it to, and the room's text is what the buffer ends on.
- A guest's buffer is created and shown as soon as the handshake names the room's documents,
  which is before the sync carrying their text. A keystroke made in that window is superseded by
  the room's text: the two are counted together once it lands, and the room's text is what the
  buffer ends on, with the keystroke in neither the buffer nor the room.
- A join shows only the room's first document. A room with several leaves the rest as buffers
  for `:SelvageOpen` rather than opening a window each, and a document the host opens after the
  join gets a buffer without taking the guest's window, except the first one into a room that
  was empty at the join.
- A peer's selection is the colour blended with the editor's background: a buffer highlight has no
  alpha.
- A guest's mirror holds the room's listing as real files, and that is what a language server,
  `rg`, ctags and a tree plugin see. What it does not hold is content nobody has fetched: a file
  whose path has not been opened or fetched is empty, and the window marks it `[not fetched]`,
  so a search over the mirror is visibly partial until the paths it covers have been fetched
  (`DESIGN.md` §4.2). A file a tool creates in the mirror is not part of
  the room, and a mutation made in the mirror (create, rename, delete) still reaches the room
  nowhere; what does reach it is the host's own folder, through the listing above.
- A host wiping a shared buffer releases the path in the room; a guest wiping one does too, but a
  guest keeps a path the room stops naming, because this client's document set only grows within a
  session.
