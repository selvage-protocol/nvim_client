-- The pickers ask through `vim.ui.select` and require no external picker.
--
-- `:SelvageOpen`, `:SelvageGoTo` and `:SelvageFollow` choose through the
-- editor's own `vim.ui.select`: whatever the person configured (fzf-lua,
-- telescope-ui-select, dressing.nvim, mini.pick, snacks.nvim) is what opens,
-- and a Neovim with none of those falls back to the builtin numbered list.
-- No fzf integration was ever added here (`git log -S fzf` is empty over
-- `lua/`, `plugin/`, `companion/` and `test/`; the choosers arrived with
-- `vim.ui.select` in 3b4dd0a and 0f196f3), and none may arrive unnoticed:
-- the scan below fails on any fzf reference in the shipped code.
--
-- The functional half runs every chooser with a plain recording stub — the
-- fzf-absent simulation, since this headless Neovim has no picker plugin —
-- and proves each completes without one.
--
--   nvim --headless -l test/lua/pickers.lua      (or scripts/test-lua.sh)

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

-- -- no external picker in the shipped code -----------------------------------------
--
-- The scan reaches what it claims to cover: it fails when it reads nothing.

local code_files = vim.fn.globpath('lua/selvage', '*.lua', false, true)
for _, file in ipairs(vim.fn.globpath('plugin', '*.lua', false, true)) do
  code_files[#code_files + 1] = file
end
check('the scan reaches the shipped code', #code_files >= 6, true)

local fzf_hits = {}
local picker_requires = {}
for _, file in ipairs(code_files) do
  local lines = vim.fn.readfile(file)
  for number, line in ipairs(lines) do
    if line:lower():find('fzf', 1, true) ~= nil then
      fzf_hits[#fzf_hits + 1] = ('%s:%d'):format(file, number)
    end
    if line:find('require%s*%(?%s*[\"\']', 1) ~= nil then
      local module = line:match('require%s*%(?%s*[\"\']([^\"\']+)')
      if
        module ~= nil
        and (
          module:find('telescope', 1, true) ~= nil
          or module:find('dressing', 1, true) ~= nil
          or module:find('mini%.pick', 1, true) ~= nil
          or module:find('snacks', 1, true) ~= nil
        )
      then
        picker_requires[#picker_requires + 1] = ('%s:%d:%s'):format(file, number, module)
      end
    end
  end
end
check('no fzf reference in the shipped code', #fzf_hits == 0, true)
if #fzf_hits > 0 then
  print('  hits: ' .. table.concat(fzf_hits, ', '))
end
check('no external picker required', #picker_requires == 0, true)
if #picker_requires > 0 then
  print('  requires: ' .. table.concat(picker_requires, ', '))
end

-- -- every chooser completes on plain vim.ui.select ----------------------------------
--
-- A guest holding two documents with two peers in the room. The stub records
-- each picker call and answers it the way a person would; nothing external
-- is installed (this Neovim has no picker plugin, which is the point).

local builtin_select = vim.ui.select
local picked = {}
vim.ui.select = function(items, opts, on_choice)
  picked[#picked + 1] = { count = #items, prompt = opts ~= nil and opts.prompt or nil }
  return nil
end

local sent = {}
local handlers = nil
local next_id = 0
local texts = { ['a/one.lua'] = 'one\n', ['a/two.lua'] = 'two\n' }
package.loaded['selvage.companion'] = {
  start = function(given)
    handlers = given
    return {
      send = function(_, message)
        sent[#sent + 1] = message
        if message.type == 'open' and texts[message.path] ~= nil then
          next_id = next_id + 1
          local body = texts[message.path]:gsub('\n$', '')
          handlers.on_message({
            type = 'applyEdit',
            id = next_id,
            path = message.path,
            start = 0,
            ['end'] = #body + 1,
            text = body,
            version = 0,
          })
          next_id = next_id + 1
          handlers.on_message({ type = 'save', id = next_id, path = message.path })
        end
      end,
      stop = function() end,
    }
  end,
}
local function handle(message)
  handlers.on_message(message)
end

local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local selvage = require('selvage')
vim.g.selvage_display_name = 'Test User'

selvage.leave()
selvage.join('ws://127.0.0.1:1/session?room=r-pick&token=t')
handle({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-pick' })
handle({ type = 'report', report = { kind = 'grant', paths = { 'a/one.lua', 'a/two.lua' } } })
handle({ type = 'report', report = { kind = 'documents', documents = { 'a/one.lua', 'a/two.lua' } } })
handle({
  type = 'report',
  report = { kind = 'peers', peers = {
    { peer_id = 'p1', display_name = 'Ada', role = 'guest' },
    { peer_id = 'p2', display_name = 'Bo', role = 'host' },
  } },
})
handle({
  type = 'presence',
  cursors = {
    { peerId = 'p1', label = 'Ada', role = 'guest', path = 'a/one.lua', anchor = 0, head = 0, colour = '#ff0000' },
    { peerId = 'p2', label = 'Bo', role = 'host', path = 'a/two.lua', anchor = 0, head = 0, colour = '#00ff00' },
  },
})
check('two peers in two documents', #selvage.peers(), 2)

-- `:SelvageOpen` with several documents asks through the editor's picker, and
-- the answer opens.
local before_open = #picked
vim.ui.select = function(items, opts, on_choice)
  picked[#picked + 1] = { count = #items, prompt = opts ~= nil and opts.prompt or nil }
  on_choice(items[2])
end
selvage.open()
check('opening asks which document', picked[before_open + 1] ~= nil and picked[before_open + 1].count or nil, 2)
check(
  '  in the editor idiom',
  picked[before_open + 1] ~= nil and picked[before_open + 1].prompt or nil,
  'selvage: open which document?'
)
check('  and the answer opens', vim.api.nvim_buf_get_name(0):find('a/two.lua', 1, true) ~= nil, true)

-- `:SelvageGoTo` with several participants asks the same way, and the answer lands.
local before_go = #picked
vim.ui.select = function(items, opts, on_choice)
  picked[#picked + 1] = { count = #items, prompt = opts ~= nil and opts.prompt or nil }
  for _, row in ipairs(items) do
    if row.peerId == 'p1' then
      on_choice(row)
      return
    end
  end
end
selvage.go_to('')
check('going asks which participant', picked[before_go + 1] ~= nil and picked[before_go + 1].count or nil, 2)
check(
  '  in the editor idiom',
  picked[before_go + 1] ~= nil and picked[before_go + 1].prompt or nil,
  'selvage: go to which participant?'
)
check('  and the answer lands', vim.api.nvim_buf_get_name(0):find('a/one.lua', 1, true) ~= nil, true)

-- `:SelvageFollow` asks the same way, and the answer follows.
local before_follow = #picked
vim.ui.select = function(items, opts, on_choice)
  picked[#picked + 1] = { count = #items, prompt = opts ~= nil and opts.prompt or nil }
  for _, row in ipairs(items) do
    if row.peerId == 'p2' then
      on_choice(row)
      return
    end
  end
end
selvage.follow('')
check('following asks which participant', picked[before_follow + 1] ~= nil and picked[before_follow + 1].count or nil, 2)
check(
  '  in the editor idiom',
  picked[before_follow + 1] ~= nil and picked[before_follow + 1].prompt or nil,
  'selvage: follow which participant?'
)
check('  and the answer follows', selvage.following(), 'Bo')

vim.ui.select = builtin_select
selvage.leave()

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
