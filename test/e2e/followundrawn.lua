-- Following a peer into a document this window has not opened, between two real editors in one
-- real room.
--
--   SELVAGE_SELVAGED=/path/to/selvaged nvim --headless -l test/e2e/followundrawn.lua
--   (or scripts/e2e/run-two-instance.sh, which runs it after the follow-and-type proof)
--
-- Ada hosts two files and has one of them open; Grace joins and lands in that one. Ada then
-- moves into the other, which is a room document Grace holds nothing for — no buffer, no hold —
-- and Grace follows her there. Nothing in Grace's window holds the document she asks for, so
-- the follow has to open it: a buffer, a hold, and the room's text the hold brings. Her caret
-- lands on Ada's once that text is there. Every wait is on the effect, with a deadline that
-- reports what it saw.

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

local run = root .. '/.tmp/e2e-followundrawn'
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

--- Ends in the suffix `wanted`, or says what the name was instead.
local function named(ask, wanted)
  return function()
    local name = ask()
    if type(name) ~= 'string' then
      return name
    end
    return name:sub(-#wanted) == wanted or name
  end
end

--- The two editors, the room between them, and the follow.
local function main()
  local ada, ada_chan, ada_home = editor('Ada')
  local grace, grace_chan = editor('Grace')

  -- The host's folder: two files, one of them open when the room is minted.
  vim.fn.writefile({ '-- a file the host shares', 'local x = 1', 'print(x)' }, ada_home .. '/work/hello.lua')
  vim.fn.writefile({ 'one', 'two', 'three' }, ada_home .. '/work/notes.txt')

  ada([[vim.cmd('edit hello.lua'); require('selvage').host(...)]], 'ws://' .. address)
  local invite
  reach('Ada hosts a room', function()
    invite = ada([[return require('selvage').session().invite]])
    return invite ~= vim.NIL and invite ~= nil or 'no invite yet'
  end)

  grace([[require('selvage').join(...)]], invite)
  reach('Grace joins it and lands in the room\'s document', named(function()
    return grace([[return vim.api.nvim_buf_get_name(0)]])
  end, 'hello.lua'))
  reach('  with its text in her window', function()
    local lines = grace([[return vim.api.nvim_buf_line_count(0)]])
    return lines == 3 or lines
  end)

  -- Ada moves into the second file. That file joins the room — a buffer and a hold on Ada's
  -- side — and she puts her caret on `three` so a landing has somewhere to be.
  ada([[vim.cmd('edit notes.txt'); vim.api.nvim_win_set_cursor(0, { 3, 0 })]])
  reach('Ada is in a file Grace has not opened, and Grace can see which one', function()
    return grace([[
      for _, person in ipairs(require('selvage').room().people) do
        if person.label == 'Ada' then
          return person.path == 'notes.txt' or vim.inspect(person.path)
        end
      end
      return 'no Ada in the room'
    ]])
  end)
  check('  and Grace holds nothing for it', grace([[return require('selvage').text('notes.txt')]]), vim.NIL)

  grace([[vim.v.errmsg = '']])
  vim.rpcrequest(grace_chan, 'nvim_input', ':SelvageFollow Ada<CR>')
  reach('Grace follows Ada', function()
    return grace([[return require('selvage').following() == 'Ada']])
  end)
  reach('  saying what opening the file costs the room', function()
    return grace([[
      for _, notice in ipairs(_G.notices) do
        if notice.message:find('notes.txt is opened in the room, so every peer receives it.', 1, true) then
          return true
        end
      end
      return 'nothing said'
    ]])
  end)
  reach('  landing in the document she had not opened', named(function()
    return grace([[return vim.api.nvim_buf_get_name(0)]])
  end, 'notes.txt'))
  reach('  on Ada\'s caret', function()
    local here = grace([[return table.concat(vim.api.nvim_win_get_cursor(0), ',')]])
    return here == '3,0' or here
  end)
  reach('  with the room\'s text in it', function()
    local text = grace([[return require('selvage').text('notes.txt')]])
    return text == 'one\ntwo\nthree' or vim.inspect(text)
  end)
  reach('  holding it in the room now', function()
    return grace([[return vim.tbl_contains(require('selvage').session().documents, 'notes.txt')]])
  end)
  reach('Ada sees Grace where she followed', function()
    return ada([[
      for _, person in ipairs(require('selvage').room().people) do
        if person.label == 'Grace' then
          return person.path == 'notes.txt' or vim.inspect(person.path)
        end
      end
      return 'no Grace in the room'
    ]])
  end)
  check('  with no error on the way', grace([[return vim.v.errmsg]]), '')
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  failures = failures + 1
  print('FAIL ' .. tostring(err))
end
finish()
