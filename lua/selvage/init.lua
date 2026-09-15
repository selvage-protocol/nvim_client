-- Selvage for Neovim: the commands, and which buffers a session shares.
--
-- Everything that decides anything about a document is in the companion process
-- (`companion/`, driving the vendored engine and bridge). What is here is which buffer is
-- shared under which room path, and the wiring between the two.

local companion = require('selvage.companion')
local Document = require('selvage.document')
local utf16 = require('selvage.utf16')

local api = vim.api

local M = {}

local state = {
  process = nil,
  status = 'idle',
  role = nil,
  room = nil,
  invite = nil,
  --- @type table<string, table> room path to document
  documents = {},
  --- The room paths this session refused to share, so the refusal is said once: a buffer that
  --- is not UTF-8 is entered and left many times over a session.
  unshareable = {},
  group = nil,
  -- Presence: the augroup the caret watchers live in, the marks drawn for peers, and the one
  -- scheduled flush that publishes this user's caret.
  presence_group = nil,
  presence_ns = nil,
  presence_marks = {},
  peer_groups = {},
  peer_fills = {},
  peer_count = 0,
  cursors = {},
  -- The peers the last presence report drew, as rows for `:SelvagePeers` to print.
  peers = {},
  -- The peers the room itself named, which is everyone in it and not only the ones this client
  -- holds a document for (`report.kind == 'peers'`).
  room_peers = {},
  selection_armed = false,
  selection_path = nil,
  generation = 0,
  -- Whether the next document the room names is still the one to put in front of the user.
  -- Set when a guest joins; cleared by the first document shown.
  auto_open = false,
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

--- Where the session stands, for a statusline or a script.
function M.session()
  return {
    status = state.status,
    role = state.role,
    room = state.room,
    invite = state.invite,
    documents = M.documents(),
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
  api.nvim_set_hl(0, name, { fg = '#000000', bg = cursor.colour or '#888888', bold = true })
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
  local r, g, b = channels(cursor.colour)
  if r == nil then
    api.nvim_set_hl(0, name, {})
    return name
  end
  local background = api.nvim_get_hl(0, { name = 'Normal' }).bg
  if background == nil then
    background = vim.o.background == 'light' and 0xffffff or 0x000000
  end
  local nr = math.floor(background / 65536) % 256
  local ng = math.floor(background / 256) % 256
  local nb = background % 256
  local alpha = fill_alpha(cursor.fill)
  local function mix(fore, back)
    return math.floor(fore * alpha + back * (1 - alpha) + 0.5)
  end
  api.nvim_set_hl(0, name, { bg = ('#%02x%02x%02x'):format(mix(r, nr), mix(g, ng), mix(b, nb)) })
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
  state.cursors = cursors or {}
  state.peers = {}
  clear_presence()
  local ns = presence_namespace()
  for _, cursor in ipairs(state.cursors) do
    local document = state.documents[cursor.path]
    if document ~= nil and api.nvim_buf_is_valid(document.bufnr) then
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
    notify('join a session first', vim.log.levels.WARN)
    return
  end
  local peers = M.peers()
  if #peers == 0 then
    notify('no other participants to name; a session names them as they arrive', vim.log.levels.WARN)
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
        tostring(peer.role or 'peer'),
        tostring(peer.path or 'no shared document open')
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
end

--- The room path a buffer is shared under, or nil when it is not one to share.
local function room_path(bufnr)
  if vim.bo[bufnr].buftype ~= '' then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  local relative = vim.fn.fnamemodify(name, ':.')
  -- `:.` leaves the path absolute when it is not under the working directory. The directory
  -- the session was started in is the grant (`DESIGN.md` §4.2); anything outside it is not
  -- this room's to share.
  if relative:sub(1, 1) == '/' then
    return nil
  end
  return (relative:gsub('\\', '/'))
end

local function share(bufnr, path)
  if state.process == nil or state.documents[path] ~= nil then
    return
  end
  -- The same text `Document.new` will shadow, read once. The companion decodes its stdin as
  -- UTF-8, so a buffer whose bytes are not UTF-8 would reach the room as U+FFFD; refusing it
  -- here keeps the `open` out of the room and every later `change` with it.
  local text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n') .. '\n'
  if not utf16.valid(text) then
    if state.unshareable[path] == nil then
      state.unshareable[path] = true
      notify(path .. ' is not valid UTF-8, so it is not shared', vim.log.levels.ERROR)
    end
    return
  end
  local document = Document.new(bufnr, path, function(message)
    state.process:send(message)
  end)
  state.documents[path] = document
  document:attach()
  state.process:send({ type = 'open', path = path, text = text })
  -- The document may already have a peer's caret resolved against it, and this buffer's own
  -- caret is worth publishing the moment the room holds it.
  draw_presence(state.cursors)
  schedule_selection()
end

--- The buffer a guest holds the room's document in. It has nowhere on disk to go.
local function guest_buffer(path)
  local name = 'selvage://' .. path
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end
  local bufnr = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].modifiable = true
  return bufnr
end

local function share_current()
  local bufnr = api.nvim_get_current_buf()
  local path = room_path(bufnr)
  if path ~= nil then
    share(bufnr, path)
  end
end

--- Puts a buffer in the window the user is looking at.
local function show(bufnr)
  if bufnr == nil or not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return pcall(api.nvim_win_set_buf, 0, bufnr)
end

--- The room path a user's words name: the room path, its `selvage://` buffer name, or a
--- suffix of the path at a directory boundary. A host above a folder called `workspace`
--- publishes `workspace/README.md`; a guest who types `README.md` means that one.
local function resolve(wanted)
  wanted = wanted:gsub('^selvage://', '')
  if state.documents[wanted] ~= nil then
    return wanted, {}
  end
  local matches = {}
  for _, candidate in ipairs(M.documents()) do
    if candidate:sub(-(#wanted + 1)) == '/' .. wanted then
      matches[#matches + 1] = candidate
    end
  end
  if #matches == 1 then
    return matches[1], matches
  end
  return nil, matches
end

local function choose(paths)
  vim.ui.select(paths, { prompt = 'selvage: open which document?' }, function(choice)
    if choice ~= nil then
      show(state.documents[choice].bufnr)
    end
  end)
end

--- Opens one of the room's documents in the current window.
---
--- With no argument and one document, that document; with several, the user is asked which.
function M.open(path)
  local paths = M.documents()
  if #paths == 0 then
    notify('no shared documents; join a session first', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(path or '')
  if wanted == '' then
    if #paths == 1 then
      show(state.documents[paths[1]].bufnr)
    else
      choose(paths)
    end
    return
  end
  local resolved, candidates = resolve(wanted)
  if resolved == nil then
    if #candidates > 1 then
      notify('"' .. wanted .. '" matches several: ' .. table.concat(candidates, ', '), vim.log.levels.WARN)
    else
      notify('no shared document matches "' .. wanted .. '"; :SelvageOpen alone offers them', vim.log.levels.WARN)
    end
    return
  end
  show(state.documents[resolved].bufnr)
end

--- A host shares what it opens for as long as the session lasts.
local function watch_buffers()
  state.group = api.nvim_create_augroup('SelvageHost', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.group,
    callback = function(event)
      local path = room_path(event.buf)
      if path ~= nil then
        share(event.buf, path)
      end
    end,
  })
  -- A wiped buffer is not a buffer anymore: the room is told, and the path stops being held
  -- here. Without this the room keeps the document for the life of the session, offering
  -- edits to a `Document` that answers every one of them `ok = false`, and the companion
  -- retries until it reports a refusal about a buffer the user closed.
  --
  -- The send belongs here rather than in `Document:on_detach`, which also fires when the
  -- session ends: every `:SelvageLeave` would put a `close` on the wire for each document it
  -- is letting go of, and the companion would hear about a room it is already leaving.
  api.nvim_create_autocmd('BufWipeout', {
    group = state.group,
    callback = function(event)
      local document = document_for_buf(event.buf)
      if document == nil then
        return
      end
      document:detach()
      if state.process ~= nil then
        state.process:send({ type = 'close', path = document.path })
      end
      state.documents[document.path] = nil
    end,
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
    document:detach()
  end
  state.documents = {}
  state.unshareable = {}
end

--- Ends the session: every buffer it shared stops reporting, presence goes, and the front-end
--- is back to nothing shared.
local function reset()
  -- A callback left attached would keep sending into a companion that is gone.
  forget_documents()
  clear_presence()
  state.peers = {}
  state.room_peers = {}
  state.cursors = {}
  for _, name in pairs(state.peer_groups) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  for _, name in pairs(state.peer_fills) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  state.peer_groups = {}
  state.peer_fills = {}
  state.peer_count = 0
  state.generation = state.generation + 1
  state.selection_armed = false
  state.selection_path = nil
  state.status = 'idle'
  state.role = nil
  state.room = nil
  state.invite = nil
  state.auto_open = false
  if state.group ~= nil then
    api.nvim_del_augroup_by_id(state.group)
    state.group = nil
  end
  if state.presence_group ~= nil then
    api.nvim_del_augroup_by_id(state.presence_group)
    state.presence_group = nil
  end
end

local function on_status(message)
  state.status = message.state
  state.role = message.role
  state.room = message.roomId
  if message.invite ~= nil then
    state.invite = message.invite
  end
  if message.state == 'idle' then
    -- The session is over, whoever ended it: `:SelvageLeave` has reset before it hears this, and
    -- a room that goes or a connection the engine gave up on reaches here from the companion,
    -- which has already let the engine go.
    reset()
  elseif message.state == 'hosting' then
    notify('hosting ' .. tostring(message.roomId) .. '; :SelvageCopyInvite to share it')
    share_current()
    watch_buffers()
    watch_presence()
  elseif message.state == 'joined' then
    notify('joined ' .. tostring(message.roomId))
    state.auto_open = true
    watch_presence()
  elseif message.state == 'error' then
    notify(tostring(message.message), vim.log.levels.ERROR)
  end
end

local function on_report(report)
  if report.kind == 'documents' then
    if state.role == 'guest' then
      local first = nil
      for _, path in ipairs(report.documents) do
        local bufnr = guest_buffer(path)
        first = first or bufnr
        share(bufnr, path)
      end
      -- Once, for the report that follows the join: the room's document set is what the user
      -- who just ran `:SelvageJoin` asked to be shown. A document the host opens later gets a
      -- buffer and waits for `:SelvageOpen` — stealing the window then would interrupt
      -- whatever the guest is already editing.
      if state.auto_open and first ~= nil then
        state.auto_open = false
        if vim.g.selvage_open_on_join ~= false then
          show(first)
          if #report.documents > 1 then
            notify(('opened %s; %d more, :SelvageOpen to choose'):format(report.documents[1], #report.documents - 1))
          end
        end
      end
    end
  elseif report.kind == 'peers' then
    -- The room's own list of who is in it: everyone, not only the peers this client holds a
    -- document for and can draw a caret for.
    state.room_peers = report.peers or {}
  elseif report.kind == 'roomGone' then
    -- The room is over and the companion has let the engine go, so the session here ends with
    -- it rather than leaving buffers, marks and a statusline behind for a room nobody is in.
    notify('the room is gone: ' .. tostring(report.reason), vim.log.levels.WARN)
    reset()
  elseif report.kind == 'hostDetached' then
    notify(
      ('the host left the room; it closes in %ds unless they come back'):format(seconds(report.graceMs)),
      vim.log.levels.WARN
    )
  elseif report.kind == 'hostAttached' then
    notify(tostring((report.peer or {}).display_name or 'the host') .. ' is hosting again')
  elseif report.kind == 'sessionError' then
    notify(tostring(report.code) .. ': ' .. tostring(report.message), vim.log.levels.ERROR)
  elseif report.kind == 'applyRefused' or report.kind == 'divergence' then
    notify(report.kind .. ' on ' .. tostring(report.path), vim.log.levels.WARN)
  elseif report.kind == 'saveFailed' then
    notify('could not write ' .. tostring(report.path), vim.log.levels.WARN)
  elseif report.kind == 'disconnected' then
    -- The bridge reconnects on its own until it runs out of attempts, and this is that end:
    -- the session is over and typing would accumulate in a replica nobody hears. The
    -- companion process is deliberately left running — `ensure` reuses it on the next host
    -- or join, and the engine on the other side of it has already finished.
    notify('the connection ended and could not be re-established; the session is over', vim.log.levels.ERROR)
    reset()
  end
end

local function on_message(message)
  if message.type == 'applyEdit' then
    local document = state.documents[message.path]
    local ok = document ~= nil and document:apply(message) or false
    state.process:send({ type = 'applied', id = message.id, ok = ok })
  elseif message.type == 'save' then
    local document = state.documents[message.path]
    local ok = document == nil or document:save()
    state.process:send({ type = 'saved', id = message.id, ok = ok })
  elseif message.type == 'status' then
    on_status(message)
  elseif message.type == 'report' then
    on_report(message.report)
  elseif message.type == 'presence' then
    draw_presence(message.cursors)
  end
end


local function ensure()
  if state.process ~= nil then
    return state.process
  end
  local process, err
  process, err = companion.start({
    on_message = on_message,
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
        notify('the companion exited with ' .. code, vim.log.levels.ERROR)
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

--- How long `name` is beside the limit, as a refusal says it. `#value` would count bytes and
--- `vim.fn.strchars` characters; neither is the unit the room counts.
local function over_long(name)
  return ('%d UTF-16 code units and the room allows %d'):format(utf16.len(name), MAX_DISPLAY_NAME)
end

--- Whether a name with nobody to re-ask fits the limit, saying so and naming `source` when it
--- does not. A false answer means the session or the command did not happen: `did` says which.
local function acceptable(name, source, did)
  if utf16.len(name) <= MAX_DISPLAY_NAME then
    return true
  end
  notify(
    ('%s is %s, so %s: a name is never shortened; set a shorter one'):format(source, over_long(name), did),
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

--- Runs `callback(name)` with the name a session starting now should use, asking for one when
--- none is configured.
---
--- The configured value wins. With neither the global nor the environment set, the user is asked
--- with `vim.ui.input`, pre-filled with the login name, and the answer becomes the global so the
--- next session is not asked again. The pre-fill is a suggestion and nothing more: it is not an
--- answer, so a cancelled or emptied prompt refuses the session rather than seating a room under
--- a name nobody chose. Nobody to ask is the same refusal said differently — a process without a
--- UI starts no room rather than guessing one.
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
  if not can_prompt() then
    notify(
      'no display name is set and there is no one to ask; set vim.g.selvage_display_name or SELVAGE_DISPLAY_NAME, or run :SelvageDisplayName',
      vim.log.levels.ERROR
    )
    return
  end
  local function ask()
    vim.ui.input({ prompt = 'The name other participants see: ', default = login_name() }, function(input)
      local name = vim.trim(input or '')
      if name == '' then
        notify('a name is needed; the session was not started', vim.log.levels.ERROR)
        return
      end
      if utf16.len(name) > MAX_DISPLAY_NAME then
        notify(('the display name is %s; say a shorter one'):format(over_long(name)), vim.log.levels.WARN)
        ask()
        return
      end
      vim.g.selvage_display_name = name
      callback(name)
    end)
  end
  ask()
end

--- Mints a room on `url` and shares the current buffer.
function M.host(url)
  if url == nil or url == '' then
    notify('a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080', vim.log.levels.ERROR)
    return
  end
  resolve_display_name(function(display_name)
    local process = ensure()
    if process ~= nil then
      process:send({ type = 'host', serverUrl = url, displayName = display_name })
    end
  end)
end

--- Joins the room an invite link names.
function M.join(invite)
  if invite == nil or invite == '' then
    notify('an invite link is needed', vim.log.levels.ERROR)
    return
  end
  resolve_display_name(function(display_name)
    local process = ensure()
    if process ~= nil then
      process:send({ type = 'join', invite = invite, displayName = display_name })
    end
  end)
end

--- Puts the invite on the clipboard and the unnamed register.
function M.copy_invite()
  if state.invite == nil then
    notify('there is no invite: this session is not hosting one', vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('"', state.invite)
  pcall(vim.fn.setreg, '+', state.invite)
  notify(state.invite)
end

--- Leaves the session and stops the companion.
---
--- The guard is the session, not the process: a companion outlives the session it held — a
--- connection the engine gave up on and a room that goes both leave it running for the next host
--- or join — so a process alone would say there was something left to leave.
function M.leave()
  if not in_session() then
    notify('not in a session', vim.log.levels.WARN)
    return
  end
  local process = state.process
  state.process = nil
  if process ~= nil then
    process:send({ type = 'leave' })
    process:stop()
  end
  reset()
  notify('left the session')
end

--- The name other participants see, when one is set: the plugin's global, or the environment's
--- name, and nil when there is neither. Nothing is invented here — a name nobody chose is not a
--- name, and the login name is only ever what the prompt starts from — so a script reading this
--- can tell that the next host or join will ask, or refuse where there is no one to ask. It
--- reports whatever was configured, so a name over the room's limit comes back too; that one
--- stops a session rather than being shortened, and `:SelvageDisplayName` says so.
function M.display_name()
  local configured = configured_display_name()
  return configured
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
    local configured, source = configured_display_name()
    if configured ~= nil and not acceptable(configured, source, 'the next session will not start') then
      return
    end
    if configured == nil then
      notify('no display name is set yet')
    else
      notify(('the name others see is "%s"; :SelvageDisplayName <name> to change it'):format(configured))
    end
    return
  end
  if utf16.len(wanted) > MAX_DISPLAY_NAME then
    notify(('the display name is %s; give a shorter one'):format(over_long(wanted)), vim.log.levels.ERROR)
    return
  end
  vim.g.selvage_display_name = wanted
  if state.process ~= nil then
    state.process:send({ type = 'rename', displayName = wanted })
  end
  notify(('display name set to "%s"'):format(wanted))
end

return M
