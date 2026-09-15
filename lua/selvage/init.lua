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
  --- is not UTF-8 is entered and left many times over a session.
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
  --- The folder this session's grant is rooted at, as it stood when the session started. The
  --- working directory can move under it at any moment (`:cd`, `:lcd`, `:tcd`) and the grant
  --- does not: it is the folder the invite was offered from (`DESIGN.md` §4.2), not wherever
  --- the person happens to be looking now.
  root = nil,
  --- The paths this session refused to share because they are outside that folder, so the
  --- refusal is said once per path, as it is for a buffer that is not UTF-8.
  outside = {},
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
  -- Whether the join has been said out loud yet. The sentence names the room, and what the
  -- landing did with the room's documents, which is only known once they are named — so it is
  -- said over the first `documents` report rather than when the handshake arrives.
  join_said = false,
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
    notify('no other participants yet', vim.log.levels.WARN)
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
    ('%s is outside %s, the folder this session shares, so it is not shared'):format(
      path,
      state.root == '' and '/' or state.root
    ),
    vim.log.levels.WARN
  )
end

--- The room path a buffer is shared under, and the absolute name it is refused for when it
--- is not one to share.
---
--- The grant is the folder the session was started in (`DESIGN.md` §4.2), so a name is
--- measured against that and never against the working directory, which `:cd` moves at any
--- moment. A name is absolute — Neovim resolves it when it sets one — and the separator in
--- the prefix is what keeps a sibling whose name merely begins with the grant's out of it.
--- A file outside the grant comes back as the second value so the refusal can be said;
--- anything that is not a file buffer is neither shared nor refused.
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
      notify(('%s is not valid UTF-8, so it is not shared'):format(path), vim.log.levels.ERROR)
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
    ('%s is not in the room, so it is not shared; the mirror holds the room\'s files and is removed when the session ends'):format(path),
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
    ('%s is not in the room, so the mirror did not write it; save it outside the mirror to keep it'):format(path),
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
  notify('the room carries no file mutations yet', vim.log.levels.WARN)
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
    ('%s is no longer in the room; the host no longer has it'):format(path),
    vim.log.levels.WARN
  )
end

