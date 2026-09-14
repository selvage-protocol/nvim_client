-- The plugin's own wiring, against a companion process that is a stub.
--
--   nvim --headless -l test/lua/session.lua      (or scripts/test-lua.sh)
--
-- `test/lua/document.lua` covers the buffer arithmetic in a real buffer; this covers what a
-- session does with that buffer — which of them it shares, and, when the session ends, that it
-- lets them go. A buffer outlives the companion, so a callback left attached to one would keep
-- sending into a process that is no longer there.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime! plugin/selvage.lua')

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- Replaces the companion with one that records what it is asked to send and answers nothing,
--- so that a test can say what a session did without a process on the other end of a pipe.
local function stub_companion()
  local sent = {}
  local handlers = nil
  package.loaded['selvage.companion'] = {
    start = function(given)
      handlers = given
      return {
        send = function(_, message)
          sent[#sent + 1] = message
        end,
        stop = function() end,
      }
    end,
  }
  return sent, function()
    return handlers
  end
end

local sent, handlers = stub_companion()
local selvage = require('selvage')

vim.fn.mkdir('.tmp', 'p')
local path = '.tmp/lua-session.txt'
vim.fn.writefile({ 'one' }, path)
vim.cmd('edit ' .. vim.fn.fnameescape(path))
local bufnr = vim.api.nvim_get_current_buf()

selvage.host('ws://127.0.0.1:1')
check('hosting sends the command', sent[1] and sent[1].type, 'host')

-- The session is live, and the buffer it is hosting is now shared.
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-test' })
check('the shared buffer is opened in the room', sent[2] and sent[2].type, 'open')
check('  under its path', sent[2] and sent[2].path, path)

vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { 'two' })
check('a keystroke while the session is live is sent', sent[3] and sent[3].type, 'change')

selvage.leave()
check('leaving sends the command', sent[#sent].type, 'leave')

-- The buffer is still open and still the user's; the session that was sharing it is not.
local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, -1, -1, true, { 'three' })
check('a keystroke after the session ended is not an error', ok and 'ok' or tostring(err), 'ok')
check('  and it is not sent anywhere', sent[#sent].type, 'leave')
check(
  '  and the buffer keeps the edit',
  table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n'),
  'one\ntwo\nthree'
)

-- -- a companion that outlives the command that stopped it ----------------------
--
-- `:SelvageLeave` closes the companion's stdin and does not wait for the round trip that leaving
-- the room takes, so the process outlives the command. Whatever it exits with is then not an
-- error to report: the session asked it to go, and killed it if it had not gone on its own.

local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local function errors()
  local count = 0
  for _, notice in ipairs(notices) do
    if notice.level == vim.log.levels.ERROR then
      count = count + 1
    end
  end
  return count
end

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-test' })

local after_leave = errors()
selvage.leave()
handlers().on_exit(143)
check('the exit of a companion this session stopped is not reported', errors(), after_leave)

-- A companion that dies while the session is live still is: it has taken the session's buffers
-- with it, and they have to be let go of.
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-test' })

local after_crash = errors()
handlers().on_exit(1)
check('a companion that dies on its own is', errors(), after_crash + 1)

-- -- a guest has the room's document put in front of it -----------------------
--
-- The room path is the host's working directory plus the path within it — a VS Code host
-- started above a folder called `workspace` publishes `workspace/README.md` — so it is not a
-- name a guest can guess, and a guest typing it wrong concluded the join had failed. Joining
-- now shows the document, and `:SelvageOpen` reaches the ones that are not shown.

vim.cmd('edit! ' .. path)
selvage.join('ws://127.0.0.1:1/room#tok')
check('joining sends the command', sent[#sent].type, 'join')

handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-guest' })
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'workspace/README.md' } },
})
check('the room document is shown in the window', vim.fn.bufname('%'), 'selvage://workspace/README.md')
check('  and shared under its room path', sent[#sent].path, 'workspace/README.md')

-- A document the host opens afterwards gets a buffer but does not take the window: the guest
-- may be editing the first one.
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'workspace/README.md', 'workspace/other.lua' } },
})
check('a document opened later does not steal the window', vim.fn.bufname('%'), 'selvage://workspace/README.md')
check('  and it is reachable as a buffer', vim.fn.bufnr('selvage://workspace/other.lua') ~= -1, true)

