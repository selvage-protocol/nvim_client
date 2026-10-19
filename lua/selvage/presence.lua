-- Where the peers are, and where this person is.
--
-- The room's reports say which document each peer is in and at what offset, and this is that
-- turned into extmarks in a buffer, plus this person's own caret turned back into an offset and
-- published. Nothing here decides anything about a document: what a peer's position means in the
-- room's text belongs to `Document`, and the text itself to the companion. The one thing it does
-- not own is the redraw of every window's row, which lives with the bar and is handed in.
local api = vim.api

local peer_fill = require('selvage.colour').peer_fill
local peer_highlight = require('selvage.colour').peer_highlight
local peer_sign = require('selvage.colour').peer_sign
local notify_draw_failure = require('selvage.notify').notify_draw_failure
local current_document = require('selvage.state').current_document
local state = require('selvage.state').state

local M = {}

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

--- Withdraws every mark drawn for a peer, so a presence report that no longer names one leaves
--- nothing of theirs behind.
local function clear_presence()
  local ns = state.presence_ns
  if ns == nil then
    return
  end
  for _, mark in ipairs(state.presence_marks) do
    local ok, err = pcall(api.nvim_buf_del_extmark, mark.bufnr, ns, mark.id)
    if not ok then
      notify_draw_failure(
        ('could not clear a presence mark in %s: %s')
          :format(mark.path or ('buffer %d'):format(mark.bufnr), tostring(err))
      )
    end
  end
  state.presence_marks = {}
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

--- The session row redraw lives with the indicators in `selvage.bar`, and a presence report is the
--- other draw that reaches every window — a row names no peer, and that is the frame it has to
--- survive.
local refresh_indicators = require('selvage.bar').refresh_indicators

--- Publishes where every peer the room put in a document is, for a plugin that decorates a file
--- list of its own (netrw, oil, nvim-tree, telescope): `vim.g.selvage_file_peers` is
--- `{ [room_path] = { { initials, colour, label, peerId } } }` and `User SelvagePresence` fires
--- whenever it changes. This client draws the row itself and depends on none of them.
---
--- The room's own presence is what this is built from, not the rows the gutter drew: the key is
--- the room path, and a peer in a document this window has not opened has a path and no caret
--- here. A file-tree plugin decorating the mirror shows their badge whether or not this window
--- holds their buffer, which is what the key is for. `initials` is the same two cells the gutter
--- signs them with, so a decorator that draws both agrees with itself.
local function publish_file_peers()
  local by_path = {}
  for _, cursor in ipairs(state.cursors) do
    if type(cursor) == 'table' and type(cursor.path) == 'string' and type(cursor.peerId) == 'string' then
      local label = cursor.label or cursor.peerId
      local list = by_path[cursor.path]
      if list == nil then
        list = {}
        by_path[cursor.path] = list
      end
      list[#list + 1] = {
        initials = peer_sign(label),
        colour = cursor.colour,
        label = label,
        peerId = cursor.peerId,
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
--- An entry this window cannot draw — a document it has not opened, or an anchor that does not
--- resolve here — draws nothing and is kept in `state.cursors` all the same: the peer and their
--- document are still the room's word about where they are, which is what a follow or a jump
--- opens to reach them, and what `M.peers()` reads a row's `path` from.
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
--- the position wrong: a virtual line starts at the text column, not the caret's.
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
            state.presence_marks[#state.presence_marks + 1] =
              { bufnr = document.bufnr, id = id, path = document.path }
          else
            notify_draw_failure(
              ("could not draw %s's selection in %s: %s"):format(label, document.path, tostring(id))
            )
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
          state.presence_marks[#state.presence_marks + 1] =
            { bufnr = document.bufnr, id = id, path = document.path }
        else
          notify_draw_failure(
            ("could not draw %s's caret in %s: %s"):format(label, document.path, tostring(id))
          )
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

--- The UTF-16 offset just past what a charwise selection ending at (`row`, `col`) takes of that
--- position: the character there, a wide or an astral one whole, or, beyond the line's text and
--- when `line_break` is set, the line break. The last line has no break to take.
local function past(document, row, col, line_break)
  local line = document:line(row)
  if col < #line then
    return document:offset(row, cell_end(line, col))
  end
  local offset = document:offset(row, #line)
  if line_break and row < #document.lines - 1 then
    return offset + 1
  end
  return offset
end

--- The caret as the two UTF-16 offsets the room counts. In Visual mode the selection's other
--- end is the anchor; a caret is both ends alike. Select mode shows the same range as the Visual
--- mode it is named after — only the keys accepted differ, and `'selection'` is documented as
--- used in both — so a Select selection is read here as the Visual one of its shape. Neovim
--- spells Select mode `s`, `S` and CTRL-S, and `vs`, `Vs` and CTRL-Vs while `CTRL-O` has it
--- paused in Visual for one command (`mode()`, `v_CTRL-O`, `Select-mode`). `v`, `V` and CTRL-V
--- enter Select mode rather than Visual when `'selectmode'` names `cmd`, and `gh`, `gH` and
--- `g_CTRL-H` always do, so the two spellings are the same selection on screen and the same two
--- offsets here.
---
--- A charwise selection includes the character its later end is on, whichever end that is, as
--- Neovim's operators do. With `'selection'` set to `exclusive` it does not, except when the two
--- ends meet: an operator still takes that one character. Past a line's text there is no
--- character: an anchor there takes the line break, and a head stops at the end of the text, for
--- the reason a linewise head does below, leaving out the line break an operator would take.
--- `old` is read as `inclusive`, and where an end is on an empty line the range can then
--- differ from what an operator takes, which may be less, or whole lines. That gap is accepted.
---
--- A linewise selection is its lines whole, from the start of the first to the end of the last
--- one's text, with the head on whichever end the cursor is. The end of the text rather than the
--- start of the next line, because the head is where a peer draws this user's caret, and the
--- start of the next line is a line the cursor is not on; the last line has no next line anyway.
--- An empty line alone is then a collapsed selection: there is nothing on it to fill.
local function caret(document)
  local cursor = api.nvim_win_get_cursor(0)
  local head = document:offset(cursor[1] - 1, cursor[2])
  local anchor = head
  local mode = vim.fn.mode(1)
  -- Select mode, and the state `CTRL-O` pauses it in, as the Visual mode of the same shape.
  if mode == 's' or mode == 'vs' then
    mode = 'v'
  elseif mode == 'S' or mode == 'Vs' then
    mode = 'V'
  elseif mode == '\19' or mode == '\22s' then
    mode = '\22'
  end
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local start = vim.fn.getpos('v')
    if mode == 'V' and start[2] > 0 then
      local from, to = start[2] - 1, cursor[1] - 1
      if from <= to then
        anchor = document:prefix(from)
        head = document:offset(to, #document:line(to))
      else
        anchor = document:offset(from, #document:line(from))
        head = document:prefix(to)
      end
    elseif start[2] > 0 and start[3] > 0 then
      anchor = document:offset(start[2] - 1, start[3] - 1)
      if mode == 'v' and (vim.o.selection ~= 'exclusive' or anchor == head) then
        if anchor <= head then
          head = past(document, cursor[1] - 1, cursor[2], false)
        else
          anchor = past(document, start[2] - 1, start[3] - 1, true)
        end
      end
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


M.clear_presence = clear_presence
M.draw_presence = draw_presence
M.publish_file_peers = publish_file_peers
M.schedule_selection = schedule_selection
M.watch_presence = watch_presence

return M
