-- Selvage for Neovim: the commands, and which buffers a session shares.
--
-- Everything that decides anything about a document is in the companion process
-- (`companion/`, driving the vendored engine and bridge). What is here is which buffer is
-- shared under which room path, and the wiring between the two.

local companion = require('selvage.companion')
local Document = require('selvage.document')
local mirror = require('selvage.mirror')
local utf16 = require('selvage.utf16')

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local state = {
  process = nil,
  status = 'idle',
  --- Whether the companion is re-establishing a connection it lost. The engine retries a
  --- dropped socket on its own and says so locally; the companion passes that on, so the row
  --- reads `reconnecting…` while it lasts instead of the person finding out by typing into a
  --- replica nobody hears.
  reconnecting = false,
  role = nil,
  room = nil,
  invite = nil,
  --- @type table<string, table> room path to document
  documents = {},
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
  --- The held paths a fresh open never received, which a listing leaving them named once per path.
  gone = {},
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
  --- nothing: every report redrew every caret's highlight, at a highlight set per cursor per
  --- report, on top of the marks the draw already recreates.
  peer_paints = {},
  peer_count = 0,
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
  --- The host's absence, while the room waits out its grace: the name to say and the deadline the
  --- countdown is derived from. Nil while the host is present.
  host_away = nil,
  --- The repeating timer that redraws the host-away countdown, or nil when none is running.
  host_away_timer = nil,
  --- The display name of the room's host, remembered from a peers report so the sentence that says
  --- they left can name them: `host.detached` carries no name, and `peer.left` has already removed
  --- them from the room by the time it arrives.
  host_name = nil,
  --- Whether the session highlight is set for the current colorscheme. A colorscheme runs
  --- `highlight clear`, which takes it, so the flag is dropped there and the group is made again.
  session_painted = false,
  --- A go-to whose landing cannot be made yet: the peer id and the label the refusal would
  --- name. A one-shot follow — every room event that could have brought the text tries it
  --- again, and the first landing, refusal or departure clears it.
  pending_go_to = nil,
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

--- The room paths this session holds, ordered so that completion and a prompt agree.
function M.documents()
  local paths = vim.tbl_keys(state.documents)
  table.sort(paths)
  return paths
end

--- What the room offers: its grant, and the paths it holds open, ordered as `documents()` is.
---
--- The union is deliberate rather than the grant alone, so a server that has no grant — one
--- older than `doc.grant` — still offers everything the room knows, and a document shared after
--- the listing was published is reachable as well. What this is *not* is a statement of what
--- this session holds: a granted path with no buffer behind it is offered and openable, and
--- `documents()` is still the answer to which paths it holds.
function M.offered()
  local seen = {}
  local paths = {}
  for _, path in ipairs(state.grant) do
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for _, path in ipairs(M.documents()) do
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

--- The paths the room's listing names, ordered as `offered()` is: what `:SelvageFetch` can be
--- given, and what its completion offers.
---
--- The listing rather than everything the room offers: a document the room holds open that its
--- listing does not name has no file in the mirror, so there is nothing to fetch for it.
function M.fetchable()
  local paths = {}
  for _, path in ipairs(state.grant) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

--- Where the session stands, for a statusline or a script.
---
--- `mirror` is the directory this session materialises the room into, for a guest whose room
--- listed something, and nil otherwise: it is where a plugin that reads the filesystem has to
--- look, because nothing else tells a person where the room is.
function M.session()
  return {
    status = state.status,
    role = state.role,
    room = state.room,
    invite = state.invite,
    documents = M.documents(),
    mirror = mirror.root(),
  }
end

--- The text of a shared document, as the room holds it.
function M.text(path)
  local document = state.documents[path]
  return document and document:text() or nil
end

local function notify(message, level)
  vim.notify('selvage: ' .. message, level or vim.log.levels.INFO)
end

--- A duration as a person reads it: whole seconds, rounded, which is the unit the room's
--- deadlines are named in and the one the other client shows.
local function seconds(ms)
  return math.max(0, math.floor((tonumber(ms) or 0) / 1000 + 0.5))
end

--- The whole seconds left before `deadline`, rounded up: a deadline twelve and a half seconds away
--- still has thirteen seconds to run and reads so, and a passed one reads zero rather than a
--- negative count. Derived from the deadline on every read, so the number a person sees is the
--- room's clock rather than a value printed once when the countdown started.
---
--- @param deadline number a `uv.now()` millisecond timestamp
--- @return integer
local function until_seconds(deadline)
  local left = (tonumber(deadline) or 0) - uv.now()
  if left <= 0 then
    return 0
  end
  return math.ceil(left / 1000)
end

--- How long after the first caret event a selection reaches the companion.
---
--- A caret moves on every keystroke — the buffer's own text moves it again when a line is
--- inserted — so one send per event would put a message on the IPC, and a presence update on
--- the wire, for every character typed. Events are coalesced into one flush per interval, which
--- is under the threshold at which a caret reads as lagging, and the flush reads the caret when
--- it runs, so what a burst publishes is where the caret ended.
local SELECTION_INTERVAL_MS = 100

--- The namespace every peer mark lives in. A test finds it by name:
--- `nvim_get_namespaces()['selvage.presence']`.
local function presence_namespace()
  if state.presence_ns == nil then
    state.presence_ns = api.nvim_create_namespace('selvage.presence')
  end
  return state.presence_ns
end

--- The highlight group a peer's caret block and sign are drawn in, made once per peer from the
--- colour the bridge derived, so a peer is the same colour in every client: black on the
--- peer's own colour, a block over the caret's cell and a legible sign in the gutter alike.
local function peer_highlight(cursor)
  local name = state.peer_groups[cursor.peerId]
  if name == nil then
    state.peer_count = state.peer_count + 1
    name = 'SelvagePeer' .. state.peer_count
    state.peer_groups[cursor.peerId] = name
  end
  -- The set is the cost, not the name: a colour that did not move since the last report keeps
  -- the highlight it already has.
  local paints = state.peer_paints[cursor.peerId]
  if paints == nil then
    paints = {}
    state.peer_paints[cursor.peerId] = paints
  end
  local paint = tostring(cursor.colour or '#888888')
  if paints.group ~= paint then
    paints.group = paint
    api.nvim_set_hl(0, name, { fg = '#000000', bg = cursor.colour or '#888888', bold = true })
  end
  return name
end

--- The RGB channels of a `#rrggbb` colour, or nil for anything else.
local function channels(colour)
  local r, g, b = tostring(colour or ''):match('^#(%x%x)(%x%x)(%x%x)')
  if r == nil then
    return nil
  end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

--- The alpha the bridge gave a selection's fill, or its own quarter when it named none.
local function fill_alpha(fill)
  local alpha = tostring(fill or ''):match('^#%x%x%x%x%x%x(%x%x)$')
  return alpha ~= nil and tonumber(alpha, 16) / 255 or 0.25
end

--- The highlight a peer's selection is filled with, made once per peer beside the caret one.
---
--- The bridge hands the fill as `#rrggbbaa` and a buffer highlight takes an opaque
--- `#rrggbb`, so the alpha is resolved here: against the editor's own background, so the fill
--- is a tint the text stays legible on rather than the peer's colour painted over it, which is
--- the trade a `Visual` highlight makes too. A theme with no `Normal` background has the
--- colour its `background` option names.
local function peer_fill(cursor)
  local name = state.peer_fills[cursor.peerId]
  if name == nil then
    state.peer_count = state.peer_count + 1
    name = 'SelvagePeer' .. state.peer_count .. 'Fill'
    state.peer_fills[cursor.peerId] = name
  end
  local paints = state.peer_paints[cursor.peerId]
  if paints == nil then
    paints = {}
    state.peer_paints[cursor.peerId] = paints
  end
  local background = api.nvim_get_hl(0, { name = 'Normal' }).bg
  if background == nil then
    background = vim.o.background == 'light' and 0xffffff or 0x000000
  end
  -- The fill, the colour and the background it was resolved against: a report that moves
  -- none of them keeps the highlight it already has, a theme switch included.
  local paint = tostring(cursor.colour) .. '\0' .. tostring(cursor.fill) .. '\0' .. tostring(background)
  if paints.fill ~= paint then
    paints.fill = paint
    local r, g, b = channels(cursor.colour)
    if r == nil then
      api.nvim_set_hl(0, name, {})
      return name
    end
    local nr = math.floor(background / 65536) % 256
    local ng = math.floor(background / 256) % 256
    local nb = background % 256
    local alpha = fill_alpha(cursor.fill)
    local function mix(fore, back)
      return math.floor(fore * alpha + back * (1 - alpha) + 0.5)
    end
    api.nvim_set_hl(0, name, { bg = ('#%02x%02x%02x'):format(mix(r, nr), mix(g, ng), mix(b, nb)) })
  end
  return name
end

--- Withdraws every mark drawn for a peer, so a presence report that no longer names one leaves
--- nothing of theirs behind.
local function clear_presence()
  local ns = state.presence_ns
  if ns == nil then
    return
  end
  for _, mark in ipairs(state.presence_marks) do
    pcall(api.nvim_buf_del_extmark, mark.bufnr, ns, mark.id)
  end
  state.presence_marks = {}
end

--- The sign a peer's caret carries in the gutter. `sign_text` takes one or two cells: the
--- first two characters of the name tell two peers whose names share an initial apart — `pi`
--- and `pc` both begin with `p` — and the colour tells the rest apart. A wide character takes
--- both cells on its own, so the second character is only taken when it still fits.
local function peer_sign(label)
  local first = vim.fn.strcharpart(label or '', 0, 1)
  if first == '' then
    return '•'
  end
  local two = vim.fn.strcharpart(label, 0, 2)
  return vim.fn.strdisplaywidth(two) <= 2 and two or first
end

--- The byte column just past the character at `col`, which is where a cell's block ends. One
--- code point, so a wide or an astral character is coloured whole rather than half.
local function cell_end(line, col)
  return vim.fn.byteidx(line, vim.fn.charidx(line, col) + 1)
end

--- The byte column the character before `col` starts at, or nil when there is none: the start
--- of a line. That character is the cell a caret at this offset is drawn on — the one the caret
--- is in front of rather than the one it has reached. A column inside a character, which the
--- room's offsets never produce, names the character before it.
local function cell_before(line, col)
  if col <= 0 then
    return nil
  end
  local index = vim.fn.charidx(line, col) - 1
  if index < 0 then
    return nil
  end
  return vim.fn.byteidx(line, index)
end

--- The session row redraw lives with the indicators far below, and a presence report is the other
--- draw that reaches every window — a row names no peer, and that is the frame it has to survive.
--- Declared here so the draw can call it; assigned where the row is drawn.
local refresh_indicators

--- Publishes where every drawn peer is, for a plugin that decorates a file list of its own
--- (netrw, oil, nvim-tree, telescope): `vim.g.selvage_file_peers` is `{ [room_path] = { { initials,
--- colour, label, peerId } } }` and `User SelvagePresence` fires whenever it changes. This client
--- draws the row itself and depends on none of them.
local function publish_file_peers()
  local by_path = {}
  for _, peer in ipairs(state.peers) do
    if type(peer.path) == 'string' then
      local list = by_path[peer.path]
      if list == nil then
        list = {}
        by_path[peer.path] = list
      end
      list[#list + 1] = {
        initials = peer.sign,
        colour = peer.colour,
        label = peer.label,
        peerId = peer.peerId,
      }
    end
  end
  vim.g.selvage_file_peers = by_path
  api.nvim_exec_autocmds('User', { pattern = 'SelvagePresence' })
end

--- Draws the peer carets a presence report resolved, and the ranges behind the ones that
--- selected something. Every mark is recreated rather than moved: a mark travels with the
--- buffer's edits, but where a peer *is* changes, and a mark for a peer the report no longer
--- names would otherwise stay behind.
---
--- The caret is a block cursor on the cell *before* the room's offset: the character the peer
--- is in front of, not the one it has reached. The room's offset names a position between two
--- cells, and a block has to pick one; the one it picks is the cell to the left of the caret,
--- which is what a caret drawn as a bar in front of a character means. The character under the
--- block stays readable through it. The start of a line has
--- no cell to the left, so the block stays on the cell the caret is on, where a bar at the
--- line's start is drawn; an empty line has no cell either, and the block is the single one
--- placed in the empty cell. Neither inserts anything, so the line keeps its width and the caret
--- stays against the selection fill rather than beside it. A row of its own above the line reads
--- the position wrong, as before: a virtual line starts at the text column, not the caret's.
local function draw_presence(cursors)
  -- The report is the companion's, and a misshapen one must not wedge the drawing: `ipairs`
  -- over a string errors inside the job callback, aborting the message with the follow and
  -- go-to retries piggybacked on it. Anything but a table clears the drawing; a cursor entry
  -- that is not a table is skipped where it stands.
  if type(cursors) ~= 'table' then
    cursors = {}
  end
  state.cursors = cursors
  state.peers = {}
  clear_presence()
  local ns = presence_namespace()
  for _, cursor in ipairs(state.cursors) do
    if type(cursor) == 'table' then
      -- The offsets are the companion's: a table cursor with a held path but missing or
      -- non-numeric offsets would fail in the comparison and `position` calls below,
      -- inside the job callback, aborting the message with the retries piggybacked on it.
      local document = type(cursor.path) == 'string' and state.documents[cursor.path] or nil
      if
        document ~= nil
        and api.nvim_buf_is_valid(document.bufnr)
        and type(cursor.anchor) == 'number'
        and type(cursor.head) == 'number'
      then
        local label = cursor.label or cursor.peerId or 'peer'
        local name = peer_highlight(cursor)
        -- What the gutter shows is built here, where it is drawn, so the list `:SelvagePeers`
        -- prints is this session's own rendering of the peers rather than a second opinion on it.
        state.peers[#state.peers + 1] = {
          peerId = cursor.peerId,
          label = label,
          sign = peer_sign(label),
          role = cursor.role,
          path = cursor.path,
          colour = cursor.colour,
          highlight = name,
        }
        -- The selection first, so the caret block sits over it. `anchor` after `head` is a
        -- selection made backwards, which is still a selection: the range is the two ends in
        -- order, and a collapsed one is a caret with nothing to fill.
        if cursor.anchor ~= cursor.head then
          local from, to = cursor.anchor, cursor.head
          if from > to then
            from, to = to, from
          end
          local from_row, from_col = document:position(from)
          local to_row, to_col = document:position(to)
          local ok, id = pcall(api.nvim_buf_set_extmark, document.bufnr, ns, from_row, from_col, {
            end_row = to_row,
            end_col = to_col,
            hl_group = peer_fill(cursor),
            priority = 100,
          })
          if ok then
            state.presence_marks[#state.presence_marks + 1] = { bufnr = document.bufnr, id = id }
          end
        end
        local row, col = document:position(cursor.head)
        local line = document:line(row)
        -- The offset names a position between two cells; the block goes on the one to the left.
        -- The start of a line has none, so the block falls back to the cell the caret is on.
        local from = cell_before(line, col)
        if from == nil then
          from = col
        end
        local caret = {
          sign_text = peer_sign(label),
          sign_hl_group = name,
          -- Above the fill, so the first cell of a backwards selection reads as the caret.
          priority = 110,
        }
        if from < #line then
          caret.end_row = row
          caret.end_col = cell_end(line, from)
          caret.hl_group = name
        else
          -- No cell at the caret either — an empty line — so the block is the one drawn in the
          -- empty cell. Nothing is inserted, so the line keeps its width.
          caret.virt_text = { { ' ', name } }
          caret.virt_text_pos = 'overlay'
        end
        local ok, id = pcall(api.nvim_buf_set_extmark, document.bufnr, ns, row, from, caret)
        if ok then
          state.presence_marks[#state.presence_marks + 1] = { bufnr = document.bufnr, id = id }
        end
      end
    end
  end
  -- After the draw, because which peers stand in a buffer is only known once every cursor is
  -- drawn: that set is what the seam below publishes. Every window's row is redrawn from it too,
  -- and a row that names no peer is what that redraw has to leave.
  publish_file_peers()
  refresh_indicators()
end

--- The peers the last presence report drew, keyed by peer id: the ones whose caret this client
--- can draw, and so the ones the gutter has a sign and a colour for.
local function drawn_by_id()
  local drawn = {}
  for _, peer in ipairs(state.peers) do
    drawn[peer.peerId] = peer
  end
  return drawn
end

--- The room's participants: every peer the room names, each with what this session knows about
--- it. A peer the room names whose document this client does not hold is listed all the same: the
--- list is the room's, and someone looking for a person here should find them whether or not their
--- caret is on screen. That row carries no `sign`, `highlight` or `colour`, because those are the
--- two cells and the colour the gutter draws — a list that explains the gutter has to agree with
--- it cell for cell, and a peer the gutter drew nothing for has nothing there to explain.
---
--- `label` is the whole display name the two cells abbreviate, or the peer id when the room left
--- the name blank; `path` is the document the peer is in as the room's presence said. `sign` is
--- what the gutter shows, so a reader holding the two cells has one lookup to make, and
--- `highlight` is the very group the caret and the sign are drawn with.
function M.peers()
  local drawn = drawn_by_id()
  local peers = {}
  local named = {}
  for _, peer in ipairs(state.room_peers) do
    local name = tostring(peer.display_name or '')
    local mine = drawn[peer.peer_id]
    named[peer.peer_id] = true
    peers[#peers + 1] = {
      peerId = peer.peer_id,
      label = name ~= '' and name or tostring(peer.peer_id),
      role = peer.role,
      path = mine and mine.path or nil,
      sign = mine and mine.sign or nil,
      colour = mine and mine.colour or nil,
      highlight = mine and mine.highlight or nil,
    }
  end
  -- A peer the last presence report drew and the room has not named: there is no session report
  -- to list them from, and the caret on screen is still someone.
  for _, peer in ipairs(state.peers) do
    if not named[peer.peerId] then
      peers[#peers + 1] = vim.deepcopy(peer)
    end
  end
  return peers
end

--- Lists the session's participants: each sign beside the whole name it stands for, in the
--- colour both are drawn in. Echoed rather than notified, because a notification provider may
--- render a message as plain text and the colour is the point. A peer this client holds no
--- document for has no sign and no colour, and is listed by name and role alone.
function M.list_peers()
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local peers = M.peers()
  if #peers == 0 then
    notify('no other participants yet.', vim.log.levels.WARN)
    return
  end
  local chunks = {}
  for _, peer in ipairs(peers) do
    if #chunks > 0 then
      chunks[#chunks + 1] = { '\n' }
    end
    if peer.sign ~= nil then
      chunks[#chunks + 1] = { peer.sign, peer.highlight }
    end
    chunks[#chunks + 1] = {
      ('  %s  (%s, %s)'):format(
        peer.label,
        tostring(peer.role or 'participant'),
        tostring(peer.path or 'not in a document')
      ),
    }
  end
  api.nvim_echo(chunks, true, {})
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

--- The caret as the two UTF-16 offsets the room counts. In Visual mode the selection's other
--- end is the anchor; a caret is both ends alike.
local function caret(document)
  local cursor = api.nvim_win_get_cursor(0)
  local head = document:offset(cursor[1] - 1, cursor[2])
  local anchor = head
  local mode = vim.fn.mode(1)
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local start = vim.fn.getpos('v')
    if start[2] > 0 and start[3] > 0 then
      anchor = document:offset(start[2] - 1, start[3] - 1)
    end
  end
  return anchor, head
end

--- Publishes where the caret is now, or clears it when the user is not in a shared document.
--- The state is read at flush time, so a burst of movement costs one look and one message.
local function publish_selection()
  state.selection_armed = false
  if state.process == nil then
    return
  end
  local document = current_document()
  if document == nil then
    if state.selection_path ~= false then
      state.process:send({ type = 'selectionCleared' })
      state.selection_path = false
    end
    return
  end
  local anchor, head = caret(document)
  state.process:send({ type = 'selection', path = document.path, anchor = anchor, head = head })
  state.selection_path = document.path
end

--- Arms the one flush the interval allows. Called from every event that can have moved the
--- caret; only the first arms, so the rest cost nothing.
local function schedule_selection()
  if state.process == nil or state.selection_armed then
    return
  end
  state.selection_armed = true
  local generation = state.generation
  vim.defer_fn(function()
    if generation ~= state.generation then
      -- The session this was armed under has ended; a fresh one publishes its own caret.
      return
    end
    publish_selection()
  end, SELECTION_INTERVAL_MS)
end

--- Watches the events that move the caret within the shared documents. A guest needs them as
--- much as a host: both ends publish a caret and both draw the other's.
local function watch_presence()
  state.presence_group = api.nvim_create_augroup('SelvagePresence', { clear = true })
  api.nvim_create_autocmd({
    'CursorMoved',
    'CursorMovedI',
    'ModeChanged',
    'BufEnter',
    'WinEnter',
    'TextChanged',
    'TextChangedI',
  }, {
    group = state.presence_group,
    callback = schedule_selection,
  })
  -- A colorscheme runs `highlight clear`, which takes the peer groups the session made with
  -- it: without this the paint cache would skip setting them ever again, leaving carets
  -- and fills unstyled for the rest of the session. The session row's own group goes the same
  -- way, so its flag is dropped with them.
  api.nvim_create_autocmd('ColorScheme', {
    group = state.presence_group,
    callback = function()
      state.peer_paints = {}
      state.session_painted = false
      draw_presence(state.cursors)
    end,
  })
end

--- The folder this session's grant is rooted at: where the person stood when they started it.
--- Called as a session starts, before the buffer in front of them is shared.
---
--- The root is kept as a prefix — `/` separators, no trailing slash — so a buffer's own path
--- can be measured against it with one comparison. `getcwd()` answers with the directory in
--- force in this window, so a `:lcd` or `:tcd` made before the session is where the session
--- started, which is the folder the person chose to invite from.
local function capture_root()
  state.root = vim.fn.getcwd():gsub('\\', '/'):gsub('/+$', '')
end

--- Says, once per path, that a file is not the room's to share because it lies outside the
--- session's grant. Neovim shows no workspace the way the other client's window does, so
--- nothing else here tells a person which folder the room can see: a refusal nobody hears is
--- indistinguishable from a plugin that is not sharing at all.
local function refuse_outside(path)
  if state.outside[path] ~= nil then
    return
  end
  state.outside[path] = true
  notify(
    ('%s is outside %s, the folder this session shares, so it is not shared.'):format(
      path,
      state.root == '' and '/' or state.root
    ),
    vim.log.levels.WARN
  )
end

--- Says, once per buffer, that a buffer with no file is not the room's to share. Hosting from
--- an untitled buffer and typing is the newcomer's silence: the room never hears it, and
--- nothing else here says so.
local function refuse_unfiled(bufnr)
  if state.unfiled[bufnr] ~= nil then
    return
  end
  local root = state.root
  if root == nil then
    return
  end
  state.unfiled[bufnr] = true
  notify(
    ('this buffer has no file, so it is not shared; the folder this session shares is %s.'):format(
      root == '' and '/' or root
    ),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that a buffer's name is not a regular file and so is not the room's
--- to share. The serve path a peer's ask takes refuses every link (`companion/grant.ts`
--- reads with `O_NOFOLLOW`); the share path must not read straight through one and publish
--- the target's bytes. The name is read with `lstat`, which reports the link itself.
local function refuse_link(path)
  if state.linked[path] ~= nil then
    return
  end
  state.linked[path] = true
  notify(('%s is not a regular file, so it is not shared.'):format(path), vim.log.levels.WARN)
end

--- The room path a buffer is shared under, and the absolute name it is refused for when it
--- is not one to share.
---
--- The grant is the folder the session was started in (`DESIGN.md` §4.2), so a name is
--- measured against that and never against the working directory, which `:cd` moves at any
--- moment. A name is absolute — Neovim resolves it when it sets one — and the separator in
--- the prefix is what keeps a sibling whose name merely begins with the grant's out of it.
--- A file outside the grant comes back as the second value so the refusal can be said;
--- anything that is not a file buffer comes back as neither, so its own refusal can be.
local function room_path(bufnr)
  if vim.bo[bufnr].buftype ~= '' then
    return nil, nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil, nil
  end
  local root = state.root
  if root == nil then
    return nil, nil
  end
  local absolute = (name:gsub('\\', '/'))
  local prefix = root .. '/'
  if absolute:sub(1, #prefix) == prefix then
    return absolute:sub(#prefix + 1), nil
  end
  if absolute:sub(1, 1) == '/' or absolute:match('^%a:/') ~= nil then
    return nil, absolute
  end
  return nil, nil
end

--- Ends the follow, defined alongside the follow below: `share` is what hears a local edit
--- first, and it is defined before that section.
local end_follow

--- The largest file a session carries, mirroring `MAX_GRANT_FILE_BYTES` in the grant's own rules
--- (`vendor/bridge/grant.ts`, and `MAX_GRANT_PATH_BYTES` is mirrored the same way in
--- `mirror.lua`). A file past it is one the companion refuses for its size before it reads a byte,
--- so the share path does not read one either.
local MAX_FILE_BYTES = 1024 * 1024

--- Whether a session may carry the file a buffer is named for: its **bytes**, as they stand on
--- disk, are text — no NUL byte, and well-formed UTF-8. The same gate the companion applies to a
--- peer's request for the file (`companion/grant.ts`, `decodableText`), reached from the other
--- side of the same question.
---
--- The buffer's own text cannot stand in for it. Neovim reads a file whose bytes are not UTF-8 as
--- Latin-1 (`'fileencodings'`' own fallback, which is how a `.bin` opens at all), so the buffer
--- holds a transliteration: every byte became a character, and the text the buffer reports is
--- well-formed UTF-8 whatever the file was. That text is what a session publishes, and a peer's
--- later edit made the room's save policy write it back over the host's own file — the file's
--- original bytes survive that round trip only because the same `'fileencoding'` converts them
--- back, which stops being true the moment a peer types a character it cannot hold.
---
--- `true` when the bytes are text, `false` when they are not, and nil when the file could not be
--- read in one piece at all — a file that moved under the read is not a prefix of itself to judge,
--- and what a buffer holds for it is not what the bytes say.
---
--- @param name string the file the buffer is named for
--- @return boolean|nil
local function file_is_text(name)
  local fd = uv.fs_open(name, 'r', tonumber('644', 8))
  if fd == nil then
    return nil
  end
  local bytes
  local ok = pcall(function()
    local opened = uv.fs_fstat(fd)
    -- The descriptor is what the bytes are read from, so the size is read there as well: a name
    -- may have been another file's by the time it is opened.
    if opened == nil or opened.type ~= 'file' then
      return
    end
    local chunks = {}
    local read = 0
    while read < opened.size do
      local chunk = uv.fs_read(fd, opened.size - read, read)
      if chunk == nil or #chunk == 0 then
        break
      end
      chunks[#chunks + 1] = chunk
      read = read + #chunk
    end
    -- Fewer bytes than the descriptor holds is not a prefix of the file to judge: it is a file
    -- that moved under the read, and what it holds now is not what the buffer was read from.
    if read == opened.size then
      bytes = table.concat(chunks)
    end
  end)
  uv.fs_close(fd)
  if not ok or bytes == nil then
    return nil
  end
  return bytes:find('\0', 1, true) == nil and utf16.valid(bytes)
end

--- Says, once per path, that a file a person opened is not one a room can carry: its bytes are not
--- text. The companion says the same thing about the same file when a peer asks the room for it.
local function refuse_binary(path)
  if state.unshareable[path] ~= nil then
    return
  end
  state.unshareable[path] = true
  notify(
    ('%s is a binary file, and a room carries text, so it is not shared.'):format(path),
    vim.log.levels.ERROR
  )
end

--- Says, once per path, that a file could not be read, so nothing was shared for it. A file that
--- moved between the buffer's own read and this one is one whose bytes are not known, and what a
--- session cannot judge is not carried: the text the buffer holds for it may be a transliteration
--- of bytes it no longer has (`file_is_text`). Entering the buffer again looks again, so this is
--- said once rather than once per visit.
local function refuse_unreadable(path)
  if state.unshareable[path] ~= nil then
    return
  end
  state.unshareable[path] = true
  notify(('%s could not be read, so it is not shared.'):format(path), vim.log.levels.WARN)
end

--- A `viewer`'s editor is read-only in the room.
---
--- §13.9 gives a viewer its own edit and publishes none of it, so a buffer that accepted one
--- would show text the room never receives — a keystroke the person believes is shared, which is
--- worse than a refusal. Only a `selvage/2` room can seat a viewer: the role is the room state's
--- (§13.4) and version 1's server seats nobody as anything.
local function apply_read_only_writable(bufnr)
  if bufnr ~= nil and api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].modifiable = true
  end
end

local function apply_read_only(bufnr)
  if bufnr == nil or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = state.role ~= 'viewer'
end

--- Every room document this session holds, read-only or not as the role says. Called where a
--- role arrives and where a document does, so a viewer that joined an empty room and one that
--- joined a full one end up the same.
local function apply_read_only_to_room()
  for _, document in pairs(state.documents) do
    apply_read_only(document.bufnr)
  end
end

local function share(bufnr, path)
  if state.process == nil or state.documents[path] ~= nil then
    return
  end
  -- The buffer's name is read with `lstat` before its text is: a link inside the grant
  -- would otherwise be read straight through and its target's bytes published to the room,
  -- which the serve path a peer's ask takes refuses. Anything but a regular file — a link,
  -- a directory, a socket — is refused the way a file outside the grant is. A name with
  -- nothing behind it is a file the person has not written yet, and shares empty.
  local behind = uv.fs_lstat(api.nvim_buf_get_name(bufnr))
  if behind ~= nil and behind.type ~= 'file' then
    refuse_link(path)
    return
  end
  -- The same text `Document.new` will shadow, read once. The companion decodes its stdin as
  -- UTF-8, so a buffer whose bytes are not UTF-8 would reach the room as U+FFFD; refusing it
  -- here keeps the `open` out of the room and every later `change` with it.
  local text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n')
  if not utf16.valid(text) then
    if state.unshareable[path] == nil then
      state.unshareable[path] = true
      notify(('%s is not valid UTF-8, so it is not shared.'):format(path), vim.log.levels.ERROR)
    end
    return
  end
  -- A buffer's text is not the file's bytes: Neovim decodes a file it cannot read as UTF-8 into
  -- one, so a buffer can hold text that reads as valid UTF-8 while the file it was read from
  -- holds a binary. The room is refused the file it cannot carry rather than the transliteration
  -- of it — the same refusal a peer asking for the path is given, from the same question.
  --
  -- A file past the bound is not read at all: the companion judges the text the buffer holds and
  -- refuses one past the session's own bound, in words that say so. What that leaves is a file
  -- past the bound whose decoded text is not (a UTF-16 file, say), and that one is carried: its
  -- text is the file's rather than a transliteration of it, so nothing is written back over the
  -- file that the file did not hold.
  if behind ~= nil and behind.size <= MAX_FILE_BYTES then
    local bytes_are_text = file_is_text(api.nvim_buf_get_name(bufnr))
    if bytes_are_text == false then
      refuse_binary(path)
      return
    end
    if bytes_are_text == nil then
      refuse_unreadable(path)
      return
    end
  end
  local document = Document.new(bufnr, path, function(message)
    -- A local edit of a shared document ends a follow: with the caret moved by the follow,
    -- typing and following are in direct conflict, and the keystroke has already chosen the
    -- place. A remote edit never reaches this closure — `Document:apply` writes the buffer
    -- under its own flag and sends nothing — so only an edit made here ends one.
    if message.type == 'change' and state.following ~= nil then
      end_follow('stopped')
    end
    state.process:send(message)
  end)
  state.documents[path] = document
  document:attach()
  apply_read_only(bufnr)
  state.process:send({ type = 'open', path = path, text = text })
  -- The document may already have a peer's caret resolved against it, and this buffer's own
  -- caret is worth publishing the moment the room holds it.
  draw_presence(state.cursors)
  schedule_selection()
end

--- The buffer a guest holds the room's document in.
---
--- For a path the room's grant names, that is the mirror's file: a real path on disk, so that a
--- language server, ripgrep, ctags and every plugin that reads one sees the file the person is
--- editing. The file is read into the buffer the way `:edit` reads it, so the buffer really is a
--- file buffer — its `:w` is the session's to route, and a plugin that looks at the buffer finds
--- the file behind it. A document the grant does not name has nowhere to go and stays a
--- `selvage://` buffer, which is what it was before the mirror existed.
---
--- @param path string the room path
--- @return integer bufnr
local function guest_buffer(path)
  local name = mirror.buffer_name(path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end
  if name == 'selvage://' .. path then
    local bufnr = api.nvim_create_buf(true, true)
    state.suppress_rename = true
    local ok, err = pcall(api.nvim_buf_set_name, bufnr, name)
    state.suppress_rename = false
    if not ok then
      error(err)
    end
    vim.bo[bufnr].modifiable = true
    return bufnr
  end
  local bufnr = api.nvim_create_buf(true, false)
  state.suppress_rename = true
  local named, name_err = pcall(api.nvim_buf_set_name, bufnr, name)
  state.suppress_rename = false
  if not named then
    error(name_err)
  end
  api.nvim_buf_call(bufnr, function()
    vim.cmd('silent noautocmd edit!')
  end)
  -- `noautocmd` keeps the session's own hooks and the person's out of the way while the buffer is
  -- made, and it also suppresses what the `filetypedetect` group does on `BufRead`: the buffer is
  -- named for a real file and would hold no `filetype`, and so no syntax. Detection is therefore
  -- asked for directly, by the same name the buffer carries.
  local filetype = vim.filetype.match({ buf = bufnr, filename = name })
  if filetype ~= nil then
    vim.bo[bufnr].filetype = filetype
  end
  vim.bo[bufnr].modifiable = true
  return bufnr
end

--- Says, once per path, that a file inside the mirror is not one the room knows: a tool that
--- created it there made a file on this disk and nothing else, and a person who edits it should
--- hear that before they think the room has it.
---
--- @param path string the room path as the mirror's file names it
local function refuse_unlisted(path)
  if state.unlisted[path] ~= nil then
    return
  end
  state.unlisted[path] = true
  notify(
    ('%s is not in the room, so it is not shared; the mirror holds the room\'s files and is removed when the session ends.'):format(path),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that the mirror would not write a file: the room has no document for it,
--- so a save would put a file into a cache the session deletes and the room would never hold.
--- The buffer keeps the text, so the person can still save it somewhere of their own choosing.
---
--- @param path string the room path as the mirror's file names it
local function refuse_mirror_write(path)
  if state.unwritable[path] ~= nil then
    return
  end
  state.unwritable[path] = true
  notify(
    ('%s is not in the room, so the mirror did not write it; save it outside the mirror to keep it.'):format(path),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that the room has no frame for a file mutation: create, rename and
--- delete stay out of v1, so the file is refused where the editor names it.
---
--- @param path string the room path as the mirror's file names it
local function refuse_mutation(path)
  if state.unmutated[path] ~= nil then
    return
  end
  state.unmutated[path] = true
  notify('the room carries no file mutations yet.', vim.log.levels.WARN)
end

--- Says, once per path, that a freshly opened document never arrived because the listing left
--- it: the host no longer has the file, so the empty buffer is not content still loading.
--- The buffer stays — an open buffer is never taken away — and a document holding text is not
--- this: content that arrived, or the person's own keystrokes, is still the room's to keep.
---
--- @param path string the room path
local function notice_gone(path)
  if state.gone[path] ~= nil then
    return
  end
  state.gone[path] = true
  notify(
    ('%s is no longer in the room; the host no longer has it.'):format(path),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that a mirror file opened empty holds nothing yet because its content
--- has not been fetched: the shape is materialised and the content is not, so an empty file is
--- the expected sight, and `:SelvageFetch` is what fills it.
---
--- Said for the first such file in a session and never again: the sentence is for the shape,
--- and the shape is the same on every empty file, so one hint per file is a flood with
--- the file count. The paths are all still recorded, so a file fetched later is not news.
--- The join's own landing is the exception: while it is placed the hint is suppressed
--- outright, unrecorded, so the first file opened afterwards still earns it.
local function notice_unfetched(path)
  if state.suppress_unfetched then
    return
  end
  if state.unfetched[path] ~= nil then
    return
  end
  local first = next(state.unfetched) == nil
  state.unfetched[path] = true
  if first then
    notify(('this file is empty until fetched; :SelvageFetch %s fills it.'):format(path))
  end
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

--- Shares the buffer in the window, or says why it is not the room's to share.
local function share_current()
  local bufnr = api.nvim_get_current_buf()
  local path, refused = room_path(bufnr)
  if path ~= nil then
    share(bufnr, path)
  elseif refused ~= nil then
    refuse_outside(refused)
  else
    refuse_unfiled(bufnr)
  end
end

--- Puts a buffer in the window the user is looking at.
local function show(bufnr)
  if bufnr == nil or not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return pcall(api.nvim_win_set_buf, 0, bufnr)
end

--- The room path a user's words name: the room path, its `selvage://` buffer name, its file in
--- the mirror, or a suffix of the path at a directory boundary. A host above a folder called
--- `workspace` publishes `workspace/README.md`; a guest who types `README.md` means that one.
---
--- The search is over what the room offers, so a path the grant named and nobody has opened is
--- as nameable as one with a buffer behind it.
---
--- @param wanted string
--- @return string|nil resolved, string[] matches
local function resolve(wanted)
  wanted = wanted:gsub('^selvage://', '')
  local root = mirror.root()
  if root ~= nil and wanted:sub(1, #root + 1) == root .. '/' then
    wanted = wanted:sub(#root + 2)
  end
  local offered = M.offered()
  for _, candidate in ipairs(offered) do
    if candidate == wanted then
      return wanted, {}
    end
  end
  local matches = {}
  for _, candidate in ipairs(offered) do
    if candidate:sub(-(#wanted + 1)) == '/' .. wanted then
      matches[#matches + 1] = candidate
    end
  end
  if #matches == 1 then
    return matches[1], matches
  end
  return nil, matches
end

--- Puts a room path in the window: the buffer this session already holds for it, or the buffer
--- a guest's room path is shown in when the room offers it and nobody has opened it yet.
---
--- A granted path goes through exactly what a room document goes through — a buffer and an `open`
--- the companion turns into a hold — because the room is what has the content: the host reads its
--- working copy when it is asked, and a path with no `Document` behind it is not one this session
--- holds. The buffer is the mirror's file when the grant names the path, and a `selvage://` one
--- when it does not.
local function reveal(path)
  local document = state.documents[path]
  if document ~= nil then
    return show(document.bufnr)
  end
  local bufnr = guest_buffer(path)
  share(bufnr, path)
  return show(bufnr)
end

local function choose(paths)
  vim.ui.select(paths, { prompt = 'selvage: open which document?' }, function(choice)
    if choice ~= nil then
      reveal(choice)
    end
  end)
end

--- Opens one of the room's documents in the current window.
---
--- With no argument and one document, that document; with several, the user is asked which.
--- What is offered is the room's grant unioned with the documents it holds, so a path the host
--- listed and nobody has opened yet is offered too.
---
--- A host is refused: the room's documents are the host's own files, already in its buffer list,
--- and the command means the copy the room holds that a window does not have. Its own set is not
--- lost — `:SelvagePeers` and `require('selvage').session()` still report it.
function M.open(path)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('you are the host — the files you open are the ones your guests see.', vim.log.levels.INFO)
    return
  end
  local paths = M.offered()
  if #paths == 0 then
    notify('the room has no open documents yet.', vim.log.levels.INFO)
    return
  end
  local wanted = vim.trim(path or '')
  if wanted == '' then
    if #paths == 1 then
      reveal(paths[1])
    else
      choose(paths)
    end
    return
  end
  local resolved, candidates = resolve(wanted)
  if resolved == nil then
    if #candidates > 1 then
      notify(
        ('"%s" matches several: %s.'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no shared document matches "%s"; :SelvageOpen alone offers them.'):format(wanted),
        vim.log.levels.WARN
      )
    end
    return
  end
  reveal(resolved)
end

--- How many unarrived paths a fetch that ran out of time names.
local FETCH_NAMES = 3

--- How long a fetch waits, in total, for the room's content to arrive.
---
--- The room has to answer every hold and send every document it holds, and a fetch of a whole
--- project is a lot of both: this bounds silence rather than work, and it is given room to scale
--- with how much was asked for. A fetch that reaches it says what it got rather than failing,
--- because content that is late is still content. `vim.g.selvage_fetch_timeout_ms` sets it for a
--- run that knows better than the default.
---
--- @param count integer how many paths the fetch names
--- @return integer milliseconds
local function fetch_timeout_ms(count)
  local configured = tonumber(vim.g.selvage_fetch_timeout_ms)
  if configured ~= nil and configured > 0 then
    return configured
  end
  return math.min(60000, 5000 + 500 * count)
end

--- The room paths a fetch's argument names: the whole listing, one path of it, or a directory of
--- it. Nil and the paths it would have matched when the words name nothing the listing has.
---
--- The argument is read against the *listing* rather than against everything the room offers: a
--- document the room holds and its listing does not name has no file in the mirror, so there is
--- nothing to fetch for it.
---
--- @param wanted string
--- @return string[]|nil targets, string[]|nil candidates
local function fetch_targets(wanted)
  local paths = {}
  for _, path in ipairs(state.grant) do
    paths[#paths + 1] = path
  end
  if wanted == '' then
    return paths
  end
  local prefix = wanted .. '/'
  local under = {}
  for _, path in ipairs(paths) do
    if path == wanted then
      return { path }
    end
    if path:sub(1, #prefix) == prefix then
      under[#under + 1] = path
    end
  end
  if #under > 0 then
    return under
  end
  local resolved, candidates = resolve(wanted)
  if resolved ~= nil and mirror.granted(resolved) then
    return { resolved }
  end
  return nil, candidates
end

--- The paths of `pending` whose content the mirror does not hold yet, dropping the ones it does.
---
--- Fetched is the file, not a message: a path counts once the room's content has been written into
--- it, which is what a save does and what a fetch waits for. An empty file is not evidence of
--- anything, because an empty placeholder and an empty room document look exactly alike — so a
--- path this client holds but whose room's text never arrived is reported as not arrived, rather
--- than read back off disk as an answer.
---
--- @param pending table<string, boolean>
--- @return string[] unfetched
local function unfetched(pending)
  local left = {}
  for path in pairs(pending) do
    if mirror.written(path) then
      pending[path] = nil
    else
      left[#left + 1] = path
    end
  end
  return left
end

--- Fetches the room's content into the mirror: one file, a directory of them, or all of it.
---
--- A file's content arrives the way any shared document's does — the path is held in the room, the
--- host reads its working copy when the room asks, and the text comes back — so a fetch takes a
--- hold on what it names and opens it as a buffer without putting it in front of the user. What
--- writes the file is the same save that follows a document the room changed, which is why the
--- wait is for the file and not for a message: content is fetched when it is on disk and not
--- before, and a search over the mirror sees exactly that.
---
--- The command returns while the room answers: the completion is a later notice, said when
--- the files are on disk or when the wait runs out, so a slow room never holds the editor.
---
--- @param path string|nil one path, a directory of them, or nil for the whole listing
function M.fetch(path)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('your files are already on your disk, so there is nothing to fetch while you host.', vim.log.levels.INFO)
    return
  end
  if mirror.root() == nil then
    notify('the room lists no files to fetch.', vim.log.levels.INFO)
    return
  end
  local wanted = vim.trim(path or '')
  local targets, candidates = fetch_targets(wanted)
  if targets == nil then
    if candidates ~= nil and #candidates > 1 then
      notify(
        ('"%s" matches several: %s.'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no file the room lists matches "%s"; :SelvageOpen and completion name them.'):format(wanted),
        vim.log.levels.WARN
      )
    end
    return
  end
  if #targets == 0 then
    notify('the room lists no files to fetch.', vim.log.levels.INFO)
    return
  end
  local pending = {}
  local opening = 0
  for _, target in ipairs(targets) do
    if state.documents[target] == nil then
      opening = opening + 1
    end
  end
  if opening > 0 then
    -- A fetch is a hold: every path it takes joins the room's open-document set, so every peer
    -- receives it and, with a mirror, materialises it. Said before it happens, because a fetch of
    -- a whole listing is a whole project published and the sentence after it is too late to be a
    -- choice (`DESIGN.md` §4.2). A single path names itself; the plural is for the listing.
    if #targets == 1 then
      notify(('fetching opens %s in the room, so every peer receives it.'):format(targets[1]))
    else
      notify('fetching opens them in the room, so every peer receives them.')
    end
  end
  for _, target in ipairs(targets) do
    pending[target] = true
    local document = state.documents[target]
    if document == nil then
      share(guest_buffer(target), target)
    elseif not mirror.holds(target, document:text()) then
      -- A document this session already holds: the file is given what this client holds for the
      -- room, so that fetching a path whose file a tool overwrote is a fetch and not a no-op.
      -- The file is given what this client holds for the room, which is the room's text to
      -- the fetch's own accounting: writing it counts as fetched.
      document:save(true)
    end
  end
  -- The wait is a deferred re-check, not a foreground one: a fetch of a whole project holds
  -- the editor for up to a minute if the room is slow, and the command should return while
  -- the room answers. What is already held is said at once; the rest is said when it arrives
  -- or when the wait runs out.
  local timeout = fetch_timeout_ms(#targets)
  local generation = state.generation
  local deadline = uv.hrtime() + timeout * 1000000
  local function revisit()
    -- A fetch a later session outlived is that session's silence: the room it asked is gone,
    -- and its deadline must not speak into the one that replaced it. A session that ended
    -- with nothing after it still ends the wait the same way the foreground one did.
    if state.generation ~= generation and in_session() then
      return
    end
    if not in_session() then
      notify('the session ended before the files were fetched.', vim.log.levels.WARN)
      return
    end
    local left = unfetched(pending)
    if #left == 0 then
      notify('fetched the files.')
      return
    end
    if uv.hrtime() >= deadline then
      notify(
        ('fetched the files; these had not arrived within %ds: %s.'):format(
          seconds(timeout),
          table.concat(vim.list_slice(left, 1, math.min(#left, FETCH_NAMES)), ', ')
        ),
        vim.log.levels.WARN
      )
      return
    end
    vim.defer_fn(revisit, 50)
  end
  revisit()
end

-- -- going to a participant, and following one ------------------------------------
--
-- `:SelvageGoTo` lands where a participant is; `:SelvageFollow` keeps landing there as
-- they move, until something ends it. The landing moves the follower's caret: Neovim has
-- no durable viewport-only state — the next redraw pulls the viewport back over the
-- cursor — so following is being where they are, not watching from elsewhere. What
-- follows from that is the break rule: a local edit of a shared document ends the follow,
-- because the next keystroke lands where the caret is.

--- The drawn cursor for `peer_id` in the last presence report, or nil when the room drew
--- nothing for them: they are in no document, or in one this client does not hold and so
--- cannot resolve. What is not drawn cannot be landed on, so a follow re-lands only onto
--- these and anything else is a frame with nothing to do.
local function cursor_for(peer_id)
  for _, cursor in ipairs(state.cursors) do
    if cursor.peerId == peer_id then
      return cursor
    end
  end
  return nil
end

--- The participant row for `peer_id`, as `:SelvagePeers` prints it, or nil.
local function peer_row(peer_id)
  for _, peer in ipairs(M.peers()) do
    if peer.peerId == peer_id then
      return peer
    end
  end
  return nil
end

--- The name a row is picked by: the display name, disambiguated only when it must be.
--- Two people can share a name and the room does not forbid it, so the disambiguator is
--- the identity itself — the shortest prefix of the peer id that no other peer sharing
--- the name shares — and the command carries the full id.
local function row_name(peers, peer)
  local clash = false
  for _, other in ipairs(peers) do
    if other.peerId ~= peer.peerId and other.label == peer.label then
      clash = true
      break
    end
  end
  if not clash then
    return peer.label
  end
  local id = tostring(peer.peerId)
  for length = 1, #id do
    local prefix = id:sub(1, length)
    local shared = false
    for _, other in ipairs(peers) do
      if
        other.peerId ~= peer.peerId
        and other.label == peer.label
        and tostring(other.peerId):sub(1, length) == prefix
      then
        shared = true
        break
      end
    end
    if not shared then
      return ('%s (%s)'):format(peer.label, prefix)
    end
  end
  return ('%s (%s)'):format(peer.label, id)
end

--- The completion rows for the room's participants: the display name, disambiguated with
--- the peer id where two share one, so two people called Ada do not complete to the same
--- indistinguishable row. Every row names its peer back: the commands accept a
--- disambiguated row as well as a name (see `resolve_peer`).
function M.complete_peers()
  local peers = M.peers()
  local rows = {}
  for _, peer in ipairs(peers) do
    rows[#rows + 1] = row_name(peers, peer)
  end
  return rows
end

--- The participant `wanted` names: an exact peer id first, then a disambiguated row as the
--- several-refusal and completion print it, then the peers carrying that display name.
--- Returns the row; or nil with 'several' and the rows; or nil with 'none'.
local function resolve_peer(wanted)
  wanted = vim.trim(wanted or '')
  local peers = M.peers()
  for _, peer in ipairs(peers) do
    if peer.peerId == wanted then
      return peer
    end
  end
  for _, peer in ipairs(peers) do
    if row_name(peers, peer) == wanted then
      return peer
    end
  end
  local matches = {}
  for _, peer in ipairs(peers) do
    if peer.label == wanted then
      matches[#matches + 1] = peer
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    return nil, 'several', matches
  end
  return nil, 'none'
end

--- Opens the room's document at `path` so a landing has a buffer to place: a guest's
--- `selvage://` buffer or mirror file through the ordinary share, a host's own file under
--- the folder the session started in.
---
--- A host never creates: a path that does not resolve to a readable file inside the grant
--- is refused rather than opened into being, which `autoSave` would then write to disk.
--- Returns true once the document is held here — a guest's text still arrives over the
--- sync, so a landing waits a frame for it — or false with the reason, said as
--- `Could not open <path> from the room: <reason>`.
local function open_room_path(path)
  if state.role ~= 'host' then
    local made, bufnr_or_err = pcall(guest_buffer, path)
    if not made then
      return false, tostring(bufnr_or_err)
    end
    local shared, share_err = pcall(share, bufnr_or_err, path)
    if not shared then
      return false, tostring(share_err)
    end
    return true
  end
  local root = vim.fn.resolve(state.root or '')
  if root == '' then
    return false, 'the path is not one this window shares'
  end
  -- Measured against the resolved grant root, never the working directory: an absolute
  -- path, a `..` climber and a link pointing outside all read as outside the grant.
  local outside = path:sub(1, 1) == '/'
    or path:match('^%a:/') ~= nil
    or path:match('(^|/)%.%.(/|$)') ~= nil
  local file = root .. '/' .. path
  if outside or vim.fn.resolve(file):sub(1, #root + 1) ~= root .. '/' then
    return false, 'the path is not one this window shares'
  end
  if vim.fn.filereadable(file) ~= 1 then
    return false, 'there is no readable file there'
  end
  -- Loaded, not edited: the window moves only when the landing places, and a modified
  -- buffer in front of the user is not disturbed by opening the target.
  local loaded, bufnr_or_err = pcall(function()
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    return bufnr
  end)
  if not loaded then
    return false, tostring(bufnr_or_err)
  end
  local shared, share_err = pcall(share, bufnr_or_err, path)
  if not shared then
    return false, tostring(share_err)
  end
  return true
end

--- Puts the window on the peer's caret: their document shown, the cursor on the head
--- offset the last presence report resolved. The row and column come through
--- `Document:position`, which is in range for any offset by construction; the set itself is
--- still guarded, because the buffer may have gone while the report stood.
---
--- Returns true on landing; false with 'unknown' when no caret is drawn for the peer,
--- with 'waiting' when their document opened here and its text still arrives, with
--- 'open-failed' and the reason when it cannot be opened, with 'missing' when showing it
--- failed even so, or 'unresolvable' when the cursor cannot be placed.
local function land(peer_id)
  local cursor = cursor_for(peer_id)
  if cursor == nil or cursor.path == nil or cursor.head == nil then
    return false, 'unknown'
  end
  local document = state.documents[cursor.path]
  if document == nil or not api.nvim_buf_is_valid(document.bufnr) then
    if document ~= nil then
      -- A wiped buffer is not a buffer anymore: the entry points nowhere, and the share
      -- below makes the document the room still holds, the way the stale-entry repair the
      -- documents report would make does.
      document:detach()
      state.documents[cursor.path] = nil
    end
    -- The hold is what makes the room send the text, so a document that was never opened
    -- here opens now. A host's own file is read by the open itself, so the landing
    -- carries on onto it; a guest's text still arrives over the sync, so the landing waits
    -- for the frame it unlocks rather than placing at offset zero of an empty buffer.
    local opened, err = open_room_path(cursor.path)
    if not opened then
      return false, 'open-failed', err
    end
    -- A landing that opens takes a hold: the document joins the room's open set, so every
    -- peer receives it, the way a fetch does. Said once, where the hold is taken, in the
    -- fetch's own sentence shape — not on every frame that lands on it afterwards.
    notify(('%s is opened in the room, so every peer receives it.'):format(cursor.path))
    if state.role ~= 'host' then
      return false, 'waiting'
    end
    document = state.documents[cursor.path]
    if document == nil or not api.nvim_buf_is_valid(document.bufnr) then
      return false, 'missing'
    end
  end
  if not show(document.bufnr) then
    return false, 'missing'
  end
  local row, col = document:position(cursor.head)
  -- The follow's own placement is not a move the user made: Neovim reports no reason for a cursor
  -- change, so the flag is what tells the move handler this caret is the follow's, not theirs.
  state.applying_follow = true
  local placed = pcall(api.nvim_win_set_cursor, 0, { row + 1, col })
  state.applying_follow = false
  if not placed then
    return false, 'unresolvable'
  end
  -- The landing moved the caret, so the room hears it through the coalesced publish
  -- rather than through whatever event the editor may or may not fire for a programmatic
  -- move: headless Neovim fires none for anything, and the interval drops the duplicate
  -- where the editor fired its own.
  schedule_selection()
  return true
end

--- A name or a sentence as part of one of the indicators' rows. The row is evaluated like a
--- statusline, where `%` starts an item and `%{…}` is a Vimscript expression, and a display name
--- is whatever the peer typed: every `%` in it arrives doubled, so a name reads as itself rather
--- than as the item it spells.
local function row_text(text)
  return tostring(text or ''):gsub('%%', '%%%%')
end

--- The indicator's own row for `label`: the peer's name and the way to stop, clickable
--- where the editor takes a mouse. The `%0@...@ ... %X` label is what makes a click stop
--- the follow, through the stop command's own handler; a click needs `'mouse'` set, while
--- the command stops the follow regardless.
local function indicator_text(label)
  return ('%%#SelvageFollow#%%0@SelvageStopFollowing@ Following %s — click or :SelvageStopFollowing to stop %%X%%*'):format(row_text(label))
end

-- What the indicator's click label calls: a Vim function by name. A Lua `_G` function is
-- invisible to that lookup (`exists('*name')` is 0 for one), so this thin wrapper exists
-- to hand the click to the stop command's handler. Defined once, when the module loads:
-- with no follow standing the handler only says there is nothing to stop, and no clickable
-- row stands then anyway.
vim.cmd([[function! SelvageStopFollowing(minwid, clicks, button, mods) abort
  call v:lua.require('selvage').stop_following()
endfunction]])

--- Which saved row a window's buffer reads and writes: the window and the buffer together,
--- because that is the granularity the editor swaps them at.
local function winbar_key(win, bufnr)
  return win .. ':' .. bufnr
end

--- Whether a window is a float: a notification, a hover, a completion menu — the editor's own
--- furniture rather than a window showing a document.
---
--- No indicator belongs in one. A float is not a place a person reads the session's rows and it is
--- often shorter than the row itself: the one line a one-line float has is already spoken for, so
--- writing a winbar into one is where Neovim raises `E36: Not enough room`. The host-away row is
--- redrawn by a repeating timer, and Neovim stops a repeating timer after three of its runs raise
--- an error — which is what the frozen countdown at 27s was found beside, on the configuration
--- this came from: with `nvim-notify`'s popup on screen the errors accumulated and the timer went;
--- with no float on screen there is no `E36` at all and the countdown ticks to the end.
local function floating(win)
  local ok, config = pcall(api.nvim_win_get_config, win)
  return ok and config.relative ~= ''
end

--- The highlight the session's own row is drawn in: the framing that tells its row apart
--- from a person's own, and the name a colorscheme or a person may style. Linked to `Title`
--- and defined with `default`, so anything a colorscheme defines for the name wins; a
--- colorscheme runs `highlight clear`, which is why this is set where the row is drawn rather
--- than once.
local SESSION_HIGHLIGHT = 'SelvageSession'
local SESSION_FRAME = '%#' .. SESSION_HIGHLIGHT .. '#'

--- The sentence a room waiting out its host's absence says, with the leaving host's name and the
--- whole seconds left before the server's deadline. One home: the row and the one announcement
--- both read it, so the countdown a person watches and the notice they were given agree. The
--- deadline is the server's (`host.detached`); nothing here can move it.
local HOST_DISCONNECTED = 'Host disconnected. %s left — if they return within %ds the session continues, otherwise this room closes and your local copy is kept.'

--- How the session row is shown: `always` for `true`, `'always'` and the default — the row stands
--- for as long as the session does, the way the VS Code client's status bar does, so whoever has
--- just hosted reads that they have before anyone joins; `changes` for the quiet row, which
--- appears only while there is something to act on; `never` for `false` and `'never'`.
local function indicator_mode()
  local setting = vim.g.selvage_indicator
  if setting == false or setting == 'never' then
    return 'never'
  end
  if setting == 'changes' then
    return 'changes'
  end
  return 'always'
end

--- The session's own words: which side of the session the person is on, how many are in the
--- room, and whether the connection is being re-established — the words the VS Code client's own
--- status bar carries, so a person reading either client reads the session the same way. Nil when
--- there is no session to speak of, and nil while the row is turned off, which is also what
--- silences a statusline built on the same words.
---
--- These are the three facts a window otherwise says nothing about: hosting is one notice,
--- and after it the session, its people and its liveness are only in `:messages`.
local function session_words()
  if indicator_mode() == 'never' then
    return nil
  end
  if state.reconnecting then
    return 'Selvage: reconnecting…'
  end
  if state.status == 'connecting' then
    return 'Selvage: connecting…'
  end
  if state.host_away ~= nil then
    return 'Selvage: ' .. HOST_DISCONNECTED:format(state.host_away.name, until_seconds(state.host_away.deadline))
  end
  if in_session() then
    local here = #state.room_peers + 1
    return ('Selvage: %s — %s'):format(
      state.status == 'hosting' and 'hosting' or 'guest',
      here == 1 and '1 person in the room' or ('%d people in the room'):format(here)
    )
  end
  return nil
end

--- Whether a buffer stands for a room file whose content this session has not fetched: the
--- room's shape is materialised on disk and its text is not, so an empty buffer is not an
--- empty file.
---
--- `DESIGN.md` §4.2 leaves a listing partial by design, and every tool that reads the mirror —
--- ripgrep, ctags, a language server — reads a partial project with it. The row is where that
--- is visible while the file is in front of the person, rather than a sentence in `:messages`
--- they have to remember.
local function unfetched_buffer(bufnr)
  if not buffer_empty(bufnr) then
    return false
  end
  local path = mirror.room_path(api.nvim_buf_get_name(bufnr))
  if path == nil or not mirror.granted(path) then
    return false
  end
  return not mirror.written(path)
end

--- Whether this buffer's row is wanted: under `always`, wherever a session stands; under
--- `changes`, only while there is something to act on — a connection being made or retried, the
--- host away, or content the room has not sent yet; never under `never`.
local function row_wanted(bufnr)
  local mode = indicator_mode()
  if mode == 'never' then
    return false
  end
  if state.reconnecting or state.status == 'connecting' or state.host_away ~= nil then
    return true
  end
  if unfetched_buffer(bufnr) then
    return true
  end
  return mode == 'always' and session_words() ~= nil
end

--- The session's own row for a buffer: the words the VS Code client's status bar carries, and the
--- mark a file holding no fetched content wears. Nil when the buffer has no row to wear —
--- `row_wanted` is that question.
---
--- The peers in the file are not named here, which is the one thing this row does not carry: a
--- sign is two cells and cannot spell anyone, so whose caret that is reads from the gutter's own
--- colour, from `vim.g.selvage_file_peers`, and from `:SelvagePeers`, which lists each of them
--- with the document they are in.
local function session_text(bufnr)
  if not row_wanted(bufnr) then
    return nil
  end
  if not state.session_painted then
    pcall(api.nvim_set_hl, 0, SESSION_HIGHLIGHT, { link = 'Title', default = true })
    state.session_painted = true
  end
  return ('%s%s%s%%*'):format(
    SESSION_FRAME,
    row_text(session_words()),
    unfetched_buffer(bufnr) and ' [not fetched]' or ''
  )
end

--- The row a window's buffer should wear: the follow's while one stands, the session's
--- otherwise. A follow is what the person asked to watch and changes with every frame; the
--- session's words are standing background underneath it.
local function indicator_row(bufnr)
  if state.following ~= nil then
    return indicator_text(state.following.label)
  end
  return session_text(bufnr)
end

--- Whether `text` is one of the indicators' own rows: only they write those framings, so a
--- buffer showing one with no row saved for it is residue rather than someone's own row.
local function is_indicator_row(text)
  text = tostring(text)
  return text:find('%#SelvageFollow#%0@SelvageStopFollowing@ Following ', 1, true) == 1
    or text:find(SESSION_FRAME, 1, true) == 1
end

--- Puts back the winbar rows the indicators replaced, wherever they stand: every window
--- still showing a buffer one of them visited gets its own row back. With nothing wanted on
--- the row, a window showing an indicator's own row with nothing saved is residue — a split
--- the departures never swept — and reads empty instead.
local function restore_indicators()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      local key = winbar_key(win, api.nvim_win_get_buf(win))
      local prev = state.saved_winbars[key]
      if prev ~= nil then
        state.saved_winbars[key] = nil
        -- A float keeps no row of a person's back: it is not a window showing their buffer, and
        -- a row it never had is not one to put back. Clearing one is safe where writing one is
        -- not — removing a winbar needs no line the float has not got.
        if not floating(win) then
          pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
        end
      elseif state.following == nil then
        local ok, current = pcall(api.nvim_get_option_value, 'winbar', { win = win })
        if ok and is_indicator_row(current) then
          pcall(api.nvim_set_option_value, 'winbar', '', { win = win })
        end
      end
    end
  end
end

--- Puts the row a window should wear on it, saving the person's own first, and puts the
--- person's own back when neither indicator wants the row. The one path both of them take:
--- which of them speaks is `indicator_row`'s answer.
---
--- Window-local, so nothing else on screen moves, and every buffer's own row is put back as
--- it leaves. Never the statusline, which is what statusline plugins own.
local function show_indicator(win)
  win = win or api.nvim_get_current_win()
  if floating(win) then
    return
  end
  local bufnr = api.nvim_win_get_buf(win)
  local key = winbar_key(win, bufnr)
  local ours = indicator_row(bufnr)
  local ok, current = pcall(api.nvim_get_option_value, 'winbar', { win = win })
  current = (ok and current) or ''
  if ours == nil then
    local prev = state.saved_winbars[key]
    if prev ~= nil then
      state.saved_winbars[key] = nil
      if current ~= prev then
        pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
      end
    elseif is_indicator_row(current) then
      pcall(api.nvim_set_option_value, 'winbar', '', { win = win })
    end
    return
  end
  if state.saved_winbars[key] == nil then
    -- A re-target lands an indicator in a buffer whose row is already saved, and a rename
    -- only re-words it, so those never reach here. What does is a split inheriting the row
    -- it split from: the copy is ours but nothing saved it, and its own row is the default —
    -- it never had one — so that is what leaving puts back.
    state.saved_winbars[key] = is_indicator_row(current) and '' or current
  end
  if current ~= ours then
    pcall(api.nvim_set_option_value, 'winbar', ours, { win = win })
  end
end

--- Draws the wanted row again on every window: what a session transition needs, and what a
--- room whose membership moved needs — the session's words are the same in every window, and
--- each window keeps its own saved row.
---
--- While a follow stands nothing moves: the row is the follow's, the membership report does not
--- change its words, and the follow's own paths are what re-label it.
refresh_indicators = function()
  if state.following ~= nil then
    return
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      show_indicator(win)
    end
  end
end
--- Draws the row again in the windows showing `bufnr`: what one buffer holds is the one
--- thing the row says that changes without a session event — the mark a file wears while the
--- room's text has not arrived goes the moment it does.
local function refresh_indicator_for(bufnr)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
      show_indicator(win)
    end
  end
end

--- Stops the timer that redraws the host-away countdown, if one is running.
local function stop_host_away_timer()
  if state.host_away_timer ~= nil then
    pcall(vim.fn.timer_stop, state.host_away_timer)
    state.host_away_timer = nil
  end
end

--- Redraws the host-away countdown once a second while it stands. The number is derived from the
--- deadline on each read, so this is what makes it tick rather than a value stored once.
local function start_host_away_timer()
  stop_host_away_timer()
  state.host_away_timer = vim.fn.timer_start(1000, function()
    refresh_indicators()
  end, { ['repeat'] = -1 })
end

--- Shows the follow in the window, in their own colour. Called wherever the follow moves or
--- re-labels, so the row follows it.
local function set_indicator()
  local following = state.following
  if following == nil then
    return
  end
  show_indicator()
  pcall(api.nvim_set_hl, 0, 'SelvageFollow', {
    fg = '#000000',
    bg = following.colour or '#888888',
    bold = true,
  })
  vim.g.selvage_following = following.peerId
end

--- Takes the indicators down, wherever they stand.
local function clear_indicator()
  restore_indicators()
  vim.g.selvage_following = nil
end

--- Keeps the indicator on the window through a switch: every buffer it shows carries the
--- row over its own saved row, and a buffer whose row is still saved gets it back when
--- neither indicator has anything to say about it — the lazy half of leaving nothing behind.
local function indicator_window_enter()
  show_indicator()
end

--- Puts back the row the indicator replaced in the buffer being left: the window about to
--- show another buffer would otherwise keep the indicator in the old buffer's own row. Only
--- the buffer going out of view is touched — a split still showing its own copy keeps it.
local function follow_window_leave(event)
  if state.following == nil then
    return
  end
  local leaving = event ~= nil and event.buf or nil
  -- The event's own window is the one leaving: a split still showing the same buffer keeps
  -- its own copy of the indicator until it moves, rather than losing it to a sibling's
  -- switch. Without an event there is no leaver to name, so every window still showing a
  -- visited buffer is swept instead.
  local wins = leaving == nil and api.nvim_list_wins() or { api.nvim_get_current_win() }
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then
      local bufnr = api.nvim_win_get_buf(win)
      if leaving == nil or bufnr == leaving then
        local key = winbar_key(win, bufnr)
        local prev = state.saved_winbars[key]
        if prev ~= nil then
          state.saved_winbars[key] = nil
          pcall(api.nvim_set_option_value, 'winbar', prev, { win = win })
        end
      end
    end
  end
end

--- Drops the saved rows of a wiped buffer: its rows go with it, and a buffer number Neovim
--- hands out again starts clean rather than inheriting them.
local function forget_winbar_stash(event)
  local suffix = ':' .. tostring(event.buf)
  for key in pairs(state.saved_winbars) do
    if key:sub(-#suffix) == suffix then
      state.saved_winbars[key] = nil
    end
  end
end

--- Watches the window for the indicators: the switches that swap which buffer's row they
--- show are the ones that save and put back each buffer's own.
local function watch_follow_window()
  state.follow_group = api.nvim_create_augroup('SelvageFollowWindow', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = state.follow_group,
    callback = indicator_window_enter,
  })
  -- A caret the user moved ends the follow: the next frame would drag it back, and a follow that
  -- fought the person is the behaviour they remember as broken. A move the follow itself made is
  -- behind `applying_follow`, not read here.
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = state.follow_group,
    callback = function()
      if state.applying_follow or state.following == nil then
        return
      end
      end_follow('moved')
    end,
  })
  api.nvim_create_autocmd('BufLeave', {
    group = state.follow_group,
    callback = follow_window_leave,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = state.follow_group,
    callback = forget_winbar_stash,
  })
end

--- Ends the follow, saying so as `why` asks: 'stopped' for the user and for an edit, 'left'
--- for a peer that went, and silence for the session going with it.
end_follow = function(why)
  local following = state.following
  if following == nil then
    return
  end
  state.following = nil
  clear_indicator()
  -- The row is the window's, and the session's words are what stands on it with no follow:
  -- ending one puts the other back on every window, not only the one in front.
  if why ~= 'silent' then
    refresh_indicators()
  end
  if why == 'stopped' then
    notify(('stopped following %s.'):format(following.label))
  elseif why == 'moved' then
    notify(('Stopped following %s — you moved.'):format(following.label), vim.log.levels.WARN)
  elseif why == 'left' then
    notify(('%s left the room, so following stopped.'):format(following.label), vim.log.levels.WARN)
  end
end

--- Attempts one landing of the standing follow. Says and indicates only on success — a
--- miss leaves every one of those where they were, so refusing an establishment touches
--- nothing a standing follow owns. Returns what `land` returned.
local function land_follow()
  local following = state.following
  if following == nil then
    return false, 'unknown'
  end
  -- The target is the peer id, so a rename keeps the follow and re-labels it.
  local row = peer_row(following.peerId)
  if row ~= nil then
    following.label = row.label
    following.colour = row.colour or following.colour
  end
  local ok, reason, err = land(following.peerId)
  if ok then
    set_indicator()
    -- The first landing is said out loud.
    if not following.said then
      following.said = true
      notify(('following %s.'):format(following.label))
    end
  end
  return ok, reason, err
end

--- Lands the follow again on a new frame: the peer moved, or their text arrived. A frame
--- with nothing drawn for them is a frame with nothing to land on — they may be between
--- documents, or in one this client does not hold — so the follow stands, saying so once on
--- the first such frame and never per frame.
local function follow_frame()
  local following = state.following
  if following == nil then
    return false
  end
  local ok, reason, err = land_follow()
  if ok then
    -- Drawable again: the next undrawable stretch is news again too.
    following.gone_warned = false
    return true
  end
  if reason == 'open-failed' then
    -- Said once per document: every frame retries the same refusal, and the second saying
    -- carries nothing the first did not.
    local cursor = cursor_for(following.peerId)
    local path = cursor ~= nil and cursor.path or nil
    if following.open_warned_for ~= path then
      following.open_warned_for = path
      notify(
        ('could not open %s from the room: %s.'):format(tostring(path), tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
  if reason == 'unknown' and not following.gone_warned then
    -- The first frame with no drawable caret: the indicator keeps saying Following and
    -- the window stays put, so the change from somewhere to nowhere is said once rather
    -- than never, and never per frame. A document opened here whose text still arrives is
    -- 'waiting', not 'unknown', and stays silent: a frame away from landing.
    following.gone_warned = true
    notify(('%s is not in a document; still following.'):format(following.label))
  end
  return false
end

--- Follows the peer, landing now and again on every frame until something ends it.
---
--- The first landing establishes the follow — the indicator, the sentence and `vim.g` all
--- happen on it — so a first landing that lands nowhere refuses instead of establishing: a
--- follow standing nowhere has no indicator and no stop state, which is the branch's own
--- contract broken silently. A failed re-target puts the standing follow back as it was;
--- the attempt itself says and indicates nothing, so there is nothing to put back with it.
local function begin_follow(row)
  -- A peer the room names but draws nothing for is in no document this client holds:
  -- there is nothing to land on, so the command refuses rather than landing at zero. A
  -- peer in an unheld-but-listed document reads exactly the same here — the bridge only
  -- forwards held, resolvable cursors, so their path never reaches Lua — and opening it
  -- blind is not possible: closing that gap needs the companion to forward unresolved
  -- presence, a companion change rather than a wire one. The other client pends a
  -- programmatic follow instead, for its awareness-lag rationale stated in-code there; the
  -- refusal is this client's honest answer to the same row, per the study's no-document
  -- vocabulary.
  if row.path == nil then
    notify(('nothing to follow: %s is not in a document.'):format(row.label), vim.log.levels.WARN)
    return
  end
  -- A pending go-to is superseded: the follow is the newer navigation, and a late frame
  -- for the old target must not yank the window back to it.
  state.pending_go_to = nil
  local previous = state.following
  state.following = {
    peerId = row.peerId,
    label = row.label,
    colour = row.colour,
    -- Following the peer already followed re-lands, idempotent: said once.
    said = previous ~= nil and previous.peerId == row.peerId and previous.said or false,
    open_warned_for = nil,
  }
  local ok, reason, err = land_follow()
  if not ok then
    state.following = previous
    if reason == 'open-failed' then
      local cursor = cursor_for(row.peerId)
      local path = cursor ~= nil and cursor.path or row.path
      notify(
        ('could not open %s from the room: %s.'):format(tostring(path), tostring(err)),
        vim.log.levels.ERROR
      )
    else
      notify(("nothing to follow: %s's caret does not resolve here."):format(row.label), vim.log.levels.WARN)
    end
  end
end

--- Holds a go-to whose landing cannot be made yet: the peer is in no document this client
--- holds, which reads exactly like a presence update one frame away, or their document
--- opened here a frame ago and its text still arrives. A pending landing is a one-shot
--- follow: every room event that could have brought the text tries it again, and the first
--- landing, refusal or departure clears it. It holds no resources — one slot, replaced by
--- the next go-to, cleared by a follow — and reports nothing while it waits: waiting is not
--- a failure yet, and any timer here would be a magic number.
local function pend_go_to(row)
  state.pending_go_to = { peerId = row.peerId, label = row.label }
end

--- Tries the pending go-to again: presence, an applied edit, the documents and the
--- membership each call this, because any of them can be the frame the text arrived on.
local function retry_go_to()
  local pending = state.pending_go_to
  if pending == nil then
    return
  end
  local row = peer_row(pending.peerId)
  if row == nil then
    -- The room no longer names them: a peer who left between the command and the text
    -- matches nobody now, the same refusal a stale picker choice reads.
    state.pending_go_to = nil
    notify(('no participant matches "%s".'):format(pending.label), vim.log.levels.WARN)
    return
  end
  pending.label = row.label
  if row.path == nil then
    return
  end
  local ok, reason, err = land(pending.peerId)
  if ok then
    state.pending_go_to = nil
  elseif reason == 'open-failed' then
    state.pending_go_to = nil
    notify(
      ('could not open %s from the room: %s.'):format(row.path, tostring(err)),
      vim.log.levels.ERROR
    )
  elseif reason ~= 'unknown' and reason ~= 'waiting' then
    state.pending_go_to = nil
    notify(("nothing to go to: %s's caret does not resolve here."):format(row.label), vim.log.levels.WARN)
  end
end

--- Lands on the peer's caret once: the hold taken by the open is what makes the room send
--- the text, so a landing that cannot be made yet pends on the frames rather than placing
--- at offset zero, and never lands at zero for an anchor that does not resolve either.
local function go_to_row(row)
  -- A deliberate navigation ends a follow: the user chose a different place to be, and a
  -- follow that yanked them back a moment later is the behaviour people remember as
  -- broken. A pending go-to is superseded the same way: the newer navigation owns the
  -- window now, and a late frame for the old target must not take it back.
  if state.following ~= nil then
    end_follow('stopped')
  end
  state.pending_go_to = nil
  if row.path == nil then
    pend_go_to(row)
    return
  end
  local ok, reason, err = land(row.peerId)
  if ok then
    return
  end
  if reason == 'unknown' or reason == 'waiting' then
    pend_go_to(row)
  elseif reason == 'open-failed' then
    notify(
      ('could not open %s from the room: %s.'):format(row.path, tostring(err)),
      vim.log.levels.ERROR
    )
  else
    notify(("nothing to go to: %s's caret does not resolve here."):format(row.label), vim.log.levels.WARN)
  end
end

--- Asks which participant, in the editor's own idiom: a picker over the room's rows, each
--- the name, the role and the document, disambiguated where two share a name.
local function pick_peer(prompt, on_choice)
  local peers = M.peers()
  vim.ui.select(peers, {
    prompt = prompt,
    format_item = function(peer)
      return ('%s — %s — %s'):format(
        row_name(peers, peer),
        tostring(peer.role or 'participant'),
        tostring(peer.path or 'not in a document')
      )
    end,
  }, on_choice)
end

--- The words a name that matched several peers is refused with, in the shape
--- `:SelvageOpen` uses for a path.
local function several_rows(wanted, matches)
  local peers = M.peers()
  local rows = {}
  for _, peer in ipairs(matches) do
    rows[#rows + 1] = row_name(peers, peer)
  end
  return rows
end

--- Goes to the participant `name` picks: their document shown, the cursor on their caret.
--- With no name and one participant, that one; with several, the user is asked which.
function M.go_to(name)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local peers = M.peers()
  if #peers == 0 then
    notify('no other participants yet.', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(name or '')
  if wanted == '' then
    if #peers == 1 then
      go_to_row(peers[1])
    else
      pick_peer('selvage: go to which participant?', function(row)
        if row ~= nil then
          -- The choice is read fresh: the room may have moved since the picker opened, and
          -- a peer who left it matches nobody now. A row in no document is refused here,
          -- where the row itself says so; a typed name pends on the frames instead.
          local fresh = peer_row(row.peerId)
          if fresh == nil then
            notify(('no participant matches "%s".'):format(row.label), vim.log.levels.WARN)
          elseif fresh.path == nil then
            notify(
              ('nothing to go to: %s is not in a document.'):format(fresh.label),
              vim.log.levels.WARN
            )
          else
            go_to_row(fresh)
          end
        end
      end)
    end
    return
  end
  local row, err, matches = resolve_peer(wanted)
  if row ~= nil then
    go_to_row(row)
  elseif err == 'several' then
    notify(('"%s" matches several: %s.'):format(wanted, table.concat(several_rows(wanted, matches), ', ')), vim.log.levels.WARN)
  else
    notify(('no participant matches "%s".'):format(wanted), vim.log.levels.WARN)
  end
end

--- Follows the participant `name` picks, until something ends it: the user, an edit of
--- their own, the peer leaving, or the session going.
function M.follow(name)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local peers = M.peers()
  if #peers == 0 then
    notify('no other participants yet.', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(name or '')
  if wanted == '' then
    if #peers == 1 then
      begin_follow(peers[1])
    else
      pick_peer('selvage: follow which participant?', function(row)
        if row ~= nil then
          -- The choice is read fresh: the room may have moved since the picker opened. A peer
          -- who left it matches nobody now; one still here but in no document refuses with
          -- it, the same refusal the typed name reads.
          local fresh = peer_row(row.peerId)
          if fresh == nil then
            notify(('no participant matches "%s".'):format(row.label), vim.log.levels.WARN)
          elseif fresh.path == nil then
            notify(('nothing to follow: %s is not in a document.'):format(fresh.label), vim.log.levels.WARN)
          else
            begin_follow(fresh)
          end
        end
      end)
    end
    return
  end
  local row, err, matches = resolve_peer(wanted)
  if row == nil then
    if err == 'several' then
      notify(('"%s" matches several: %s.'):format(wanted, table.concat(several_rows(wanted, matches), ', ')), vim.log.levels.WARN)
    else
      notify(('no participant matches "%s".'):format(wanted), vim.log.levels.WARN)
    end
    return
  end
  begin_follow(row)
end

--- Stops following, or says there is nothing to stop.
function M.stop_following()
  if state.following == nil then
    notify('not following anyone.', vim.log.levels.WARN)
    return
  end
  end_follow('stopped')
end

--- The label of the participant this window follows, or nil when it follows nobody: what
--- the indicator shows, for a statusline or a script.
function M.following()
  return state.following ~= nil and state.following.label or nil
end

--- What the indicator shows, for whoever wants it in the statusline:
--- `%{v:lua.require'selvage'.statusline()}`. The follow's words while one stands, and the
--- session's own otherwise: the same words the window's row carries, without its highlight
--- framing, so a person with their own statusline reads them where they read everything else.
function M.statusline()
  local following = state.following
  if following ~= nil then
    return 'following ' .. tostring(following.label or '')
  end
  local words = session_words()
  if words == nil then
    return ''
  end
  if unfetched_buffer(api.nvim_get_current_buf()) then
    return words .. ' [not fetched]'
  end
  return words
end


--- A wiped buffer is not a buffer anymore: the room is told, and the path stops being held
--- here. Without this the room keeps the document for the life of the session, offering
--- edits to a `Document` that answers every one of them `ok = false`, and the companion
--- retries until it reports a refusal about a buffer the user closed.
---
--- The send belongs here rather than in `Document:on_detach`, which also fires when the
--- session ends: every `:SelvageLeave` would put a `close` on the wire for each document it
--- is letting go of, and the companion would hear about a room it is already leaving.
---
--- @param event table
local function document_wiped(event)
  local document = document_for_buf(event.buf)
  if document == nil then
    return
  end
  document:detach()
  if state.process ~= nil then
    state.process:send({ type = 'close', path = document.path })
  end
  state.documents[document.path] = nil
end

--- Re-opens the documents this session holds whose room path the mirror now has a file for.
---
--- The room's grant and its open-document set are two messages, and which of them arrives first is
--- the server's to decide: the grant is restated in a `doc.granted` straight after `room.joined`,
--- so a guest usually hears which documents the room holds before it hears what the room grants,
--- and a `selvage://` buffer made in that window becomes the file the listing names for it. A
--- republished listing that names a path the guest already holds goes the same way.
---
--- What the buffer holds is carried into the file it is opened as, and the room's text this client
--- holds is saved into it, because re-pointing a document is not a document that starts over: a
--- buffer that began empty would tell the companion the document is empty for as long as the room
--- takes to answer, and a peer's caret resolved against it would be drawn in the wrong column.
local function remirror_documents()
  for path, document in pairs(state.documents) do
    if
      document ~= nil
      and mirror.granted(path)
      and api.nvim_buf_get_name(document.bufnr) ~= mirror.buffer_name(path)
    then
      local old = document.bufnr
      local lines = api.nvim_buf_get_lines(old, 0, -1, true)
      local held_text = #lines > 1 or lines[1] ~= ''
      local bufnr = guest_buffer(path)
      if bufnr ~= old then
        document:detach()
        state.documents[path] = nil
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        if api.nvim_buf_is_valid(old) then
          -- A window showing the buffer that is going away is pointed at the one replacing it,
          -- so that closing the room's copy does not move the person somewhere else. The move
          -- is the session's own placement rather than an open, so the unfetched hint stays
          -- silent for it the way it does for the landing's `show`.
          state.suppress_unfetched = true
          for _, win in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == old then
              pcall(api.nvim_win_set_buf, win, bufnr)
            end
          end
          state.suppress_unfetched = false
          pcall(api.nvim_buf_delete, old, { force = true })
        end
        share(bufnr, path)
        local replaced = state.documents[path]
        if replaced ~= nil and held_text then
          -- The file the buffer is now opened as holds what this client holds for the room. An
          -- empty placeholder is left alone: there is nothing to write that the file does not
          -- already hold.
          replaced:save(true)
        end
      end
    end
  end
end

--- Watches the mirror's files, for a guest.
---
--- Reading one is how a person or a plugin opens the room's file, and it goes through the same
--- share `:SelvageOpen` uses: the room is what has the content, and the host reads its working
--- copy when this client asks for it. A name under the mirror that is neither in the room's listing
--- nor a document this session holds is a file on this disk and nothing else, and is said so once:
--- a path that left the listing while its buffer stayed open is still the room's document.
---
--- Saving one is the session's to route, not the editor's. `BufWriteCmd` suppresses the write the
--- editor would have made, and the document's own save gives the file the text this client holds
--- for the room. A path the room knows nothing about is refused rather than written into a
--- directory the session deletes.
---
--- A write of *part* of a buffer reaches none of that: `:[range]write {file}` runs `FileWriteCmd`
--- and `:write >> {file}` runs `FileAppendCmd`, and both are matched against the file being
--- written rather than against the buffer. Either one naming a file inside the mirror would put
--- the buffer's own lines into the room's files with the room hearing nothing, so they are
--- refused here. A file outside the mirror is the person's own and is left to the editor.
local function watch_mirror()
  local root = mirror.root()
  if root == nil then
    return
  end
  state.mirror_group = api.nvim_create_augroup('SelvageMirror', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path == nil then
        return
      end
      -- A document this session holds is the room's whether or not the listing still names it:
      -- the listing is what it mirrors, and the open-document set is a fact of its own.
      if mirror.granted(path) or state.documents[path] ~= nil then
        share(event.buf, path)
        local file = mirror.file(path)
        if file ~= nil and mirror.granted(path) and vim.fn.filereadable(file) == 0 then
          refuse_mutation(path)
        end
        if mirror.granted(path) and not mirror.written(path) and buffer_empty(event.buf) then
          notice_unfetched(path)
        end
      elseif state.unmutated[path] == nil then
        refuse_unlisted(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path == nil then
        return
      end
      local document = state.documents[path]
      if document == nil then
        refuse_mirror_write(path)
        return
      end
      if not document:save() then
        notify(('%s could not be written into the mirror.'):format(path), vim.log.levels.ERROR)
      end
    end,
  })
  -- A partial write or an append, to a file this session's mirror holds: the pattern is the file
  -- being written, so a target outside the mirror never reaches this.
  for _, name in ipairs({ 'FileWriteCmd', 'FileAppendCmd' }) do
    api.nvim_create_autocmd(name, {
      group = state.mirror_group,
      pattern = root .. '/*',
      callback = function(event)
        local target = event.file or ''
        if target:sub(1, #root + 1) == root .. '/' then
          target = target:sub(#root + 2)
        end
        notify(
          ('%s is inside the mirror, which holds the room\'s files, so it is not written; write outside the mirror to keep it.'):format(target),
          vim.log.levels.WARN
        )
      end,
    })
  end
  -- A file mutation has no frame, so it is refused where the editor names it: a new file,
  -- and a buffer renamed onto a mirror name, each say so once per path. A file outside the
  -- mirror is the person's own and is left alone.
  api.nvim_create_autocmd('BufNewFile', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path ~= nil then
        refuse_mutation(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufFilePost', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      if state.suppress_rename then
        return
      end
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path ~= nil then
        refuse_mutation(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = state.mirror_group,
    callback = document_wiped,
  })
end

--- A host shares what it opens for as long as the session lasts.
local function watch_buffers()
  state.group = api.nvim_create_augroup('SelvageHost', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.group,
    callback = function(event)
      local path, refused = room_path(event.buf)
      if path ~= nil then
        share(event.buf, path)
      elseif refused ~= nil then
        refuse_outside(refused)
      else
        refuse_unfiled(event.buf)
      end
    end,
  })
  -- A wiped buffer is not a buffer anymore: the room is told, and the path stops being held
  -- here. See `document_wiped`.
  api.nvim_create_autocmd('BufWipeout', {
    group = state.group,
    callback = document_wiped,
  })
end

--- Lets every document this session shares go. A session ends while the companion stays up —
--- `:SelvageLeave` is one way, and a new host or join another, since the companion's own
--- `connect()` leaves the session before it (`status idle`) — so the paths of the session that
--- just ended have to stop counting as shared. They would otherwise make `share` return early
--- and never send the `open` that puts them in the new room, while the companion, which does
--- start clean, holds nothing.
---
--- Detaching is what makes this the end of the document rather than a leak: a `Document` left
--- attached would keep reporting the buffer beside the one the new session makes for it. A
--- refusal goes the same way, so the next session looks at the buffer again.
local function forget_documents()
  for _, document in pairs(state.documents) do
    -- The room's documents are the room's; a buffer that leaves the session is the person's
    -- again, and a read-only one that stayed read-only after `:SelvageLeave` would be a buffer
    -- nobody could edit.
    apply_read_only_writable(document.bufnr)
    document:detach()
  end
  state.documents = {}
  state.unshareable = {}
  state.outside = {}
  state.unfiled = {}
  state.linked = {}
end

--- The buffers a guest session put on screen, captured before its documents are forgotten: they
--- are the room's only for as long as the session holds them. A host's buffers are its own
--- files, which outlive the room, so there is nothing here for a host to land.
--- Whether this connection is a peer rather than the room's host: a guest, or — in a `selvage/2`
--- room — a viewer. The two differ in what the room accepts from them (§13.9 refuses a viewer's
--- content) and not in where the room's documents live, which is what most of these rules are
--- about.
local function is_peer()
  return state.role == 'guest' or state.role == 'viewer'
end

local function room_buffers()
  if not is_peer() then
    return nil
  end
  local held = {}
  for _, document in pairs(state.documents) do
    if api.nvim_buf_is_valid(document.bufnr) then
      held[#held + 1] = document.bufnr
    end
  end
  return held
end

--- A room that dies under a person leaves no window showing it.
---
--- The room's buffers are the room's, and when the room is gone they are nobody's: a window still
--- showing one reads as a room that is still there. What the person has not changed goes with it
--- — its text is the room's, and the session that could write it has ended — while a buffer
--- holding their own unsaved changes is kept in the buffer list and said so: the session can no
--- longer save it, so dropping it would drop their text, and silence would hide where it went.
--- (`:SelvageLeave` and a new host or join are not this: the room lives on, and the person asked.)
local function land_room_buffers(held)
  if held == nil or #held == 0 then
    return
  end
  local landing = nil
  for _, win in ipairs(api.nvim_list_wins()) do
    local showing = api.nvim_win_get_buf(win)
    local room = false
    for _, bufnr in ipairs(held) do
      if showing == bufnr then
        room = true
        break
      end
    end
    if room then
      if landing == nil then
        landing = api.nvim_create_buf(true, false)
      end
      pcall(api.nvim_win_set_buf, win, landing)
    end
  end
  local kept = 0
  for _, bufnr in ipairs(held) do
    if api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        kept = kept + 1
      else
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
  if kept > 0 then
    notify(
      ('%d buffers with unsaved changes were kept; :ls lists them.'):format(kept),
      vim.log.levels.WARN
    )
  end
end

--- Ends the session: every buffer it shared stops reporting, presence goes, and the front-end
--- is back to nothing shared. `land` is for a room that died under the person (`roomGone`,
--- `disconnected`): the buffers and the window still showing them are the room's, and the room
--- is not. Every other ending leaves them where they are — the person asked, and a leave does
--- not close the room for anyone else.
---
--- `keep_mirror` is for a room that closed under a guest rather than being left: the directory is
--- then kept and its path returned, because it holds work the room never received and deleting it
--- would leave the person with nowhere to recover it. A leave, a new session and a host's own
--- files are not that, and their mirror is removed as before.
---
--- @param land boolean|nil
--- @param keep_mirror boolean|nil
--- @return string|nil the kept mirror's path, when one was kept
local function reset(land, keep_mirror)
  local held = land and room_buffers() or nil
  local kept = keep_mirror and mirror.root() or nil
  -- The session is over before anything else moves, and the indicators go with it: landing a
  -- dead room's buffers switches windows, and a switch is a `BufEnter` — an indicator that
  -- still read a live session would put its row back on a session that is gone. Setting the
  -- status first is what makes that switch read the session as ended, and the rows are put
  -- back here rather than left for a window that may never be entered again.
  state.status = 'idle'
  state.reconnecting = false
  stop_host_away_timer()
  state.host_away = nil
  state.host_name = nil
  clear_indicator()
  -- A callback left attached would keep sending into a companion that is gone.
  forget_documents()
  clear_presence()
  state.peers = {}
  state.room_peers = {}
  state.cursors = {}
  -- The seam a file-list plugin reads is emptied with the session: a badge for a peer is not
  -- something to leave standing over a room that is gone.
  publish_file_peers()
  for _, name in pairs(state.peer_groups) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  for _, name in pairs(state.peer_fills) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  state.peer_groups = {}
  state.peer_fills = {}
  state.peer_paints = {}
  state.peer_count = 0
  state.generation = state.generation + 1
  state.selection_armed = false
  state.selection_path = nil
  -- The follow goes with the session, silently: leaving, the room going and the
  -- connection ending say their own sentence, and none of them is about the follow. A
  -- pending go-to goes with it, for the same reason and with the same silence.
  end_follow('silent')
  state.pending_go_to = nil
  land_room_buffers(held)
  state.role = nil
  state.room = nil
  state.invite = nil
  state.auto_open = false
  state.join_said = false
  state.join_mirror = nil
  state.join_empty = false
  state.join_listed = false
  state.suppress_unfetched = false
  -- The grant belongs to the session, and a session that has ended grants nothing: the folder it
  -- was rooted at, the listing the room carried, and the mirror those two made on disk. The room
  -- is the truth and the directory is a cache of it, so a mirror is removed unless `keep_mirror`
  -- says the room closed under the person and the cache holds the only copy of their work.
  state.root = nil
  state.grant = {}
  state.unlisted = {}
  state.unwritable = {}
  state.unmutated = {}
  state.gone = {}
  state.unfetched = {}
  mirror.teardown(keep_mirror)
  if state.group ~= nil then
    api.nvim_del_augroup_by_id(state.group)
    state.group = nil
  end
  if state.mirror_group ~= nil then
    api.nvim_del_augroup_by_id(state.mirror_group)
    state.mirror_group = nil
  end
  if state.presence_group ~= nil then
    api.nvim_del_augroup_by_id(state.presence_group)
    state.presence_group = nil
  end
  if state.follow_group ~= nil then
    api.nvim_del_augroup_by_id(state.follow_group)
    state.follow_group = nil
  end
  state.saved_winbars = {}
  return kept
end

--- Ends the session this front-end is in, leaving the companion process for what comes next: one
--- process serves every session a Neovim instance runs, and only `:SelvageLeave` stops it. The
--- companion hears the `leave` and answers with `status idle`, which is the same teardown again
--- from the other side; a front-end that has already forgotten the session does not notice.
local function end_session()
  if state.process ~= nil then
    state.process:send({ type = 'leave' })
  end
  reset()
end

--- Puts this session's page link on the clipboard and the unnamed register; defined below,
--- declared here because the host confirm above runs before its definition loads.
local hand_on_invite

--- What a host or join that could not open says, as one sentence a person can act on.
---
--- A refusal the protocol named is said from its code rather than repeated from the server's
--- message, which answers with a value the person never chose to see: `no such room: <room id>`
--- names what could not be found and not the way back from it. A connection that never got as
--- far as a handshake carries no code — the engine has only its own words about a socket — and
--- the two causes of one are the server at that address and the address itself, so a host is
--- told to check the address it dialled and a guest the link it pasted.
---
--- `connect` names which of the two this was — `{ what = 'host', address = … }` or
--- `{ what = 'join' }` — because the two say different sentences.
---
--- The two failures that are neither: a wire version the server's `/meta` does not seat, which
--- the companion refuses before it dials anything (`PROTOCOL.md` §2, §10), and a link whose
--- fragment it will not read (`PROTOCOL.md` §5.1). In both there is no connection to describe, and
--- the companion's message is already the whole sentence — the server, the version it does not
--- seat and what it offers instead; or what is wrong with the link — so each is said as it stands
--- rather than behind a sentence about a dial that never happened.
---
--- @param connect table|nil `what` and, for a host, `address`
--- @param code string|nil the protocol's own code for a refusal — or the companion's own, for one of
--- the two local refusals above — absent for a socket
--- @param message string|nil the failure's own words
--- @return string
local function connect_failure(connect, code, message)
  if code == 'wire_version_refused' or code == 'invite_refused' then
    return tostring(message or '')
  end
  local what = connect and connect.what or 'join'
  local why
  if code == 'room_unknown' then
    why = 'That invite names a room the server does not have. Ask the host for a fresh invite.'
  elseif code == 'token_invalid' then
    why = 'That invite is no longer valid. Ask the host for a fresh invite.'
  elseif code == 'host_present' then
    why = 'That room already has a host.'
  elseif code == 'x.room_full' then
    why = 'The room is full — it seats no more people.'
  elseif code == 'room_gone' then
    why = 'That room is gone.'
  elseif code == 'unsupported_version' then
    why = ('This client and that server speak different versions (%s).'):format(
      tostring(message or '')
    )
  elseif tostring(message or ''):find('^server full') ~= nil then
    -- The server's own capacity policy, stated in the close reason rather than in a code:
    -- the room is up, so this is not a connection that failed to reach one.
    why = 'The server is full. Try again in a few minutes.'
  elseif code == nil or code == '' or code == 'hello_required' then
    if what == 'host' then
      why = 'No server answered — check the address is the one the server printed, and that the server is running.'
    else
      why = 'No server answered — check the invite is complete, and that the server is running at the address it names.'
    end
  else
    why = tostring(message or '')
  end
  if what == 'host' then
    return ('could not host on %s. %s'):format(tostring(connect.address or ''), why)
  end
  return 'could not join the session. ' .. why
end

local function on_status(message)
  state.status = message.state
  state.role = message.role
  state.room = message.roomId
  -- A status is this session's own word: whatever the connection was doing before it, the
  -- companion has just said where the session stands.
  state.reconnecting = false
  if message.invite ~= nil then
    state.invite = message.invite
  end
  if message.state == 'idle' then
    -- The session is over, whoever ended it: `:SelvageLeave` has reset before it hears this, and
    -- a room that goes or a connection the engine gave up on reaches here from the companion,
    -- which has already let the engine go.
    reset()
  elseif message.state == 'connecting' then
    -- The session is being opened: the row says so, and the result replaces it. Watched
    -- before the session stands, because the switches that swap the row are already
    -- happening — the address and the name were answered before this arrived.
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'hosting' then
    -- A host's next move is pasting the link to a guest, so the room copies its page
    -- link without being asked; `:SelvageCopyInvite` stays for later copies. What is
    -- copied is never the wire address: only the page link leaves this editor. A copy that
    -- did not happen says which way it did not happen — a refused clipboard and a link this
    -- connection never held are different faults, and naming the copy command for either
    -- would answer a person with a command that has nothing to copy.
    local handed, why = hand_on_invite()
    if handed == 'copied' then
      notify('the room is open. Send this link to your friend — it is on the clipboard.')
    elseif handed == 'register' then
      notify(
        ('the room is open, but the invite link could not be copied (%s).'):format(why),
        vim.log.levels.WARN
      )
    else
      notify('the room is open, but this connection holds no invite link to send.', vim.log.levels.WARN)
    end
    share_current()
    watch_buffers()
    watch_presence()
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'joined' then
    -- The join is said over the `documents` report that follows this one: the sentence carries
    -- what the landing did with the room's documents, and that is the report's news.
    state.auto_open = true
    state.join_said = false
    state.join_empty = false
    state.join_listed = false
    -- A viewer is told once, here, and its documents are made read-only: the role is the room
    -- state's word and this is where it first reaches this editor.
    if state.role == 'viewer' then
      apply_read_only_to_room()
      notify('you are a viewer in this room, so its documents are read-only.', vim.log.levels.WARN)
    end
    watch_presence()
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'error' then
    -- A connection that failed, or a refusal the companion decided before it dialled anything:
    -- a version the server's `/meta` does not seat (`§2`, `§10`) and a link whose fragment it will
    -- not read (`§5.1`) both reach here, and both already carry the companion's own sentence.
    notify(connect_failure(state.connect, message.code, message.message), vim.log.levels.ERROR)
    -- Nothing is standing after it, so the row goes with the failure: the notification is
    -- what says why, and a word about a session that is not open would outlive it.
    refresh_indicators()
  end
end

local function on_report(report)
  if state.reconnecting and (report.kind == 'documents' or report.kind == 'peers') then
    -- Both are reports of a seat — the first and every one after a reconnect — so either one
    -- is the room reachable again: the retry gets there, and the session's row says so.
    state.reconnecting = false
    refresh_indicators()
  end
  if report.kind == 'documents' then
    if is_peer() then
      local first = nil
      for _, path in ipairs(report.documents) do
        local bufnr = guest_buffer(path)
        first = first or bufnr
        share(bufnr, path)
      end
      -- The join is said here, where the room's document set is known, rather than when the
      -- handshake named the room: the sentence carries the landing, and a room with nothing in
      -- it is a join with a sentence of its own. The landing is the first document the room
      -- names after the join — a later one gets a buffer and waits for `:SelvageOpen`, because
      -- taking the window then would interrupt what the guest is already editing — so a room
      -- that was empty at the join still lands the first document that fills it.
      local lands = vim.g.selvage_open_on_join ~= false
      if state.auto_open and first ~= nil then
        state.auto_open = false
        if lands then
          -- The landing is the join's own window placement: its empty buffer is what the
          -- summary's fetched count already accounts for, so the unfetched hint stays silent.
          state.suppress_unfetched = true
          show(first)
          state.suppress_unfetched = false
        end
        if not state.join_said then
          state.join_said = true
          -- The landing, and — when the room holds more than one document — how many others
          -- there are. Where the mirror lives and how much of the room has arrived are not
          -- part of it: the row, `:SelvageOpen`'s completion and
          -- `require('selvage').session().mirror` answer those, and a greeting that carries
          -- a path and two counts is not read.
          if not lands then
            notify('joined the room.')
          elseif #report.documents > 1 then
            notify(
              ('joined the room — opening %s; %d more in the room.'):format(
                report.documents[1],
                #report.documents - 1
              )
            )
          else
            notify(('joined the room — opening %s.'):format(report.documents[1]))
          end
        end
      elseif state.auto_open and not state.join_said then
        state.join_said = true
        state.join_empty = true
        local mirror_summary = state.join_mirror
        state.join_listed = mirror_summary ~= nil
        if mirror_summary ~= nil then
          notify(
            ('joined the room; the room has no open documents yet; %d files mirrored at %s.'):format(
              mirror_summary.count,
              mirror_summary.root
            )
          )
        else
          notify('joined the room; the room has no open documents yet.')
        end
      end
    end
    -- The room's document set is one of the frames a pending landing waits on: a buffer a
    -- guest opens here is what the next presence frame draws into a landing.
    retry_go_to()
    follow_frame()
  elseif report.kind == 'grant' then
    -- The room's whole grant, replacing whatever this front-end held — the same rule the server
    -- applies to `doc.grant`, and the reason a shorter listing is a smaller grant rather than an
    -- error. The listing is what `:SelvageOpen` completes over, and a room that lists five
    -- hundred files has nothing worth interrupting a person for; what a *guest* does with it is
    -- materialise it, and the one sentence that says where is said over the session's first
    -- listing rather than over every republish. The join's own listing is the exception:
    -- the summary said over the documents report carries where the mirror lives, so the
    -- first listing before the join is said records its counts and stays silent.
    local previous = {}
    for _, path in ipairs(state.grant) do
      previous[path] = true
    end
    -- `mirror.setup` drops the file and the written mark of a path the listing no longer names,
    -- so the removal check below reads the pre-update mark: an empty document the session already
    -- wrote is fetched, not gone.
    local written_before = {}
    for path in pairs(state.documents) do
      written_before[path] = mirror.written(path)
    end
    state.grant = report.paths or {}
    if is_peer() then
      local root, blocked, created = mirror.setup(state.room, state.grant)
      if root ~= nil then
        if created then
          watch_mirror()
        end
        if state.join_mirror == nil and not state.join_said then
          state.join_mirror = { count = #state.grant - #blocked, root = root }
        end
        -- A first listing that arrives after the join was said stays silent: the summary already
        -- went out, and one summary plus errors is the whole of the join's news. The mirror stays
        -- discoverable without a notice (`require('selvage').session().mirror`, the README,
        -- `:SelvageFetch` completion). The exception is a join the room had nothing open in: that
        -- guest has no document to watch and no tree to read, so a listing that arrives after the
        -- sentence is the only place the room's files reach them, and it is said once here.
        if state.join_said and state.join_empty and not state.join_listed and #state.grant > #blocked then
          state.join_listed = true
          notify(
            ('%d files are mirrored at %s; :SelvageOpen opens one.'):format(#state.grant - #blocked, root)
          )
        end
        if #blocked > 0 then
          notify(
            ('%d of the room\'s files could not be mirrored, starting with %s.'):format(
              #blocked,
              blocked[1]
            ),
            vim.log.levels.WARN
          )
        end
        remirror_documents()
        for path, document in pairs(state.documents) do
          if
            previous[path]
            and not mirror.granted(path)
            and not written_before[path]
            and document:text() == ''
          then
            notice_gone(path)
          end
        end
        -- The grant is what `unfetched_buffer` reads, so a window already showing a buffer the
        -- listing no longer names is carrying a mark that is now wrong: the row is redrawn here
        -- rather than waiting for the next keystroke or session event.
        refresh_indicators()
      end
    end
  elseif report.kind == 'peers' then
    -- The room's own list of who is in it: everyone, not only the peers this client holds a
    -- document for and can draw a caret for.
    state.room_peers = report.peers or {}
    -- The host's name is remembered here, while they are in the room: the detach frame names no
    -- one, and the departure has already taken them out of this list by the time it arrives.
    local host_present = false
    for _, peer in ipairs(state.room_peers) do
      if peer.role == 'host' then
        host_present = true
        if type(peer.display_name) == 'string' and peer.display_name ~= '' then
          state.host_name = peer.display_name
        end
      end
    end
    -- Membership is the all-clear as well as the departure. `host.attached` is the only frame
    -- that says the host is back, and a guest whose socket was down when it arrived would
    -- otherwise keep a countdown — and then a deadline that has already passed — standing for
    -- the rest of the session. A report that names the host means the host is here.
    if host_present and state.host_away ~= nil then
      stop_host_away_timer()
      state.host_away = nil
    end
    -- The report is the room's own membership, so a peer it no longer names is gone even
    -- before the next presence frame redraws: their drawn row and cursor go now, rather than
    -- offering a departed peer in completion or landing on their last caret.
    --
    -- The count is what the session's row says, so the rows standing are drawn again: one more
    -- or one fewer is the first thing a person looking for their friend wants to see.
    refresh_indicators()
    do
      local member = {}
      for _, peer in ipairs(state.room_peers) do
        member[peer.peer_id] = true
      end
      local cursors = {}
      for _, cursor in ipairs(state.cursors) do
        if member[cursor.peerId] then
          cursors[#cursors + 1] = cursor
        end
      end
      -- Redrawn, not just reassigned: the marks of a departed peer would otherwise stand
      -- until the next presence frame. The rows above stay the membership join; the draw
      -- rebuilds the same drawable metadata and clears what no cursor names anymore.
      draw_presence(cursors)
    end
    -- A peer the room no longer names has left it: the follow ends, saying so. The peer id
    -- is the target, so a rename — same id, new name — keeps following and re-labels, now,
    -- from the report rather than the next presence frame: the indicator and the eventual
    -- stop message read the new name even when the peer goes idle.
    if state.following ~= nil then
      local gone = true
      for _, peer in ipairs(state.room_peers) do
        if peer.peer_id == state.following.peerId then
          gone = false
          break
        end
      end
      if gone then
        end_follow('left')
      else
        local row = peer_row(state.following.peerId)
        if row ~= nil then
          state.following.label = row.label
          state.following.colour = row.colour or state.following.colour
          set_indicator()
        end
      end
    end
    -- Membership is one of the frames a pending landing waits on: the room naming the peer
    -- is what tells a wait for their document from a wait for someone who left.
    retry_go_to()
  elseif report.kind == 'roomGone' then
    -- The room is over and the companion has let the engine go, so the session here ends with
    -- it rather than leaving buffers, marks and a statusline behind for a room nobody is in.
    -- The window is part of that: a buffer still shown for the dead room reads as one that is
    -- still there, so the room's buffers are landed as well.
    notify(('the room is gone (%s).'):format(tostring(report.reason)), vim.log.levels.WARN)
    -- The mirror is kept: it is a cache of the room, but whatever the person did in it during the
    -- grace is not in the room and has nowhere else to be recovered from, so the directory stays
    -- and they are told where.
    local kept = reset(true, true)
    if kept ~= nil then
      notify(('The room closed. Your copy is kept at %s.'):format(kept), vim.log.levels.WARN)
    end
  elseif report.kind == 'hostDetached' then
    -- The deadline is the server's: `grace_ms` is how long the room has before the host's absence
    -- destroys it, and the countdown here is only an echo of it, redrawn from the deadline rather
    -- than printed once. The name is the one remembered from membership, since this frame carries
    -- none.
    local name = state.host_name or 'the host'
    state.host_away = {
      name = name,
      deadline = uv.now() + math.max(0, tonumber(report.graceMs) or 0),
    }
    notify((HOST_DISCONNECTED):format(name, seconds(report.graceMs)), vim.log.levels.WARN)
    start_host_away_timer()
    refresh_indicators()
  elseif report.kind == 'hostAttached' then
    local name = tostring((report.peer or {}).display_name or state.host_name or 'the host')
    state.host_name = name
    stop_host_away_timer()
    state.host_away = nil
    notify(('%s is back — the session continues.'):format(name))
    refresh_indicators()
  elseif report.kind == 'sessionError' then
    -- The report's own sentence, and its code is not shown: a refusal the protocol named and
    -- one this session made for itself both say what happened in words already — `the room
    -- seats at most 2 peers`, `will not share .env with the room…` — and a code is a lookup,
    -- not a sentence. The one exception is the capacity policy this server states with a code
    -- of its own, which a person wants said rather than spelled out.
    if report.code == 'x.room_full' then
      notify('the room is full — it seats no more people.', vim.log.levels.ERROR)
    else
      notify(tostring(report.message or ''), vim.log.levels.ERROR)
    end
  elseif report.kind == 'applyRefused' then
    notify(
      ('the editor would not apply the room\'s change to %s; the file may be read-only.'):format(
        tostring(report.path)
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'divergence' then
    notify(
      ('%s was out of step with the room; the room\'s copy has been put back.'):format(
        tostring(report.path)
      ),
      vim.log.levels.WARN
    )
  elseif report.kind == 'saveFailed' then
    -- The reason, when the report has one, is what says what to do about it: the sentence is the
    -- fact and the parenthetical is why.
    local why = report.message
    notify(
      ('could not save %s; the file on disk is behind the room%s.'):format(
        tostring(report.path),
        why == nil and '' or (' (' .. tostring(why) .. ')')
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'reconnecting' then
    -- The socket dropped mid-session and the engine's bounded retry is running: the room is
    -- out of reach until it seats again, and a seat reports the room's documents and its
    -- peers. Said rather than inferred from the room going quiet, because a quiet room is
    -- also what everyone else simply editing looks like.
    state.reconnecting = true
    refresh_indicators()
  elseif report.kind == 'disconnected' then
    -- The bridge reconnects on its own until it runs out of attempts, and this is that end:
    -- the session is over and typing would accumulate in a replica nobody hears. The
    -- companion process is deliberately left running — `ensure` reuses it on the next host
    -- or join, and the engine on the other side of it has already finished.
    notify('the connection ended and the session is over; it could not be re-established.', vim.log.levels.ERROR)
    reset(true)
  end
end

--- The companion message types this session already named as unknown, so the version-skew
--- warning is said once per type rather than once per message.
local warned_message_types = {}
local function on_message(message)
  -- The companion is the same user's own process, not a remote peer, so a misshapen message
  -- is a bug rather than an attack — but one answered blindly fails inside the job callback,
  -- aborting the message with the follow and go-to retries piggybacked on it. Anything
  -- without a type is said and dropped; each arm below reads only the fields it needs.
  if type(message) ~= 'table' or type(message.type) ~= 'string' then
    notify('unreadable message from the companion.', vim.log.levels.WARN)
    return
  end
  if message.type == 'applyEdit' then
    local document = type(message.path) == 'string' and state.documents[message.path] or nil
    -- The range is applied against counted text: a start, end, text or version of the wrong
    -- type would fail inside the buffer arithmetic, aborting the message with the retries
    -- piggybacked on it. Answered false, like a version the front-end has left.
    local ok = false
    if
      document ~= nil
      and type(message.start) == 'number'
      and type(message['end']) == 'number'
      and type(message.text) == 'string'
      and type(message.version) == 'number'
    then
      ok = document:apply(message)
    end
    if ok and document ~= nil then
      -- The room's text has landed, so a file that was empty until now is not: the row's
      -- mark for it goes with the text.
      refresh_indicator_for(document.bufnr)
      -- And the caret the room has not heard: a buffer for a room document exists as soon as
      -- the handshake names it, while the text is a later message — a caret published in
      -- between is one the companion has no document for yet, and the bridge drops those
      -- rather than inventing a document. A programmatic write fires no `TextChanged`, so
      -- this apply is the only moment left to publish it again; without it a peer who has
      -- not moved is a peer whose caret nobody draws.
      schedule_selection()
    end
    state.process:send({ type = 'applied', id = message.id, ok = ok })
    -- The room's text moved under the follow: land again where the peer's caret resolves
    -- now. A remote edit is not a local one, so it never ends the follow.
    follow_frame()
    -- The text a pending go-to waited on may have arrived with this edit.
    retry_go_to()
  elseif message.type == 'save' then
    local document = type(message.path) == 'string' and state.documents[message.path] or nil
    -- A path this session holds nothing for answers false: the companion's save policy would
    -- otherwise hear that a document reached the disk it never touched.
    local ok = document ~= nil and document:save(true)
    state.process:send({ type = 'saved', id = message.id, ok = ok })
  elseif message.type == 'status' then
    -- The session's standing is a word from a fixed set: anything else leaves the guard
    -- this session's liveness is read from holding whatever it held.
    if type(message.state) == 'string' then
      on_status(message)
    else
      notify('unreadable status from the companion.', vim.log.levels.WARN)
    end
  elseif message.type == 'refused' then
    -- This process did not open a second session: one is already live. The commands ask before
    -- they send one, so this is the answer when something else did not.
    local where = message.what == 'host' and 'hosting' or 'in a session'
    notify(('already %s; leave that session first.'):format(where), vim.log.levels.WARN)
  elseif message.type == 'report' then
    if type(message.report) == 'table' then
      on_report(message.report)
    else
      notify('unreadable report from the companion.', vim.log.levels.WARN)
    end
  elseif message.type == 'presence' then
    draw_presence(message.cursors)
    -- The peer may have moved, or arrived where this client can draw them: land again.
    follow_frame()
    -- ... or arrived where a pending go-to can land: the same frame unlocks both.
    retry_go_to()
  else
    -- A version-skewed companion's new message would otherwise desync the versions without
    -- a word. Said once per type rather than per message, so a repeated one does not flood.
    if not warned_message_types[message.type] then
      warned_message_types[message.type] = true
      notify(
        ('unknown message type from the companion: %s.'):format(message.type),
        vim.log.levels.WARN
      )
    end
  end
end


local function ensure()
  if state.process ~= nil then
    return state.process
  end
  local process, err
  process, err = companion.start({
    on_message = function(message)
      -- The handler is registered per process, so this is where a message can be attributed to
      -- the process that sent it. A companion this session has let go is not the one to believe:
      -- `leave` forgets the process before stopping it and does not wait for the stop, so the
      -- `status idle` that leave earns can still be in the pipe when the next host or join has
      -- started a process of its own and already heard `hosting` from it. An `applyEdit` from
      -- the same pipe would be answered on the wrong process just as readily.
      if state.process ~= process then
        return
      end
      on_message(message)
    end,
    on_exit = function(code)
      -- A companion this session stopped is no longer its process — `leave` forgets it before
      -- stopping it, and the stop is not waited for — so its exit is not news, whether the
      -- process went on its own or had to be killed. A process the session still knows is one
      -- that went by itself, and that is worth a word when it did not exit cleanly.
      if state.process ~= process then
        return
      end
      state.process = nil
      reset()
      if code ~= 0 then
        notify(('the companion exited with %s.'):format(tostring(code)), vim.log.levels.ERROR)
      end
    end,
  })
  if process == nil then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  state.process = process
  return process
end

--- The room's limit on a display name, counted the way the protocol counts: UTF-16 code units,
--- so an astral character costs two. A name at the limit is allowed and one over it is refused,
--- never shortened, because the room must see the name its owner chose or no name at all.
local MAX_DISPLAY_NAME = 32

--- How long `name` is beside the limit, in the unit the room counts and the sentence both
--- clients use: UTF-16 code units, so an astral character costs two.
local function over_long(name)
  return ('%d UTF-16 code units and the limit is %d'):format(utf16.len(name), MAX_DISPLAY_NAME)
end

--- Whether a name with nobody to re-ask fits the limit, saying so when it does not. A false
--- answer means what the caller was about to do did not happen, and `did` names which: the
--- name came from a setting rather than from a question, so the sentence is where that setting
--- is — the only place this refusal can be acted on.
local function acceptable(name, source, did)
  if utf16.len(name) <= MAX_DISPLAY_NAME then
    return true
  end
  notify(
    ('this name is %s; a name is refused rather than shortened, so %s. Set a shorter one in %s.'):format(
      over_long(name),
      did,
      source
    ),
    vim.log.levels.ERROR
  )
  return false
end

--- The name the room is told this client is, when one has been configured: the plugin's own
--- global first, then `SELVAGE_DISPLAY_NAME`, the variable the launcher and the runbook set.
--- Nil when there is neither, because that is the case that asks. The second value names the
--- source, so a refusal can say which setting to change.
local function configured_display_name()
  local name = vim.g.selvage_display_name
  local source = 'vim.g.selvage_display_name'
  if name == nil or vim.trim(tostring(name)) == '' then
    name = vim.env.SELVAGE_DISPLAY_NAME
    source = 'SELVAGE_DISPLAY_NAME'
  end
  if name == nil or vim.trim(tostring(name)) == '' then
    return nil
  end
  return vim.trim(tostring(name)), source
end

--- The name a prompted answer left behind, so a restart is not asked again: the other
--- half of the last server address, in a file beside it under `stdpath`. Read when a
--- session starts without a configured name, written when one is answered or set.
--- A read or write that fails is not a session's failure, so both give up silently.
local function last_display_name_file()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_display_name')
end

--- The name the file remembers, or nil when no session has answered yet or it cannot be read.
local function read_last_display_name()
  local ok, lines = pcall(vim.fn.readfile, last_display_name_file())
  if not ok or type(lines) ~= 'table' or #lines < 1 then
    return nil
  end
  local name = vim.trim(tostring(lines[1]))
  if name == '' then
    return nil
  end
  return name
end

--- Remembers `name` for the next session, in this Neovim and after it.
local function remember_last_display_name(name)
  local file = last_display_name_file()
  pcall(vim.fn.mkdir, vim.fs.dirname(file), 'p')
  pcall(vim.fn.writefile, { name }, file)
end

--- The `vim.ui.input` the plugin was loaded with. A replaced one — a GUI prompt, another
--- plugin — is a prompt mechanism of its own, so it counts as somewhere to ask even where no
--- UI is attached; the built-in reads the terminal, which a headless process does not have.
local builtin_input = vim.ui.input

--- The login name, as the suggestion a prompt starts from. Nothing is ever seated under it: it
--- is what the user is offered, and `$USERNAME` is the name the other platform sets.
local function login_name()
  return vim.env.USER or vim.env.USERNAME or ''
end

--- Whether there is anyone to answer a prompt.
local function can_prompt()
  return #api.nvim_list_uis() > 0 or vim.ui.input ~= builtin_input
end

--- Runs `callback(name)` with the name a session starting now should use: the configured
--- value, else the remembered answer, else one question whose answer is written down.
---
--- With neither the global nor the environment set, the user is asked once with `vim.ui.input`,
--- pre-filled with the login name, and the answer becomes the global and the remembered file,
--- so neither this Neovim nor the next one asks again. The pre-fill is a suggestion and nothing
--- more: it is not an answer, so a cancelled or emptied prompt refuses the session rather than
--- seating a room under a name nobody chose. Nobody to ask is the same refusal said
--- differently — a process without a UI starts no room rather than guessing one.
---
--- Every one of those names has to fit the room's limit. A name the user typed is asked for again
--- with its length; one that came from the global or the environment has nobody to re-ask, so it
--- stops the session rather than being shortened.
local function resolve_display_name(callback)
  local configured, source = configured_display_name()
  if configured ~= nil then
    if acceptable(configured, source, 'the session was not started') then
      callback(configured)
    end
    return
  end
  local remembered = read_last_display_name()
  if remembered ~= nil and utf16.len(remembered) <= MAX_DISPLAY_NAME then
    callback(remembered)
    return
  end
  if not can_prompt() then
    notify(
      'no display name is set and there is no one to ask; set vim.g.selvage_display_name or SELVAGE_DISPLAY_NAME, or run :SelvageDisplayName.',
      vim.log.levels.ERROR
    )
    return
  end
  local function ask()
    vim.ui.input(
      {
        prompt = ('The name other participants see (at most %d characters): '):format(MAX_DISPLAY_NAME),
        default = login_name(),
      },
      function(input)
      local name = vim.trim(input or '')
      if name == '' then
        notify('a name is needed; the session was not started.', vim.log.levels.ERROR)
        return
      end
      if utf16.len(name) > MAX_DISPLAY_NAME then
        notify(
          ('this name is %s; a name is refused rather than shortened.'):format(over_long(name)),
          vim.log.levels.ERROR
        )
        ask()
        return
      end
      vim.g.selvage_display_name = name
      remember_last_display_name(name)
      callback(name)
    end)
  end
  ask()
end

--- The server a bare `:SelvageHost` asks about when nothing was configured and nothing
--- was remembered: the Pi demo from `ai_notes/docs/runbook-pi-demo.md`. An overridable
--- default, never a commitment — the answer is remembered, and an explicit argument and
--- `vim.g.selvage_server_url` always win — so moving the demo is this one line.
local DEFAULT_SERVER_URL = 'ws://100.64.0.3:8080'

--- A scheme at the start of a typed value: `ws`, `wss`, `http`, `https`. Its presence is what
--- separates a URL from an address someone typed out of their head, and the bare form is the
--- one that has to be completed rather than refused.
local function has_scheme(text)
  return text:match('^%a[%w+.-]*://') ~= nil
end

--- The address the engine dials, from whatever was typed in a server-address position.
---
--- A person types a host, not a URL: `selvage-demo.dontblameme.dev` means the published shape,
--- which is TLS, so a bare address means `wss://<host>`. The endpoint path is not part of a
--- server address — the engine appends `/session` to the base it is given — so an address that
--- already names the endpoint loses it, or the room would be dialled at `/session/session`,
--- and a trailing slash is not a second server. Any other path is kept: a server behind a
--- prefix was addressed deliberately, not mistyped.
local function normalise_server_address(text)
  local trimmed = vim.trim(text or '')
  if trimmed == '' then
    return ''
  end
  local addressed = has_scheme(trimmed) and trimmed or ('wss://' .. trimmed)
  addressed = (addressed:gsub('/+$', ''))
  return (addressed:gsub('/session$', ''))
end

--- The page a server's room is linked at: the server's own origin, over the scheme a browser
--- speaks. One address decides the whole invite — the page the guest opens and the socket they
--- join on are the same host — so a room cannot be linked at a page that dials another server,
--- which is what a separate page setting used to allow.
local function page_origin(base)
  local wanted = vim.trim(base or ''):gsub('/+$', '')
  if wanted:match('^wss://') ~= nil then
    return 'https://' .. wanted:sub(7)
  end
  if wanted:match('^ws://') ~= nil then
    return 'http://' .. wanted:sub(6)
  end
  return wanted
end

--- The last server address a host was started on, so the next bare `:SelvageHost` reuses
--- it without asking. The file below is what outlives this Neovim; this is what answers
--- without reading it twice in one process. `vim.g.selvage_server_url` is the setting that
--- uses another address instead.
local last_server = nil

--- The file the last server address is kept in across restarts: the other client remembers it
--- in its global state, and a bare `:SelvageHost` starts its question from it all the same. A
--- file beside the mirrors under `stdpath`, read when the question is asked and written when a
--- host starts, so a restart forgets nothing. A read or write that fails is not a session's
--- failure, so both give up silently.
local function last_server_file()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_server')
end

--- The address the file remembers, or nil when no host has been started yet or it cannot be read.
local function read_last_server()
  local ok, lines = pcall(vim.fn.readfile, last_server_file())
  if not ok or type(lines) ~= 'table' or #lines < 1 then
    return nil
  end
  local address = vim.trim(tostring(lines[1]))
  if address == '' then
    return nil
  end
  return address
end

--- Remembers `address` for the next host, in this Neovim and after it: a bare host
--- reuses it without asking, and an argument or `vim.g.selvage_server_url` uses another.
local function remember_last_server(address)
  last_server = address
  local file = last_server_file()
  pcall(vim.fn.mkdir, vim.fs.dirname(file), 'p')
  pcall(vim.fn.writefile, { address }, file)
end

--- Whether a document the room changes is written. Nothing is sent when the plugin's global says
--- nothing, so the companion's own default — write it — stands, as the other client's setting
--- defaults to on.
---
--- The version a host is pinned to: `vim.g.selvage_wire_version`, which is `1` (or `'1'`, or
--- `'selvage/1'`) for the readable wire and `2` (or `'2'`, or `'selvage/2'`) for the encrypted one.
--- Anything else — including unset, and the `'auto'` the other client spells its default with —
--- pins nothing, and the server's `/meta` decides: a client that can speak `selvage/2` mints it
--- where the server seats it, and is refused rather than fallen back to `selvage/1` where it does
--- not, so a room the server can read is asked for deliberately or not at all.
---
--- It is a host's setting and not a guest's. A join speaks the version the *link* names, because
--- the `selvage/2` invite's fragment is the room key and the host key: a client that cannot read
--- them cannot join the room at all, and one that can has been told which version to speak.
local function pinned_wire_version()
  local configured = vim.g.selvage_wire_version
  if configured == 2 or configured == '2' or configured == 'selvage/2' then
    return 'selvage/2'
  end
  if configured == 1 or configured == '1' or configured == 'selvage/1' then
    return 'selvage/1'
  end
  return nil
end

local function auto_save()
  local configured = vim.g.selvage_auto_save
  if type(configured) == 'boolean' then
    return configured
  end
  return nil
end

--- The question a session that is already live needs before another one replaces it: giving up a
--- room is the person's call, and a join or a host that took one from them silently could take the
--- room from everyone in it. Answered yes only by the button that names it; a process with nobody
--- to ask cannot be asked, so the question is said and the answer is no.
local function confirm_leave(question, button)
  if not can_prompt() then
    notify(question, vim.log.levels.WARN)
    return false
  end
  return vim.fn.confirm(question, ('&%s\n&Cancel'):format(button), 2, 'Warning') == 1
end

--- The box the first-run question and `:SelvageChangeServer`'s change both ask through: the
--- server address, starting from `default`. Answers `callback(address)` for a non-empty,
--- trimmed reply; a cancelled or emptied one calls nothing, so the caller's own state stands.
local function ask_server_url(default, callback)
  vim.ui.input({
    prompt = 'Selvage server to host on (selvaged printed it when it started): ',
    default = default,
  }, function(input)
    local address = vim.trim(input or '')
    if address == '' then
      return
    end
    callback(address)
  end)
end

--- The server to mint a room on: the configured address, else the remembered one with no
--- question asked, else one question starting from the demo default (`DEFAULT_SERVER_URL`).
--- Asked once, then reused: an argument or `vim.g.selvage_server_url` uses another, and
--- writes it down as the remembered one.
local function resolve_server_url(callback)
  local configured = vim.g.selvage_server_url
  if configured ~= nil and vim.trim(tostring(configured)) ~= '' then
    callback(vim.trim(tostring(configured)))
    return
  end
  local remembered = last_server or read_last_server()
  if remembered ~= nil then
    callback(remembered)
    return
  end
  if not can_prompt() then
    notify('a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080.', vim.log.levels.ERROR)
    return
  end

  ask_server_url(DEFAULT_SERVER_URL, callback)
end

--- Percent-encodes a query value the way the page builds its link: the unreserved
--- characters stand, everything else rides as uppercase `%XX`.
local function encode_component(text)
  return (tostring(text):gsub('[^A-Za-z0-9%.%-%_~]', function(char)
    return ('%%%02X'):format(string.byte(char))
  end))
end

--- Percent-decodes a query value, turning `+` into a space as a form would.
local function decode_component(text)
  local spaced = tostring(text):gsub('+', ' ')
  return (spaced:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Reads the room and its token out of a query string. Keys match whole, so a `bedroom=`
--- lookalike does not pass, and empty values do not count.
local function query_parts(query, fragment)
  local found = {}
  for pair in tostring(query):gmatch('[^&]+') do
    local key, value = pair:match('^([^=]*)=(.*)$')
    if (key == 'room' or key == 'token') and found[key] == nil then
      if value ~= nil and value ~= '' then
        found[key] = decode_component(value)
      end
    end
  end
  if found.room == nil or found.room == '' or found.token == nil or found.token == '' then
    return nil
  end
  -- §5.1's fragment is not a parameter and never a parameter's value: it is the two keys a
  -- `selvage/2` invite carries, opaque to everything that only joins a room. It is kept as it
  -- arrived, because handing the link on has to hand it on whole.
  found.fragment = fragment or ''
  return found
end

--- The fragment of a link as it is written, `#` included, and the address before it.
local function split_fragment(text)
  local hash = text:find('#', 1, true)
  if hash == nil then
    return text, ''
  end
  return text:sub(1, hash - 1), text:sub(hash)
end

--- Splits a wire invite into the server base and the room/token it carries, or
--- answers nil when the value has no wire-invite shape.
local function parse_wire_invite(text)
  local trimmed = vim.trim(text or '')
  if trimmed:match('^wss?://%S+$') == nil then
    return nil
  end
  local address, fragment = split_fragment(trimmed)
  local mark = address:find('?', 1, true)
  if mark == nil then
    return nil
  end
  local parts = query_parts(address:sub(mark + 1), fragment)
  if parts == nil then
    return nil
  end
  return {
    base = (address:sub(1, mark - 1):gsub('/session$', '')),
    room = parts.room,
    token = parts.token,
    fragment = parts.fragment,
  }
end

--- Reads a pasted page link back into the room and its token — the page's own parsing,
--- mirrored so a copied link joins the same way it loads. The server is the link's origin, so
--- nothing in the query names one.
local function parse_page_link(text)
  local trimmed = vim.trim(text or '')
  if trimmed:match('^https?://%S+$') == nil then
    return nil
  end
  local address, fragment = split_fragment(trimmed)
  local mark = address:find('?', 1, true)
  if mark == nil then
    return nil
  end
  local parts = query_parts(address:sub(mark + 1), fragment)
  if parts == nil then
    return nil
  end
  return {
    room = parts.room,
    token = parts.token,
    origin = address:sub(1, mark - 1),
    fragment = parts.fragment,
  }
end

--- The guest link for a room: the page the room's own server serves, carrying room and token.
--- The link *is* the server — its origin is the address the guest dials — so it carries nothing
--- else.
local function build_page_link(room, token, base, fragment)
  return page_origin(base)
    .. '/?room='
    .. encode_component(room)
    .. '&token='
    .. encode_component(token)
    .. (fragment or '')
end

--- The wire URL an invite joins on: a page link resolves to the server its own origin names,
--- while a `ws://` invite — a room whose server serves no page, or a guest that reached one
--- that way — joins as it stands.
local function resolve_invite_to_wire(link)
  local page = parse_page_link(link)
  if page == nil then
    return link
  end
  local server = (page.origin:gsub('^https://', 'wss://'):gsub('^http://', 'ws://'))
  return (server:gsub('/+$', ''))
    .. '/session?room='
    .. encode_component(page.room)
    .. '&token='
    .. encode_component(page.token)
    .. (page.fragment or '')
end

--- Whether a typed value has an invite link's shape: the page link the host copies,
--- or a WebSocket address naming a room and its token. The names match whole with a
--- non-empty value, so a `bedroom=` lookalike or an empty value does not pass.
local function is_invite_link(text)
  return parse_wire_invite(text) ~= nil or parse_page_link(text) ~= nil
end

--- The refusal a value that is not an invite link earns, whoever asked: the box a bare
--- `:SelvageJoin` opens, and the argument an explicit one carries. One sentence for both, so the
--- same paste is answered the same way however it arrived, and a truncated one fails here rather
--- than later as whatever the engine said — nobody can tell "bad paste" from "server down" from
--- an ECONNREFUSED.
local function refuse_invite()
  notify(
    'that does not look like a Selvage invite link. Paste the whole link the host sent you — it looks like https://page/?room=…&token=…. A ws://host:8080/session?room=…&token=… link still joins.',
    vim.log.levels.ERROR
  )
end

--- What the clipboard holds, when it holds an invite: the host has just sent the link and pasting
--- it is the next thing the person does. Only a link that names a room is offered, so a stray
--- address in the clipboard is not joined by mistake.
local function clipboard_invite()
  local ok, text = pcall(vim.fn.getreg, '+')
  if not ok or text == nil or text == '' then
    ok, text = pcall(vim.fn.getreg, '"')
  end
  if not ok or type(text) ~= 'string' then
    return ''
  end
  text = vim.trim(text)
  if is_invite_link(text) then
    return text
  end
  return ''
end

--- The invite to join on, asked for when the command was given none. What the box returns is
--- checked here; what arrived as an argument is checked before the name is resolved, in
--- `M.join`, and both say the same sentence (`refuse_invite`).
local function resolve_invite(callback)
  if not can_prompt() then
    notify('an invite link is needed.', vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = 'Join a Selvage session: ', default = clipboard_invite() }, function(input)
    local invite = vim.trim(input or '')
    if invite == '' then
      return
    end
    if not is_invite_link(invite) then
      refuse_invite()
      return
    end
    callback(invite)
  end)
end

--- Puts this session's invite on the clipboard and the unnamed register, and answers what
--- became of it: `'copied'` when the system clipboard took the link, `'register'` and the
--- reason when only this Neovim's own registers did, `'no-session'` when there is no session
--- to hand one on from, and `'no-invite'` when the session stands but this connection holds no
--- link for it.
---
--- Nothing is consumed here: the link is derived from the session every time it is asked for,
--- so one copy leaves the next one with just as much to put on the clipboard.
---
--- What a host copies is its page link, never the wire address it holds. A guest holds the
--- token it joined with — the invite *is* the permission — so the link its host sent is the
--- guest's to hand on, as it stands: the page link keeps the origin the host sent it from, and
--- a guest that reached the room over `ws://` has no other address for it.
hand_on_invite = function()
  -- An invite that outlived its session is not one to hand on: a failed join leaves the link
  -- remembered, and a room nobody is in is not a room to invite anyone to.
  if not in_session() then
    return 'no-session'
  end
  local invite = state.invite
  if invite == nil then
    return 'no-invite'
  end
  local link = invite
  if not is_peer() then
    local wire = parse_wire_invite(invite)
    if wire == nil then
      return 'no-invite'
    end
    link = build_page_link(wire.room, wire.token, wire.base, wire.fragment)
  end
  vim.fn.setreg('"', link)
  -- The system clipboard is not this editor's to command: a Neovim with no clipboard provider
  -- takes the link into the unnamed register and nowhere else on the machine, so a sentence
  -- saying the clipboard has it would claim what the code cannot do. The unnamed register is
  -- written first and stands either way, so the link is never lost, only less reachable.
  local copied, why = pcall(vim.fn.setreg, '+', link)
  if not copied then
    return 'register', tostring(why)
  end
  return 'copied'
end

--- Mints a room and shares the current buffer.
---
--- Hosting while hosting is reaching for the invite, not asking for a room: a second room would
--- end the first for everyone in it, and nobody asked for that. Hosting while a guest means
--- leaving the room first, which is the person's call and so a question.
function M.host(url)
  local wanted = vim.trim(url or '')
  if state.status == 'hosting' then
    local handed, why = hand_on_invite()
    if handed == 'copied' then
      notify('you are already hosting this session; the invite link is on the clipboard.')
    elseif handed == 'register' then
      notify(
        ('you are already hosting this session, but the invite link could not be copied (%s).'):format(
          why
        ),
        vim.log.levels.WARN
      )
    else
      notify(
        'you are already hosting this session, but this connection holds no invite link to send.',
        vim.log.levels.WARN
      )
    end
    return
  end
  -- A session being opened is one in flight: a second host behind it earns the companion's
  -- refusal, whose sentence describes a live room rather than a double invocation half a
  -- second apart.
  if state.status == 'connecting' then
    notify('a session is already being opened.', vim.log.levels.WARN)
    return
  end
  if in_session() then
    local can_leave = confirm_leave(
      'you are in this session; hosting a session means leaving it first.',
      'Leave and host'
    )
    if not can_leave then
      return
    end
    end_session()
  end
  local function with_url(address)
    -- Whatever was typed — an argument, an answer to the first-run question, a remembered one — is
    -- completed here, so one place decides what a bare host means and the command that reports
    -- an address reports the address a host would dial.
    address = normalise_server_address(address)
    remember_last_server(address)
    resolve_display_name(function(display_name)
      local process = ensure()
      if process ~= nil then
        capture_root()
        state.connect = { what = 'host', address = address }
        process:send({
          type = 'host',
          serverUrl = address,
          displayName = display_name,
          autoSave = auto_save(),
          root = state.root,
          wire = pinned_wire_version(),
        })
      end
    end)
  end
  if wanted ~= '' then
    with_url(wanted)
    return
  end
  resolve_server_url(with_url)
end

--- Joins the room an invite link names.
---
--- A session already live is given up first, and only when the person says so: joining another
--- room ends this one for everyone in it, and a mistyped link must not do that on its own. A
--- mistyped one does nothing at all: it is refused here, before the name is asked for, before a
--- live session is given up for it and before anything is dialled.
function M.join(invite)
  local wanted = vim.trim(invite or '')
  -- An argument that is not an invite link cannot join whatever the session is doing, so it is
  -- answered at once rather than behind a name prompt: a question put in front of a failure
  -- reads as a join in progress, and the name it collects would outlive it.
  if wanted ~= '' and not is_invite_link(wanted) then
    refuse_invite()
    return
  end
  -- As hosting one: a second join behind a session being opened earns the companion's
  -- refusal for a room that was never live.
  if state.status == 'connecting' then
    notify('a session is already being opened.', vim.log.levels.WARN)
    return
  end
  if in_session() then
    local can_leave
    if state.role == 'host' then
      can_leave = confirm_leave(
        'you are hosting this session; joining another session ends this room for everyone.',
        'Leave and join'
      )
    else
      can_leave = confirm_leave(
        'you are in this session; joining another session leaves it.',
        'Leave and join'
      )
    end
    if not can_leave then
      return
    end
    end_session()
  end
  local function with_invite(link)
    resolve_display_name(function(display_name)
      local process = ensure()
      if process ~= nil then
        capture_root()
        -- The invite this guest joined by is kept as it arrived: it is the permission the
        -- room was entered with, so it is the guest's to hand on (`:SelvageCopyInvite`).
        state.invite = link
        state.connect = { what = 'join' }
        process:send({
          type = 'join',
          -- The companion dials the wire URL: a pasted page link resolves to its
          -- room's server here, while a `ws://` link joins as it always has.
          invite = resolve_invite_to_wire(link),
          displayName = display_name,
          autoSave = auto_save(),
        })
      end
    end)
  end
  if wanted ~= '' then
    with_invite(wanted)
    return
  end
  resolve_invite(with_invite)
end

--- Puts the invite on the clipboard and the unnamed register, and says where it is. A session
--- that stands without a link to hand on is not a session that is absent: the sentence for the
--- one says what was missing, and `host or join a room first` is left for the window that is
--- in no session at all.
function M.copy_invite()
  local handed, why = hand_on_invite()
  if handed == 'no-session' then
    notify('there is no invite link; host or join a room first.', vim.log.levels.WARN)
    return
  end
  if handed == 'no-invite' then
    notify('this session holds no invite link to copy.', vim.log.levels.WARN)
    return
  end
  if handed == 'register' then
    notify(('the invite link could not be copied (%s).'):format(why), vim.log.levels.WARN)
    return
  end
  notify('the invite link is on the clipboard.')
end

--- Leaves the session and stops the companion.
---
--- The guard is the session, not the process: a companion outlives the session it held — a
--- connection the engine gave up on and a room that goes both leave it running for the next host
--- or join — so a process alone would say there was something left to leave.
function M.leave()
  if not in_session() then
    notify('not in a session.', vim.log.levels.WARN)
    return
  end
  local process = state.process
  state.process = nil
  if process ~= nil then
    process:send({ type = 'leave' })
    process:stop()
  end
  reset()
  notify('left the session.')
end

--- The name other participants see, when one is in force: the plugin's global, the
--- environment's name, or the remembered answer — which is what a session starting now
--- would use without asking. Nil when there is none of those: nothing is invented here —
--- a name nobody chose is not a name, and the login name is only ever what the prompt
--- starts from — so a script reading this can tell that the next host or join will ask,
--- or refuse where there is no one to ask. It reports whatever was configured, so a name
--- over the room's limit comes back too; that one stops a session rather than being
--- shortened, and `:SelvageDisplayName` says so.
function M.display_name()
  local configured = configured_display_name()
  if configured ~= nil then
    return configured
  end
  return read_last_display_name()
end

--- Sets the name other participants see, and says when it takes effect.
---
--- Before a session the name rides in the `host`/`join` handshake. During one the change is sent
--- now, as `session.rename`, and the room is told with `peer.renamed`: the sign and
--- `:SelvagePeers` re-label from that event, so the name in force is the room's answer rather
--- than anything held here. With no name, it reports the one now in force instead of setting an
--- empty one. A name over the room's limit is refused with its length, before either, since a
--- session cannot join under one and a report of it as the name in force would be a lie.
function M.set_display_name(name)
  local wanted = vim.trim(name or '')
  if wanted == '' then
    local name = M.display_name()
    if name == nil then
      notify('no display name is set yet.')
    else
      local _, source = configured_display_name()
      if source ~= nil and not acceptable(name, source, 'the next session will not start') then
        return
      end
      notify(('the name others see is "%s"; :SelvageDisplayName <name> to change it.'):format(name))
    end
    return
  end
  if utf16.len(wanted) > MAX_DISPLAY_NAME then
    notify(
      ('this name is %s; a name is refused rather than shortened.'):format(over_long(wanted)),
      vim.log.levels.ERROR
    )
    return
  end
  vim.g.selvage_display_name = wanted
  remember_last_display_name(wanted)
  if state.process ~= nil then
    state.process:send({ type = 'rename', displayName = wanted })
  end
  notify(('display name set to "%s".'):format(wanted))
end

--- The palette-reachable answer to "how do I change which server I am using", without hosting
--- first: reports the server the next host uses and offers to change it through the same box
--- the first-run question asks. `vim.g.selvage_server_url` outranks the remembered address
--- (`resolve_server_url()`), so writing the remembered one while it is set would be silently
--- ignored by the next host; this says the global is in force instead of pretending to change
--- anything. Either way the write only reaches the *next* host, never a live room.
function M.change_server(url)
  local wanted = vim.trim(url or '')
  local configured = vim.g.selvage_server_url
  local configured_str = configured ~= nil and normalise_server_address(tostring(configured)) or ''
  if configured_str ~= '' then
    notify(
      ('the "vim.g.selvage_server_url" setting fixes the server at %s; change it in your config to use a different one.'):format(
        configured_str
      )
    )
    return
  end
  if wanted ~= '' then
    local address = normalise_server_address(wanted)
    remember_last_server(address)
    notify(('will host on %s next. Leave this session and host again to move there.'):format(address))
    return
  end
  local current = last_server or read_last_server()
  if current == nil then
    notify('no server is remembered yet; the next host asks.')
  else
    notify(('the next host uses %s.'):format(normalise_server_address(current)))
  end
  if not can_prompt() then
    return
  end
  -- The box and its answer are completed before either is used, so the address this command
  -- reports is the address the next host dials, bare host or not.
  local base = normalise_server_address(current or DEFAULT_SERVER_URL)
  ask_server_url(base, function(address)
    address = normalise_server_address(address)
    if address == base then
      return
    end
    remember_last_server(address)
    notify(('will host on %s next. Leave this session and host again to move there.'):format(address))
  end)
end

return M
