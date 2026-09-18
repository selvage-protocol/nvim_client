-- The offset arithmetic, against a real Neovim buffer.
--
--   nvim --headless -l test/lua/document.lua      (or scripts/test-lua.sh)
--
-- This is the one part of the Lua side that is not translation: Neovim reports byte positions
-- and the protocol counts UTF-16 code units, and the two only agree on ASCII. It needs a real
-- buffer and a real `on_bytes` to mean anything, which is why it is a headless Neovim run
-- rather than part of the Node suite.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Document = require('selvage.document')
local utf16 = require('selvage.utf16')

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- A shared document over a scratch buffer, and the messages it has sent.
local function document(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  local sent = {}
  local shared = Document.new(bufnr, 'a.txt', function(message)
    sent[#sent + 1] = message
  end)
  shared:attach()
  return shared, bufnr, sent
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n')
end

local function change(message)
  return ('%d..%d %s'):format(message.start, message['end'], vim.inspect(message.text))
end

local function apply(shared, edit)
  edit.version = shared.version
  return shared:apply(edit)
end

-- -- a local edit, reported in UTF-16 code units ------------------------------

local shared, bufnr, sent = document({ 'héllo', 'wörld' })
check('the document text invents no trailing newline', shared:text(), 'héllo\nwörld')

-- The ends of the contract the room and this side share: the text is the lines joined by LF, so
-- a one-line document has no newline of its own and an empty one is the empty string.
local single = document({ 'one line' })
check('a one-line document has no trailing newline', single:text(), 'one line')
local blank = document({})
check('an empty document is the empty string', blank:text(), '')

vim.api.nvim_buf_set_text(bufnr, 0, 3, 0, 3, { 'X' })
check('an insert after a two-byte character', change(sent[1]), '2..2 "X"')

vim.api.nvim_buf_set_text(bufnr, 1, 1, 1, 3, {})
check('a delete of a two-byte character', change(sent[2]), '8..9 ""')

vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'tail' })
check('a line appended past the last line', change(sent[3]), '11..11 "\\ntail"')
check('the shadow tracks the buffer', shared:text(), buffer_text(bufnr))

