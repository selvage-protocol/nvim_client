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

-- A name for the sessions this file starts. A process with nothing configured and nobody to ask
-- refuses to open a room rather than seating one under the login name, and every section but the
-- one about the name itself wants a live session. That section configures the name its own way
-- and puts this one back when it is done.
vim.g.selvage_display_name = 'Test User'

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

--- The notice, if any, a command added since `from`.
local function said_since(from, needle)
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      return notices[index].message
    end
  end
  return nil
end

-- The host confirm names the folder the session shares: the root is otherwise invisible until
-- a file outside it is opened. (The session at the top of this file hosted before `vim.notify`
-- was captured, so the check below names the next hosting instead.)

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-test' })

local after_leave = errors()
selvage.leave()
handlers().on_exit(143)
check('the exit of a companion this session stopped is not reported', errors(), after_leave)

-- A companion that dies while the session is live still is: it has taken the session's buffers
-- with it, and they have to be let go of.
selvage.host('ws://127.0.0.1:1')
local before_host_confirm = #notices
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-test' })
check(
  'the host confirm names the folder the session shares',
  said_since(before_host_confirm, 'The room is open (sharing ' .. vim.fn.getcwd() .. ')') ~= nil,
  true
)

local after_crash = errors()
handlers().on_exit(1)
check('a companion that dies on its own is', errors(), after_crash + 1)

-- A connection that fails says what the engine said and what to try next: the engine's text is
-- accurate but names no next step, and a bad address is the newcomer's failure. A fresh host
-- earns the failure: the crashed companion above hears nothing anymore.
selvage.host('ws://127.0.0.1:1')
local before_error = #notices
handlers().on_message({ type = 'status', state = 'error', message = 'connection refused' })
local failed = said_since(before_error, 'connection refused')
check('a failed connection says what the engine said', failed ~= nil, true)
check(
  '  and what to try next',
  failed ~= nil and failed:find('check the address and try again', 1, true) ~= nil,
  true
)
check('  at error level', notices[#notices].level, vim.log.levels.ERROR)
selvage.leave()

-- -- a guest has the room's document put in front of it -----------------------
--
-- The room path is the host's working directory plus the path within it — a VS Code host
-- started above a folder called `workspace` publishes `workspace/README.md` — so it is not a
-- name a guest can guess, and a guest typing it wrong concluded the join had failed. Joining
-- now shows the document, and `:SelvageOpen` reaches the ones that are not shown.

vim.cmd('edit! ' .. path)
selvage.join('ws://127.0.0.1:1/session?room=r-guest&token=t')
check('joining sends the command', sent[#sent].type, 'join')

local before_join = #notices
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-guest' })
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'workspace/README.md' } },
})
check('the room document is shown in the window', vim.fn.bufname('%'), 'selvage://workspace/README.md')
check('  and shared under its room path', sent[#sent].path, 'workspace/README.md')
check(
  '  and the join says the landing',
  said_since(before_join, 'Joined the room; opening workspace/README.md') ~= nil,
  true
)

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
selvage.join('ws://127.0.0.1:1/session?room=r-two&token=t')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-two' })
local before = #notices
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'a/one.lua', 'a/two.lua' } },
})
check('the first of several is shown', vim.fn.bufname('%'), 'selvage://a/one.lua')
check(
  '  and said so, pointing at the others',
  said_since(before, 'Joined the room; opening a/one.lua; 1 more, :SelvageOpen to choose') ~= nil,
  true
)
local pointed = false
for index = before + 1, #notices do
  pointed = pointed or notices[index].message:find(':SelvageOpen', 1, true) ~= nil
end
check('  and the rest are pointed at', pointed, true)

-- A room with no documents yet has a join sentence of its own, and shows the room's first
-- document when it arrives: that is what a person who just joined asked to see, and a room that
-- was empty at the join fills. Nothing says so, either — the buffer appearing is the signal.
selvage.leave()
vim.cmd('edit! ' .. path)
local unrelated = vim.fn.bufname('%')
selvage.join('ws://127.0.0.1:1/session?room=r-empty&token=t')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-empty' })
local before_empty = #notices
handlers().on_message({ type = 'report', report = { kind = 'documents', documents = {} } })
check('an empty room leaves the window alone', vim.fn.bufname('%'), unrelated)
check(
  '  and the join says the room has nothing in it yet',
  said_since(before_empty, 'Joined the room; the room has no open documents yet') ~= nil,
  true
)
local before_late = #notices
handlers().on_message({ type = 'report', report = { kind = 'documents', documents = { 'late.md' } } })
check('  and the first document to arrive is shown', vim.fn.bufname('%'), 'selvage://late.md')
check('  without a sentence about it', #notices, before_late)

-- The escape hatch: `vim.g.selvage_open_on_join = false` keeps the buffer but not the window.
selvage.leave()
vim.g.selvage_open_on_join = false
selvage.join('ws://127.0.0.1:1/session?room=r-off&token=t')
vim.cmd('edit! ' .. path)
local before_off = #notices
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-off' })
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'workspace/README.md' } },
})
check('the escape hatch leaves the window alone', vim.fn.bufname('%'), unrelated)
check('  and the document is still opened as a buffer', vim.fn.bufnr('selvage://workspace/README.md') ~= -1, true)
check(
  '  and the join claims no landing',
  said_since(before_off, 'Joined the room') ~= nil,
  true
)
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
-- conversion ran. `a😀b` is six bytes and four UTF-16 code units. `guest` is the plain line the
-- caret's cell is asserted on, and the empty line is the one position a line offers with no cell
-- in it at all. Where each line starts: `a😀b` at 0, `wörld` at 5, `guest` at 11, the empty
-- line at 17.
local presence_path = '.tmp/lua-presence.txt'
vim.fn.writefile({ 'a😀b', 'wörld', 'guest', '' }, presence_path)
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

