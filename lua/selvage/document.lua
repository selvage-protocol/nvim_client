-- A shared buffer: the translation between Neovim's byte positions and the companion's
-- UTF-16 offsets, in both directions.
--
-- The document's text is the buffer's lines joined by `\n`, byte for byte what the room
-- holds: one newline between lines and none after the last, so a buffer whose last line is
-- empty ends in a newline and a buffer of one empty line is the empty string. A shadow of the
-- lines is kept because
-- `on_bytes` reports what was removed as a range, not as text: the removed text is already gone
-- from the buffer by the time the callback runs, and its length in UTF-16 units cannot be
-- recovered from a buffer that no longer has it.

local utf16 = require('selvage.utf16')
local mirror = require('selvage.mirror')

local api = vim.api

local Document = {}
Document.__index = Document

--- @param bufnr integer
--- @param path string the room path this buffer is shared under
--- @param send fun(message: table)
function Document.new(bufnr, path, send)
  local self = setmetatable({
    bufnr = bufnr,
    path = path,
    send = send,
    lines = api.nvim_buf_get_lines(bufnr, 0, -1, true),
    len16 = {},
    -- Counted the same way the companion counts it: one for a local change, one for an applied
    -- remote edit. An `applyEdit` carrying any other number was computed against a buffer this
    -- one has moved on from.
    version = 0,
    -- A remote edit changes the buffer too, and that change is not news for the room.
    applying = false,
    detached = false,
  }, Document)
  for index, line in ipairs(self.lines) do
    self.len16[index] = utf16.len(line)
  end
  return self
end

--- The document's whole text, as the companion counts it: the buffer's lines joined by
--- `\n`, byte for byte what the room holds.
function Document:text()
  return table.concat(self.lines, '\n')
end

--- The line at a 0-based row. `on_bytes` addresses the row after the last one — the end of
--- the document — and there is no line there.
function Document:line(row)
  return self.lines[row + 1] or ''
end

--- The UTF-16 offset the row `row` (0-based) starts at.
function Document:prefix(row)
  local offset = 0
  for index = 1, row do
    offset = offset + self.len16[index] + 1
  end
  return offset
end

--- The (0-based row, byte column) a UTF-16 offset lands on.
function Document:position(offset)
  local seen = 0
  for index = 1, #self.lines do
    local length = self.len16[index]
    if offset <= seen + length then
      return index - 1, utf16.to_byte(self.lines[index], offset - seen)
    end
    seen = seen + length + 1
  end
  -- Past the end of the text. A buffer holds lines, so there is no position after the last one
  -- to address; the end of the last line is the closest thing that exists.
  local last = #self.lines
  return last - 1, #self.lines[last]
end

--- The UTF-16 offset of a (0-based row, byte column). The inverse of `position`, and where the
--- caret is turned into what the room's offsets count.
function Document:offset(row, col)
  return self:prefix(row) + utf16.of_byte(self:line(row), col)
end

--- Replaces the shadow's rows `[first, last]` (0-based, inclusive) with `replacement`.
function Document:reshadow(first, last, replacement)
  local lines, len16 = {}, {}
  local count = #self.lines
  local added = #replacement
  for index = 1, first do
    lines[index] = self.lines[index]
    len16[index] = self.len16[index]
  end
  -- The replacement and the tail have different lengths, so one destination index counts the
  -- rows written so far: a `#` on the list being written is a search per row.
  local at = first
  for index = 1, added do
    at = at + 1
    lines[at] = replacement[index]
    len16[at] = utf16.len(replacement[index])
  end
  for index = last + 2, count do
    at = at + 1
    lines[at] = self.lines[index]
    len16[at] = self.len16[index]
  end
  self.lines, self.len16 = lines, len16
end

--- Applies a remote edit. Returns whether the buffer now holds it.
function Document:apply(edit)
  if self.detached or not api.nvim_buf_is_valid(self.bufnr) then
    return false
  end
  -- The range was computed against a version of this document; a local change has reached the
  -- companion since, and applying the range now would land it on text it was not computed from.
  if edit.version ~= self.version then
    return false
  end
  -- The range counts the document's text, whose lines are the buffer's: a text ending in a
  -- newline ends in an empty last line, and one without ends in its last line of content.
  -- Either way the range lands on rows the lines API addresses, so it is mapped and written
  -- as it stands.
  local first, first_col = self:position(edit.start)
  local last, last_col = self:position(edit['end'])
  local replacement = vim.split(edit.text, '\n', { plain = true })
  self.applying = true
  local ok, err = pcall(
    api.nvim_buf_set_text,
    self.bufnr,
    first,
    first_col,
    last,
    last_col,
    replacement
  )
  self.applying = false
  if not ok then
    vim.notify('selvage: could not apply an edit to ' .. self.path .. ': ' .. tostring(err), vim.log.levels.WARN)
    return false
  end
  self:reshadow(first, last, api.nvim_buf_get_lines(self.bufnr, first, first + #replacement, true))
  self.version = self.version + 1
  return true
end

--- Writes the buffer, if it is one that has somewhere to be written.
---
--- A guest's document has a file when the room's grant named its path — the mirror — and the save
--- is what writes the buffer into it, which is also what makes the file fetched for anything that
--- reads the filesystem rather than this editor. What it writes is the buffer's text, which is
--- the room's text once the room's edits have been applied to it. A `selvage://` document has
--- nowhere to be written; the call is still made, because that is what the companion's save
--- policy asks for.
---
--- A path that left the room's listing keeps the file's name in a buffer the person still has
--- open, while the removal took the file and the directories that emptied with it. The save is
--- what puts the directory back: the text is the room's already, the file is only a cache of it,
--- and a `:w` that answered `E212` would leave the person with an error and a modified buffer.
--- @param settled boolean|nil the buffer holds the room's text, so writing it counts as fetched
function Document:save(settled)
  if self.detached or not api.nvim_buf_is_valid(self.bufnr) then
    return false
  end
  if vim.bo[self.bufnr].buftype ~= '' then
    return true
  end
  mirror.ensure_parent(api.nvim_buf_get_name(self.bufnr))
  local ok = pcall(function()
    api.nvim_buf_call(self.bufnr, function()
      vim.cmd('silent noautocmd write')
    end)
  end)
  if ok then
    -- A write of an empty buffer over an empty placeholder proves nothing about the room:
    -- an empty placeholder and an empty room document look exactly alike, so a `:w` before
    -- the room's text arrives must not mark the path fetched, or the fetch claims files the
    -- filesystem sees as empty. The save the room settles on marks regardless: the room's
    -- text is in the buffer because the room put it there, even when it is empty.
    local text = table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, true), '\n')
    if settled or text ~= '' or mirror.written(self.path) then
      mirror.wrote(self.path)
    end
  end
  return ok
