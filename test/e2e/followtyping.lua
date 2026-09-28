-- Typing ends a follow, between two real editors in one real room.
--
--   SELVAGE_SELVAGED=/path/to/selvaged nvim --headless -l test/e2e/followtyping.lua
--   (or scripts/e2e/run-two-instance.sh, which runs it after the main proof)
--
-- Ada hosts and Grace joins, each a Neovim whose event loop turns (driven over RPC, as
-- `test/lua/followloop.lua` drives one) with the real plugin and its real companion, over a real
-- `selvaged`. Ada runs `:SelvageFollow Grace` and types in the window the follow landed in. The
-- follow has to end saying why, the keystroke has to reach Grace, and the two copies have to
-- agree. Every wait is on the effect, with a deadline
-- that reports what it saw.

local root = vim.fn.getcwd()
local failures = 0
local DEADLINE = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '20000')

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local run = root .. '/.tmp/e2e-followtyping'
vim.fn.delete(run, 'rf')
vim.fn.mkdir(run, 'p')

--- The server binary: `SELVAGE_SELVAGED`, or one built in the sibling `reference_server`.
local function selvaged_binary()
  local named = vim.env.SELVAGE_SELVAGED
  if named ~= nil and named ~= '' then
    return named
  end
  for _, profile in ipairs({ 'debug', 'release' }) do
    local candidate = vim.fs.normalize(root .. '/../reference_server/target/' .. profile .. '/selvaged')
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local children = {}
local server

local function finish()
  for _, chan in ipairs(children) do
    pcall(vim.rpcnotify, chan, 'nvim_command', 'qall!')
  end
  if #children > 0 then
    vim.fn.jobwait(children, 5000)
  end
  for _, chan in ipairs(children) do
    pcall(vim.fn.jobstop, chan)
  end
  if server ~= nil then
    server:kill('sigterm')
    pcall(server.wait, server, 5000)
  end
  print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
  os.exit(failures == 0 and 0 or 1)
end

local binary = selvaged_binary()
if binary == nil then
  print('FAIL no selvaged: set SELVAGE_SELVAGED or build ../reference_server')
  failures = failures + 1
  finish()
end

local address
server = vim.system({ binary, '--listen', '127.0.0.1:0' }, {
  stdout = function(_, data)
    address = address or (data and data:match('ws://([0-9.]+:[0-9]+)/session'))
  end,
})
check('the server says where it listens', vim.wait(10000, function()
  return address ~= nil
end, 20), true)
if address == nil then
  finish()
end

