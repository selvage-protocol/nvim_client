# Configuration

The name other participants see is resolved when a session starts, in this order:
`vim.g.selvage_display_name`, the `SELVAGE_DISPLAY_NAME` environment variable, the remembered
answer, then a prompt pre-filled with the login name. The pre-fill is a suggestion: an emptied
prompt asks again, leading with `A name is needed.`, a cancelled one starts nothing and says
nothing, and a process with nobody to ask refuses the session, saying how to configure one.
`require('selvage').display_name()` is `nil` until one is set or remembered. `:SelvageDisplayName`
sets the global and writes it down, and a prompted answer is written down too, so neither this
Neovim nor the next one asks again. It renames a live session; a direct write to the global is
picked up by the next host or join. A name is at most **32 UTF-16 code units**, the unit the
protocol counts, so an astral character costs two, and one over that is refused rather than
shortened. A name typed at the prompt that is too long says how long it is and asks again; one that
arrived from the global or the environment has nobody to re-ask, so the session is not started and
the refusal names the setting to change.

`vim.g.selvage_open_on_join = false` keeps the join from opening the room's document at all — no
window, no buffer and no hold for it — and leaves the room's documents to `:SelvageOpen`.

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

Presence is drawn with the terminal's own colours when `'termguicolors'` is off, as it is by
default: beside each truecolor value the client sets, a peer's caret and selection fill, the seat
faces on the session bar and its crown, your own face and the follow mark each carry the nearest
xterm-256 colour, so a peer is visible on a stock Neovim and on a 256-colour terminal with
nothing configured. Turn `'termguicolors'` on and the same groups keep the truecolor values.
