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
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n') .. '\n'
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
check('the document text has the trailing newline', shared:text(), 'héllo\nwörld\n')

vim.api.nvim_buf_set_text(bufnr, 0, 3, 0, 3, { 'X' })
check('an insert after a two-byte character', change(sent[1]), '2..2 "X"')

vim.api.nvim_buf_set_text(bufnr, 1, 1, 1, 3, {})
check('a delete of a two-byte character', change(sent[2]), '8..9 ""')

vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'tail' })
check('a line appended past the final newline', change(sent[3]), '12..12 "tail\\n"')
check('the shadow tracks the buffer', shared:text(), buffer_text(bufnr))

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
  apply(appended, { start = 2, ['end'] = 2, text = 'b\n' }) and buffer_text(appended_buf),
  'a\nb\n'
)
check('  and the shadow with it', appended:text(), 'a\nb\n')

local replaced, replaced_buf = document({ 'a', 'b' })
check(
  'an edit replacing the last line',
  apply(replaced, { start = 2, ['end'] = 4, text = 'c\n' }) and buffer_text(replaced_buf),
  'a\nc\n'
)

local empty, empty_buf = document({ '' })
check(
  'an empty buffer filled from the room',
  apply(empty, { start = 0, ['end'] = 0, text = 'hello' }) and buffer_text(empty_buf),
  'hello\n'
)

local two, two_buf = document({ '' })
check(
  'an empty buffer filled with two lines',
  apply(two, { start = 0, ['end'] = 0, text = 'a\nb' }) and buffer_text(two_buf),
  'a\nb\n'
)

local multibyte, multibyte_buf = document({ 'héllo' })
check(
  'a range inside multibyte text',
  apply(multibyte, { start = 1, ['end'] = 2, text = 'E' }) and buffer_text(multibyte_buf),
  'hEllo\n'
)

local unterminated, unterminated_buf = document({ 'a' })
check(
  'a room text with no final newline gains one',
  apply(unterminated, { start = 0, ['end'] = 2, text = 'xyz' }) and buffer_text(unterminated_buf),
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
check('  and stops tracking the buffer', left:text(), 'a\n')
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
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
