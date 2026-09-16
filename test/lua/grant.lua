-- The grant root: the folder a session was started in is what it shares, and a `:cd` afterwards
-- does not move it.
--
--   nvim --headless -l test/lua/grant.lua      (or scripts/test-lua.sh)
--
-- A buffer's room path is resolved against the folder the session was started in (`DESIGN.md`
-- §4.2). The *working directory* is not that folder: `:cd`, `:lcd` and `:tcd` move it at any
-- moment, so a room whose reach followed it would share a file that was not shareable a moment
-- ago — and stop sharing one that was. This file starts a session in one folder, moves the
-- working directory to another, and asserts the grant did not follow in either direction: the
-- file that was shareable is still shared under its path from the grant, and the one that was
-- not is still not. It also pins that the refusal is said, once per path, rather than left
-- silent, which is indistinguishable from a plugin that is not sharing at all.

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

--- Replaces the companion with one that records what it is asked to send and answers nothing, so
--- a test can say what a session shared without a process on the other end of a pipe.
local function stub_companion()
  local sent = {}
  local handlers = nil
  package.loaded['selvage.companion'] = {
    start = function(given)
      handlers = given
      return {
        send = function(_, message)
          sent[#sent + 1] = message
        end,
        stop = function() end,
      }
    end,
  }
  return sent, function()
    return handlers
  end
end

-- Captured before the session starts: the refusal is a notification, and it is part of what the
-- test asserts.
local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local sent, handlers = stub_companion()
local selvage = require('selvage')
vim.g.selvage_display_name = 'Test User'

--- How many `open`s for `path` were sent since `from`.
local function opens_of(path, from)
  local count = 0
  for index = (from or 0) + 1, #sent do
    local message = sent[index]
    if message.type == 'open' and message.path == path then
      count = count + 1
    end
  end
  return count
end

local function documents()
  return table.concat(selvage.documents(), ',')
end

--- How many notices since `from` carry `needle`.
local function said_since(from, needle)
  local count = 0
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function open(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

local function start_hosting(room)
  selvage.host('ws://127.0.0.1:1')
  handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = room })
end

local repo = vim.fn.getcwd()
local grant = repo .. '/.tmp/lua-grant/inside'
local elsewhere = repo .. '/.tmp/lua-grant/inside-elsewhere'
local outside = repo .. '/.tmp/lua-grant/outside'
for _, directory in ipairs({ grant, elsewhere, outside }) do
  vim.fn.mkdir(directory, 'p')
end
for _, name in ipairs({ 'one.txt', 'three.txt', 'five.txt', 'seven.txt' }) do
  vim.fn.writefile({ name }, grant .. '/' .. name)
end
for _, name in ipairs({ 'two.txt', 'four.txt', 'six.txt', 'refused.txt' }) do
  vim.fn.writefile({ name }, outside .. '/' .. name)
end
vim.fn.writefile({ 'lookalike' }, elsewhere .. '/lookalike.txt')

--- Puts every scope of the working directory to `directory`, so that the move a case makes is
--- the thing that moves it: a `:cd` made underneath a `:tcd` does not change where Neovim looks,
--- and the case would then be testing the wrong command.
local function set_cwd(directory)
  vim.cmd('cd ' .. vim.fn.fnameescape(directory))
  vim.cmd('tcd ' .. vim.fn.fnameescape(directory))
  vim.cmd('lcd ' .. vim.fn.fnameescape(directory))
end

-- The session starts here, so this folder is the grant and `one.txt` is shared as `one.txt` —
-- the path from the grant, not from wherever the directory happens to be later.
vim.cmd('cd ' .. vim.fn.fnameescape(grant))
open(grant .. '/one.txt')
start_hosting('r-grant')
check('the buffer the session was started in is shared', opens_of('one.txt'), 1)
check('  under its path from the grant', documents(), 'one.txt')

-- -- the working directory moves and the grant does not ----------------------------
--
-- Each move is made the way a person makes it, and the file on either side of the grant is
-- opened afterwards. The working directory is asserted to have moved, so a `:cd` that quietly
-- did nothing cannot let the rest of the case pass for the wrong reason.

--- Moves the working directory with `move`, then checks the grant did not follow: the file whose
--- name is `names[1]` outside it is not shared, and the one named `names[2]` under it still is.
local function prove_move(label, move, names)
  set_cwd(repo)
  vim.cmd(move)
  check(label .. ': the working directory moved', vim.fn.getcwd(), outside)
  local from = #sent
  open(outside .. '/' .. names[1])
  check(label .. ': a file outside the grant is not shared', opens_of(names[1], from), 0)
  open(grant .. '/' .. names[2])
  check(label .. ': a file under the grant is still shared', opens_of(names[2], from), 1)