--- One editor with its own home, clipboard and temporary directory, loading this checkout.
local function editor(name)
  local home = run .. '/' .. name
  for _, dir in ipairs({ 'work', 'config', 'data', 'state', 'cache', 'tmp' }) do
    vim.fn.mkdir(home .. '/' .. dir, 'p')
  end
  local chan = vim.fn.jobstart({ 'nvim', '--clean', '--embed', '--headless', '-i', 'NONE', '-n' }, {
    rpc = true,
    cwd = home .. '/work',
    env = {
      XDG_CONFIG_HOME = home .. '/config',
      XDG_DATA_HOME = home .. '/data',
      XDG_STATE_HOME = home .. '/state',
      XDG_CACHE_HOME = home .. '/cache',
      TMPDIR = home .. '/tmp',
    },
  })
  children[#children + 1] = chan
  vim.rpcrequest(
    chan,
    'nvim_exec_lua',
    [[
      local root, name = ...
      vim.opt.runtimepath:prepend(root)
      vim.cmd('runtime! plugin/selvage.lua')
      vim.g.selvage_display_name = name
      _G.notices = {}
      local original = vim.notify
      vim.notify = function(message, level, opts)
        table.insert(_G.notices, { message = message, level = level })
        return original(message, level, opts)
      end
    ]],
    { root, name }
  )
  return function(code, ...)
    return vim.rpcrequest(chan, 'nvim_exec_lua', code, { ... })
  end,
    chan,
    home
end

--- Waits until `ask()` answers true, and says what it last answered when it never does.
local function reach(label, ask)
  local last
  local ok = vim.wait(DEADLINE, function()
    last = ask()
    return last == true
  end, 50)
  check(label, ok and true or last, true)
  return ok
end

--- The two editors, the room between them, and the keystroke.
local function main()
  local ada, ada_chan, ada_home = editor('Ada')
  local grace = editor('Grace')

  vim.fn.writefile({ '-- a file the host shares', 'local x = 1', 'print(x)', 'print(x + 1)' }, ada_home .. '/work/hello.lua')
  ada([[vim.cmd('edit hello.lua'); require('selvage').host(...)]], 'ws://' .. address)
  local invite
  reach('Ada hosts a room', function()
    invite = ada([[return require('selvage').session().invite]])
    return invite ~= vim.NIL and invite ~= nil or 'no invite yet'
  end)

  grace([[require('selvage').join(...)]], invite)
  reach('Grace joins it and has the file', function()
    return grace([[
      local session = require('selvage').session()
      local text = require('selvage').text('hello.lua')
      if session.status ~= 'joined' or text == nil then
        return session.status .. ' ' .. vim.inspect(text)
      end
      local name = vim.api.nvim_buf_get_name(0)
      return name:sub(-#'hello.lua') == 'hello.lua' or name
    ]])
  end)

  reach('  and its text in her window', function()
    local lines = grace([[return vim.api.nvim_buf_line_count(0)]])
    return lines == 4 or lines
  end)
  -- Grace's caret on `print(x)`, where the follow lands.
  grace([[vim.api.nvim_win_set_cursor(0, { 3, 2 })]])
  reach('Ada sees where Grace is', function()
    return ada([[
      for _, person in ipairs(require('selvage').room().people) do
        if person.label == 'Grace' then
          return person.path == 'hello.lua' or vim.inspect(person.path)
        end
      end
      return 'no Grace in the room'
    ]])
  end)

  ada([[vim.v.errmsg = '']])
  vim.rpcrequest(ada_chan, 'nvim_input', ':SelvageFollow Grace<CR>')
  reach(':SelvageFollow Grace follows her', function()
    return ada([[return require('selvage').following() == 'Grace']])
  end)
  reach('  landing on her caret', function()
    return ada([[
      local here = table.concat(vim.api.nvim_win_get_cursor(0), ',')
      return here == '3,2' or here
    ]])
  end)

  local said = ada('return #_G.notices')
  vim.rpcrequest(ada_chan, 'nvim_input', 'ix<Esc>')
  reach('typing there ends the follow', function()
    return ada([[return require('selvage').following() == nil and vim.fn.mode() == 'n']])
  end)
  reach('  saying why', function()
    return ada(
      [[
        local from = ...
        for index = from + 1, #_G.notices do
          local notice = _G.notices[index]
          if notice.message:find('Stopped following', 1, true) then
            return (notice.message == 'selvage: Stopped following Grace because you started typing.'
              and notice.level == vim.log.levels.INFO) or vim.inspect(notice)
          end
        end
        return 'nothing said'
      ]],
      said
    )
  end)
  check('  with no error on the way', ada([[return vim.v.errmsg]]), '')
  check('Ada holds the keystroke', ada([[return vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] ]]), 'prxint(x)')
  reach('Grace receives it', function()
    local line = grace([[return vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] ]])
    return line == 'prxint(x)' or line
  end)
  reach('the two copies agree', function()
    local ours = ada([[return require('selvage').text('hello.lua')]])
    local theirs = grace([[return require('selvage').text('hello.lua')]])
    return ours == theirs or ('Ada ' .. vim.inspect(ours) .. ' / Grace ' .. vim.inspect(theirs))
  end)

end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  check('the run stopped on an error', err, nil)
end
finish()
