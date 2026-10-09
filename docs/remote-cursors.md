# Remote cursors

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
where that peer sees their own cursor. A charwise Visual selection is published with the character
at its later end included, as Neovim's own operators take it. A selection made forward then ends
just past the cursor's character, so its block is drawn on that character. When the cursor is past
the line's text, the selection ends at the end of that text, without the line break an operator
would take, so the block stays on the cursor's line. The line break is included when the other end
is the one past the text, except on the last line, which has none. With `'selection'` set to
`exclusive` that last character is left out, again as the operators do. A linewise Visual
selection is published as its lines whole, from the start of the first to the end of the last one's
text, so there the head, and the block drawn for it, is at the start or the end of the line the
cursor is on rather than on its character. A Select-mode selection is published as the Visual
selection of the same shape, which is the same range on screen with other keys accepted: the `s`,
`S` and CTRL-S Neovim reports for Select mode, and the `vs`, `Vs` and CTRL-Vs it reports while
CTRL-O has Select mode paused in Visual for one command, are read as `v`, `V` and CTRL-V.

The sign column carries the first two characters of a peer's name, coloured with the peer's own
highlight, so two peers whose names share an initial, `pi` and `pc`, are not identical signs. Two
cells is all `sign_text` takes, so a peer called `thisismylongusername` is `th` there and the
gutter cannot say who that is: the name reads from `vim.g.selvage_file_peers` and from
[`:SelvagePeers`](../README.md), which lists everyone in the room by name beside their initials in
their seat's colour. Nothing is put over the document when a peer moves. Every mark is cleared and
recreated when presence changes, and every one goes when the session ends.

This user's own caret is published from the events that move it (`CursorMoved`, `ModeChanged`,
entering a buffer), coalesced into one `selection` message per 100 ms, and once more when the
room's own edit lands in the buffer: a buffer for a room document exists before the document's text
does, so the caret published in between is one the companion had no document for, and a write the
room makes fires no `TextChanged` to publish it again. `selectionCleared` goes out when there is no
shared document in front of the user.

Following moves the follower's caret: Neovim has no viewport-only state that survives a redraw, so
being where a peer is means the cursor is there, and the next keystroke lands there too. That is
why a local edit of a shared document ends the follow while a remote edit only re-lands it. A follow
that ends by itself says why in the web page's words: `Stopped following <name> because you
started typing.`, `… because you moved.`, `… because the file is gone.`, or `<name> left the room,
so following stopped.`. Starting a follow says nothing about the landing, and neither does going
somewhere or stopping it yourself, as on the web. A follow or a jump that has to *open* a
document to reach the peer says what that costs the room, in the fetch's own words: `<path> is
opened in the room, so every peer receives it.` — and then waits for the room's text, because that
is what the caret resolves against. A rename keeps it. While a follow stands, the session bar
carries a `Following <name> ✕` chip in the peer's own colour and marks their face with `◉`; clicking
the chip stops the follow, where the editor takes a mouse. Every buffer's own row is saved as the
bar arrives and put back as it leaves, so re-targeting across documents leaves nothing behind.
`vim.g.selvage_following` holds the followed peer's id meanwhile, and
`%{v:lua.require'selvage'.statusline()}` is the snippet for whoever wants the same words in their
own statusline. A typed jump to a peer in no document waits for the frame that draws them; the
picker refuses its own rows where the row says they are in no document. A peer in a document this
window has not opened is not that: the presence entry carries their document, so a jump or a follow
opens it — a `selvage://` buffer or the mirror's file, the way `:SelvageOpen` opens any room path —
takes the hold, and lands on their caret when the room's text brings it. That wait is bounded: a
document opened for a landing whose caret has not arrived within `vim.g.selvage_landing_timeout_ms`
gives up, saying `<name>'s caret did not arrive within <n>s` — a follow stops rather than standing
over a place it never reached, and a jump is dropped. A host opens a peer's
document only when it resolves to a readable file inside the shared folder, never creating it;
anything else says `could not open <path> from the room: <reason>`, and such a follow is refused
rather than established.

The session is on screen without any statusline configuration: the window's `winbar` is the web
page's session bar. It opens with what the session is called, `Sharing “notes”` for a host and
`In Hana’s session` (or `In a shared session`) for a guest, and at the right everyone's face as
their initials in their seat's colour, in the web page's order: yours first, underlined, then the
others as the room lists them, the host crowned with `♛`. The states that are not a healthy session
say so on the same row: `Connecting…`, `Reconnecting…`, the host away, and a file whose content has
not been fetched (`[not fetched]`). `vim.g.selvage_indicator = 'changes'` keeps the row for those
alone and never for the standing line; `vim.g.selvage_indicator = false` (or `'never'`) leaves the
row off, and the statusline snippet with it, except for a follow's chip, which is the way to stop
it.

When the host's connection drops, the room says who left and how long it will wait, once, as a
warning: `Hana left the session. The room disconnects in 30 seconds.` The bar then counts it down,
`Hana left the session · Disconnecting in 28s`, until the host is back, which is said once too:
`Hana is back. The session continues.` A room that ends says why in one notice, with where the
guest's copy is kept when there is one: `The host was away too long, so the session ended. Your copy
is kept at <path>.` A host who leaves with `:SelvageLeave` ends the room at once, and the guests
read `The host ended the session.` there instead. The row is window-local and the person's own row
is saved and put back as it arrives and leaves.
`%{v:lua.require'selvage'.statusline()}` returns the session's words for a statusline that wants
them somewhere else, `Following <name>` while a follow stands, and `[not fetched]` after them for a
file holding no fetched content, so a search over [the mirror](mirror.md) reads as the partial
thing it is.

The bar and `:SelvagePeers` draw with these highlight groups, each set with `default` so a colour
scheme or your config can set its own:

| Group | Default | Where |
|---|---|---|
| `SelvageSession` | links to `Title` | the session bar |
| `SelvageWarn` | links to `WarningMsg` | the host away and `Reconnecting…` |
| `SelvageCrown` | yellow, bold | the host's crown |
| `SelvageFollowed` | mauve, bold | the mark on the face you follow |

`SelvageYou` (your face) and `SelvageFollow` (the follow chip) are painted with a seat's colour, as
are the `SelvagePeer<n>` groups a peer's caret, sign and face wear.

Whose caret is in the file in front of the person is the gutter's fact and not the row's: the
caret wears a block in the peer's own colour, the sign column their initials, and `:SelvagePeers`
names them in full with the file they are in. The same peers are published for everyone else as
`vim.g.selvage_file_peers`, a map of room path to
`{ initials, colour, label, peerId }`, with a `User SelvagePresence` autocmd fired whenever it
changes. netrw, oil.nvim, nvim-tree, telescope, lualine and heirline each decorate from that one
table, and this client depends on none of them.
