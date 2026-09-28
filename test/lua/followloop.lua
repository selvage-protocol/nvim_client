-- The follow in an editor whose event loop runs, against a stubbed companion.
--
--   nvim --headless -l test/lua/followloop.lua      (or scripts/test-lua.sh)
--
-- A script run with `-l` never returns to Neovim's main loop, and that loop is where a moved
-- caret fires `CursorMoved`: after the call that moved it, not inside it. `test/lua/follow.lua`
-- cannot see that event, so this file drives a second Neovim over RPC, whose loop turns between
-- every request the way a person's editor does. Every wait is on the effect with a deadline.

local root = vim.fn.getcwd()
local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

vim.fn.mkdir(root .. '/.tmp', 'p')
local file = root .. '/.tmp/lua-followloop.txt'
vim.fn.writefile({ 'alpha', 'beta', 'gamma', 'delta' }, file)

local chan = vim.fn.jobstart({ 'nvim', '--clean', '--embed', '--headless', '-i', 'NONE' }, {
  rpc = true,
  cwd = root,
})
check('the second editor started', chan > 0, true)

local function child(code, ...)
  return vim.rpcrequest(chan, 'nvim_exec_lua', code, { ... })
end

child(
  [[
  local root, file = ...
  vim.opt.runtimepath:prepend(root)
  vim.cmd('runtime! plugin/selvage.lua')
  vim.g.selvage_display_name = 'Test User'
  _G.notices = {}
  vim.notify = function(message, level)
    table.insert(_G.notices, { message = message, level = level })
  end
  local handlers
  package.loaded['selvage.companion'] = {
    start = function(given)
      handlers = given
      return { send = function() end, stop = function() end }
    end,
  }
  _G.deliver = function(message)
    handlers.on_message(message)
  end
  _G.moves = 0
  vim.api.nvim_create_autocmd('CursorMoved', {
    callback = function()
      _G.moves = _G.moves + 1
    end,
  })
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  require('selvage').host('ws://127.0.0.1:1')
  _G.deliver({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-loop' })
]],
  root,
  file
)

local path = child([[return require('selvage').documents()[1] ]])
check('the file is shared', type(path), 'string')

child(
  [[
  local path = ...
  _G.deliver({ type = 'report', report = { kind = 'peers', peers = {
    { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  } } })
  -- Offset 13 is the `m` in `gamma`: row 3, byte column 2.
  _G.deliver({ type = 'presence', cursors = { {
    peerId = 'p-ada', label = 'Ada', role = 'guest', path = path,
    anchor = 13, head = 13, colour = '#94e2d5', fill = '#94e2d540',
  } } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
]],
  path
)

--- Waits until the second editor's loop has fired `CursorMoved` more than `seen` times, and
--- answers how many it has fired, or nil at the deadline.
local function moved_past(seen)
  local count
  local fired = vim.wait(5000, function()
    count = child('return _G.moves')
    return count > seen
  end, 20)
  return fired and count or nil
end

local before = child('return _G.moves')
child([[require('selvage').follow('Ada')]])
check('the follow lands on the caret', child([[return table.concat(vim.api.nvim_win_get_cursor(0), ',')]]), '3,2')
check('the landing moved the caret, and the loop said so', moved_past(before) ~= nil, true)
check('the follow stands after the loop has turned', child([[return require('selvage').following()]]), 'Ada')
check(
  '  and no sentence said it ended',
  child([[
    for _, notice in ipairs(_G.notices) do
      if notice.message:find('Stopped following', 1, true) then
        return notice.message
      end
    end
    return nil
  ]]),
  vim.NIL
)

-- The next frame moves Ada, and the landing it makes is the follow's too.
local before_frame = child('return _G.moves')
child(
  [[
  local path = ...
  _G.deliver({ type = 'presence', cursors = { {
    peerId = 'p-ada', label = 'Ada', role = 'guest', path = path,
    anchor = 7, head = 7, colour = '#94e2d5', fill = '#94e2d540',
  } } })
]],
  path
)
check('a new frame lands again', child([[return table.concat(vim.api.nvim_win_get_cursor(0), ',')]]), '2,1')
check('  and the loop said so', moved_past(before_frame) ~= nil, true)
check('  and the follow still stands', child([[return require('selvage').following()]]), 'Ada')

-- A move the person makes is not the follow's, and it ends the follow.
local before_move = child('return _G.moves')
vim.rpcrequest(chan, 'nvim_input', 'G')
check('the person moving is seen by the loop', moved_past(before_move) ~= nil, true)
check('  and ends the follow', child([[return require('selvage').following()]]), vim.NIL)
check(
  '  saying so',
  child([[
    for _, notice in ipairs(_G.notices) do
      if notice.message:find('Stopped following', 1, true) then
        return notice.message:find('Stopped following Ada', 1, true) ~= nil
      end
    end
    return nil
  ]]),
  true
)

vim.fn.jobstop(chan)
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
