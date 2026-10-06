-- The two floors this plugin states, and that nothing starts without them.
--
-- The README requires Neovim 0.12 and Node 22.18, and the companion is launched as TypeScript
-- (`companion/main.ts`), so both are a floor rather than advice: `plugin/selvage.lua` says so as
-- the plugin is set up, `selvage.companion` refuses to start a job below either one, and
-- `selvage.health` reports what the machine has. What is pinned here is the comparison itself —
-- the versions are the suite's own, not this machine's — the refusal sentence, the bound on the
-- spawn that reads Node's version, and that the floors the code holds are the ones the README and
-- the npm manifest state.
--
--   nvim --headless -l test/lua/health.lua      (or scripts/test-lua.sh)

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

local versions = require('selvage.versions')

--- A parsed version as text: `==` compares tables by identity, so what a parse holds is compared
--- as what it holds.
local function numbers(version)
  if version == nil then
    return 'nil'
  end
  return ('%d.%d.%d'):format(version.major, version.minor, version.patch)
end

-- -- the plugin says so as it is set up --------------------------------------------------
--
-- Below the Neovim floor nothing in this plugin works, and the plugin is where a person finds
-- that out: the sentence has to be said without the front-end loading. The version this suite
-- runs on is above the floor, so the refusal is handed in rather than waited for.