-- -- a whole-buffer clear ------------------------------------------------------
--
-- Clearing the whole buffer through the API reports the row past the last line as the end of the
-- change, and the removed text is the document's whole text.
local cleared, cleared_buf, cleared_sent = document({ 'one', 'two', 'three' })
vim.api.nvim_buf_set_lines(cleared_buf, 0, -1, true, {})
check('a clear keeps the buffer and the shadow together', cleared:text(), buffer_text(cleared_buf))
check('  both being one empty line', cleared:text(), '')
check(
  '  and the published change stops before the final newline',
  change(cleared_sent[#cleared_sent]),
  '0..13 ""'
)

-- -- a change at the end of the document ---------------------------------------
--
-- The row past the last line is where a buffer's byte positions and the text's part. A buffer
-- counts a newline after every row, its last one included, and the text — the lines joined —
-- has none after its last; every shape that appends, replaces or removes a line at the end
-- lands on that row. What the room does with a change is apply its range to the text it
-- holds, so that is what these assert: the text a room holding the old one is left with.

--- The text a room holding `before` is left with after applying `message`.
local function followed(before, message)
  return before:sub(1, utf16.to_byte(before, message.start))
    .. message.text
    .. before:sub(utf16.to_byte(before, message['end']) + 1)
end

--- A document whose buffer `edit` changes, and the room's copy of its text carried along.
local function ends(name, lines, edit)
  local shared_end, end_buf, end_sent = document(lines)
  local before = shared_end:text()
  edit(end_buf)
  local delta = end_sent[#end_sent]
  check(name, delta and followed(before, delta), buffer_text(end_buf))
  check('  and the shadow with it', shared_end:text(), buffer_text(end_buf))
end

-- The reported shape: a room text that ends in a newline is a buffer whose last line is
-- empty, and replacing that line is the one change whose published range must not carry the
-- buffer's newline after it.
local reported, reported_buf, reported_sent = document({ 'a file', '' })
vim.api.nvim_buf_set_lines(reported_buf, 1, 2, true, { 'MARK' })
check('replacing the empty last line', change(reported_sent[1]), '7..7 "MARK"')
check('  leaves the room holding what the buffer holds', followed('a file\n', reported_sent[1]), buffer_text(reported_buf))

local end_shapes = {
  { 'the empty last line replaced', { 'a file', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { 'MARK' })
  end },
  { 'the empty last line replaced by two', { 'a file', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { 'M1', 'M2' })
  end },
  { 'a line appended after a trailing empty line', { 'a file', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'MARK' })
  end },
  { 'two lines appended after a trailing empty line', { 'a file', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'M1', 'M2' })
  end },
  { 'the last empty line deleted', { 'a file', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, {})
  end },
  { 'the last line of content deleted', { 'a file', 'x' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, {})
  end },
  { 'the last empty line replaced by an empty one', { 'a', '', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, true, { '' })
  end },
  { 'the last empty line replaced by two empty ones', { 'a', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { '', '' })
  end },
  { 'the last content line replaced', { 'a', 'b', 'c' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, true, { 'C' })
  end },
  { 'the last line made empty', { 'a', 'b' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { '' })
  end },
  { 'a line appended past a line of content', { 'HOST', 'seed' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'MARK' })
  end },
  { 'every line replaced by more of them', { 'a', 'b' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { 'x', 'y', 'z' })
  end },
  { 'every line replaced by one', { 'a', 'b' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { 'z' })
  end },
  { 'the only line cleared', { 'a' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, true, {})
  end },
  { 'the only line deleted as text', { 'a' }, function(bufnr)
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 1, {})
  end },
  { 'the empty buffer filled', { '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { 'only' })
  end },
  { 'the empty buffer filled with two lines', { '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { 'a', 'b' })
  end },
  -- A replacement that ends at column 0 of the line after it, which is the same row past the
  -- last one written the other way round.
  { 'a replacement spanning to the next line\'s column 0', { 'a file', 'tail', '' }, function(bufnr)
    vim.api.nvim_buf_set_text(bufnr, 0, 2, 1, 0, { 'M' })
  end },
  { 'a deletion spanning to the next line\'s column 0', { 'a file', 'tail', '' }, function(bufnr)
    vim.api.nvim_buf_set_text(bufnr, 0, 2, 1, 0, {})
  end },
  { 'a replacement spanning into the empty last line', { 'a', '' }, function(bufnr)
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 1, 0, { 'M' })
  end },
  { 'a two-byte empty last line replaced', { 'héllo', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { 'wörld' })
  end },
  { 'a two-byte last line of content replaced', { 'a', 'héllo' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { 'x' })
  end },
  { 'an astral last line of content replaced', { 'a', '😀b' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, true, { 'x' })
  end },
  { 'an astral empty last line appended past', { '😀', '' }, function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'x' })
  end },
}

for _, shape in ipairs(end_shapes) do
  ends(shape[1], shape[2], shape[3])
end

-- -- the end of the document, over many shapes ----------------------------------
--
-- The shapes above are the ones worth naming; this is the guard that they are all of them. A
-- deterministic walk over small buffers of empty, ASCII, two-byte and astral lines, editing
-- each at a character boundary through both APIs and carrying the room's own copy of the text
-- along with every published change, comparing the two after each edit. The generator stays
-- inside what a double holds exactly, so the walk is the same on every run and a failure
-- reproduces from the seed.
local seed = 20260918
local span = 16777216
local state = seed % span
local function next_random(n)
  state = (state * 48271 + 1) % span
  return math.floor(state * n / span)
end

