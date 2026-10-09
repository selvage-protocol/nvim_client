# Command behaviour

`:SelvageHost` and `:SelvageJoin` open a session and never end one. Hosting while hosting reaches
for the invite link instead of minting a second room, and a `:SelvageHost` while a guest or a
`:SelvageJoin` while in a session asks first, naming what leaving it does, and does nothing at all
when the answer is no. A process with nobody to answer the question cannot be asked, so it says
what the command would have done and leaves the session alone.

## Pickers

`:SelvageOpen`, `:SelvageGoTo` and `:SelvageFollow` ask through `vim.ui.select`, the editor's own
chooser, so no picker plugin is ever required. Whatever overrides `vim.ui.select` is what opens
(fzf-lua, telescope-ui-select, dressing.nvim, mini.pick, snacks.nvim, or any other provider, in
whatever order that override resolves); with none installed, Neovim's builtin numbered list asks
instead.

A join says one summary sentence plus errors: `joined the room, opening <path>. <n> more files are
open.` The exception is a room that had nothing open at the join and grants files afterwards:
that guest landed no document and has no tree to read, so the listing is said once. The mirror's
location is `require('selvage').session().mirror`.

## A room can seat you as a viewer

The room's state assigns roles, and a connection seated as `viewer` gets the room's documents with
`modifiable` off: a viewer publishes no content (`PROTOCOL.md` §13.9), so a buffer that accepted a
keystroke would show text the room never receives. It says so once, in as many words: `you are a
viewer in this room, so its documents are read-only.` Leaving gives every buffer back the
`modifiable` it had.
