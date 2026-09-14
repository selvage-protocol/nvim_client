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

vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