-- A peer's caret is a block on the cell *before* the room's offset: the character the caret is
-- in front of, not the one it has reached, so a caret published at the offset of `e` in `guest`
-- fills `u`. The colour is the one the bridge gave the peer and the character under the block
-- stays readable through it. Nothing is inserted, so the line keeps its width and the block sits
-- against the selection fill rather than beside it. The column is the conversion from the UTF-16
-- offset the room counts, and the lines are multi-byte so the two cannot be confused.
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
check(
  "  on the byte column of the cell before the offset, not the offset's own",
  marks[1] and marks[1][3],
  1
)
check('  filling that character, not one byte of it: `ö` is two bytes', marks[1] and marks[1][4].end_col, 3)
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

-- The owner's case, and the one an off-by-one shows up in: a caret between two characters is
-- in front of the second of them, so `gu|est` fills `u`. `guest` starts at UTF-16 offset 11,
-- so the offset in front of its `e` is 13 — reading the offset as the cell it names fills `e`
-- instead, which is what this asserts against.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 13,
    head = 13,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret between two characters draws one mark', #marks, 1)
check('  on the line the offset is on', marks[1] and marks[1][2], 2)
check('  on the character before the offset, not the one at it', marks[1] and marks[1][3], 1)
check('  filling that one cell', marks[1] and marks[1][4].end_col, 2)

-- Offset 0 has no cell before it, so the block stays on the first cell of the line, where a
-- bar at the line's start is drawn: not on another line, and not off the text. The character
-- under it is the one the offset's own cell holds, because there is no other cell there.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 0,
    head = 0,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret at the start of a line draws one mark', #marks, 1)
check('  on the line the offset is on', marks[1] and marks[1][2], 0)
check('  on the first cell, having none on its left', marks[1] and marks[1][3], 0)
check('  filling it', marks[1] and marks[1][4].end_col, 1)

-- The block covers the whole character, not one byte of it: `😀` is four bytes and two UTF-16
-- units, and the caret in front of `b` is at offset 2, where a byte count would say five.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 2,
    head = 2,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret with a multi-byte character before it draws one mark', #marks, 1)
check("  at that character's byte column", marks[1] and marks[1][3], 1)
check('  and fills the whole character, not one byte', marks[1] and marks[1][4].end_col, 5)

-- A caret at the end of a line — the offset after the last character — is in front of the last
-- character, so that is the cell filled: a peer typing at the end of a line is drawn on the
-- text, not after it. Nothing is inserted and nothing is shifted either way.
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
check('  on the last character of the line', marks[1] and marks[1][3], 5)
check('  filling it', marks[1] and marks[1][4].end_col, 6)
check('  and not as text placed after the line', marks[1] ~= nil and marks[1][4].virt_text == nil, true)