end

--- Starts reporting this buffer's changes.
function Document:attach()
  local ok = api.nvim_buf_attach(self.bufnr, false, {
    on_bytes = function(...)
      return self:on_bytes(...)
    end,
    on_detach = function()
      self.detached = true
    end,
    on_reload = function()
      -- The file changed underneath the buffer. The shadow is no longer the buffer's text and
      -- the next range would be computed from the wrong one; re-reading it is what keeps the
      -- offsets meaning what they say, and the companion's own comparison publishes whatever
      -- the reload changed.
      self:resync()
    end,
  })
  return ok
end

--- Stops reporting this buffer's changes. A session that has ended must not leave an
--- `on_bytes` behind: the buffer outlives the companion, and the callback it would keep
--- calling has nothing left to send to.
---
--- What ends this document's callbacks is Neovim's own `api-lua-detach`: `on_bytes` returning
--- `true` detaches every callback the one `nvim_buf_attach` call it made registered, and leaves
--- a formatter's or a diagnostics plugin's own attach alone. It lands on the buffer change that
--- returns it, so until then the flag is what keeps this document quiet. There is nothing to
--- call in its place: `nvim_buf_detach` is RPC-only, acts on a channel's buffer updates, and
--- is not in the Lua API at all.
function Document:detach()
  if self.detached then
    return
  end
  self.detached = true
end

--- Re-reads the buffer into the shadow and publishes the whole document as one change.
function Document:resync()
  if self.detached or not api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local previous = self:text()
  self.lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, true)
  for index, line in ipairs(self.lines) do
    self.len16[index] = utf16.len(line)
  end
  for index = #self.lines + 1, #self.len16 do
    self.len16[index] = nil
  end
  self.version = self.version + 1
  self.send({
    type = 'change',
    path = self.path,
    start = 0,
    ['end'] = utf16.len(previous),
    text = self:text(),
  })
end

function Document:on_bytes(
  _,
  _,
  _,
  start_row,
  start_col,
  _,
  old_row_count,
  old_end_col,
  _,
  new_row_count,
  new_end_col,
  _
)
  if self.detached then
    return true
  end
  if self.applying then
    return
  end
  -- The end columns are relative to the start when the change stayed on one row, and absolute
  -- when it did not.
  local old_end_row = start_row + old_row_count
  local old_end = old_row_count == 0 and start_col + old_end_col or old_end_col
  local new_end_row = start_row + new_row_count
  local new_end = new_row_count == 0 and start_col + new_end_col or new_end_col

  -- A row past the last line is the end of the document: the text holds no trailing newline
  -- for it to sit past, so it counts the text's own length.
  local count = #self.lines
  local past_end = self:prefix(count) - 1
  local from = start_row >= count and past_end
    or self:prefix(start_row) + utf16.of_byte(self:line(start_row), start_col)
  local to = old_end_row >= count and past_end
    or self:prefix(old_end_row) + utf16.of_byte(self:line(old_end_row), old_end)

  -- The rows the change now spans. The last of them can be the row past the buffer's end —
  -- an edit that appended a line ends there — which holds no line but does bound the text.
  local rows = api.nvim_buf_get_lines(self.bufnr, start_row, new_end_row + 1, false)
  local spanned = vim.list_slice(rows)
  for _ = #spanned, new_end_row - start_row do
    spanned[#spanned + 1] = ''
  end

  local text
  if #spanned == 1 then
    text = spanned[1]:sub(start_col + 1, new_end)
  else
    local parts = { spanned[1]:sub(start_col + 1) }
    for index = 2, #spanned - 1 do
      parts[#parts + 1] = spanned[index]
    end
    parts[#parts + 1] = spanned[#spanned]:sub(1, new_end)
    text = table.concat(parts, '\n')
  end

  -- A change starting past the last line starts a new one: the newline it starts after is not
  -- in the text, so the change brings it, in front. The span above padded the rows with the
  -- empty line past the buffer's end, whose join put that newline at the back instead.
  if start_row >= count then
    text = '\n' .. text:gsub('\n$', '')
  elseif old_end_row >= count and start_col == 0 and start_row > 0 and text:find('\n$') == nil then
    -- A change reaching past the last line from a line boundary took the newline before that
    -- line with it, so the removed text starts one unit earlier than the row does. A change
    -- bringing a newline of its own already ends where it should.
    from = from - 1
  end

  self:reshadow(start_row, old_end_row, rows)
  self.version = self.version + 1
  self.send({ type = 'change', path = self.path, start = from, ['end'] = to, text = text })
end

return Document
