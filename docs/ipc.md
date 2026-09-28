# The local IPC

The plugin and the companion speak one JSON object per line over the companion's stdin and
stdout, in both directions. [`companion/ipc.ts`](../companion/ipc.ts) is the normative list;
this is the summary.

Every offset is a UTF-16 code unit, counted in the document's text as Neovim holds it: the
buffer's lines joined by `\n`, one newline between lines and none after the last. A buffer whose
last line is empty therefore ends in a newline, and a buffer of one empty line is the empty
string. That text is byte for byte what the room holds, and it is the unit `Y.Text` indices are
counted in and the unit `vendor/bridge/editing.ts` works in, so nothing is converted on the
companion's side; Lua converts from Neovim's byte positions, where the bytes are.

Line endings are not this adapter's business. A Neovim buffer holds lines and `fileformat` turns
them into CRLF at write time, so the companion always reports `\n`.

| Plugin to companion | |
|---|---|
| `host {serverUrl, displayName?, autoSave?, root?}` | Mint a room and become its host. Refused while a session is live: see `refused`. `root` is the folder the session shares: the room's listing is sealed from it when the room is minted, the host republishes it when the folder changes, and serves a path from it when a peer asks. |
| `join {invite, displayName?, autoSave?}` | Join the room an invite link names. Refused while a session is live: see `refused`. |
| `leave {}` | End the session; the companion answers `status idle` and does not exit on it. Only `:SelvageLeave` stops the process: the `leave` a new `:SelvageHost` or `:SelvageJoin` sends first (`lua/selvage/init.lua`'s `end_session`) leaves it running for the session that is starting to reuse. A host's leave closes the room first, giving the closing a second to go out. |
| `rename {displayName}` | Change the name this connection is known by, mid-session. |
| `open {path, text}` | A buffer is now shared under `path` and holds `text`. |
| `close {path}` | Stop sharing it. |
| `change {path, start, end, text}` | A local edit: `[start, end)` became `text`. |
| `applied {id, ok}` | The answer to an `applyEdit`. |
| `saved {id, ok}` | The answer to a `save`. |
| `selection {path, anchor, head}` / `selectionCleared {}` | Where the caret is. |

| Companion to plugin | |
|---|---|
| `applyEdit {id, path, start, end, text, version}` | Replace `[start, end)` with `text`. Always the smallest range that gets there. |
| `save {id, path}` | Write the document. |
| `status {state, role?, roomId?, invite?, message?, code?}` | `idle`, `connecting`, `hosting`, `joined` or `error`. `role` is the role the room's state assigns this connection (`§13.4`) as far as the session can read it at that moment, which at the seat is the `guest` a key no state has committed yet is read as. `code` is the protocol's own code for a failure the server named, or the one refusal this process decides itself: `invite_refused` for an invite whose fragment it will not read, made before it dials anything. It is absent for a failure nothing named. |
| `refused {what, roomId}` | A `host` or `join` this process did not carry out, because a session is live and ending it is the front-end's to ask about; the room named is the one still standing. |
| `report {report}` | The bridge's own report: the room's documents, its grant (with `unsafe` naming the listed paths the grant's rules would never let a host publish, which a guest's mirror does not put on disk), peers, a divergence, a refusal, a dropped socket being retried (`reconnecting`), or a connection the engine gave up re-establishing — and one of this process's own, `role {role}`, sent when the room's state gives this connection a different role than the seat's status carried. |
| `presence {cursors}` | The remote carets this replica can resolve, each in its seat's colour. |
| `words {words}` | The fixed words the plugin shows and says, sent once as the process starts: `Reconnecting…`, the four ways a follow ends, and a host's leave question with its two buttons. They are the web client's own, from `vendor/bridge`; a `%s` is where a name goes. `test/lua/words.json` is a copy the Lua tests read, and `npm test` keeps it equal. |

Some reports carry more than the bridge put in them, so the plugin has nothing to work out:

- `peers` also carries `self`, this connection's own seat, and `identity`, what the session is
  called (`Sharing “<folder>”` for a host, `In <host>’s session` or `In a shared session` for a
  guest). Every seat in it has `roster` (the name, with the end of the peer id when two people
  share it), `initials` and `colour`, the seat's colour in the web page's order: the host, then
  you, then the others.
- `hostDetached` carries `sentence`, said once, and `line`, what the session bar reads. The
  companion then sends `hostAway {line}` once a second with the countdown until the host is back,
  the room is gone, or a `peers` report names the host again.
- `hostAttached` carries `sentence`, said once.
- `roomGone` carries `sentence`, the reason in the web page's words.

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
