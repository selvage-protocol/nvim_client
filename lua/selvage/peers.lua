-- Finding a participant, and landing on their document.
--
-- A name picks a peer the way `:SelvagePeers` prints one — the display name, disambiguated by the
-- identity itself only when two people share a name — and landing opens what they are in and puts
-- the caret where the room says theirs is. A landing that cannot be made yet is a wait rather than
-- a refusal: the frame that opens the document is the one that resolves the caret.
local api = vim.api

local notify = require('selvage.notify').notify
local schedule_selection = require('selvage.presence').schedule_selection
local queries = require('selvage.queries')
local guest_buffer = require('selvage.share').guest_buffer
local share = require('selvage.share').share
local show = require('selvage.share').show
local state = require('selvage.state').state

local M = {}

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
  for _, peer in ipairs(queries.peers()) do
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
  local peers = queries.peers()
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
  local peers = queries.peers()
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

--- Shares `bufnr` as the room's document at `path`, answering whether the room now holds it.
---
--- `share` takes a buffer and refuses one in the same silence: a name the buffer is read through
--- that is not a regular file, text the room cannot carry, a session whose process has gone. The
--- refusal is said where it happens, in `share`'s own words; a caller that must know what the room
--- received reads the document set rather than the call.
---
--- @param bufnr integer
--- @param path string
--- @return boolean, string|nil
local function share_document(bufnr, path)
  local shared, err = pcall(share, bufnr, path)
  if not shared then
    return false, tostring(err)
  end
  if state.documents[path] == nil then
    return false, 'this window does not share it'
  end
  return true
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
    return share_document(bufnr_or_err, path)
  end
  local root = vim.fn.resolve(state.root or '')
  if root == '' then
    return false, 'the path is not one this window shares'
  end
  -- Measured against the resolved grant root, never the working directory: an absolute
  -- path, a `..` climber and a link pointing outside all read as outside the grant.
  -- Lua patterns have no alternation, so the `..` segment is looked for with the path framed in
  -- separators rather than with a `(^|/)` that would only ever match those three characters.
  local outside = path:sub(1, 1) == '/'
    or path:match('^%a:/') ~= nil
    or ('/' .. path .. '/'):find('/../', 1, true) ~= nil
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
  return share_document(bufnr_or_err, path)
end

--- The document the room puts the peer in: the path the companion resolved a caret in, or, when
--- it resolved none, the path the room's own presence names for them. The two are one presence
--- entry read twice, because a companion draws a cursor only against a replica it holds: a peer
--- in a room document this window has not opened arrives with their document and no caret, and
--- that document is what a follow or a go-to opens to reach them.
---
--- @param peer_id string
--- @return string|nil
local function peer_path(peer_id)
  local cursor = cursor_for(peer_id)
  if cursor ~= nil and type(cursor.path) == 'string' then
    return cursor.path
  end
  local row = peer_row(peer_id)
  return row ~= nil and row.path or nil
end

--- Puts the window on the peer's caret: their document shown, the cursor on the head
--- offset the last presence report resolved. The row and column come through
--- `Document:position`, which is in range for any offset by construction; the set itself is
--- still guarded, because the buffer may have gone while the report stood.
---
--- A peer the room puts in a document this window does not hold is opened here first: the hold
--- is what makes the room send the text, so a guest's landing waits a frame for it, and a host's
--- own file is read by the open itself. Nothing is placed until the caret resolves against that
--- text, so a landing that cannot be made yet is 'waiting' rather than a refusal — the frame
--- that draws the caret is the one that lands.
---
--- Returns true on landing; false with 'unknown' when the room puts the peer in no document,
--- with 'waiting' when their document is open here and its caret has not resolved, with
--- 'open-failed' and the reason when it cannot be opened, with 'missing' when showing it
--- failed even so, or 'unresolvable' when the cursor cannot be placed.
local function land(peer_id)
  local cursor = cursor_for(peer_id)
  local path = peer_path(peer_id)
  if path == nil then
    return false, 'unknown'
  end
  local document = state.documents[path]
  if document == nil or not api.nvim_buf_is_valid(document.bufnr) then
    if document ~= nil then
      -- A wiped buffer is not a buffer anymore: the entry points nowhere, and the share
      -- below makes the document the room still holds, the way the stale-entry repair the
      -- documents report would make does.
      document:detach()
      state.documents[path] = nil
    end
    -- The hold is what makes the room send the text, so a document that was never opened
    -- here opens now. A host's own file is read by the open itself, so the landing
    -- carries on onto it; a guest's text still arrives over the sync, so the landing waits
    -- for the frame it unlocks rather than placing at offset zero of an empty buffer.
    local opened, err = open_room_path(path)
    if not opened then
      return false, 'open-failed', err
    end
    -- A landing that opens takes a hold: the document joins the room's open set, so every
    -- peer receives it, the way a fetch does. Said once, where the hold is taken, in the
    -- fetch's own sentence shape — not on every frame that lands on it afterwards.
    notify(('%s is opened in the room, so every peer receives it.'):format(path))
    if state.role ~= 'host' then
      return false, 'waiting'
    end
    document = state.documents[path]
    if document == nil or not api.nvim_buf_is_valid(document.bufnr) then
      return false, 'missing'
    end
  end
  local head = cursor ~= nil and cursor.head or nil
  if type(head) ~= 'number' then
    -- No caret to place: the document this window holds has no text for the peer's anchor yet,
    -- or the anchor names content this replica does not have (§8.1). Offset zero would be an
    -- invention, so nothing lands here and the frame that resolves the caret is the one that does.
    return false, 'waiting'
  end
  local win = show(document.bufnr)
  if win == nil then
    return false, 'missing'
  end
  local row, col = document:position(head)
  -- The follow's own placement is not a move the user made: Neovim reports no reason for a cursor
  -- change, so the flag is what tells the move handler this caret is the follow's, not theirs.
  state.applying_follow = true
  local placed = pcall(api.nvim_win_set_cursor, win, { row + 1, col })
  state.applying_follow = false
  if not placed then
    return false, 'unresolvable'
  end
  -- An editor with a UI fires `CursorMoved` for this placement later, from its main loop, when the
  -- flag above is long down: the place it landed is what tells that event from a move of the
  -- person's own.
  local landed = api.nvim_win_get_cursor(win)
  state.follow_landed = {
    win = win,
    buf = document.bufnr,
    row = landed[1],
    col = landed[2],
  }
  -- The landing moved the caret, so the room hears it through the coalesced publish
  -- rather than through whatever event the editor may or may not fire for a programmatic
  -- move: headless Neovim fires none for anything, and the interval drops the duplicate
  -- where the editor fired its own.
  schedule_selection()
  return true
end


M.land = land
M.peer_path = peer_path
M.peer_row = peer_row
M.resolve_peer = resolve_peer
M.row_name = row_name

return M
