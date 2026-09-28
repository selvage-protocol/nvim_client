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

local chan = vim.fn.jobstart({ 'nvim', '--clean', '--embed', '--headless', '-i', 'NONE', '-n' }, {
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
    -- A notifier that draws its message in a float, as nvim-notify and noice do: opening a
    -- window is what Neovim refuses inside a buffer's change callback.
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { relative = 'editor', row = 0, col = 0, width = 1, height = 1 })
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  _G.sent = {}
  local handlers
  package.loaded['selvage.companion'] = {
    start = function(given)
      handlers = given
      return {
        send = function(_, message)
          table.insert(_G.sent, message)
        end,
        stop = function() end,
      }
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

-- -- typing ends a follow ----------------------------------------------------------------
--
-- A follow lands in the file, so the next thing a person does is type there. The keystroke's
-- change arrives inside the buffer's own change callback, where Neovim refuses to open a window:
-- the notifier's float is drawn after it, not inside it.

--- Waits for `code` to answer true in the second editor, and answers whether it did.
local function until_child(code)
  return vim.wait(5000, function()
    return child(code) == true
  end, 20)
end

child([[
  vim.v.errmsg = ''
  _G.sent = {}
]])
child(
  [[
  local path = ...
  _G.deliver({ type = 'presence', cursors = { {
    peerId = 'p-ada', label = 'Ada', role = 'guest', path = path,
    anchor = 13, head = 13, colour = '#94e2d5', fill = '#94e2d540',
  } } })
]],
  path
)
vim.rpcrequest(chan, 'nvim_input', ':SelvageFollow Ada<CR>')
check('following them', until_child([[return require('selvage').following() == 'Ada']]), true)
check('  lands on their caret', child([[return table.concat(vim.api.nvim_win_get_cursor(0), ',')]]), '3,2')
local said_before_typing = child('return #_G.notices')
vim.rpcrequest(chan, 'nvim_input', 'ix<Esc>')
check(
  'typing there ends the follow',
  until_child([[return require('selvage').following() == nil and vim.fn.mode() == 'n']]),
  true
)
check(
  '  saying why, once',
  until_child(([[
    local said = {}
    for index = %d + 1, #_G.notices do
      said[#said + 1] = _G.notices[index]
    end
    return #said == 1
      and said[1].message == 'selvage: Stopped following Ada because you started typing.'
      and said[1].level == vim.log.levels.INFO
  ]]):format(said_before_typing)),
  true
)
check(
  '  and the edit goes to the room',
  child([[
    for _, message in ipairs(_G.sent) do
      if message.type == 'change' and message.text == 'x' then
        return true
      end
    end
    return vim.inspect(_G.sent)
  ]]),
  true
)
check('  with the line as it was typed', child([[return vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] ]]), 'gaxmma')
check(
  '  and no error on the way',
  child([[return vim.v.errmsg .. (vim.fn.execute('messages'):match('E%d+[^\n]*') or '')]]),
  ''
)

vim.fn.jobstop(chan)
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
