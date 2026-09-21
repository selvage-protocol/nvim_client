-- The companion process: the framing of what it writes, and what `:SelvageLeave` does to it,
-- against a real job.
--
--   nvim --headless -l test/lua/leave.lua      (or scripts/test-lua.sh)
--
-- The process is started with a command that ignores its stdin and never exits on its own,
-- which the real companion never does: it reads the closed pipe as "leave the room" and goes.
-- That is the whole point of the wait — a round trip to the server — and the whole point of the
-- bound: the editor must not be held for it, and a process that does not go must still be
-- ended. The companion started for real (a clean leave) is `test/lua/session.lua`'s business and
-- the end-to-end run's.
--
-- The framing is read off `Companion:receive` directly, with the lists Neovim hands a job's
-- stdout over in: the tail of the line the call before left unfinished first, a whole line for
-- every element before the last, and the next unfinished tail last. A process is started because
-- receiving is a method on the running companion, not because anything here reads its output.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local companion = require('selvage.companion')

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local exits = {}
local process, err = companion.start({
  on_message = function() end,
  on_exit = function(code)
    exits[#exits + 1] = code
  end,
}, { 'sh', '-c', 'sleep 30' })

if process == nil then
  print('FAIL the process did not start: ' .. tostring(err))
  os.exit(1)
end
check('the process is running', vim.fn.jobwait({ process.job }, 0)[1], -1)

local before = vim.fn.reltime()
process:stop()
check(
  'stopping it does not wait for it',
  vim.fn.reltimefloat(vim.fn.reltime(before)) < 1,
  true
)

-- It is given `STOP_GRACE_MS` (two seconds) to leave the room on its own before it is killed.
vim.wait(6000, function()
  return #exits > 0
end)
check('  and a process that does not go is ended', #exits > 0, true)
check('  and its exit is reported to the front-end', type(exits[1]), 'number')

-- -- the framing of what it writes -----------------------------------------------
--
-- One JSON object per line, and a line arrives as chunks: Neovim hands stdout over in pieces of
-- at most 128 KiB, and a whole-document `open` is one line of many pieces. The other mouth of
-- this pipe holds a line to `MAX_IPC_LINE_BYTES` (`companion/ipc.ts`); this one has to hold the
-- same bound, and the pieces of a line have to cost the bytes in the line rather than the square
-- of how many pieces carried it.
local delivered = {}
local function on_message(message)
  delivered[#delivered + 1] = message
end

process:receive({ '{"type":"status","state":"connecting"}' }, on_message)
check('a line that has not ended yet is not delivered', #delivered, 0)
process:receive({ '', '' }, on_message)
check('a line arriving in pieces is delivered once, whole', #delivered, 1)
check('  as the line its pieces spelled', delivered[1].state, 'connecting')

-- A callback carrying a whole line and the next tail: the element before the last is a whole
-- line, and the last is what the next callback continues.
process:receive({ '{"type":"status","state":"idle"}', '{"type":"sta' }, on_message)
check('  and a call carrying two lines delivers the whole one', #delivered, 2)
check('    while the tail it ends with waits', delivered[2].state, 'idle')
process:receive({ 'tus","state":"error"}', '' }, on_message)
check('    until its own newline arrives', delivered[3].state, 'error')

-- The bound: a line as long as it is still a line, and one past it is shed to the newline that
-- ends it rather than collected for as long as the writer keeps going.
local warnings = {}
local reported = vim.notify
vim.notify = function(message, level)
  warnings[#warnings + 1] = { message = message, level = level }
end

local piece = string.rep('x', 131072)
local to_the_bound = 32 * 1024 * 1024 / #piece
for _ = 1, to_the_bound do
  process:receive({ piece }, on_message)
end
check('a line as long as the bound is still collected', #warnings, 0)
process:receive({ piece }, on_message)
check('a line past it is shed', #warnings, 1)
local shed = warnings[1] or {}
check(
  '  saying the bound it passed',
  tostring(shed.message or ''):find('past 33554432 bytes', 1, true) ~= nil,
  true
)
check('  at warning level', shed.level, vim.log.levels.WARN)
local before_the_next = #delivered
process:receive({ '', '' }, on_message)
process:receive({ '{"type":"status","state":"idle"}', '' }, on_message)
check('  and the line after the shed one arrives', #delivered, before_the_next + 1)
check('    as itself', delivered[#delivered].state, 'idle')

-- What the bound and the end of a line cost together: the pieces are joined once, so twice as
-- many pieces past the bound must not cost more than the bound did. A mouth that appended each
-- piece to the line as it came copied every piece before it every time, and four times the work
-- for twice the input is what that looks like. The ratio does not depend on the machine.
local function shed_cost(pieces)
  local best
  for _ = 1, 3 do
    local started = os.clock()
    for _ = 1, pieces do
      process:receive({ piece }, on_message)
    end
    local elapsed = os.clock() - started
    if best == nil or elapsed < best then
      best = elapsed
    end
    -- End the line, so the next round starts a fresh one.
    process:receive({ '', '' }, on_message)
  end
  return best
end

local at_the_bound = shed_cost(to_the_bound + 1)
local twice_the_bound = shed_cost(2 * to_the_bound + 2)
local ratio = twice_the_bound / at_the_bound
if ratio >= 3 then
  print(('     bound=%.4fs 2x=%.4fs ratio=%.2f'):format(at_the_bound, twice_the_bound, ratio))
end
check('twice the pieces past the bound costs no more than the bound alone', ratio < 3, true)

vim.notify = reported

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
