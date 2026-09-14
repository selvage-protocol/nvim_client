-- What `:SelvageLeave` does to the companion process, against a real job.
--
--   nvim --headless -l test/lua/leave.lua      (or scripts/test-lua.sh)
--
-- The process is started with a command that ignores its stdin and never exits on its own,
-- which the real companion never does: it reads the closed pipe as "leave the room" and goes.
-- That is the whole point of the wait — a round trip to the server — and the whole point of the
-- bound: the editor must not be held for it, and a process that does not go must still be
-- ended. The companion started for real (a clean leave) is `test/lua/session.lua`'s business and
-- the end-to-end run's.

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

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