vim.cmd('SelvageOpen workspace/other.lua')
check(':SelvageOpen shows a document by its room path', vim.fn.bufname('%'), 'selvage://workspace/other.lua')

vim.cmd('SelvageOpen README.md')
check(':SelvageOpen takes the basename', vim.fn.bufname('%'), 'selvage://workspace/README.md')

check(
  'completion offers the session documents',
  table.concat(vim.fn.getcompletion('SelvageOpen workspace/', 'cmdline'), ','),
  'workspace/README.md,workspace/other.lua'
)

local offered = nil
local select = vim.ui.select
vim.ui.select = function(items, _, on_choice)
  offered = items
  on_choice(items[2], 2)
end
vim.cmd('SelvageOpen')
vim.ui.select = select
check(
  'a bare :SelvageOpen offers every document',
  offered and table.concat(offered, ','),
  'workspace/README.md,workspace/other.lua'
)
check('  and shows the one chosen', vim.fn.bufname('%'), 'selvage://workspace/other.lua')

-- A join whose room has several documents shows the first and points at the rest.
selvage.leave()
selvage.join('ws://127.0.0.1:1/room#tok')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-two' })
local before = #notices
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'a/one.lua', 'a/two.lua' } },
})
check('the first of several is shown', vim.fn.bufname('%'), 'selvage://a/one.lua')
local pointed = false
for index = before + 1, #notices do
  pointed = pointed or notices[index].message:find(':SelvageOpen', 1, true) ~= nil
end
check('  and the rest are pointed at', pointed, true)

-- A room with no documents yet shows the first one that arrives.
selvage.leave()
vim.cmd('edit! ' .. path)
local unrelated = vim.fn.bufname('%')
selvage.join('ws://127.0.0.1:1/room#tok')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-empty' })
handlers().on_message({ type = 'report', report = { kind = 'documents', documents = {} } })
check('an empty room leaves the window alone', vim.fn.bufname('%'), unrelated)
handlers().on_message({ type = 'report', report = { kind = 'documents', documents = { 'late.md' } } })
check('  and the first document to arrive is shown', vim.fn.bufname('%'), 'selvage://late.md')

-- The escape hatch: `vim.g.selvage_open_on_join = false` keeps the buffer but not the window.
selvage.leave()
vim.g.selvage_open_on_join = false
selvage.join('ws://127.0.0.1:1/room#tok')
vim.cmd('edit! ' .. path)
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-off' })
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'workspace/README.md' } },
})
check('the escape hatch leaves the window alone', vim.fn.bufname('%'), unrelated)
check('  and the document is still opened as a buffer', vim.fn.bufnr('selvage://workspace/README.md') ~= -1, true)
vim.g.selvage_open_on_join = nil

-- -- presence: the caret out, the peers' carets in ------------------------------
--
-- The two directions of the IPC's `selection`/`presence`. This user's caret reaches the room
-- from the events that move it, throttled to one message per interval; a peer's caret and
-- selection arrive as a report and are drawn where the peer is.

local function count_type(kind)
  local count = 0
  for _, message in ipairs(sent) do
    if message.type == kind then
      count = count + 1
    end
  end
  return count
end

local function last_of(kind)
  for index = #sent, 1, -1 do
    if sent[index].type == kind then
      return sent[index]
    end
  end
  return nil
end

selvage.leave()
-- Flush any timer a session that has just ended had armed; its generation no longer matches.
vim.wait(200, function()
  return false
end)

-- A character outside the BMP, so a published offset can only be right if the byte to UTF-16
-- conversion ran. `a😀b` is six bytes and four UTF-16 code units.
local presence_path = '.tmp/lua-presence.txt'
vim.fn.writefile({ 'a😀b', 'wörld' }, presence_path)
vim.cmd('edit! ' .. vim.fn.fnameescape(presence_path))
local presence_buf = vim.api.nvim_get_current_buf()
local presence_room = vim.fn.fnamemodify(presence_path, ':.')

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-presence' })
check('the presence file is opened in the room', last_of('open') and last_of('open').path, presence_room)

vim.wait(500, function()
  return last_of('selection') ~= nil
end)
check('sharing a buffer publishes the caret', last_of('selection') and last_of('selection').path, presence_room)

