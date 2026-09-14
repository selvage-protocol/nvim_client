-- The plugin's own wiring, against a companion process that is a stub.
--
--   nvim --headless -l test/lua/session.lua      (or scripts/test-lua.sh)
--
-- `test/lua/document.lua` covers the buffer arithmetic in a real buffer; this covers what a
-- session does with that buffer — which of them it shares, and, when the session ends, that it
-- lets them go. A buffer outlives the companion, so a callback left attached to one would keep
-- sending into a process that is no longer there.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

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

vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
