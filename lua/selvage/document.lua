-- A shared buffer: the translation between Neovim's byte positions and the companion's
-- UTF-16 offsets, in both directions.
--
-- The document's text is the buffer's lines joined by `\n` with a trailing `\n` — what Neovim's
-- own byte offsets count and what the file on disk holds. A shadow of the lines is kept because
-- `on_bytes` reports what was removed as a range, not as text: the removed text is already gone
-- from the buffer by the time the callback runs, and its length in UTF-16 units cannot be
-- recovered from a buffer that no longer has it.

local utf16 = require('selvage.utf16')

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

--- The document's whole text, as the companion counts it.
function Document:text()
  return table.concat(self.lines, '\n') .. '\n'
end

--- The line at a 0-based row. `on_bytes` addresses the row after the last one — the position
--- past the document's final newline — and there is no line there.
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
  -- Past the final newline. A buffer holds lines, so there is no position after the last one
  -- to address; the end of the last line is the closest thing that exists.
  local last = #self.lines
  return last - 1, #self.lines[last]
end

--- Replaces the shadow's rows `[first, last]` (0-based, inclusive) with `replacement`.
function Document:reshadow(first, last, replacement)
  local removed = last - first + 1
  for _ = 1, removed do
    table.remove(self.lines, first + 1)
    table.remove(self.len16, first + 1)
  end
  for index = #replacement, 1, -1 do
    table.insert(self.lines, first + 1, replacement[index])
    table.insert(self.len16, first + 1, utf16.len(replacement[index]))
  end
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
  -- The one offset a buffer cannot address is the one past its final newline: the lines API
  -- has no position there, and that is where an edit appending a line lands. Such an edit is
  -- the same edit made at the end of the last line with its newline moved to the front —
  -- appending `"b\n"` after the final newline and inserting `"\nb"` before it leave the same
  -- text — so it is rewritten rather than clamped, which would put the text on the wrong line.
  local length = self:prefix(#self.lines)
  local text = edit.text
  local first, first_col
  local last, last_col = self:position(edit['end'])
  if edit['end'] >= length then
    -- A room document whose text does not end in a newline cannot be held in a buffer; the
    -- newline this strips is one the companion's comparison then publishes back to the room.
    text = text:gsub('\n$', '')
    last, last_col = #self.lines - 1, #self.lines[#self.lines]
  end
  if edit.start >= length then
    text = '\n' .. text
    first, first_col = #self.lines - 1, #self.lines[#self.lines]
  else
    first, first_col = self:position(edit.start)
  end
  local replacement = vim.split(text, '\n', { plain = true })
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
function Document:save()
  if self.detached or not api.nvim_buf_is_valid(self.bufnr) then
    return false
  end
  if vim.bo[self.bufnr].buftype ~= '' then
    -- A guest's document is the room's, not a file here. The call is still made, because that
    -- is what the companion's save policy asks for; there is simply nothing to write.
    return true
  end
  local ok = pcall(function()
    api.nvim_buf_call(self.bufnr, function()
      vim.cmd('silent noautocmd write')
    end)
  end)
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
--- This is the whole buffer's attachment, not Selvage's own callback: Neovim hands out no
--- handle for one, so `nvim_buf_detach` takes every `on_bytes` this channel holds for the
--- buffer with it — a formatter's or a diagnostics plugin's as well as this one. Attaching
--- the buffer again is the only way back, and that is the caller's to do.
function Document:detach()
  if self.detached then
    return
  end
  self.detached = true
  if api.nvim_buf_is_valid(self.bufnr) then
    pcall(api.nvim_buf_detach, self.bufnr)
  end
end

--- Re-reads the buffer into the shadow and publishes the whole document as one change.
function Document:resync()
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

  local from = self:prefix(start_row) + utf16.of_byte(self:line(start_row), start_col)
  local to = self:prefix(old_end_row) + utf16.of_byte(self:line(old_end_row), old_end)

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

  self:reshadow(start_row, old_end_row, rows)
  self.version = self.version + 1
  self.send({ type = 'change', path = self.path, start = from, ['end'] = to, text = text })
end

return Document