-- Throttling: three events in one interval publish once, and the caret read is the one at
-- flush time, not the one the first event saw. The caret sits on `b` in `a😀b`: three UTF-16
-- units in (one for `a`, two for the emoji), where a byte count would say five.
local published_before = count_type('selection')
vim.api.nvim_win_set_cursor(0, { 1, 5 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = presence_buf })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = presence_buf })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = presence_buf })
check('a caret move waits for the throttle', count_type('selection'), published_before)
vim.wait(500, function()
  return count_type('selection') > published_before
end)
check('  and a burst of moves publishes one selection', count_type('selection'), published_before + 1)
local published = last_of('selection')
check('  carrying the room path', published and published.path, presence_room)
check(
  '  and the caret as UTF-16 offsets',
  published and ('%d:%d'):format(published.anchor, published.head),
  '3:3'
)

-- A buffer the room does not hold is not where anyone can see the caret, so it is cleared —
-- once, however much the caret moves there.
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(other)
vim.api.nvim_exec_autocmds('BufEnter', { buffer = other })
vim.wait(500, function()
  return last_of('selectionCleared') ~= nil
end)
check('a caret outside the shared documents is cleared', last_of('selectionCleared') ~= nil, true)
local cleared = count_type('selectionCleared')
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = other })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = other })
vim.wait(300, function()
  return false
end)
check('  and clearing again sends nothing', count_type('selectionCleared'), cleared)

-- A peer's caret is drawn where the caret is: the one cell at their own row and byte column,
-- filled with the colour the bridge gave them and left readable through it. Nothing is inserted,
-- so the line keeps its width and the block sits against the selection fill rather than beside
-- it. The column is the conversion from the UTF-16 offset the room counts, and the line is
-- multi-byte so the two cannot be confused.
vim.api.nvim_set_current_buf(presence_buf)
local ns = vim.api.nvim_get_namespaces()['selvage.presence']

local function draw(cursors)
  handlers().on_message({ type = 'presence', cursors = cursors })
  return vim.api.nvim_buf_get_extmarks(presence_buf, ns, 0, -1, { details = true })
end

--- The mark that carries the selection, as opposed to the caret's own. Both cover cells now, but
--- only the caret carries the sign, and only the selection is a range the peer made.
local function range_of(marks)
  for _, mark in ipairs(marks) do
    if mark[4].end_row ~= nil and mark[4].sign_text == nil then
      return mark
    end
  end
  return nil
end

local marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 7,
    head = 7,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret-only presence report draws one mark', #marks, 1)
check('  on the line the peer is on', marks[1] and marks[1][2], 1)
check("  at the peer's byte column, not their UTF-16 offset", marks[1] and marks[1][3], 3)
check('  filling the one cell the caret is on', marks[1] and marks[1][4].end_col, 4)
check('  on that line, adding none', marks[1] and marks[1][4].end_row, 1)
check(
  '  as a block in the peer colour, not text over the line',
  marks[1] ~= nil and marks[1][4].hl_group ~= nil and marks[1][4].virt_text == nil,
  true
)
check('  and not as a virtual line of its own', marks[1] ~= nil and marks[1][4].virt_lines == nil, true)
check(
  '  in the colour the bridge chose',
  marks[1] and vim.api.nvim_get_hl(0, { name = marks[1][4].hl_group }).bg,
  tonumber('61afef', 16)
)
check(
  '  with the character under it left a readable colour',
  marks[1] and vim.api.nvim_get_hl(0, { name = marks[1][4].hl_group }).fg,
  tonumber('000000', 16)
)
check("  and the sign keeps the name's first two characters", marks[1] and marks[1][4].sign_text, 'Bo')

-- The block covers the whole character, not one byte of it: `😀` is four bytes, and the caret
-- sits on it at UTF-16 offset 1, where a byte count would say one.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 1,
    head = 1,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret on a multi-byte character draws one mark', #marks, 1)
check("  at that character's byte column", marks[1] and marks[1][3], 1)
check('  and fills the whole character, not one byte', marks[1] and marks[1][4].end_col, 5)

