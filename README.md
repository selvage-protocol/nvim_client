# Selvage for Neovim

A Neovim client for the [Selvage session protocol](https://github.com/selvage-protocol/specification):
share a link, come edit my code with me.

Status: v1 in progress. Hosting, joining by invite and editing together work today; the gaps are in
[What is not here yet](docs/limits.md).

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
-- vim.pack (Neovim 0.12+)
vim.pack.add({
  {
    src = 'https://github.com/selvage-protocol/nvim_client',
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

Nix builds the plugin with a Neovim and a Node of its own: [With Nix](docs/install-nix.md).

There is no `setup()` call.

A first session:

1. Start `selvaged` and note the address it prints.
2. `:SelvageHost` shares the current buffer. Answer its one question with that address (the host
   alone is enough, since `selvage-demo.dontblameme.dev` means `wss://selvage-demo.dontblameme.dev`), and
   the invite link goes on the clipboard as the room opens.
3. Send the link. The other person runs `:SelvageJoin <invite>`, which joins the room and opens its
   first document.
4. Both edit the same file, and each sees the other's text and caret as they type.

## Commands

Hosting starts outside the editor: start `selvaged`, note the address it prints, and give that
address to `:SelvageHost`, or set `vim.g.selvage_server_url` to always use it. The address is asked
for once and remembered across restarts, so later bare `:SelvageHost` calls reuse it without asking.
With none of the three, the one question starts from the demo server
`selvage-demo.dontblameme.dev` (a domain on its own, which the completion below reads as
`wss://selvage-demo.dontblameme.dev`).
`:SelvageChangeServer` reports or changes the address without hosting first.

Everywhere a *server* address is typed (the argument, the question's answer, the setting, a
remembered one) the host on its own is enough, and it means the published shape: a bare host is
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
| `:SelvageCopyInvite` | Put the session's invite on the clipboard and the unnamed register. A notification says it was copied. A session the server gave no invite to says so, and a clipboard that refuses the link says why. A host copies the page its own server serves, carrying the room and its token: one address for the page and the socket both. A guest holds the token it joined with, because the invite *is* the permission, so it copies the link it joined by: that same page link, or the `ws://` link where that is how the room was reached. The unnamed register (and register `0`) is cleared of the link when the session ends or Neovim quits, unless something else was yanked since, and a link typed into `:SelvageJoin` or its prompt is removed from the command-line and input histories once read: ShaDa writes both to disk, and an invite is the room's permission and its key (`PROTOCOL.md` §12). |
| `:SelvageLeave` | Leave the session and stop the companion. A host is asked first, `Leaving ends the room for everyone and stops the invite link.`, with `Leave anyway` and `Cancel`; a guest leaves at once. With no session it says so. |
| `:SelvagePeers` | List everyone in the room, one line each: their initials in their seat's colour, their name and the file they are in. You come first and then the others as the room lists them; the host is crowned with `♛` and the person you follow marked with `◉`. |
| `:SelvageGoTo [name]` | Go to a participant: show their document and put the cursor on their caret. With no name it goes to the only participant, or asks which when there are several. `name` completes over display names and may be a peer id; a name two peers share is refused with both told apart, and a typed name whose caret has not arrived yet waits for it. |
| `:SelvageFollow [name]` | Follow a participant: land where they are and keep landing there as they move, across documents, until something ends it. Typing or moving yourself stops it. Takes its name the way `:SelvageGoTo` does. |
| `:SelvageStopFollowing` | Stop following, or say there is nothing to stop. |

## More

- [With Nix](docs/install-nix.md): installing the plugin from the flake, under Home Manager and as
  an overlay.
- [Shape](docs/architecture.md): the engine, the companion and the plugin, and what talks to what.
- [The local IPC](docs/ipc.md): every JSON line the plugin and the companion exchange, in both
  directions.
- [Remote cursors](docs/remote-cursors.md): how a peer's caret, selection and sign are drawn, the
  follow, and the session bar.
- [The vendored engine](docs/vendored-engine.md): the `vendor/` copy and the script that refreshes
  it.
- [The companion's session](docs/companion-session.md): hosting, joining, the viewer role, and what
  is not carried.
- [Command behaviour](docs/commands.md): what `:SelvageHost` and `:SelvageJoin` ask and refuse, the
  chooser, and the join notice.
- [Configuration](docs/configuration.md): display names and the `vim.g.selvage_*` settings.
- [The room's grant](docs/grant.md): the folder a session shares, and the listing the host
  publishes from it.
- [The mirror](docs/mirror.md): the real directory a guest keeps the room's paths in, and what is
  fetched into it.
- [Checks](docs/checks.md): the commands the gate runs, and where each test lives.
- [What is not here yet](docs/limits.md): the known gaps.

## Licence

`MIT OR Apache-2.0`: `LICENSE-MIT` and `LICENSE-APACHE`.