end

prove_move(':cd', 'cd ' .. vim.fn.fnameescape(outside), { 'two.txt', 'three.txt' })
prove_move(':tcd', 'tcd ' .. vim.fn.fnameescape(outside), { 'four.txt', 'five.txt' })
prove_move(':lcd', 'lcd ' .. vim.fn.fnameescape(outside), { 'six.txt', 'seven.txt' })

-- A sibling whose name merely begins with the grant's is outside it. The separator in the
-- comparison is what keeps it out, and a directory called `inside` beside `inside-elsewhere` is
-- the shape a prefix test without one gets wrong.
local before_lookalike = #sent
open(elsewhere .. '/lookalike.txt')
check(
  "a sibling whose name begins with the grant's is outside it",
  opens_of('lookalike.txt', before_lookalike),
  0
)

-- The refusal is said, once per path: Neovim has no workspace in the window to show the grant,
-- so a file that is silently not shared is a plugin that looks broken.
local before_refusal = #notices
open(outside .. '/refused.txt')
check(
  'a file outside the grant is named in a warning',
  said_since(before_refusal, 'refused.txt is outside'),
  1
)
check(
  '  naming the folder the session shares',
  said_since(before_refusal, grant .. ', the folder this session shares'),
  1
)
check('  at warning level', notices[#notices].level, vim.log.levels.WARN)

local before_revisit = #notices
open(grant .. '/one.txt')
open(outside .. '/refused.txt')
check('  once per path, not once per visit', said_since(before_revisit, 'is outside'), 0)

-- A new session started where the last move left the working directory grants that folder
-- instead: the root is captured per session, not once per Neovim.
local before_second = #sent
selvage.leave()
set_cwd(outside)
open(outside .. '/two.txt')
start_hosting('r-grant-2')
check('a session started elsewhere grants the folder it started in', opens_of('two.txt', before_second), 1)
check('  under its path from that grant', documents(), 'two.txt')

-- A host standing in a file outside the folder it starts the session in shares nothing, and says
-- so. That buffer is the one the person most expects to be in the room, and it is the one the
-- grant is most likely to be wrong about.
selvage.leave()
set_cwd(grant)
open(outside .. '/six.txt')
local before_standing = #notices
local before_standing_sends = #sent
start_hosting('r-grant-3')
check('a host standing outside the grant shares nothing', #selvage.documents(), 0)
check('  and says why', said_since(before_standing, 'six.txt is outside'), 1)
check('  and asks the room for nothing', opens_of('six.txt', before_standing_sends), 0)

-- A buffer with no file is not shared either, and says so once per buffer rather than leaving
-- a person typing into a silence: hosting from an untitled buffer names it, returning to that
-- buffer does not name it again, and a second untitled buffer is named once for itself.
selvage.leave()
set_cwd(grant)
vim.cmd('enew!')
local unfiled_buf = vim.api.nvim_get_current_buf()
local before_unfiled = #notices
local before_unfiled_sends = #sent
start_hosting('r-grant-4')
check('a host with no file shares nothing', #selvage.documents(), 0)
check(
  '  and says the buffer has no file',
  said_since(before_unfiled, 'has no file, so it is not shared'),
  1
)
check(
  '  naming the folder the session shares',
  said_since(before_unfiled, 'the folder this session shares is '),
  1
)
check('  at warning level', notices[#notices].level, vim.log.levels.WARN)
local unfiled_opens = 0
for index = before_unfiled_sends + 1, #sent do
  if sent[index].type == 'open' then
    unfiled_opens = unfiled_opens + 1
  end
end
check('  and asks the room for nothing', unfiled_opens, 0)

local before_revisit_unfiled = #notices
open(grant .. '/one.txt')
vim.cmd('buffer ' .. unfiled_buf)
check('  once per buffer, not once per visit', said_since(before_revisit_unfiled, 'has no file'), 0)
-- `:enew!` on an empty unnamed buffer reuses its number, so the second buffer is made
-- explicitly: entering it is what has to name it.
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
check(
  '  while a second untitled buffer is named once for itself',
  said_since(before_revisit_unfiled, 'has no file, so it is not shared'),
  1
)

selvage.leave()

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