-- An empty line is the one position with no cell before the caret and none under it, and a
-- block cursor is still owed there: the single block in the empty cell, as before.
marks = draw({
  {
    peerId = 'p-bob',
    label = 'Bob',
    role = 'guest',
    path = presence_room,
    anchor = 17,
    head = 17,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a caret on an empty line draws one mark', #marks, 1)
check('  on that line', marks[1] and marks[1][2], 3)
check('  in the one cell it has', marks[1] and marks[1][3], 0)
check(
  '  as a one-cell block',
  marks[1] and marks[1][4].virt_text and #marks[1][4].virt_text[1][1],
  1
)
check(
  '  in the peer colour',
  marks[1] and marks[1][4].virt_text and marks[1][4].virt_text[1][2],
  marks[1] and marks[1][4].sign_hl_group
)
check('  and not as a range over nothing', marks[1] ~= nil and marks[1][4].end_col == nil, true)

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

-- -- the name behind the gutter sign -------------------------------------------
--
-- `sign_text` is one or two cells, so a peer called `thisismylongusername` is `th` and the
-- colour is all else the gutter holds. `:SelvagePeers` answers for the rest: the list the two
-- cells are looked up in, in the very colour the caret and the sign are drawn with, since a
-- list that explains the gutter has to agree with it cell for cell.
--
-- Nothing draws a peer's name over the document, however long it is: a name over the text is a
-- line and a half of the buffer covered whenever that peer moves, which is worse than the two
-- cells it explains. The gutter is where the name lives, and the caret is a block.

check('a peer whose document this client does not hold has no gutter sign to explain', #selvage.peers(), 0)

--- The floating windows on screen, which is where a name over the document would have to be.
local function overlay_windows()
  local floats = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      floats = floats + 1
    end
  end
  return floats
end

check('nothing is drawn over the document before a peer is', overlay_windows(), 0)

marks = draw({
  {
    peerId = 'p-long',
    label = 'thisismylongusername',
    role = 'guest',
    path = presence_room,
    anchor = 5,
    head = 5,
    colour = '#98c379',
    fill = '#98c37940',
  },
})
check('a long name is still two cells in the gutter', marks[1] and marks[1][4].sign_text, 'th')
check('  and draws nothing over the document', overlay_windows(), 0)
check(
  '  the caret being a cell of the line with nothing written over it',
  marks[1] ~= nil and marks[1][4].virt_text == nil and marks[1][4].end_col ~= nil,
  true
)
local name_hl = marks[1] and marks[1][4].sign_hl_group

marks = draw({
  {
    peerId = 'p-long',
    label = 'thisismylongusername',
    role = 'guest',
    path = presence_room,
    anchor = 7,
    head = 7,
    colour = '#98c379',
    fill = '#98c37940',
  },
})
check('a peer who moves draws nothing over the document with them', overlay_windows(), 0)

local peers = selvage.peers()
check('the session lists the peers the last report drew', #peers, 1)
check('  with the whole name the two cells abbreviate', peers[1] and peers[1].label, 'thisismylongusername')
check('  and the sign those two cells are', peers[1] and peers[1].sign, 'th')
check('  where the peer is', peers[1] and peers[1].path, presence_room)
check("  in that peer's own highlight", peers[1] and peers[1].highlight, name_hl)
check(
  '  which is the colour the bridge gave them',
  peers[1] and vim.api.nvim_get_hl(0, { name = peers[1].highlight }).bg,
  tonumber('98c379', 16)
)

-- The command echoes the list — the sign first, the whole name beside it — in that same
-- highlight. A notification would go through whatever provider is installed and could arrive as
-- plain text, and the colour is what ties a name to a caret on screen.
local echoed = nil
local echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
  echoed = chunks
end
vim.cmd('SelvagePeers')
vim.api.nvim_echo = echo
check('  and :SelvagePeers prints the two cells', echoed ~= nil and echoed[1] and echoed[1][1], 'th')
check('    in the peer highlight', echoed ~= nil and echoed[1] and echoed[1][2], name_hl)
check(
  '    with the whole name beside them',
  echoed ~= nil and echoed[2] and echoed[2][1]:find('thisismylongusername', 1, true) ~= nil,
  true
)

-- The room names everyone in it, and the list is the room's: a peer whose caret this client
-- cannot draw — one whose document nobody here holds — is someone to name all the same. The two
-- cells and the colour are this session's own rendering of a peer, so those are carried only
-- where the gutter drew them.
handlers().on_message({
  type = 'report',
  report = {
    kind = 'peers',
    peers = {
      { peer_id = 'p-long', display_name = 'thisismylongusername', role = 'guest' },
      { peer_id = 'p-ann', display_name = 'Ann', role = 'host' },
    },
  },
})
peers = selvage.peers()
check('the room names every peer, drawn or not', #peers, 2)
check('  the one the gutter drew comes first', peers[1] and peers[1].label, 'thisismylongusername')
check('    with its sign', peers[1] and peers[1].sign, 'th')
check('  and the one it cannot draw is named too', peers[2] and peers[2].label, 'Ann')
check('    with no sign to explain', peers[2] and peers[2].sign, nil)
check('    and no colour of its own', peers[2] and peers[2].highlight, nil)
check('    and the role the room gave it', peers[2] and peers[2].role, 'host')

echoed = nil
vim.api.nvim_echo = function(chunks)
  echoed = chunks
end
vim.cmd('SelvagePeers')
vim.api.nvim_echo = echo
-- A row is the sign and the text for a peer the gutter drew, and the text alone for one it did
-- not: two rows, one separator, so four chunks, and the signless row is the last of them.
check('  and :SelvagePeers prints a row for each', echoed ~= nil and #echoed, 4)
check('    the drawn one still behind its sign', echoed and echoed[1] and echoed[1][1], 'th')
check(
  '    and the undrawn one by name alone',
  echoed and echoed[4] and echoed[4][1]:find('Ann', 1, true) ~= nil,
  true
)
check(
  '    saying which document it is not in',
  echoed and echoed[4] and echoed[4][1]:find('no shared document open', 1, true) ~= nil,
  true
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
check('  and draws nothing over the document', overlay_windows(), 0)
check('  and the list with them', #selvage.peers(), 0)

-- With no session there is no room to name, and that is not the same answer as a room with
-- nobody in it.
local before_no_session = #notices
vim.cmd('SelvagePeers')
check(
  'with no session the list says there is none',
  said_since(before_no_session, 'Join a session first') ~= nil,
  true
)

-- -- the name the room sees -----------------------------------------------------
--
-- The name travels in the `host`/`join` handshake, and a change made while a session is live is
-- sent as `session.rename`. Every source of it is exercised here: the plugin's global,
-- `SELVAGE_DISPLAY_NAME` and the prompt. A configured name is never asked about; with nothing
-- configured the user is asked, and an answer nobody gave refuses the session rather than
-- inventing a name for it.

local saved_input = vim.ui.input
local prompted = 0

-- The remembered answers this section reads are sandboxed to this checkout, and cleared
-- wherever a check needs nothing remembered: a prompted answer from an earlier check
-- would otherwise answer a later one without asking.
local saved_data_home = vim.env.XDG_DATA_HOME
vim.env.XDG_DATA_HOME = vim.fn.getcwd() .. '/.tmp/lua-session-data'
local function forget_remembered()
  vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-session-data', 'rf')
end
forget_remembered()

vim.g.selvage_display_name = nil
vim.env.SELVAGE_DISPLAY_NAME = 'Env Name'
vim.ui.input = function()
  prompted = prompted + 1
end
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('SELVAGE_DISPLAY_NAME names the session', last_of('host') and last_of('host').displayName, 'Env Name')
check('  and it is not asked about', prompted, 0)

-- The global is the plugin's own setting, so it wins over the ambient variable.
vim.g.selvage_display_name = 'Global Name'
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('the global wins over the environment', last_of('host') and last_of('host').displayName, 'Global Name')
check('  and it is not asked about either', prompted, 0)

-- With neither set, the user is asked. The answer is used, trimmed, and becomes the global, so
-- the same Neovim is not asked again.
vim.g.selvage_display_name = nil
vim.env.SELVAGE_DISPLAY_NAME = nil
vim.ui.input = function(opts, on_confirm)
  prompted = prompted + 1
  check('  the prompt pre-fills the login name', opts and opts.default, vim.env.USER or '')
  check(
    '  and separates the prompt from the value',
    opts and opts.prompt,
    'The name other participants see (remembered; :SelvageDisplayName changes it): '
  )
  on_confirm('  Ada  ')
end
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('with nothing configured the user is asked', prompted, 1)
check('  and the answer names the session', last_of('host') and last_of('host').displayName, 'Ada')
check('  and it becomes the configured name', vim.g.selvage_display_name, 'Ada')

selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('a configured name is not asked about again', prompted, 1)
check('  and it names the next session too', last_of('host') and last_of('host').displayName, 'Ada')

-- Dismissing the prompt is not a name, and nothing else is: the suggestion it started from is
-- not an answer, so no session is opened and the global is left unset, ready to be asked for
-- again. A name an earlier check answered is forgotten first, so this one is asked.
vim.g.selvage_display_name = nil
forget_remembered()
vim.ui.input = function(_, on_confirm)
  prompted = prompted + 1
  on_confirm(nil)
end
local before_dismissal = #notices
selvage.leave()
local hosts_before_dismissal = count_type('host')
selvage.host('ws://127.0.0.1:1')
check('a dismissed prompt starts no session', count_type('host'), hosts_before_dismissal)
check('  and does not configure a name', vim.g.selvage_display_name, nil)
check('  and says A name is needed', said_since(before_dismissal, 'A name is needed') ~= nil, true)

-- An emptied box is the same answer as a dismissed one.
vim.ui.input = function(_, on_confirm)
  prompted = prompted + 1
  on_confirm('   ')
end
local before_blank = #notices
local hosts_before_blank = count_type('host')
selvage.host('ws://127.0.0.1:1')
check('an emptied prompt starts no session', count_type('host'), hosts_before_blank)
check('  and says A name is needed', said_since(before_blank, 'A name is needed') ~= nil, true)
check('  and does not configure a name', vim.g.selvage_display_name, nil)

-- No input at all: the built-in `vim.ui.input` reads a terminal a headless process does not
-- have, so the question cannot be put to anyone and no room is opened under a guessed name.
vim.ui.input = saved_input
local prompted_before_headless = prompted
local before_headless = #notices
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('a process with no one to ask is not prompted', prompted, prompted_before_headless)
check('  and starts no session', count_type('host'), hosts_before_blank)
check(
  '  and the refusal says how to configure a name',
  said_since(before_headless, 'set vim.g.selvage_display_name or SELVAGE_DISPLAY_NAME') ~= nil,
  true
)
check('  at error level', notices[#notices].level, vim.log.levels.ERROR)

-- `:SelvageDisplayName` sets the configured name before a session, says so, and reports the name in
-- force when given none.
selvage.leave()
vim.cmd('SelvageDisplayName Grace')
check(':SelvageDisplayName sets the configured name', vim.g.selvage_display_name, 'Grace')
local before_set = #notices
vim.cmd('SelvageDisplayName Pat')
check('  it says what it did', said_since(before_set, 'Display name set to "Pat"') ~= nil, true)
check('  and without protocol mechanics', said_since(before_set, 'room') == nil, true)
local before_report = #notices
vim.cmd('SelvageDisplayName')
check('  and with no name reports the one in force', said_since(before_report, 'The name others see is "Pat"') ~= nil, true)

-- A change during a live session is sent now: `session.rename` carries it and the room answers
-- with `peer.renamed`, so the sign and `:SelvagePeers` re-label from that event rather than from
-- anything held here. The configured name is set too, so a session started after this one
-- re-hellos under it. A name an earlier check set is forgotten first, so this one is asked.
vim.g.selvage_display_name = nil
forget_remembered()
vim.ui.input = function(_, on_confirm)
  on_confirm('First')
end
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('the session starts under the chosen name', last_of('host') and last_of('host').displayName, 'First')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-name' })
local renames_before = count_type('rename')
local before_live = #notices
vim.cmd('SelvageDisplayName Second')
check('  :SelvageDisplayName sets the configured name mid-session', vim.g.selvage_display_name, 'Second')
check('  and sends the live rename', count_type('rename'), renames_before + 1)
check('  naming the new name', last_of('rename') and last_of('rename').displayName, 'Second')
check('  and confirms the new name', said_since(before_live, 'Display name set to "Second"') ~= nil, true)
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('the next session uses the changed name', last_of('host') and last_of('host').displayName, 'Second')
selvage.leave()
vim.ui.input = saved_input
vim.g.selvage_display_name = nil

-- -- the room's limit on a name --------------------------------------------------
--
-- A display name is at most 32 UTF-16 code units, the unit the protocol counts, so an astral
-- character costs two. An over-long name is refused, never shortened: the room must see the
-- name its owner chose or no name at all. Where the name was typed the user is asked again
-- with its length; where it came from a setting there is nobody to re-ask, so the session is
-- not started and the refusal names the setting.

local utf16 = require('selvage.utf16')
check('a name is counted in UTF-16 code units', utf16.len('🧵'), 2)
check('  which is not its bytes', #('🧵'), 4)
check('  nor its characters', vim.fn.strchars('🧵'), 1)

-- 32 units exactly, all ASCII: allowed, and it reaches the room whole.
local at_limit = string.rep('a', 32)
vim.ui.input = function() end
vim.cmd('SelvageDisplayName ' .. at_limit)
check('a name of exactly 32 units is accepted', vim.g.selvage_display_name, at_limit)
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('  and names the session', last_of('host') and last_of('host').displayName, at_limit)

-- One unit more is refused, the name in force is kept, and the refusal says the limit and the
-- count so the answer is a shorter name rather than a guess.
local before_long = #notices
vim.cmd('SelvageDisplayName ' .. string.rep('b', 33))
check('a name of 33 units is refused', vim.g.selvage_display_name, at_limit)
check(
  '  with the count and the limit',
  said_since(before_long, 'This name is 33 UTF-16 code units and the limit is 32') ~= nil,
  true
)
check(
  '  and that it is refused rather than shortened',
  said_since(before_long, 'a name is refused rather than shortened') ~= nil,
  true
)

-- An astral character costs two units, so 30 of them plus one is exactly 32 units — 34 bytes
-- and 31 characters. A byte count would refuse this name and a character count would let 31
-- ASCII plus one astral through as if it were 32, which is why the count is pinned here.
local astral_at_limit = string.rep('e', 30) .. '🧵'
vim.cmd('SelvageDisplayName ' .. astral_at_limit)
check('32 units ending in an astral character are accepted', vim.g.selvage_display_name, astral_at_limit)
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('  and name the session', last_of('host') and last_of('host').displayName, astral_at_limit)
local before_astral = #notices
vim.cmd('SelvageDisplayName ' .. string.rep('e', 31) .. '🧵')
check('33 units ending in an astral character are refused', vim.g.selvage_display_name, astral_at_limit)
check('  with its count', said_since(before_astral, '33 UTF-16 code units') ~= nil, true)

-- At the prompt the question is asked again, so a typed name over the limit costs a keystroke
-- and not the session. A name an earlier check set is forgotten first, so this one is asked.
vim.g.selvage_display_name = nil
forget_remembered()
local answers = { string.rep('c', 33), 'Cara' }
local asked = 0
vim.ui.input = function(_, on_confirm)
  asked = asked + 1
  on_confirm(answers[asked])
end
local before_prompt = #notices
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('a 33-unit answer at the prompt is asked for again', asked, 2)
check(
  '  with the count and the limit',
  said_since(before_prompt, 'This name is 33 UTF-16 code units and the limit is 32') ~= nil,
  true
)
check('  and the shorter answer names the session', last_of('host') and last_of('host').displayName, 'Cara')
check('  and becomes the configured name', vim.g.selvage_display_name, 'Cara')

-- An over-long name the environment carried has nobody to re-ask: it stops the session and
-- is refused by name, rather than being shortened or swapped for the login name.
vim.g.selvage_display_name = nil
vim.env.SELVAGE_DISPLAY_NAME = string.rep('d', 33)
asked = 0
local hosts_before_env = count_type('host')
local before_env = #notices
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('an over-long SELVAGE_DISPLAY_NAME starts nothing', count_type('host'), hosts_before_env)
check('  and is not asked about', asked, 0)
check(
  '  and the refusal is the shared one, naming the variable',
  said_since(before_env, 'a name is refused rather than shortened (from SELVAGE_DISPLAY_NAME') ~= nil,
  true
)
check('  and says the session was not started', said_since(before_env, 'the session was not started') ~= nil, true)

-- A script can set the global without going through the command; the check is at the point
-- the session starts for exactly that reason.
vim.env.SELVAGE_DISPLAY_NAME = nil
vim.g.selvage_display_name = string.rep('f', 33)
local hosts_before_global = count_type('host')
local before_global = #notices
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('an over-long global a script set starts nothing', count_type('host'), hosts_before_global)
check(
  '  and the refusal names the global',
  said_since(before_global, 'from vim.g.selvage_display_name') ~= nil,
  true
)

-- Reporting it rather than joining under it: with no argument the command says the name in
-- force would not start a session, because the name in force is not one the room would take.
local before_report = #notices
vim.cmd('SelvageDisplayName')
check('an over-long name in force is not reported as the name others see', said_since(before_report, 'the name others see') == nil, true)
check('  and why the next session would not start', said_since(before_report, 'the next session will not start') ~= nil, true)
vim.g.selvage_display_name = nil

-- The login name is a suggestion and nothing more, however long it is: it is what the prompt
-- starts from, and a process with nobody to ask starts no room at all rather than seating one
-- under a name that was never answered for. A name an earlier check answered is forgotten
-- first, so this refusal is about there being no name at all.
vim.g.selvage_display_name = nil
forget_remembered()
local saved_user = vim.env.USER
vim.env.USER = string.rep('g', 33)
vim.ui.input = saved_input
local hosts_before_suggestion = count_type('host')
local before_suggestion = #notices
selvage.leave()
selvage.host('ws://127.0.0.1:1')
check('an over-long login name starts nothing', count_type('host'), hosts_before_suggestion)
check(
  '  and the refusal is about there being no name, not about its length',
  said_since(before_suggestion, 'No display name is set and there is no one to ask') ~= nil,
  true
)
vim.env.USER = saved_user
vim.g.selvage_display_name = nil

-- Put this file's own name back: the sections after this one are not about the name.
vim.g.selvage_display_name = 'Test User'
vim.env.XDG_DATA_HOME = saved_data_home

-- -- a session that ends without leaving ------------------------------------------
--
-- A session can end without `:SelvageLeave`: a room that goes, a connection the engine gives up
-- on, and a command that gives the live session up before it starts the next one. The companion
-- says so with `status idle`, and the front-end has to start clean from it, or the paths the
-- session that ended shared still count as its own: `share` returns early for every one of them,
-- no `open` puts them in the new room, and the plugin keeps listing them while the room has never
-- heard of them.

selvage.leave()
vim.cmd('edit! ' .. path)
local session_buf = vim.api.nvim_get_current_buf()

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-first' })
local hosted_opens = count_type('open')

-- A second host starts from the companion's own `idle`, and the buffer the first one shared is
-- shared again under the same path. The command in between is what starts it: a `status hosting`
-- this front-end did not ask for is not a sequence it can produce, and the folder the session was
-- started in comes from the command that started it.
handlers().on_message({ type = 'status', state = 'idle' })
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-second' })
check('a second host re-opens the buffer the first one shared', count_type('open'), hosted_opens + 1)
check('  under the same path', last_of('open') and last_of('open').path, path)
check('  and lists it once', #selvage.documents(), 1)
local hosted_changes = count_type('change')
vim.api.nvim_buf_set_lines(session_buf, -1, -1, true, { 'four' })
check('  and reports a later edit exactly once', count_type('change'), hosted_changes + 1)

-- The same end reached by a join: the room's document set re-opens a path the front-end
-- already held.
local joined_opens = count_type('open')
handlers().on_message({ type = 'status', state = 'idle' })
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-guest' })
handlers().on_message({ type = 'report', report = { kind = 'documents', documents = { path } } })
check('a join re-opens a document the front-end already held', count_type('open'), joined_opens + 1)
check('  under its room path', last_of('open') and last_of('open').path, path)

-- -- the engine gives up ---------------------------------------------------------
--
-- A bounded reconnect that runs out of attempts ends the session, and the bridge says so with
-- a `disconnected` report. Nothing said anything before this: the status stayed hosting or
-- joined and the documents stayed attached, so the user went on typing into a replica nobody
-- would hear.

selvage.leave()
vim.cmd('edit! ' .. path)
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-drop' })
check('the buffer is shared before the engine gives up', #selvage.documents(), 1)

local before_drop = errors()
handlers().on_message({ type = 'report', report = { kind = 'disconnected' } })
check('a connection the engine gave up on is reported', errors(), before_drop + 1)
check('  and the session lets its documents go', #selvage.documents(), 0)
check('  and it is no longer hosting', selvage.session().status, 'idle')

-- The companion process outlives the session, so it is not what a leave is about: the session it
-- held is gone, and a later `:SelvageLeave` says there is nothing to leave rather than claiming to
-- have left it.
local before_late_leave = #notices
selvage.leave()
check(
  'a leave after the engine gave up says there is no session',
  said_since(before_late_leave, 'Not in a session') ~= nil,
  true
)
check(
  '  and does not claim to have left one',
  said_since(before_late_leave, 'Left the session') == nil,
  true
)

-- -- the room's own comings and goings --------------------------------------------
--
-- Two more things the room says about itself: the host is back after a blip, and the room is
-- gone. The second is the end of the session here as much as it is in the companion — the
-- companion has let the engine go by the time this is read — so the documents, the marks and the
-- status go with it, and the process stays for the next host or join.

selvage.leave()
vim.cmd('edit! ' .. path)
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-gone' })
check('the session is live before the room goes', #selvage.documents(), 1)

local before_attached = #notices
handlers().on_message({
  type = 'report',
  report = { kind = 'hostAttached', peer = { peer_id = 'p-host', display_name = 'Ada', role = 'host' } },
})
check('the host coming back is announced', said_since(before_attached, 'Ada is hosting again') ~= nil, true)
check('  at information level', notices[#notices].level, vim.log.levels.INFO)

local before_detached = #notices
handlers().on_message({ type = 'report', report = { kind = 'hostDetached', graceMs = 30000 } })
check(
  'the host going is announced in seconds',
  said_since(before_detached, 'it closes in 30s unless they come back') ~= nil,
  true
)
check('  at warning level', notices[#notices].level, vim.log.levels.WARN)

local before_gone = #notices
handlers().on_message({ type = 'report', report = { kind = 'roomGone', reason = 'host did not return' } })
check(
  'the room going is reported with its reason',
  said_since(before_gone, 'The room is gone (host did not return)') ~= nil,
  true
)
check('  and the session ends with it', selvage.session().status, 'idle')
check('  and its documents are let go', #selvage.documents(), 0)
check('  and its peers with them', #selvage.peers(), 0)

-- -- a guest's window is landed when the room dies -----------------------------------
--
-- The room's buffers are the room's, and when the room is gone they are nobody's: a window
-- still showing one reads as a room that is still there. What the guest has not changed goes
-- with the room; a buffer holding their own unsaved changes is kept and said so, because the
-- session can no longer save it and dropping it would drop their text. A host is left alone:
-- its buffers are its own files.

selvage.join('ws://127.0.0.1:1/session?room=r-land&token=t')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-land' })
handlers().on_message({
  type = 'report',
  report = { kind = 'grant', paths = { 'room/one.txt', 'room/two.txt' } },
})
local land_root = selvage.session().mirror
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'room/one.txt' } },
})
vim.cmd('SelvageOpen room/two.txt')
local one_buf = vim.fn.bufnr(land_root .. '/room/one.txt')
local two_buf = vim.api.nvim_get_current_buf()
check('the guest is editing the room file', vim.fn.bufname('%'), land_root .. '/room/two.txt')
vim.api.nvim_buf_set_lines(two_buf, -1, -1, true, { 'kept by hand' })
check('  and it has unsaved changes', vim.bo[two_buf].modified, true)

local before_land = #notices
handlers().on_message({ type = 'report', report = { kind = 'roomGone', reason = 'host did not return' } })
check('the dead room is not left in the window', vim.fn.bufname('%'), '')
check('  and the buffer with no changes is gone', vim.api.nvim_buf_is_valid(one_buf), false)
check('  while the one with unsaved changes is kept', vim.api.nvim_buf_is_valid(two_buf), true)
check(
  '  and that buffer still holds the edit',
  table.concat(vim.api.nvim_buf_get_lines(two_buf, 0, -1, false), '\n'):find('kept by hand', 1, true) ~= nil,
  true
)
check(
  '  and the person is told it was kept',
  said_since(before_land, '1 buffers with unsaved changes were kept') ~= nil,
  true
)
check('  and the session is over', selvage.session().status, 'idle')

-- With nothing changed, the room's buffers all go and there is nothing to say.
selvage.join('ws://127.0.0.1:1/session?room=r-land2&token=t')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-land2' })
handlers().on_message({
  type = 'report',
  report = { kind = 'grant', paths = { 'room/only.txt' } },
})
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'room/only.txt' } },
})
local only_buf = vim.api.nvim_get_current_buf()
local before_clean = #notices
handlers().on_message({ type = 'report', report = { kind = 'roomGone', reason = 'host did not return' } })
check('an unchanged room buffer goes with the room', vim.api.nvim_buf_is_valid(only_buf), false)
check('  and nothing was kept to announce', said_since(before_clean, 'were kept') ~= nil, false)

-- A report's cause is part of what it says: the sentence is the fact and the parenthetical is
-- why, and a report that carries a reason must not lose it. The kind name is not a sentence.
local before_reports = #notices
handlers().on_message({ type = 'report', report = { kind = 'applyRefused', path = 'a.txt' } })
check(
  'a refused apply is a sentence',
  said_since(before_reports, "The editor would not apply the room's change to a.txt; the file may be read-only") ~= nil,
  true
)
check('  at error level', notices[#notices].level, vim.log.levels.ERROR)
handlers().on_message({ type = 'report', report = { kind = 'divergence', path = 'a.txt' } })
check(
  'a divergence is a sentence',
  said_since(before_reports, "a.txt was out of step with the room; the room's copy has been put back") ~= nil,
  true
)
check('  at warning level', notices[#notices].level, vim.log.levels.WARN)
handlers().on_message({
  type = 'report',
  report = { kind = 'saveFailed', path = 'a.txt', message = 'the path is read-only' },
})
check(
  'a save that failed says why',
  said_since(before_reports, 'Could not save a.txt; the file on disk is behind the room (the path is read-only)') ~= nil,
  true
)
handlers().on_message({ type = 'report', report = { kind = 'saveFailed', path = 'a.txt' } })
check(
  '  and the sentence alone when the report carried no reason',
  said_since(before_reports, 'Could not save a.txt; the file on disk is behind the room') ~= nil,
  true
)
check('  without inventing one', notices[#notices].message:find('()', 1, true) == nil, true)

-- -- a buffer that is not valid UTF-8 -------------------------------------------
--
-- A Neovim buffer is bytes, and a file opened as Latin-1 holds bytes that no UTF-8 sequence
-- can carry. The companion decodes its stdin as UTF-8, so sharing one of those would put
-- U+FFFD in the room where the file has a character, and the bytes would be lost in silence.
-- The buffer is refused instead, by name, and the refusal is remembered so entering it again
-- does not repeat it.

local latin_path = '.tmp/lua-latin1.txt'
local latin_room = vim.fn.fnamemodify(latin_path, ':.')

local function opens_of(room)
  local count = 0
  for _, message in ipairs(sent) do
    if message.type == 'open' and message.path == room then
      count = count + 1
    end
  end
  return count
end

selvage.leave()
vim.cmd('edit! ' .. vim.fn.fnameescape(latin_path))
local latin_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(latin_buf, 0, -1, true, { 'caf\xe9' })
check('the buffer holds the byte, which is the point', vim.api.nvim_buf_get_lines(latin_buf, 0, -1, true)[1]:byte(4), 233)

local before_latin = #notices
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-latin' })
check('a buffer that is not valid UTF-8 is not shared', opens_of(latin_room), 0)

local refusal = nil
for index = before_latin + 1, #notices do
  if notices[index].message:find(latin_room, 1, true) ~= nil then
    refusal = notices[index]
  end
end
check('  and the refusal names it', refusal ~= nil, true)
check('  at error level', refusal and refusal.level, vim.log.levels.ERROR)

local refusals = 0
for _, notice in ipairs(notices) do
  if notice.message:find(latin_room, 1, true) ~= nil then
    refusals = refusals + 1
  end
end
vim.api.nvim_exec_autocmds('BufEnter', { buffer = latin_buf })
check('  said once, however often the buffer is entered', refusals, 1)

-- The refusal is this session's: the next one looks at the buffer again.
selvage.leave()
local before_again = #notices
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-latin-again' })
check('a new session refuses it again', opens_of(latin_room), 0)
check('  and says so again', said_since(before_again, latin_room) ~= nil, true)

-- -- a wiped shared buffer -------------------------------------------------------
--
-- `:bwipeout` on a shared buffer ends the buffer, so the room has to hear that this client no
-- longer holds the path. Nothing said so: the room kept the document for the life of the
-- session, offering edits to a `Document` that answered every one of them `ok = false` until
-- the companion gave up and reported a refusal about a buffer the user had closed.
--
-- The send is on `BufWipeout` and not on the document's own detach, which also fires when the
-- session ends: sending there would put a `close` on the wire for every document
-- `:SelvageLeave` is letting go of.

selvage.leave()
vim.cmd('edit! ' .. path)
local wiped_buf = vim.api.nvim_get_current_buf()
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-wipe' })
check('the buffer is shared before it is wiped', #selvage.documents(), 1)

-- What the window shows next is another `BufEnter`, and this session shares what it is shown:
-- an unnamed buffer is not one it would, so what is asserted below is the wipe.
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
vim.api.nvim_buf_delete(wiped_buf, { force = true })
check('wiping a shared buffer tells the room', last_of('close') and last_of('close').path, path)
check('  and the session no longer holds it', #selvage.documents(), 0)

-- -- a companion the session has let go says nothing -----------------------------
--
-- `:SelvageLeave` sends the `leave` and stops the process without waiting for the round trip
-- that leaving the room takes, so the process writes on its way out: a `status idle` for the
-- `leave`, and another when its stdin closes. A host started in the same event-loop turn makes
-- that trailing idle arrive after the new process has already said `hosting`, and processing it
-- would put the front-end back to idle — the buffers the new room holds unshared while the
-- companion goes on holding it — and an `applyEdit` from the same pipe would be answered on the
-- wrong process. A message is the sender's, and a process this session has let go is not the
-- one it is in.

selvage.leave()
vim.cmd('edit! ' .. path)
local stale_buf = vim.api.nvim_get_current_buf()

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-old' })
local stale = handlers()

selvage.leave()
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-fresh' })
check('the session after a leave is hosting', selvage.session().status, 'hosting')
check('  and holds the buffer it was shown', #selvage.documents(), 1)

stale.on_message({ type = 'status', state = 'idle' })
check('a late idle from the process let go leaves the session alone', selvage.session().status, 'hosting')
check('  and its documents with it', #selvage.documents(), 1)
local before_stale = count_type('change')
vim.api.nvim_buf_set_lines(stale_buf, -1, -1, true, { 'after' })
check('  and a keystroke still reaches the room', count_type('change'), before_stale + 1)


-- The section before this one leaves its session standing, to prove a late message from
-- the process it let go says nothing: a new host on top of it would only reach for the
-- old room's invite, so this one ends it first.
selvage.leave()
-- -- a companion that misspeaks ---------------------------------------------------------
--
-- The companion is the same user's own process, so a misshapen message is a bug rather than
-- an attack — but one answered blindly fails inside the job callback, aborting the message
-- with the follow and go-to retries piggybacked on it. Each arm reads only the fields it
-- needs, a save for an unknown path answers false, and an unknown type is named rather than
-- dropped in silence.

vim.cmd('edit! ' .. path)
local before_shapes_host = #sent
selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-shapes' })
-- The last message is not necessarily the open: reloading the file settles a change the
-- buffer still held through the document the previous session left attached.
local shared_path = nil
for index = #sent, before_shapes_host + 1, -1 do
  if sent[index].type == 'open' then
    shared_path = sent[index].path
    break
  end
end
check('the shape section shares a document to misspeak about', shared_path ~= nil, true)

local before_shapes = #notices
check(
  'presence with cursors of the wrong type draws nothing and fails nothing',
  pcall(handlers().on_message, { type = 'presence', cursors = 'x' }),
  true
)
check(
  '  and a cursor entry of the wrong type is skipped where it stands',
  pcall(handlers().on_message, { type = 'presence', cursors = { 7 } }),
  true
)
check(
  '  and a held-path entry with offsets of the wrong type is skipped too',
  pcall(handlers().on_message, {
    type = 'presence',
    cursors = {
      { peerId = 'p-bad', label = 'Bad', path = shared_path, anchor = 'x' },
      { peerId = 'p-worse', label = 'Worse', path = shared_path, anchor = 0 },
    },
  }),
  true
)
check(
  '  and the next well-shaped presence still draws',
  pcall(handlers().on_message, { type = 'presence', cursors = {} }),
  true
)

local before_save = #sent
check(
  'a save for a path this session holds nothing for answers false',
  pcall(handlers().on_message, { type = 'save', id = 77, path = 'never-shared.txt' }),
  true
)
check('  answering the save the companion asked for', sent[before_save + 1].type, 'saved')
check('  with the refusal', sent[before_save + 1].ok, false)
check(
  '  and a save with no path at all answers false too',
  pcall(handlers().on_message, { type = 'save', id = 78 }),
  true
)
check('  with the refusal', sent[before_save + 2].ok, false)

local before_edit = #sent
check(
  'an edit with offsets of the wrong type is answered, not applied',
  pcall(handlers().on_message, {
    type = 'applyEdit',
    id = 79,
    path = shared_path,
    start = 'x',
    ['end'] = 1,
    text = 'z',
    version = 0,
  }),
  true
)
check('  answering the edit the companion asked for', sent[before_edit + 1].type, 'applied')
check('  with the refusal', sent[before_edit + 1].ok, false)

check(
  'an unknown type is named rather than dropped in silence',
  pcall(handlers().on_message, { type = 'frobnicate' }),
  true
)
check(
  '  naming the type',
  said_since(before_shapes, 'Unknown message type from the companion: frobnicate.') ~= nil,
  true
)
local before_second = #notices
handlers().on_message({ type = 'frobnicate' })
check('  once per type, not once per message', said_since(before_second, 'Unknown message type') ~= nil, false)
check(
  'a message with no table to read a type off is said and dropped',
  pcall(handlers().on_message, 7),
  true
)
check(
  '  as unreadable',
  said_since(before_shapes, 'Unreadable message from the companion.') ~= nil,
  true
)
check(
  'a report that is not a table is said and dropped',
  pcall(handlers().on_message, { type = 'report' }),
  true
)
check(
  'a status that is not a word leaves the session standing',
  pcall(handlers().on_message, { type = 'status', state = 7 }),
  true
)
check('  still hosting afterwards', selvage.session().status, 'hosting')
selvage.leave()

-- -- presence redraws only what moved -----------------------------------------------------
--
-- Every report recreated every caret's highlight, at a highlight set per cursor per report.
-- A report that moves no colour, fill or background sets nothing now; one that moves a
-- colour repaints.

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-paint' })
local paint_path = nil
for index = #sent, 1, -1 do
  if sent[index].type == 'open' then
    paint_path = sent[index].path
    break
  end
end
check('the repaint section shares a document to draw in', paint_path ~= nil, true)

local hl_sets = 0
local real_set_hl = vim.api.nvim_set_hl
vim.api.nvim_set_hl = function(...)
  hl_sets = hl_sets + 1
  return real_set_hl(...)
end
local paint_cursor = {
  peerId = 'p-paint',
  label = 'Paint',
  path = paint_path,
  anchor = 0,
  head = 0,
  colour = '#61afef',
  fill = '#61afef40',
}
handlers().on_message({ type = 'presence', cursors = { paint_cursor } })
local sets_after_first = hl_sets
check('the first report paints', sets_after_first > 0, true)
handlers().on_message({ type = 'presence', cursors = { paint_cursor } })
check('a report that changed nothing sets no highlight', hl_sets, sets_after_first)
paint_cursor.colour = '#98c379'
handlers().on_message({ type = 'presence', cursors = { paint_cursor } })
check('  while a colour that moved repaints', hl_sets > sets_after_first, true)
-- A selection to fill, so the fill has something to lose: caret-only reports never call it.
paint_cursor.anchor = 0
paint_cursor.head = 3
handlers().on_message({ type = 'presence', cursors = { paint_cursor } })
local paint_ns = vim.api.nvim_get_namespaces()['selvage.presence']
local fill_name = nil
for _, mark in ipairs(
  vim.api.nvim_buf_get_extmarks(vim.api.nvim_get_current_buf(), paint_ns, 0, -1, { details = true })
) do
  if mark[4].end_row ~= nil and mark[4].sign_text == nil then
    fill_name = mark[4].hl_group
  end
end
check(
  'the selection is filled',
  fill_name ~= nil and vim.api.nvim_get_hl(0, { name = fill_name }).bg ~= nil,
  true
)
vim.cmd('highlight clear')
check(
  '  until a colorscheme clears it',
  fill_name ~= nil and vim.api.nvim_get_hl(0, { name = fill_name }).bg == nil,
  true
)
vim.api.nvim_exec_autocmds('ColorScheme', {})
check(
  '  and the session repaints it',
  fill_name ~= nil and vim.api.nvim_get_hl(0, { name = fill_name }).bg ~= nil,
  true
)
vim.api.nvim_set_hl = real_set_hl

selvage.leave()

-- The framing drops a line that decoded to no shape before any handler runs: a bare value
-- decodes fine and would fail only when something indexes it, far from the line that caused
-- it.
local real_jobstart = vim.fn.jobstart
vim.fn.jobstart = function()
  return 1
end
local framing = assert(loadfile(vim.fn.getcwd() .. '/lua/selvage/companion.lua'))()
vim.fn.jobstart = real_jobstart
local framed = framing.start({ on_message = function() end, on_exit = function() end }, { 'true' })
check('the framing starts without a companion behind it', framed ~= nil, true)
local received = {}
local function receive(lines)
  framed:receive(lines, function(message)
    received[#received + 1] = message
  end)
end
local before_framing = #notices
receive({ '7\n', '' })
check('a line that decoded to no shape reaches no handler', #received, 0)
check(
  '  and is said the way an undecodable line is',
  said_since(before_framing, 'unreadable message from the companion') ~= nil,
  true
)
receive({ '{"type":"leave"}\n', '' })
check('  while a shaped line still reaches its handler', #received, 1)
check('  naming its type', received[1] and received[1].type, 'leave')

vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