--- Shares the buffer in the window, or says why it is not the room's to share.
local function share_current()
  local bufnr = api.nvim_get_current_buf()
  local path, refused = room_path(bufnr)
  if path ~= nil then
    share(bufnr, path)
  elseif refused ~= nil then
    refuse_outside(refused)
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
    notify('join a session first', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('you are hosting, so the files you open are the ones the room has', vim.log.levels.INFO)
    return
  end
  local paths = M.offered()
  if #paths == 0 then
    notify('the room has no open documents yet', vim.log.levels.INFO)
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
        ('"%s" matches several: %s'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no shared document matches "%s"; :SelvageOpen alone offers them'):format(wanted),
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
--- @param path string|nil one path, a directory of them, or nil for the whole listing
function M.fetch(path)
  if not in_session() then
    notify('join a session first', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('you are hosting, so the files a mirror would hold are already on your disk', vim.log.levels.INFO)
    return
  end
  if mirror.root() == nil then
    notify('the room lists no files to fetch', vim.log.levels.INFO)
    return
  end
  local wanted = vim.trim(path or '')
  local targets, candidates = fetch_targets(wanted)
  if targets == nil then
    if candidates ~= nil and #candidates > 1 then
      notify(
        ('"%s" matches several: %s'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no file the room lists matches "%s"; :SelvageOpen and completion name them'):format(wanted),
        vim.log.levels.WARN
      )
    end
    return
  end
  if #targets == 0 then
    notify('the room lists no files to fetch', vim.log.levels.INFO)
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
    -- choice (`DESIGN.md` §4.2).
    notify('fetching opens them in the room, so every peer receives them')
  end
  for _, target in ipairs(targets) do
    pending[target] = true
    local document = state.documents[target]
    if document == nil then
      share(guest_buffer(target), target)
    elseif not mirror.holds(target, document:text()) then
      -- A document this session already holds: the file is given what this client holds for the
      -- room, so that fetching a path whose file a tool overwrote is a fetch and not a no-op.
      document:save()
    end
  end
  local timeout = fetch_timeout_ms(#targets)
  vim.wait(timeout, function()
    return not in_session() or #unfetched(pending) == 0
  end, 50)
  if not in_session() then
    notify('the session ended before the files were fetched', vim.log.levels.WARN)
    return
  end
  local left = unfetched(pending)
  if #left == 0 then
    notify('fetched the files')
    return
  end
  notify(
    ('fetched the files; these had not arrived within %ds: %s'):format(
      seconds(timeout),
      table.concat(vim.list_slice(left, 1, math.min(#left, FETCH_NAMES)), ', ')
    ),
    vim.log.levels.WARN
  )
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
          -- so that closing the room's copy does not move the person somewhere else.
          for _, win in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(win) == old then
              pcall(api.nvim_win_set_buf, win, bufnr)
            end
          end
          pcall(api.nvim_buf_delete, old, { force = true })
        end
        share(bufnr, path)
        local replaced = state.documents[path]
        if replaced ~= nil and held_text then
          -- The file the buffer is now opened as holds what this client holds for the room. An
          -- empty placeholder is left alone: there is nothing to write that the file does not
          -- already hold.
          replaced:save()
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
        notify(('%s could not be written into the mirror'):format(path), vim.log.levels.ERROR)
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
          ('%s is inside the mirror, which holds the room\'s files, so it is not written; write outside the mirror to keep it'):format(target),
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
    document:detach()
  end
  state.documents = {}
  state.unshareable = {}
  state.outside = {}
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
  state.join_said = false
  -- The grant belongs to the session, and a session that has ended grants nothing: the folder it
  -- was rooted at, the listing the room carried, and the mirror those two made on disk. The room
  -- is the truth and the directory is a cache of it, so nothing in it is worth keeping.
  state.root = nil
  state.grant = {}
  state.unlisted = {}
  state.unwritable = {}
  state.unmutated = {}
  state.gone = {}
  mirror.teardown()
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
    notify(
      ('room %s is open; copy the invite link to let someone join (:SelvageCopyInvite)'):format(
        tostring(message.roomId)
      )
    )
    share_current()
    watch_buffers()
    watch_presence()
  elseif message.state == 'joined' then
    -- The join is said over the `documents` report that follows this one: the sentence carries
    -- what the landing did with the room's documents, and that is the report's news.
    state.auto_open = true
    state.join_said = false
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
          show(first)
        end
        if not state.join_said then
          state.join_said = true
          if not lands then
            notify(('joined room %s'):format(tostring(state.room)))
          elseif #report.documents > 1 then
            notify(
              ('joined room %s; opening %s; %d more, :SelvageOpen to choose'):format(
                tostring(state.room),
                report.documents[1],
                #report.documents - 1
              )
            )
          else
            notify(('joined room %s; opening %s'):format(tostring(state.room), report.documents[1]))
          end
        end
      elseif state.auto_open and not state.join_said then
        state.join_said = true
        notify(('joined room %s; the room has no open documents yet'):format(tostring(state.room)))
      end
    end
  elseif report.kind == 'grant' then
    -- The room's whole grant, replacing whatever this front-end held — the same rule the server
    -- applies to `doc.grant`, and the reason a shorter listing is a smaller grant rather than an
    -- error. The listing is what `:SelvageOpen` completes over, and a room that lists five
    -- hundred files has nothing worth interrupting a person for; what a *guest* does with it is
    -- materialise it, and the one sentence that says where is said over the session's first
    -- listing rather than over every republish.
    state.grant = report.paths or {}
    if state.role == 'guest' then
      local root, blocked, created = mirror.setup(state.room, state.grant)
      if root ~= nil then
        if created then
          watch_mirror()
          notify(
            ('the room\'s files are mirrored at %s; :SelvageFetch fetches their content'):format(root)
          )
        end
        if #blocked > 0 then
          notify(
            ('%d of the room\'s files could not be mirrored, starting with %s'):format(
              #blocked,
              blocked[1]
            ),
            vim.log.levels.WARN
          )
        end
        remirror_documents()
      end
    end
  elseif report.kind == 'peers' then
    -- The room's own list of who is in it: everyone, not only the peers this client holds a
    -- document for and can draw a caret for.
    state.room_peers = report.peers or {}
  elseif report.kind == 'roomGone' then
    -- The room is over and the companion has let the engine go, so the session here ends with
    -- it rather than leaving buffers, marks and a statusline behind for a room nobody is in.
    notify(('the room is gone (%s)'):format(tostring(report.reason)), vim.log.levels.WARN)
    reset()
  elseif report.kind == 'hostDetached' then
    notify(
      ('the host left the room; it closes in %ds unless they come back'):format(seconds(report.graceMs)),
      vim.log.levels.WARN
    )
  elseif report.kind == 'hostAttached' then
    notify(('%s is hosting again'):format(tostring((report.peer or {}).display_name or 'the host')))
  elseif report.kind == 'sessionError' then
    notify(('%s (%s)'):format(tostring(report.message), tostring(report.code)), vim.log.levels.ERROR)
  elseif report.kind == 'applyRefused' then
    notify(
      ('the editor would not apply the room\'s change to %s; the file may be read-only'):format(
        tostring(report.path)
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'divergence' then
    notify(
      ('%s was out of step with the room; the room\'s copy has been put back'):format(
        tostring(report.path)
      ),
      vim.log.levels.WARN
    )
  elseif report.kind == 'saveFailed' then
    -- The reason, when the report has one, is what says what to do about it: the sentence is the
    -- fact and the parenthetical is why.
    local why = report.message
    notify(
      ('could not save %s; the file on disk is behind the room%s'):format(
        tostring(report.path),
        why == nil and '' or (' (' .. tostring(why) .. ')')
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'disconnected' then
    -- The bridge reconnects on its own until it runs out of attempts, and this is that end:
    -- the session is over and typing would accumulate in a replica nobody hears. The
    -- companion process is deliberately left running — `ensure` reuses it on the next host
    -- or join, and the engine on the other side of it has already finished.
    notify('the connection ended and the session is over; it could not be re-established', vim.log.levels.ERROR)
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
  elseif message.type == 'refused' then
    -- This process did not open a second session: one is already live. The commands ask before
    -- they send one, so this is the answer when something else did not.
    local where = message.what == 'host' and 'hosting' or 'in'
    notify(('already %s room %s; leave that session first'):format(where, tostring(message.roomId)), vim.log.levels.WARN)
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
        notify(('the companion exited with %s'):format(tostring(code)), vim.log.levels.ERROR)
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
  return ('%d UTF-16 code units and the limit is %d'):format(utf16.len(name), MAX_DISPLAY_NAME)
end

--- Whether a name with nobody to re-ask fits the limit, saying so and naming `source` when it
--- does not. A false answer means the session or the command did not happen: `did` says which.
local function acceptable(name, source, did)
  if utf16.len(name) <= MAX_DISPLAY_NAME then
    return true
  end
  notify(
    ('this name is %s; a name is refused rather than shortened (from %s, so %s; set a shorter one)'):format(
      over_long(name),
      source,
      did
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
        notify(
          ('this name is %s; a name is refused rather than shortened'):format(over_long(name)),
          vim.log.levels.ERROR
        )
        ask()
        return
      end
      vim.g.selvage_display_name = name
      callback(name)
    end)
  end
  ask()
end

--- The last server address a host was started on, so the question the next bare `:SelvageHost`
--- asks starts from it. It is this Neovim's memory for as long as it runs and no more;
--- `vim.g.selvage_server_url` is the setting that stops the question being asked.
local last_server = nil

--- Whether a document the room changes is written. Nothing is sent when the plugin's global says
--- nothing, so the companion's own default — write it — stands, as the other client's setting
--- defaults to on.
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

--- The server to mint a room on: the configured address, else a question starting from the last
--- one typed. An answer is remembered for this Neovim and the question is still asked next time,
--- as it is in the other client: a value baked in would be an endpoint nobody chose.
local function resolve_server_url(callback)
  local configured = vim.g.selvage_server_url
  if configured ~= nil and vim.trim(tostring(configured)) ~= '' then
    callback(vim.trim(tostring(configured)))
    return
  end
  if not can_prompt() then
    notify('a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080', vim.log.levels.ERROR)
    return
  end
  vim.ui.input({
    prompt = 'The Selvage server to host on, e.g. ws://127.0.0.1:8080 (set vim.g.selvage_server_url to stop being asked): ',
    default = last_server or '',
  }, function(input)
    local address = vim.trim(input or '')
    if address == '' then
      return
    end
    callback(address)
  end)
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
  if text:match('^wss?://%S+$') ~= nil and text:find('room=', 1, true) ~= nil then
    return text
  end
  return ''
end

--- The invite to join on, asked for when the command was given none.
local function resolve_invite(callback)
  if not can_prompt() then
    notify('an invite link is needed', vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = 'Join a Selvage session: ', default = clipboard_invite() }, function(input)
    local invite = vim.trim(input or '')
    if invite == '' then
      return
    end
    callback(invite)
  end)
end

--- Puts this session's invite on the clipboard and the unnamed register, or answers false when
--- there is none to put there. Two moments reach for the invite — hosting again, and
--- `:SelvageCopyInvite` — and each has its own sentence about it.
local function take_invite()
  if state.invite == nil then
    return false
  end
  vim.fn.setreg('"', state.invite)
  pcall(vim.fn.setreg, '+', state.invite)
  return true
end

--- Mints a room and shares the current buffer.
---
--- Hosting while hosting is reaching for the invite, not asking for a room: a second room would
--- end the first for everyone in it, and nobody asked for that. Hosting while a guest means
--- leaving the room first, which is the person's call and so a question.
function M.host(url)
  local wanted = vim.trim(url or '')
  if state.status == 'hosting' then
    if take_invite() then
      notify(
        ('you are already hosting room %s; the invite link is on the clipboard'):format(
          tostring(state.room)
        )
      )
    end
    return
  end
  if in_session() then
    local can_leave = confirm_leave(
      ('you are in room %s; hosting a session means leaving it first'):format(tostring(state.room)),
      'Leave and host'
    )
    if not can_leave then
      return
    end
    end_session()
  end
  local function with_url(address)
    last_server = address
    resolve_display_name(function(display_name)
      local process = ensure()
      if process ~= nil then
        capture_root()
        process:send({
          type = 'host',
          serverUrl = address,
          displayName = display_name,
          autoSave = auto_save(),
          root = state.root,
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
--- room ends this one for everyone in it, and a mistyped link must not do that on its own.
function M.join(invite)
  local wanted = vim.trim(invite or '')
  if in_session() then
    local can_leave
    if state.role == 'host' then
      can_leave = confirm_leave(
        ('you are hosting room %s; joining another session ends this room for everyone'):format(
          tostring(state.room)
        ),
        'Leave and join'
      )
    else
      can_leave = confirm_leave(
        ('you are in room %s; joining another session leaves it'):format(tostring(state.room)),
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
        process:send({
          type = 'join',
          invite = link,
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

--- Puts the invite on the clipboard and the unnamed register, and says where it is.
function M.copy_invite()
  if not take_invite() then
    notify('there is no invite link: only the connection that opened the room has one', vim.log.levels.WARN)
    return
  end
  notify('the invite link is on the clipboard')
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
    notify(('this name is %s; a name is refused rather than shortened'):format(over_long(wanted)), vim.log.levels.ERROR)
    return
  end
  vim.g.selvage_display_name = wanted
  if state.process ~= nil then
    state.process:send({ type = 'rename', displayName = wanted })
  end
  notify(('display name set to "%s"'):format(wanted))
end

return M
