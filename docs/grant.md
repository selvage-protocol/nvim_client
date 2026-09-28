# The room's grant

The folder a session was started in is its root: a host publishes the listing of the files under
it to the room, and nothing outside it is ever served. The root is fixed for the session, so a
`:cd`, `:lcd` or `:tcd` afterwards moves where Neovim looks, not what the room can see, and
opening a file outside it earns a warning.

That listing is the room's **grant** (`DESIGN.md` §4.2, `PROTOCOL.md` §5): files and never content,
replaced wholesale. A host reads its own working copy when the session starts and writes the files
it holds: no directories, ascending by UTF-16 code unit, with dependency and build trees and
environment files left out, a file whose own name declares a format a room cannot carry left out
with them, and nothing over the 1 MiB a listing will carry (`MAX_GRANT_FILE_BYTES`). It reads the
folder again while it hosts, so a file created, deleted or renamed under it reaches the room as the
new listing. A guest keeps the listing beside the documents it holds, so `:SelvageOpen` completes
over a path nobody has opened yet and opens it through the same hold as any other document. Opening
it is what makes the host read that one file out of its working copy, and the host refuses anything
that is not a readable text file inside its root rather than sharing an empty document; a refusal is
reported. What the guest builds from that listing is [the mirror](mirror.md).