local pool = { '', 'a', 'ab', 'abc', 'é', 'xé', '😀', 'a😀' }
local function some_lines(count)
  local lines = {}
  for index = 1, count do
    lines[index] = pool[next_random(#pool) + 1]
  end
  return lines
end

local walked = 0
local diverged = 0
for round = 1, 120 do
  local walk_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(walk_buf, 0, -1, true, some_lines(next_random(4) + 1))
  local walk_sent = {}
  local walk = Document.new(walk_buf, 'walk.txt', function(message)
    walk_sent[#walk_sent + 1] = message
  end)
  walk:attach()
  local room = walk:text()
  for _ = 1, 8 do
    local before_count = #walk_sent
    local row_count = vim.api.nvim_buf_line_count(walk_buf)
    local start_row = next_random(row_count)
    local start_line = vim.api.nvim_buf_get_lines(walk_buf, start_row, start_row + 1, true)[1]
    -- A column inside a character splits it into bytes no text can carry, so the columns are
    -- character boundaries, named in the units the text counts.
    local start_col = utf16.to_byte(start_line, next_random(utf16.len(start_line) + 1))
    if next_random(2) == 0 then
      local end_row = start_row + next_random(row_count - start_row)
      local end_line = vim.api.nvim_buf_get_lines(walk_buf, end_row, end_row + 1, true)[1]
      local end_col = utf16.to_byte(end_line, next_random(utf16.len(end_line) + 1))
      if end_row == start_row and end_col < start_col then
        start_col, end_col = end_col, start_col
      end
      local replacement = next_random(4) == 0 and {} or some_lines(next_random(3) + 1)
      vim.api.nvim_buf_set_text(walk_buf, start_row, start_col, end_row, end_col, replacement)
    else
      local end_row = start_row + next_random(row_count - start_row + 1)
      local replacement = next_random(5) == 0 and {} or some_lines(next_random(3) + 1)
      vim.api.nvim_buf_set_lines(walk_buf, start_row, end_row, true, replacement)
    end
    if #walk_sent > before_count then
      walked = walked + 1
      room = followed(room, walk_sent[#walk_sent])
    end
    if room ~= buffer_text(walk_buf) or walk:text() ~= buffer_text(walk_buf) then
      diverged = diverged + 1
    end
  end
  vim.api.nvim_buf_delete(walk_buf, { force = true })
end
check('a walk over small buffers leaves the room holding the buffer', diverged, 0)
check('  over the edits it generates', walked > 300, true)

local pair, pair_buf, pair_sent = document({ 'a😀b' })
vim.api.nvim_buf_set_text(pair_buf, 0, 6, 0, 6, { '!' })
check('a character outside the BMP counts two', change(pair_sent[1]), '4..4 "!"')
check('and the shadow still tracks', pair:text(), buffer_text(pair_buf))

-- -- the caret's UTF-16 offset ------------------------------------------------
--
-- Where a caret is published. This is `position` read backwards, and the case that matters is
-- the one where a byte column and a UTF-16 offset differ: an astral character beside a
-- two-byte one, and a column inside a multi-byte character.
local caret = document({ 'a😀b', 'wörld' })
check('a caret after an astral character', caret:offset(0, #'a😀b'), 4)
check('  and before it', caret:offset(0, 1), 1)
check('  and in the second line', caret:offset(1, 1), 6)
check('  and after a two-byte character', caret:offset(1, 3), 7)
check('  and at the end of the document', caret:offset(1, #'wörld'), 10)
check('  and position reads the offset back as a row', select(1, caret:position(10)), 1)
check('  and a byte column', select(2, caret:position(10)), 6)
check('  and an offset on the astral character is on its row', select(1, caret:position(1)), 0)
check('  and at the byte column of that character', select(2, caret:position(1)), 1)
check('  and past the astral pair, at the byte column of the next', select(2, caret:position(3)), 5)

-- -- a remote edit, applied as a range ---------------------------------------

local appended, appended_buf = document({ 'a' })
check(
  'an edit appending a line',
  apply(appended, { start = 1, ['end'] = 1, text = '\nb\n' }) and buffer_text(appended_buf),
  'a\nb\n'
)
check('  and the shadow with it', appended:text(), 'a\nb\n')

local replaced, replaced_buf = document({ 'a', 'b' })
check(
  'an edit replacing the last line',
  apply(replaced, { start = 2, ['end'] = 3, text = 'c\n' }) and buffer_text(replaced_buf),
  'a\nc\n'
)

local empty, empty_buf = document({ '' })
check(
  'an empty buffer filled from the room',
  apply(empty, { start = 0, ['end'] = 0, text = 'hello' }) and buffer_text(empty_buf),
  'hello'
)

local two, two_buf = document({ '' })
check(
  'an empty buffer filled with two lines',
  apply(two, { start = 0, ['end'] = 0, text = 'a\nb' }) and buffer_text(two_buf),
  'a\nb'
)

local multibyte, multibyte_buf = document({ 'héllo' })
check(
  'a range inside multibyte text',
  apply(multibyte, { start = 1, ['end'] = 2, text = 'E' }) and buffer_text(multibyte_buf),
  'hEllo'
)

local unterminated, unterminated_buf = document({ 'a' })
check(
  'a room text with no final newline stays without one',
  apply(unterminated, { start = 0, ['end'] = 1, text = 'xyz' }) and unterminated:text(),
  'xyz'
)

local terminated, terminated_buf = document({ 'a' })
check(
  'a room text with a final newline keeps it',
  apply(terminated, { start = 0, ['end'] = 1, text = 'xyz\n' }) and terminated:text(),
  'xyz\n'
)

local stale = document({ 'a' })
check(
  'an edit against a version the buffer has left',
  stale:apply({ start = 0, ['end'] = 0, text = 'x', version = 7 }),
  false
)

local echoed, _, echoed_sent = document({ 'a' })
apply(echoed, { start = 0, ['end'] = 0, text = 'z' })
check('a remote edit is not reported back as a local one', #echoed_sent, 0)

-- -- a document the session has let go ----------------------------------------

local left, left_buf, left_sent = document({ 'a' })
left:detach()
vim.api.nvim_buf_set_text(left_buf, 0, 0, 0, 0, { 'X' })
check('a detached document reports nothing', #left_sent, 0)
check('  and stops tracking the buffer', left:text(), 'a')
check(
  '  and a remote edit is not applied to it',
  left:apply({ start = 0, ['end'] = 0, text = 'y', version = left.version }),
  false
)
check('  and detaching twice is not an error', pcall(function()
  left:detach()
end), true)

-- -- what detaching leaves on the buffer --------------------------------------

-- The detach ends this document's own `nvim_buf_attach` and nothing else. A second callback,
-- the way a formatter or a diagnostics plugin would have one, has to keep seeing the buffer.
local kept, kept_buf = document({ 'one' })
local other_seen = 0
vim.api.nvim_buf_attach(kept_buf, false, {
  on_bytes = function()
    other_seen = other_seen + 1
  end,
})
kept:detach()
vim.api.nvim_buf_set_text(kept_buf, 0, 0, 0, 0, { 'X' })
vim.api.nvim_buf_set_text(kept_buf, 0, 0, 0, 0, { 'Y' })
check('a detached document leaves another callback on the buffer alone', other_seen, 2)

-- A reload is the other way this document's own attach can call back. `on_bytes` ends the
-- attachment, but only on the change that returns `true`, so `on_reload` is still there in
-- between: without the flag it publishes the buffer's whole text into a session that has
-- already ended.
vim.fn.mkdir('.tmp', 'p')
local reload_path = '.tmp/lua-document-reload.txt'
vim.fn.writefile({ 'one' }, reload_path)
vim.cmd('edit ' .. vim.fn.fnameescape(reload_path))
local reload_sent = {}
local reloaded = Document.new(vim.api.nvim_get_current_buf(), 'reload.txt', function(message)
  reload_sent[#reload_sent + 1] = message
end)
reloaded:attach()
reloaded:detach()
vim.bo.autoread = true
vim.fn.writefile({ 'one', 'two' }, reload_path)
vim.cmd('silent checktime')
check('a detached document publishes nothing when its buffer is reloaded', #reload_sent, 0)

-- -- a whole-buffer change on a large buffer -------------------------------------
--
-- Replacing every line at once is ordinary — a formatter, a paste over the whole file, or the
-- companion's whole-document backstop — and it is the shape that shows how the shadow is kept.
local big = {}
for index = 1, 8000 do
  big[index] = 'line ' .. index
end
local big_shared, big_buf, big_sent = document(big)
local rewritten = {}
for index = 1, 8000 do
  rewritten[index] = 'other ' .. index
end
vim.api.nvim_buf_set_lines(big_buf, 0, -1, true, rewritten)
check('the shadow tracks after a whole-buffer change', big_shared:text(), buffer_text(big_buf))
check('  and the whole change is published once', #big_sent, 1)

-- The cost of keeping the shadow is a scale guard, not a wall-clock ceiling: a whole-buffer
-- change at `n` and at `2n` should cost about twice as much (linear) rather than four times as
-- much (the quadratic that shifting a list at a fixed index gives). Both are compared as a
-- ratio so the assertion does not depend on the machine, and each is the cheapest of a few
-- runs because one sample is at the mercy of the scheduler. Observed here: about 2.3 with the
-- one-pass rebuild, about 3.9 with the shifting one.
local function whole_change_time(n, tag)
  local lines = {}
  for index = 1, n do
    lines[index] = tag .. index
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  local shared = Document.new(bufnr, 'big.txt', function() end)
  shared:attach()
  local started = os.clock()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  local elapsed = os.clock() - started
  shared:detach()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return elapsed
end
local function cheapest(n)
  local best
  for round = 1, 3 do
    local elapsed = whole_change_time(n, 'round ' .. round .. ' line ')
    if best == nil or elapsed < best then
      best = elapsed
    end
  end
  return best
end
local at_n = cheapest(8000)
local at_2n = cheapest(16000)
local ratio = at_2n / at_n
if ratio >= 3 then
  print(('     n=%.4fs 2n=%.4fs ratio=%.2f'):format(at_n, at_2n, ratio))
end
check('a whole-buffer change scales about linearly', ratio < 3, true)

-- -- where in the document the rebuilt range sits --------------------------------
--
-- A rebuild copies every row whichever shape the change takes, so it must not cost more to
-- keep the shadow of a change at the top of a document than at the bottom. Both sides are
-- ten rebuilds in a row and the cheapest of five runs, compared as a ratio so the assertion
-- does not depend on the machine. `reshadow` is called directly because this is the rebuild's
-- own cost; the buffer's is the same at either end, and the shadow it leaves behind then drifts
-- from that buffer, which nothing here reads. Observed here: about 1.0 with an explicit
-- destination index, about 4.9 writing each row with `#lines + 1`.
local spread_lines = {}
for index = 1, 20000 do
  spread_lines[index] = 'line ' .. index
end
local spread_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(spread_buf, 0, -1, true, spread_lines)
local spread_shared = Document.new(spread_buf, 'big.txt', function() end)

local function rebuild_cost(row)
  local best
  for round = 1, 5 do
    local started = os.clock()
    for _ = 1, 10 do
      spread_shared:reshadow(row, row, { 'replacement' })
    end
    local elapsed = (os.clock() - started) / 10
    if best == nil or elapsed < best then
      best = elapsed
    end
  end
  return best
end

local at_start = rebuild_cost(0)
local at_end = rebuild_cost(#spread_shared.lines - 1)
local spread = at_start / at_end
if spread >= 2.5 then
  print(('     start=%.4fs end=%.4fs ratio=%.2f'):format(at_start, at_end, spread))
end
check('a rebuild costs no more at the top of the document than at the bottom', spread < 2.5, true)

-- -- UTF-8 validity --------------------------------------------------------------
--
-- The companion decodes its stdin as UTF-8, so the front-end has to know which texts it can
-- carry: a byte a UTF-8 sequence cannot hold would arrive as U+FFFD and the document would
-- quietly lose it. `share` refuses such a buffer rather than sending it, and this is what it
-- asks.

check('ASCII is valid UTF-8', utf16.valid('hello\n'), true)
check('a two-byte character is', utf16.valid('café'), true)
check('an astral character is', utf16.valid('😀'), true)
check('  as the buffer holds it, in four bytes', utf16.valid('\xf0\x9f\x98\x80'), true)
check('a lone Latin-1 byte is not', utf16.valid('caf\xe9'), false)
check('a truncated sequence is not', utf16.valid('\xe9\x80'), false)
check('  nor a lead byte with no continuation', utf16.valid('caf\xc3'), false)
check('an overlong encoding is not', utf16.valid('\xc0\xaf'), false)
check('  nor a three-byte one', utf16.valid('\xe0\x80\xaf'), false)
check('a surrogate is not', utf16.valid('\xed\xa0\x80'), false)
check('a code point past U+10FFFF is not', utf16.valid('\xf4\x90\x80\x80'), false)
check('  and the last one is', utf16.valid('\xf4\x8f\xbf\xbf'), true)
check('a continuation byte on its own is not', utf16.valid('\x80'), false)
check('an empty string is', utf16.valid(''), true)
check('  and so is the empty line a buffer always has', utf16.valid('\n'), true)
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