local notified = {}
local notify = vim.notify
vim.notify = function(message, level)
  notified[#notified + 1] = { message = message, level = level }
end
local below = 'this plugin needs Neovim 99.0 or newer; this is 0.12.5.'
package.loaded['selvage.versions'] = {
  neovim_refusal = function()
    return below
  end,
}
vim.g.loaded_selvage = nil
vim.cmd('runtime! plugin/selvage.lua')
vim.notify = notify
package.loaded['selvage.versions'] = versions

check(
  'the plugin says at setup why this editor cannot run it',
  notified[1] ~= nil and notified[1].message,
  'selvage: ' .. below
)
check('  at the error level', notified[1] ~= nil and notified[1].level, vim.log.levels.ERROR)
check('  and defines its commands anyway', vim.fn.exists(':SelvageHost'), 2)

-- -- reading a version ------------------------------------------------------------------

check('the numbers in a leading v are read', numbers(versions.parse('v22.18.0')), '22.18.0')
check('the numbers in a two-part version are read', numbers(versions.parse('22.18')), '22.18.0')
check('the numbers in a prerelease are read', numbers(versions.parse('0.12.5-dev')), '0.12.5')
check('a text with no version in it reads as none', numbers(versions.parse('node: not found')), 'nil')
check('a text that is not a string reads as none', numbers(versions.parse(nil)), 'nil')

check('a minor below the floor is below it', versions.at_least('0.11.9', '0.12'), false)
check('the floor itself is not below it', versions.at_least('0.12.0', '0.12'), true)
check('a patch above the floor is above it', versions.at_least('0.12.5', '0.12'), true)
check('a major above the floor is above it', versions.at_least('1.0.0', '0.12'), true)
check('a minor below the Node floor is below it', versions.at_least('22.17.9', '22.18'), false)
check('the Node floor itself is not below it', versions.at_least('22.18.0', '22.18'), true)
check('the Node floor is above the last of the major before it', versions.at_least('23.0.0', '22.18'), true)
check("Neovim's own version table is read", versions.at_least(vim.version(), versions.neovim), true)
check('a version that cannot be read is not above the floor', versions.at_least(nil, '0.12'), false)
check(
  'the refusal names what is needed and what was found',
  versions.refusal('Node', '22.18', 'v20.11.0'),
  'this plugin needs Node 22.18 or newer; this is v20.11.0.'
)
check(
  'the missing-node sentence states the floor the code holds',
  versions.no_node(),
  ('node is not on PATH; the companion needs Node %s or newer.'):format(versions.node)
)

-- -- the spawn that reads Node's version ------------------------------------------------
--
-- Bounded, because a `node` that never answers must not hold the editor, and never a traceback:
-- a path that does not run is a sentence the caller can show.

local system = vim.system
local asked = nil
local opts = nil

--- What a `vim.system` call answers with.
local function answers(stdout, code)
  return {
    wait = function()
      return { code = code, stdout = stdout, stderr = '' }
    end,
  }
end

vim.system = function(command, options)
  asked = command
  opts = options
  return answers('v22.18.0\n', 0)
end

local text, why = versions.read_version('/usr/bin/node')
check('the version Node printed is read', text, 'v22.18.0')
check('  and nothing failed', why, nil)
check('  and Node was asked for its version', table.concat(asked or {}, ' '), '/usr/bin/node --version')
check('  with a bound on how long it may take', type(opts ~= nil and opts.timeout), 'number')
check('  and its output read as text', opts ~= nil and opts.text, true)

vim.system = function()
  return answers('node: not found\nbut 22.18.0 is here\n', 0)
end
text, why = versions.read_version('/usr/bin/node')
check('an answer with more than one line is read up to the first', text, 'node: not found')
check(
  '  and no version the later lines carry is believed',
  versions.node_refusal('/usr/bin/node'),
  'this plugin needs Node 22.18 or newer; this is node: not found.'
)

vim.system = function()
  return answers('', 0)
end
text, why = versions.read_version('/usr/bin/node')
check('a Node that answered nothing is not a version', text, nil)
check('  and says so', why ~= nil and why:find('answered nothing', 1, true) ~= nil, true)

vim.system = function()
  return answers('', 124)
end
text, why = versions.read_version('/usr/bin/node')
check('a Node that had to be killed is not a version', text, nil)
check('  and says so', why ~= nil and why:find('did not answer (exit 124)', 1, true) ~= nil, true)

vim.system = function()
  error('ENOENT: no such file or directory')
end
text, why = versions.read_version('/nowhere/node')
check('a Node that cannot be run is not a version', text, nil)
check('  and says so', why ~= nil and why:find('could not be run', 1, true) ~= nil, true)

vim.system = function()
  return answers('v22.17.9\n', 0)
end
check(
  'a Node below the floor is refused',
  versions.node_refusal('/usr/bin/node'),
  'this plugin needs Node 22.18 or newer; this is v22.17.9.'
)
vim.system = function()
  return answers('v22.18.0\n', 0)
end
check('a Node at the floor is not refused', versions.node_refusal('/usr/bin/node'), nil)
vim.system = function()
  return answers('v23.1.0\n', 0)
end
check('a Node above the floor is not refused', versions.node_refusal('/usr/bin/node'), nil)
vim.system = function()
  return answers('node: something else entirely\n', 0)
end
check(
  'an answer with no version in it is refused rather than believed',
  versions.node_refusal('/usr/bin/node'),
  'this plugin needs Node 22.18 or newer; this is node: something else entirely.'
)

-- -- no job is started below a floor ----------------------------------------------------

local exepath = vim.fn.exepath
local filereadable = vim.fn.filereadable
local jobstart = vim.fn.jobstart
local version = vim.version
local started = {}

vim.fn.exepath = function()
  return '/usr/bin/node'
end
vim.fn.filereadable = function()
  return 1
end
vim.fn.jobstart = function(argv)
  started[#started + 1] = argv
  return 1
end

local companion = require('selvage.companion')
local handlers = { on_message = function() end, on_exit = function() end }

vim.system = function()
  return answers('v22.17.9\n', 0)
end
local process, refusal = companion.start(handlers)
check('a companion below the Node floor is not started', process, nil)
check(
  '  and is refused with the version that was found',
  refusal,
  'this plugin needs Node 22.18 or newer; this is v22.17.9.'
)
check('  and no job was started', #started, 0)

vim.system = function()
  return answers('', 124)
end
process, refusal = companion.start(handlers)
check('a Node that does not answer is not started either', process, nil)
check(
  '  and the reason is the one the probe gave',
  refusal ~= nil and refusal:find('did not answer', 1, true) ~= nil,
  true
)
check('  and no job was started for it', #started, 0)

vim.system = function()
  return answers('v22.18.0\n', 0)
end
vim.fn.exepath = function()
  return ''
end
process, refusal = companion.start(handlers)
check('a machine with no Node is not started on', process, nil)
check('  and is refused in the words the health check uses too', refusal, versions.no_node())
check('  and no job was started without one', #started, 0)

vim.fn.exepath = function()
  return '/usr/bin/node'
end
vim.version = function()
  return { major = 0, minor = 11, patch = 4 }
end
process, refusal = companion.start(handlers)
check('a companion under an editor below the floor is not started', process, nil)
check(
  '  and is refused with both versions',
  refusal,
  'this plugin needs Neovim 0.12 or newer; this is 0.11.4.'
)
check('  and no job was started under it', #started, 0)
vim.version = version

vim.system = function()
  return answers('v22.18.0\n', 0)
end
process, refusal = companion.start(handlers)
check('a companion that may run is started', process ~= nil, true)
check('  with nothing refused', refusal, nil)
check('  and one job started', #started, 1)
check('  and it is the Node that was read', started[1] ~= nil and started[1][1], '/usr/bin/node')

vim.fn.exepath = exepath
vim.fn.filereadable = filereadable
vim.fn.jobstart = jobstart
vim.system = system

-- -- the report `:checkhealth selvage` shows -------------------------------------------
--
-- The Node the report reads is this machine's, and a build sandbox has none: the path it would
-- be at is handed in, so what is asserted below is the report rather than where the suite runs.

local reported = {}
local health = vim.health
vim.health = {
  start = function(name)
    reported[#reported + 1] = 'start ' .. name
  end,
  ok = function(message)
    reported[#reported + 1] = 'ok ' .. message
  end,
  warn = function(message)
    reported[#reported + 1] = 'warn ' .. message
  end,
  error = function(message)
    reported[#reported + 1] = 'error ' .. message
  end,
}
vim.system = function()
  return answers('v20.11.0\n', 0)
end
vim.fn.exepath = function()
  return '/usr/bin/node'
end

require('selvage.health').check()

vim.health = health
vim.system = system
vim.fn.exepath = exepath

check('the report starts under the plugin\'s name', reported[1], 'start selvage')
check(
  "the editor's own version is reported against the floor",
  reported[2] ~= nil and reported[2]:match('^ok Neovim %d+%.%d+%.%d+ meets the floor of 0%.12%.$') ~= nil,
  true
)
check(
  'and a Node below it is one of the errors',
  reported[3],
  'error this plugin needs Node 22.18 or newer; this is v20.11.0.'
)

-- -- the floors have one home ------------------------------------------------------------
--
-- The code holds them, and the two places a reader meets them say the same: the README's
-- requirement list and the npm manifest's `engines`, which is what `npm ci` refuses on. Both
-- reads are asserted to have reached a file, because a sentence that is not there at all would
-- make the comparison pass on nil.

local readme = table.concat(vim.fn.readfile('README.md'), '\n')
check('the pin reads the README', #readme > 0, true)
check(
  'the README states the Neovim floor the code holds',
  readme:find('Neovim ' .. versions.neovim .. ' or newer', 1, true) ~= nil,
  true
)
check(
  'the README states the Node floor the code holds',
  readme:find('Node ' .. versions.node .. ' or newer', 1, true) ~= nil,
  true
)

local manifest = vim.json.decode(table.concat(vim.fn.readfile('package.json'), '\n'))
check('the pin reads the npm manifest', type(manifest.engines) == 'table', true)
check('the npm manifest holds the Node floor the code holds', manifest.engines.node, '>=' .. versions.node)

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
