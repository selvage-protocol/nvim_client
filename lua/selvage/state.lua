-- The session's own state, and the questions asked of it.
--
-- One table holds everything a session knows locally: which buffers are shared under which room
-- paths, the grant the room listed and the mirror it was materialised into, the presence the last
-- report drew, the follow this window is in, and the words the companion sent once as it started.
-- The modules beside this one read and write that table rather than passing it around; what is
-- here besides it is the four questions asked of it — a buffer's document, whether a buffer is
-- empty, whether a role is a peer's, and whether a session is live at all.
local api = vim.api


local M = {}

local state = {
  --- The companion's fixed words, once it has sent them (`words` in `companion/room.ts`): the
  --- sentences `notify_words` says, and the ones the bar and the leave question read. They arrive
  --- once as the companion starts and never change, so they are a fact of this session like the
  --- rest of the table.
  words = nil,
  process = nil,
  status = 'idle',
  --- Whether the companion is re-establishing a connection it lost. The engine retries a
  --- dropped socket on its own and says so locally; the companion passes that on, so the row
  --- reads `reconnecting…` while it lasts instead of the person finding out by typing into a
  --- replica nobody hears.
  reconnecting = false,
  role = nil,
  --- The link `hand_on_invite` last put in the unnamed register, so the session's end can take it
  --- back out before ShaDa writes it to disk (`forget_invite`).
  handed_invite = nil,
  --- Whether this session has said that the connection is a viewer, so it is said once rather than
  --- at every report of the role (§13.9, `note_role`).
  viewer_said = false,
  --- The presence-draw failure sentences this session already named, so a failed extmark write is
  --- said once per sentence rather than at every redraw that still cannot make it (`notify_draw_failure`).
  draw_failures = {},
  room = nil,
  invite = nil,
  --- @type table<string, table> room path to document
  documents = {},
  --- The room's open-document set, as the room's own reports name it: every path some peer
  --- holds open, which is each peer's statement about itself (`PROTOCOL.md` §13.7) and not
  --- this session's set. A path in it with no buffer here is offered and opened lazily, the
  --- way a granted path is; this session holds a buffer only for what its own window opened.
  room_documents = {},
  --- The room's grant: the paths the host listed when the session started, in the order the
  --- room carries them. A listing, never content — a path here may have no buffer and no text
  --- behind it yet (`DESIGN.md` §4.2).
  grant = {},
  --- The room paths this session refused to share, so the refusal is said once: a buffer that
  --- is not text a room can carry — not valid UTF-8, or a file whose bytes are not text at all —
  --- is entered and left many times over a session.
  unshareable = {},
  --- The room paths the mirror refused to write, so the refusal is said once per path: a person
  --- saves a file more than once over a session.
  unwritable = {},
  --- The paths inside the mirror that are not the room's, which a read of one has already named.
  unlisted = {},
  --- The mirror paths a file mutation was refused for, so the refusal is said once per path.
  unmutated = {},
  --- The paths the listing took away from under this session's buffers: not offered, and not shared
  --- again from the room's open-document set, until a listing names them again.
  dropped = {},
  --- The granted paths this session already said are empty until fetched, so the sentence is
  --- for the open and not for every visit: entering an empty mirror file is ordinary reading.
  unfetched = {},
  --- The folder this session's grant is rooted at, as it stood when the session started. The
  --- working directory can move under it at any moment (`:cd`, `:lcd`, `:tcd`) and the grant
  --- does not: it is the folder the invite was offered from (`DESIGN.md` §4.2), not wherever
  --- the person happens to be looking now.
  root = nil,
  --- The paths this session refused to share because they are outside that folder, so the
  --- refusal is said once per path, as it is for a buffer that is not UTF-8.
  outside = {},
  --- The buffers with no file this session already named, so the refusal is said once per
  --- buffer: entering and leaving an untitled buffer is ordinary editing, not news.
  unfiled = {},
  --- The room paths this session refused to share because the buffer's name is not a
  --- regular file, so the refusal is said once per path.
  linked = {},
  group = nil,
  --- The augroup the guest's mirror is watched with: reading one of its files shares it with the
  --- room, and saving one is the session's to route rather than the editor's to write.
  mirror_group = nil,
  -- While the guest's buffer is named for its mirror file, `nvim_buf_set_name` fires
  -- `BufFilePost` like a rename would; the rename refusal skips while this is set.
  suppress_rename = false,
  -- Presence: the augroup the caret watchers live in, the marks drawn for peers, and the one
  -- scheduled flush that publishes this user's caret.
  presence_group = nil,
  -- The window switches the follow's indicator is kept across: `BufEnter`, `WinEnter`,
  -- `BufLeave` and `WinLeave` keep every buffer's own row saved and put back, and a wipe
  -- drops the rows of a buffer that is gone.
  follow_group = nil,
  --- The winbar rows the indicator replaced, by window and buffer: a window shows one
  --- buffer's row at a time — switching buffers swaps the row it shows — so the indicator
  --- saves every buffer's own row as it arrives and puts it back as it leaves. Saving once
  --- per follow would keep the first buffer's row as the one to put back, and every buffer
  --- visited after it would keep the indicator behind it.
  saved_winbars = {},
  presence_ns = nil,
  presence_marks = {},
  peer_groups = {},
  peer_fills = {},
  --- The paint a peer's highlights were last set with, so a report that changes nothing sets
  --- nothing: repainting every caret on every report would be a highlight set per cursor per
  --- report, on top of the marks the draw already recreates.
  peer_paints = {},
  peer_count = 0,
  --- The last presence report, whole: every peer the room puts in a document, with the offsets
  --- this window resolved for them where it could. `peers` below is the subset it drew; a path
  --- is read from here for a peer whose caret is not drawn here (`presence_by_id`).
  cursors = {},
  -- The peers the last presence report drew, as rows for `:SelvagePeers` to print.
  peers = {},
  -- The peers the room itself named, which is everyone in it and not only the ones this client
  -- holds a document for (`report.kind == 'peers'`).
  room_peers = {},
  selection_armed = false,
  selection_path = nil,
  --- The participant this window follows, or nil when it follows nobody: the peer id, the
  --- label the indicator shows, the colour it shows it in, and whether the landing was said
  --- out loud. The indicator's own rows live in `saved_winbars`, one per window and buffer.
  --- A local view state, never advertised: nothing about it reaches the room.
  following = nil,
  --- Whether the caret is being placed by the follow itself. Neovim gives no reason for a cursor
  --- change, so the follow's own landing is what the move handler must not read as the user's.
  applying_follow = false,
  --- The host's absence, while the room waits out its grace: `line` is what the session bar reads,
  --- counted down by the companion once a second. Nil while the host is present.
  host_away = nil,
  --- This connection's own seat as the companion sent it: `peer_id`, `display_name`, `role`,
  --- `roster`, `initials` and `colour`, the room's peers carrying the same.
  self_seat = nil,
  --- What the session is called at the start of the bar: the folder the host shares, or whose
  --- session a guest is in.
  identity = nil,
  --- Whether the session highlight is set for the current colorscheme. A colorscheme runs
  --- `highlight clear`, which takes it, so the flag is dropped there and the group is made again.
  session_painted = false,
  --- A go-to whose landing cannot be made yet: the peer id and the label the refusal would
  --- name. A one-shot follow — every room event that could have brought the text tries it
  --- again, and the first landing, refusal or departure clears it.
  pending_go_to = nil,
  --- The stalled landing a deadline is armed for: the establishment it belongs to (the follow or
  --- the pending go-to table itself, compared by identity), the document it is waiting in, the
  --- label its sentence names, and the session it was armed in. A landing that arrives clears the
  --- slot, a second establishment replaces it, and a timer that finds another one is a landing the
  --- room has already moved past.
  landing_wait = nil,
  generation = 0,
  -- Whether the next document the room names is still the one to put in front of the user.
  -- Set when a guest joins; cleared by the first document shown.
  auto_open = false,
  -- Whether the join has been said out loud yet. The sentence carries the landing, and what
  -- the landing did with the room's documents, which is only known once they are named — so it is
  -- said over the first `documents` report rather than when the handshake arrives.
  join_said = false,
  -- What the join's own listing materialised: how many files, and where. The companion
  -- reports the listing before the documents, so the first grant lands before the join is
  -- said. It is what tells a guest whose room has nothing open that the room has files at
  -- all — that guest has no document and no tree — and a listing that arrives after the join
  -- was said is the other half of the same sentence (`granted.lua` pins both).
  join_mirror = nil,
  -- Whether the join's sentence said the room has nothing open, and whether that sentence named
  -- the listing. The two together say whether the room's files have been announced: a room that
  -- listed nothing when the guest joined and grants files afterwards has none of them to land, so
  -- the listing is the only news, and a guest has no tree to watch for it.
  join_empty = false,
  join_listed = false,
  -- While the join's own landing is placed in the window: the summary accounts for how much
  -- of the landing fetched, so its empty buffer is expected rather than news, and the
  -- session's one unfetched hint stays for the first file opened afterwards.
  suppress_unfetched = false,
}

