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
  _G.deliver({
    type = 'words',
    words = vim.json.decode(table.concat(vim.fn.readfile(root .. '/test/lua/words.json'), '\n')),
  })
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
        return notice.message
      end
    end
    return nil
  ]]),
  'selvage: Stopped following Ada because you moved.'
)

-- -- the room's panel, in a loop that turns ----------------------------------------------
--
-- The panel is a window of its own, so going into it moves a caret the follow never placed. It is
-- somewhere to look at the room from, not a move away from the person followed, and no landing
-- ever puts a file in it: a file goes in the window beside it.
child([[
  _G.panel_window = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'selvage' then
        return win
      end
    end
    return nil
  end
  _G.file_window = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= 'selvage' then
        return win
      end
    end
    return nil
  end
  _G.file_cursor = function()
    return table.concat(vim.api.nvim_win_get_cursor(_G.file_window()), ',')
  end
  _G.on_row = function(name)
    vim.api.nvim_set_current_win(_G.panel_window())
    for lnum, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return line
      end
    end
  end
  _G.press = function(lhs)
    vim.fn.maparg(lhs, 'n', false, true).callback()
  end
  _G.presence = function(path, cursors)
    local list = {}
    for _, each in ipairs(cursors) do
      list[#list + 1] = {
        peerId = each[1], label = each[2], role = 'guest', path = path,
        anchor = each[3], head = each[3], colour = '#94e2d5', fill = '#94e2d540',
      }
    end
    _G.deliver({ type = 'presence', cursors = list })
  end
]])

local before_refollow = child('return _G.moves')
child([[require('selvage').follow('Ada')]])
moved_past(before_refollow)
local said_before_panel = child('return #_G.notices')
local before_panel = child('return _G.moves')
child([[vim.cmd('SelvagePeers')]])
check('opening the panel moves into it', child('return vim.bo.filetype'), 'selvage')
check('  and the loop sees the caret move there', moved_past(before_panel) ~= nil, true)
check('  and the follow stands', child([[return require('selvage').following()]]), 'Ada')

child([[_G.presence(..., { { 'p-ada', 'Ada', 13 } })]], path)
check('a frame landing while you are in the panel leaves you there', child('return vim.bo.filetype'), 'selvage')
check('  and lands in the window beside it', child('return _G.file_cursor()'), '3,2')

local before_look = child('return _G.moves')
child([[vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })]])
check('moving about the panel is seen by the loop', moved_past(before_look) ~= nil, true)
check('  and leaves the follow standing', child([[return require('selvage').following()]]), 'Ada')
check('the panel marks the person followed', child([[return _G.on_row('Ada')]]):find('◉', 1, true) ~= nil, true)
child([[_G.press('f')]])
check('f on their row stops following', child([[return require('selvage').following()]]), vim.NIL)
check('  and says nothing, as the web does', child('return #_G.notices'), said_before_panel)

-- Bob is in the room and in no file yet: the web offers no Go to on his face, and <CR> on his
-- row does nothing, now or when he opens a file later.
child([[
  _G.deliver({ type = 'report', report = { kind = 'peers', peers = {
    { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
    { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  } } })
]])
local before_bob = child('return _G.moves')
check('someone in no file yet is listed', child([[return _G.on_row('Bob')]]) ~= nil, true)
moved_past(before_bob)
child([[_G.press('<CR>')]])
check('<CR> on them stays in the panel', child('return vim.bo.filetype'), 'selvage')
child([[_G.presence(..., { { 'p-ada', 'Ada', 13 }, { 'p-bob', 'Bob', 18 } })]], path)
check('  and nothing lands when they open a file', child('return _G.file_cursor()'), '3,2')

-- A go-to typed while they were in no file lands when they open one, and while you wait in the
-- panel it lands beside it.
child([[_G.presence(..., { { 'p-ada', 'Ada', 13 } })]], path)
child([[
  vim.api.nvim_set_current_win(_G.file_window())
  require('selvage').go_to('Bob')
  vim.api.nvim_set_current_win(_G.panel_window())
]])
child([[_G.presence(..., { { 'p-ada', 'Ada', 13 }, { 'p-bob', 'Bob', 18 } })]], path)
check('a go-to landing while you are in the panel keeps the panel', child('return _G.panel_window() ~= nil'), true)
check('  and you in it', child('return vim.bo.filetype'), 'selvage')
check('  and lands on them beside it', child('return _G.file_cursor()'), '4,1')

vim.fn.jobstop(chan)
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