-- The end of a line has no cell to fill, and that is where a peer typing at the end of a line
-- is: a single block in the empty cell after the text, still nothing inserted and nothing
-- shifted.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 4,
    head = 4,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret at the end of a line draws one mark', #marks, 1)
check('  past the last character', marks[1] and marks[1][3], 6)
check(
  '  as a one-cell block after the text',
  marks[1] and marks[1][4].virt_text and #marks[1][4].virt_text[1][1],
  1
)
check(
  '  in the peer colour',
  marks[1] and marks[1][4].virt_text and marks[1][4].virt_text[1][2],
  marks[1] and marks[1][4].sign_hl_group
)
check('  and not as a range over the text', marks[1] ~= nil and marks[1][4].end_col == nil, true)

-- Two peers whose names share an initial are not identical signs: the second character
-- separates `pi` from `pc`, and the colour separates whatever the text does not.
marks = draw({
  { peerId = 'p-pi', label = 'pi', role = 'guest', path = presence_room, anchor = 5, head = 5, colour = '#e06c75' },
  { peerId = 'p-pc', label = 'pc', role = 'guest', path = presence_room, anchor = 5, head = 5, colour = '#98c379' },
})
check('two peers are two marks', #marks, 2)
local signs, colours = {}, {}
for _, mark in ipairs(marks) do
  signs[#signs + 1] = mark[4].sign_text
  colours[#colours + 1] = vim.api.nvim_get_hl(0, { name = mark[4].sign_hl_group }).bg
end
table.sort(signs)
check('  whose signs do not collide on the first character', table.concat(signs, ','), 'pc,pi')
check('  and whose colours differ', colours[1] ~= colours[2], true)

-- A selection is a range filled in the peer's own colour, so the text under it stays legible.
-- Both ends are UTF-16 offsets converted to byte columns here, and `a😀b` is the case where
-- the two disagree: anchor 0 to head 3 is two characters, six bytes.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 0,
    head = 3,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a selection draws a range and its caret', #marks, 2)
local selection = range_of(marks)
check('  from the anchor line', selection and selection[2], 0)
check('  at the anchor byte column', selection and selection[3], 0)
check('  to the head line', selection and selection[4].end_row, 0)
check('  at the head byte column, past the astral pair', selection and selection[4].end_col, 5)
check(
  '  filled with a background',
  selection ~= nil and vim.api.nvim_get_hl(0, { name = selection[4].hl_group }).bg ~= nil,
  true
)
check(
  '  in a tint, not the opaque peer colour painted over the text',
  selection ~= nil and vim.api.nvim_get_hl(0, { name = selection[4].hl_group }).bg ~= tonumber('61afef', 16),
  true
)
check(
  '  leaving the text its own colour',
  selection ~= nil and vim.api.nvim_get_hl(0, { name = selection[4].hl_group }).fg == nil,
  true
)

-- A selection made backwards — `v` from the right end — is still a selection, and the same
-- one: `anchor` after `head` is the two ends in the other order.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 3,
    head = 0,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a backwards selection draws the same range', #marks, 2)
selection = range_of(marks)
check('  from the smaller end', selection ~= nil and selection[2] == 0 and selection[3] == 0, true)
check('  to the larger', selection ~= nil and selection[4].end_row == 0 and selection[4].end_col == 5, true)

-- A collapsed selection is a caret and nothing else: there is no range to fill.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 7,
    head = 7,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a collapsed selection is only the caret', #marks, 1)
check('  with no range behind it', range_of(marks) == nil, true)

-- A presence report is the whole set: a peer it no longer names is withdrawn, and a peer in
-- a document this client does not hold is not drawn at all.
marks = draw({
  {
    peerId = 'p-ann',
    label = 'Ann',
    role = 'guest',
    path = 'a-document-nobody-holds.txt',
    anchor = 0,
    head = 0,
    colour = '#e06c75',
  },
})
check(
  'a report without a peer withdraws their mark, and does not draw one for a document nobody holds',
  #marks,
  0
)

-- End of the session: every mark goes with it, whatever buffer it was on.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 0,
    head = 3,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret and a selection are up before the session ends', #marks, 2)
selvage.leave()
check('leaving the session clears every mark', #vim.api.nvim_buf_get_extmarks(presence_buf, ns, 0, -1, {}), 0)

vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
