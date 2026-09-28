# The mirror

A guest keeps the room's documents and materialises the room as a real directory, so that the
tools a person already uses (fzf and Telescope, ripgrep, ctags, a language server, a tree plugin,
`fd`, `:find`) see the room as a project. Those programs are separate processes; they read the
filesystem and cannot see a buffer name, a URI scheme or an in-process source. The paths it
materialises are [the room's grant](grant.md).

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

A path that leaves the listing is a file the host no longer has, and it loses its mirror file too.
A buffer open on it is taken away: the window moves to an empty buffer, the buffer is wiped, the
room is told this client no longer holds the document, and the plugin says
`<path> is no longer in the room, so it was closed.` A deleted directory does the same for every
buffer under it. A buffer holding your own unsaved changes stays where it is, with its text, and
stops being shared: `<path> is no longer in the room; your unsaved copy is kept but no longer
shared.` Nothing in it reaches the room after that, and neither the room's autosave nor a `:w`
writes it back into the mirror; save it outside the mirror to keep it. Either way the path is not
offered, and another peer still holding it does not make it open here again, until a listing names
it again. A host keeps its own buffer: the file is its own, on its own disk.

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
and keep the mirror itself, the notice that says why the room ended adding `Your copy is kept at
<path>.` A host is left alone: its buffers, and its files, are its own. Pinned by
`test/lua/session.lua`.

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