--- Whether a session is live. The companion process is not the thing to ask: it outlives the
--- session it held — a connection that ends and a room that goes both leave it running for the
--- next host or join — so a process with no room is not a session.
---
--- Opening a session is left out, as it is in the other client: what `:SelvageLeave` gives up is
--- a session there is one of.
local function in_session()
  return state.status == 'hosting' or state.status == 'joined'
end

--- The shared document whose buffer is `bufnr`, or nil when this session does not share it.
local function document_for_buf(bufnr)
  for _, document in pairs(state.documents) do
    if document.bufnr == bufnr then
      return document
    end
  end
  return nil
end

--- The shared document whose buffer is in the current window, or nil when the user is not in one.
local function current_document()
  return document_for_buf(api.nvim_get_current_buf())
end

--- Whether a buffer holds nothing: one empty line, the way an empty file reads.
---
--- Two lines are read and no more, because the answer is in the first one: the indicator asks
--- this on every applied remote edit, and a whole-buffer read there would copy a file per
--- keystroke of a peer's.
local function buffer_empty(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, 2, false)
  return #lines == 0 or (#lines == 1 and lines[1] == '')
end

--- The buffers a guest session put on screen, captured before its documents are forgotten: they
--- are the room's only for as long as the session holds them. A host's buffers are its own
--- files, which outlive the room, so there is nothing here for a host to land.
--- Whether this connection is a peer rather than the room's host: a guest, or a viewer. The two
--- differ in what the room accepts from them (§13.9 refuses a viewer's content) and not in where
--- the room's documents live, which is what most of these rules are about.
local function is_peer()
  return state.role == 'guest' or state.role == 'viewer'
end


M.buffer_empty = buffer_empty
M.current_document = current_document
M.document_for_buf = document_for_buf
M.in_session = in_session
M.is_peer = is_peer
M.state = state

return M
