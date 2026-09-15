-- The companion starts without Node's own warnings on stderr.
--
--   nvim --headless -l test/lua/warnings.lua      (or scripts/test-lua.sh)
--
-- Starting the companion prints Node's `ExperimentalWarning: localStorage is not available`
-- on stderr, which the front-end forwarder would show as a `selvage: ` warning at join time.
-- The spawn passes `--no-warnings`, so that line never reaches the forwarder. What is pinned
-- here is the spawn itself: the flag between the Node binary and the entrypoint.

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

local companion = require('selvage.companion')

local seen = nil
local exepath = vim.fn.exepath
local filereadable = vim.fn.filereadable
local jobstart = vim.fn.jobstart
vim.fn.exepath = function(_)
  return '/usr/bin/node'
end
vim.fn.filereadable = function(_)
  return 1
end
vim.fn.jobstart = function(argv, _)
  seen = argv
  return 1
end

local process, err = companion.start({
  on_message = function() end,
  on_exit = function() end,
})

vim.fn.exepath = exepath
vim.fn.filereadable = filereadable
vim.fn.jobstart = jobstart

check('the companion starts', process ~= nil, true)
check('  and starts without an error', err, nil)
check('  and Node runs without its own warnings', seen ~= nil and seen[2], '--no-warnings')
local entry = seen ~= nil and seen[#seen] or nil
check('  and still runs the companion entrypoint', entry ~= nil and entry:sub(-#'/companion/main.ts') or nil, '/companion/main.ts')

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
