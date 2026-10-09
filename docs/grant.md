# The room's grant

The folder a session was started in is its root: a host publishes the listing of the files under
it to the room, and nothing outside it is ever served. The root is fixed for the session, so a
`:cd`, `:lcd` or `:tcd` afterwards moves where Neovim looks, not what the room can see, and
opening a file outside it earns a warning.

That listing is the room's **grant** (`PROTOCOL.md` §5): files and never content,
replaced wholesale. A host reads its own working copy when the session starts and writes the files
it holds: no directories, ascending by UTF-16 code unit, with dependency and build trees and
environment files left out, a file whose own name declares a format a room cannot carry left out
with them, nothing over the 1 MiB a listing will carry (`MAX_GRANT_FILE_BYTES`), and then narrowed
by the folder's own ignore files (below). It reads the folder again while it hosts, so a file
created, deleted or renamed under it reaches the room as the new listing. A guest keeps the listing
beside the documents it holds, so `:SelvageOpen` completes over a path nobody has opened yet and
opens it through the same hold as any other document. Opening it is what makes the host read that
one file out of its working copy, and the host refuses a path the room may not have — outside its
root, left out by the rules below, not a readable text file — rather than sharing an empty
document; a refusal is reported. What the guest builds from that listing is
[the mirror](mirror.md).

## The folder's own ignore files

The listing is narrowed the way a `git status` in that folder is: `<root>/.git/info/exclude` at
the lowest precedence, then every `.gitignore` at or below the root, with the last matching pattern
deciding. The patterns are `gitignore(5)`'s, with one divergence: a `?` and a bracket class count
characters, as `fnmatch(3)` documents, where git counts UTF-8 bytes. An ignored directory is not
descended into, so nothing under it is listed either, and a `.gitignore` is an ordinary name of the
folder like any other, so the room sees it.

The same rules bind the read a peer asks for, not only the listing: what the listing does not carry
is not the host's to serve. A path that exists and they leave out is refused `not-granted`, the
refusal a name the grant never carries gets, which says nothing about whether the guess was worth
making; a path that is not there is refused `missing` first, whatever they say about the name.

An ignore file is read only where the directory holding it lists it as an ordinary file, and only
where that directory is itself an ordinary directory of the folder: a `.gitignore` that is a
symbolic link somewhere else, and a `.git` that is a link to another repository, are not this
folder's rules and are not read.

A path a peer names is resolved one segment at a time, and every segment — the leaf included — has
to be an entry of the directory that holds it, spelled exactly as that directory lists it. A file
system that folds case or ignores Unicode normalization resolves a spelling the listing does not
carry, and the ignore check runs on the spelling the peer sent, so without this check a path could
pass it and then open the file it meant to leave out. A segment that is not an entry exactly is
refused `missing`, the refusal a name the folder does not carry gets, and it says nothing about why
the spelling did not match. The check reads the same listing the directory's ignore file is read
from, so it costs no second listing. Two things it does not close: a name the local writer swaps for
a link between the check and the resolution that follows it, and a segment that is a mount point
rather than a link, which the file system reports as the directory it resolves to.

Two things this does not do, both deliberate. Nothing above the root is read, so a folder shared
from inside a repository does not honor the `.gitignore` above it, and `core.excludesFile` is not
read either: these are rules of the folder being shared rather than of the person at the machine,
and the folder is the bound on what a host reads for the room. And they bind what the host
publishes by itself: a file the host opens in Neovim is the host's own act, so the name-based
excludes still refuse it and the folder's ignore files do not.
