# What is not here yet

- Packaging and distribution beyond Nix and "clone it and `npm ci`": no nixpkgs entry, no release
  bundle.
- An edit that lands on the same characters a peer's edit is landing on is superseded by the
  room rather than merged with it. A keystroke elsewhere in the document is moved rather than
  lost (see `docs/ipc.md`); when the two are about the same text there is no position to move it
  to, and the room's text is what the buffer ends on.
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
  (`DESIGN.md` §4.2). A file a tool creates in the mirror is not part of the room, and a mutation
  made in the mirror (create, rename, delete) still reaches the room nowhere; what does reach it is
  the host's own folder, through the listing above.
- A host wiping a shared buffer releases the path in the room; a guest wiping one does too, but a
  guest keeps a path the room stops naming, because this client's document set only grows within a
  session.
