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

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
