-- What one keystroke's shadow rebuild costs, by the shape of the change.
--
--   nvim --headless -l scripts/bench-reshadow.lua [lines]
--
-- `Document:reshadow` copies the rows before the change, the replacement and the rows after it
-- into two fresh lists, so every shape copies the whole document. What differs between them is
-- which of the three loops does the copying, and the shape of the change decides that:
--
--   at the start   `reshadow(0, 0, …)`        — the tail loop copies every row
--   at the end     `reshadow(last, last, …)`  — the head loop copies every row
--   whole buffer   `reshadow(0, #lines-1, …)` — the replacement loop copies every row
--
-- A row-by-row `#` on the list being written is a search per row, and it shows up as the spread
-- between those shapes. `on_bytes` is the same work end to end, through a real buffer.
--
-- Nothing here asserts a time: a millisecond bound is not a test. The figures are `os.clock`
-- CPU time, the cheapest of five runs, at 20 000 lines unless another size is named.
--
-- Not run by `scripts/test-lua.sh` or by the flake's `lua` check. The ratio guards in
-- `test/lua/document.lua` are the part that runs everywhere.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Document = require('selvage.document')

local count = tonumber(_G.arg and _G.arg[1]) or 20000
local reps = 5

local function buffer_of(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  return bufnr
end

local function lines_of(n, tag)
  local lines = {}
  for index = 1, n do
    lines[index] = tag .. ' ' .. index
  end
  return lines
end

local function cheapest(fn)
  local best = math.huge
  for _ = 1, reps do
    local started = os.clock()
    fn()
    local elapsed = os.clock() - started
    if elapsed < best then
      best = elapsed
    end
  end
  return best
end

local function report(name, seconds)
  print(('%-44s%8.3f ms'):format(name, seconds * 1000))
end

local shared = Document.new(buffer_of(lines_of(count, 'line')), 'bench.txt', function() end)
local rows = { 'replacement' }

print(('%d lines, cheapest of %d runs, os.clock'):format(count, reps))

report('reshadow(0, 0, …)', cheapest(function()
  shared:reshadow(0, 0, rows)
end))

report('reshadow(last, last, …)', cheapest(function()
  local last = #shared.lines - 1
  shared:reshadow(last, last, rows)
end))

report('the two alternating, one pair', cheapest(function()
  shared:reshadow(0, 0, rows)
  local last = #shared.lines - 1
  shared:reshadow(last, last, rows)
end))

local whole = lines_of(count, 'other')
report('reshadow(0, last, …) whole buffer', cheapest(function()
  shared:reshadow(0, #shared.lines - 1, whole)
end))

local attached_buffer = buffer_of(lines_of(count, 'line'))
local attached = Document.new(attached_buffer, 'bench.txt', function() end)
attached:attach()
local last_row = #attached.lines - 1
local last_col = #attached.lines[#attached.lines]
report('on_bytes in the first row, end to end', cheapest(function()
  vim.api.nvim_buf_set_text(attached_buffer, 0, 0, 0, 1, { 'L' })
end))
report('on_bytes in the last row, end to end', cheapest(function()
  vim.api.nvim_buf_set_text(attached_buffer, last_row, last_col - 1, last_row, last_col, { 'Y' })
end))
attached:detach()
