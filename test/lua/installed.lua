-- The plugin as an installed package: one real Neovim, the plugin on the runtime path from
-- wherever it was installed, and the real companion process — no stub and no `command`.
--
--   SELVAGE_PLUGIN_ROOT=/path/to/nvim_client nvim --headless -l test/lua/installed.lua
--
-- Run by the flake's `plugin` check against `packages.<system>.default` — the plugin built out
-- of the store, in the wrapped Neovim that `packages.<system>.neovim-selvage` is — and by
-- `scripts/test-lua.sh` against a checkout: the check names the store's path, the script the
-- checkout's. What it can fail on is the packaging: the plugin
-- reaching the runtime path from where it was installed, the companion's entry point beside it,
-- and its imports (`yjs`, `ws`, `y-protocols`, `lib0`) resolving from the `node_modules` the
-- package carries. The other files in this directory cover behaviour; this one covers the
-- package being there at all.
--
-- `SELVAGE_PLUGIN_ROOT` is the directory the plugin is expected to have loaded from. The two are
-- compared rather than assumed equal (`test/lua/*.lua` find the plugin through the directory they
-- are run from, so a check is otherwise unable to tell a checkout from a built package), and it
-- is resolved through the package's own symlinks: a pack directory is a link, and the path the
-- runtime path carries is the link rather than the package.

local failures = 0

--- Counts one assertion, and the failures down to the exit code at the end of the file.
--- @param name string what was asserted, in the negative
--- @param got any what it was
--- @param want any what it should have been
local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- The directory this plugin's `lua/selvage/companion.lua` resolves to, or nil and why not.
local function loaded_root()
  local found = vim.api.nvim_get_runtime_file('lua/selvage/companion.lua', true)
  if #found == 0 then
    return nil, 'lua/selvage/companion.lua is on no runtime path'
  end
  local here = vim.uv.fs_realpath(found[1])
  if here == nil then
    return nil, 'the file Neovim loaded does not resolve: ' .. found[1]
  end
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
end

local expected = vim.env.SELVAGE_PLUGIN_ROOT
if expected == nil or expected == '' then
  print('FAIL SELVAGE_PLUGIN_ROOT is not set: name the directory the plugin is installed in')
  os.exit(1)
end
expected = vim.uv.fs_realpath(expected) or expected

-- The plugin is already on the runtime path when it is installed — a package manager's pack
-- directory, a plugin manager's own root — and then nothing is added here. With none there, the
-- directory the caller names is the plugin, which is how this runs from a checkout.
if #vim.api.nvim_get_runtime_file('lua/selvage/companion.lua', false) == 0 then
  vim.opt.runtimepath:prepend(expected)
end

local companion = require('selvage.companion')

local root, why = loaded_root()
print('plugin root: ' .. tostring(root))
if root == nil then
  print('FAIL ' .. why)
  os.exit(1)
end
check('the plugin loaded from the directory the caller names', root, expected)
if root ~= expected then
  -- Everything below is asserted about the plugin Neovim loaded, and the check above is the one
  -- line that says which plugin that is. A host with another installation on its runtime path — a
  -- pack, a plugin manager's root — would otherwise have the rest of this file report the other
  -- installation's files as this checkout's, which is evidence about neither of them.
  print('FAIL stopping here: the rest of this file would be about ' .. tostring(root))
  print('FAILED')
  os.exit(1)
end

-- The rest of the package, from the same place: one that ships `lua/` and forgets `plugin/`
-- installs cleanly and does nothing.
local commands = vim.api.nvim_get_runtime_file('plugin/selvage.lua', false)[1]
check(
  '  and its commands came with it',
  commands ~= nil and vim.uv.fs_realpath(commands),
  root .. '/plugin/selvage.lua'
)
-- A no-op when Neovim loaded the plugin at startup, which is what a `start` package does; the
-- source that defines them when this runs from a checkout instead.
vim.cmd('runtime! plugin/selvage.lua')
check('  and they are defined', vim.fn.exists(':SelvageHost'), 2)

for _, module in ipairs({ 'selvage', 'selvage.companion', 'selvage.document', 'selvage.mirror', 'selvage.utf16' }) do
  local ok, loaded = pcall(require, module)
  check(('  %s loads from there'):format(module), ok, true)
end

-- The companion's imports resolve from the `node_modules` beside it. Named one by one rather
-- than left to the process below, because the failure worth catching by name — a package that
-- installs `lua/` and leaves the companion unable to start — is exactly a directory missing
-- here, and the process would report it as nothing arriving at all.
for _, package in ipairs({ 'yjs', 'y-protocols', 'ws', 'lib0' }) do
  check(
    ('  node_modules/%s is beside it'):format(package),
    vim.fn.isdirectory(root .. '/node_modules/' .. package),
    1
  )
end

local messages = {}
local exits = {}
local process, err = companion.start({
  on_message = function(message)
    messages[#messages + 1] = message
  end,
  on_exit = function(code)
    exits[#exits + 1] = code
  end,
})

if process == nil then
  print('FAIL the companion did not start: ' .. tostring(err))
  os.exit(1)
end

--- The statuses heard so far, in the order they arrived.
local function statuses()
  local found = {}
  for _, message in ipairs(messages) do
    if message.type == 'status' then
      found[#found + 1] = message
    end
  end
  return found
end

-- An invite that is not one, so that the answer comes from the engine rather than from a server:
-- a reply means the process started, the vendored engine loaded, and the protocol refused the
-- paste locally. A process that could not load its imports answers nothing at all, and this
-- fails on the deadline with what it did hear.
process:send({ type = 'join', invite = 'not an invite' })

local answered = vim.wait(10000, function()
  for _, status in ipairs(statuses()) do
    if status.state == 'error' then
      return true
    end
  end
  return false
end, 20)

check('the companion answered a request', answered, true)
if not answered then
  print('  nothing in ten seconds; messages seen: ' .. vim.inspect(messages))
end

local heard = statuses()
check('  it said it was connecting first', heard[1] ~= nil and heard[1].state, 'connecting')
local refusal = heard[2]
check('  and then why it could not', refusal ~= nil and refusal.state, 'error')
check("  carrying the protocol's own code", refusal ~= nil and refusal.code, 'bad_params')
check(
  '  and the engine\'s own words',
  refusal ~= nil and refusal.message,
  'not an invite URL: it has no session address'
)

-- Closing its stdin is what the plugin does on the way out and what the companion reads as
-- "leave the room": a process that answers is one that left on its own, where the code the
-- plugin kills with is not zero.
process:stop()
vim.wait(6000, function()
  return #exits > 0
end)
check('the companion left when its stdin closed', exits[1], 0)

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
