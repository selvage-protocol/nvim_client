-- What the commands themselves decide, in a real headless Neovim and through the real command
-- definitions: which session a `:SelvageHost` or `:SelvageJoin` is allowed to give up, what it
-- asks when the command line gave it no argument, and what `:SelvageOpen` refuses to do for a
-- host.
--
--   nvim --headless -l test/lua/commands.lua      (or scripts/test-lua.sh)
--
-- `test/lua/session.lua` covers what a session does with buffers and presence, against the same
-- stubbed companion; this file is about the front-end's own policy, which is why it drives
-- `:Commands` rather than the Lua functions the commands call.

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
--- a test can say what a command did without a process on the other end of a pipe.
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

local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local sent, handlers = stub_companion()
local selvage = require('selvage')

--- The notice, if any, a command added since `from`.
local function said_since(from, needle)
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      return notices[index].message
    end
  end
  return nil
end

local function count_type(kind)
  local count = 0
  for _, message in ipairs(sent) do
    if message.type == kind then
      count = count + 1
    end
  end
  return count
end

local function last_of(kind)
  for index = #sent, 1, -1 do
    if sent[index].type == kind then
      return sent[index]
    end
  end
  return nil
end

-- A name for the sessions this file starts: a process with nothing configured and nobody to ask
-- refuses to open a room, and only the display-name checks below want that.
vim.g.selvage_display_name = 'Test User'

vim.fn.mkdir('.tmp', 'p')
local path = '.tmp/lua-commands.txt'
vim.fn.writefile({ 'one' }, path)
vim.cmd('edit ' .. vim.fn.fnameescape(path))

-- The prompt and the modal question are the person's; a test answers them. `vim.ui.input` is
-- put back to the built-in where a check wants a process with nobody to ask, which is what
-- `can_prompt()` reads.
local builtin_input = vim.ui.input
local builtin_confirm = vim.fn.confirm

local prompted = nil
local function answer_with(value)
  prompted = nil
  vim.ui.input = function(opts, on_confirm)
    prompted = opts
    on_confirm(type(value) == 'function' and value(opts) or value)
  end
end

local question = nil
local confirmation = 0
local confirmations = 0
vim.fn.confirm = function(text, choices, default, kind)
  confirmations = confirmations + 1
  question = { text = text, choices = choices, default = default, kind = kind }
  return confirmation
end

local registers = {}
local real_setreg = vim.fn.setreg
vim.fn.setreg = function(register, value)
  registers[register] = value
  pcall(real_setreg, register, value)
end

local real_getreg = vim.fn.getreg
local clipboard = ''
vim.fn.getreg = function(register)
  if register == '+' then
    return clipboard
  end
  return real_getreg(register)
end

--- Plays the part of the companion telling the front-end where the session stands.
local function report_status(state, roomId, invite)
  handlers().on_message({
    type = 'status',
    state = state,
    role = state == 'hosting' and 'host' or (state == 'joined' and 'guest' or nil),
    roomId = roomId,
    invite = invite,
  })
end

-- -- a bare command reaches the plugin's own guard ---------------------------------
--
-- `:SelvageHost` and `:SelvageJoin` take an optional argument. With none, they ask for it, and
-- where there is nobody to ask they refuse in this plugin's words: before, the command demanded
-- an argument and Neovim raised `E471: Argument required` before any of that could happen.

vim.ui.input = builtin_input
vim.g.selvage_server_url = nil
local before = #notices
local raised = pcall(vim.cmd, 'SelvageHost')
check('a bare :SelvageHost does not raise E471', raised, true)
check('  and the refusal is the plugin\u{2019}s', said_since(before, 'a server address is needed') ~= nil, true)
check('  and it names one', said_since(before, ':SelvageHost ws://127.0.0.1:8080') ~= nil, true)

before = #notices
raised = pcall(vim.cmd, 'SelvageJoin')
check('a bare :SelvageJoin does not raise E471 either', raised, true)
check('  and says what is missing', said_since(before, 'an invite link is needed') ~= nil, true)

-- With somebody to ask, the same command asks. The address is a value only the person knows, and
-- there is no default for it in this plugin.
--
-- The hosts below own the state they read: the data home is sandboxed to this checkout, so the
-- address they write is nowhere the person's own Neovim would read.
vim.env.XDG_DATA_HOME = vim.fn.getcwd() .. '/.tmp/lua-commands-data'
vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-commands-data', 'rf')
answer_with('ws://127.0.0.1:7777')
vim.cmd('SelvageHost')
check('a bare :SelvageHost asks for an address', prompted ~= nil, true)
check('  in the plugin\u{2019}s words', prompted and prompted.prompt:find('Selvage server to host on', 1, true) ~= nil, true)
check('  and hosts on the answer', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7777')

-- The answer is remembered for this Neovim, so the next question starts from it rather than from
-- nothing — a suggestion that the question still asks for, unlike the setting.
answer_with(function(opts)
  return opts.default
end)
vim.cmd('SelvageHost')
check('  the next question starts from the address just used', prompted and prompted.default, 'ws://127.0.0.1:7777')
check('    and hosting again uses it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7777')

-- The address outlives this Neovim: it is written when a host starts, so a restart — a fresh
-- plugin with no memory of its own — starts its question from the file rather than from nothing,
-- as the other client does from its global state.
answer_with('ws://127.0.0.1:7778')
vim.cmd('SelvageHost')
check('a host writes the address down', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7778')
-- A restart loads the plugin with the real prompt in place, not this file's stand-in, so the
-- input is put back before the reload: otherwise the fresh plugin mistakes the stand-in for
-- the built-in and believes there is someone to ask where there is no one.
vim.ui.input = builtin_input
package.loaded['selvage'] = nil
selvage = require('selvage')
answer_with(function(opts)
  return opts.default
end)
vim.cmd('SelvageHost')
check('  a restart still starts from the address last used', prompted and prompted.default, 'ws://127.0.0.1:7778')
check('    and hosting again uses it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7778')

-- A configured address is not asked about at all, as it is in the other client.
vim.g.selvage_server_url = 'ws://127.0.0.1:9999'
prompted = nil
vim.cmd('SelvageHost')
check('a configured address is not asked about', prompted, nil)
check('  and is the one hosted on', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:9999')
vim.g.selvage_server_url = nil

-- -- a bare :SelvageJoin takes the invite from the clipboard -------------------------
--
-- The host has just sent the link and pasting it is the next thing the person does, so the box
-- starts from it. Only a link that names a room is offered: a clipboard holding something else
-- is not joined by mistake.

clipboard = 'ws://127.0.0.1:8080/session?room=r-one&token=t'
answer_with(function(opts)
  return opts.default
end)
before = #notices
vim.cmd('SelvageJoin')
check('a bare :SelvageJoin offers the invite on the clipboard', prompted and prompted.default, clipboard)
check('  and joins the room it names', last_of('join') and last_of('join').invite, clipboard)

clipboard = 'a note the person copied instead'
vim.cmd('SelvageJoin')
check('  a clipboard that is not an invite is not offered', prompted and prompted.default, '')

-- -- the auto-save knob -------------------------------------------------------------
--
-- Whether a document the room changes is written is the front-end's setting, as it is in the
-- other client, and it rides in the request that opens the session. Nothing is sent for a
-- front-end that does not say, so the companion's own default stands.

vim.g.selvage_auto_save = false
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('auto-save off rides in the host request', last_of('host') and last_of('host').autoSave, false)

vim.g.selvage_auto_save = true
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and on', last_of('host') and last_of('host').autoSave, true)

vim.g.selvage_auto_save = nil
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and an unset global puts nothing on the wire', vim.json.encode(last_of('host')):find('autoSave'), nil)

-- -- the name, as the read form reports it -------------------------------------------
--
-- Nothing configured is no name: the read form says so rather than naming the login name, which
-- is only ever what the prompt starts from.

vim.g.selvage_display_name = nil
vim.env.SELVAGE_DISPLAY_NAME = nil
check('the name in force is nil when nothing is configured', selvage.display_name(), nil)

vim.cmd('SelvageDisplayName')
check(
  '  and the read form says there is none',
  said_since(before, 'no display name is set yet') ~= nil,
  true
)
check('  rather than reporting a name nobody chose', said_since(before, 'the name others see is') == nil, true)
check('  and the global is left unset', vim.g.selvage_display_name, nil)
vim.g.selvage_display_name = 'Test User'

-- -- giving up a session is the person's call ---------------------------------------
--
-- A `:SelvageJoin` while a session is live ends the room for everyone in it, and a `:SelvageHost`
-- while a guest means leaving the room first. Both are questions, and a declined question leaves
-- everything exactly as it was.

report_status('hosting', 'r-host', 'ws://127.0.0.1:1/session?room=r-host&token=t')
local joins_before = count_type('join')
confirmation = 0
before = #notices
vim.cmd('SelvageJoin ws://127.0.0.1:1/room#tok')
check('a join while hosting asks first', confirmations, 1)
check(
  '  naming the room and what joining it does',
  question and question.text,
  'you are hosting room r-host; joining another session ends this room for everyone'
)
check('  offering to leave and join', question and question.choices, '&Leave and join\n&Cancel')
check('  a declined question joins nothing', count_type('join'), joins_before)
check('  and leaves the session alone', selvage.session().status, 'hosting')

confirmation = 1
vim.cmd('SelvageJoin ws://127.0.0.1:1/room#tok')
check('  an accepted question gives the session up', last_of('leave') ~= nil, true)
check('  and joins the new room', last_of('join') and last_of('join').invite, 'ws://127.0.0.1:1/room#tok')

-- The same for hosting while a guest, which is the other half of it.
report_status('joined', 'r-guest')
local hosts_before = count_type('host')
local asks_before = confirmations
confirmation = 0
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('a host while a guest asks first', confirmations, asks_before + 1)
check(
  '  saying that hosting means leaving',
  question and question.text,
  'you are in room r-guest; hosting a session means leaving it first'
)
check('  offering to leave and host', question and question.choices, '&Leave and host\n&Cancel')
check('  a declined question hosts nothing', count_type('host'), hosts_before)

confirmation = 1
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  an accepted one gives the guest session up', last_of('leave') ~= nil, true)
check('  and mints a room', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:1')

-- Hosting while hosting is not a question at all: it is reaching for the invite.
report_status('hosting', 'r-again', 'ws://127.0.0.1:2/session?room=r-again&token=t')
hosts_before = count_type('host')
confirmations = 0
registers = {}
before = #notices
vim.cmd('SelvageHost ws://127.0.0.1:9')
check('hosting again mints no second room', count_type('host'), hosts_before)
check('  and asks nothing', confirmations, 0)
check('  and puts the invite on the clipboard', registers['+'], 'ws://127.0.0.1:2/session?room=r-again&token=t')

-- A process with nobody to answer the modal question cannot be asked, so the session it holds is
-- not given up: the consequence is said and nothing else happens.
vim.ui.input = builtin_input
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin ws://127.0.0.1:1/other')
check('a join while hosting with nobody to ask joins nothing', count_type('join'), joins_before)
check(
  '  and says what joining would do',
  said_since(before, 'joining another session ends this room for everyone') ~= nil,
  true
)

-- -- a host has no copy of the room to open ------------------------------------------
--
-- A host's documents are its own files, already in its buffer list, and the command means the
-- room's copy that a window does not hold. Refused with the reason rather than switching the
-- window to a buffer `:b` already reaches, which is what the other client does.

report_status('hosting', 'r-open', 'ws://127.0.0.1:1/session?room=r-open&token=t')
before = #notices
local window_before = vim.fn.bufname('%')
vim.cmd('SelvageOpen')
check(
  ':SelvageOpen while hosting is refused with the reason',
  said_since(before, 'you are hosting, so the files you open are the ones the room has') ~= nil,
  true
)
check('  and the window is left where it was', vim.fn.bufname('%'), window_before)
check('  at information level', notices[#notices].level, vim.log.levels.INFO)

-- -- the companion's own guard ------------------------------------------------------
--
-- The commands ask before they give a session up, so a `host` or `join` that arrives anyway is
-- one the companion refuses and says so: nothing about the room in hand changes.

before = #notices
handlers().on_message({ type = 'refused', what = 'host', roomId = 'r-open' })
check('a refused host is reported', said_since(before, 'already hosting room r-open') ~= nil, true)
handlers().on_message({ type = 'refused', what = 'join', roomId = 'r-open' })
check('  and a refused join', said_since(before, 'already in room r-open') ~= nil, true)

vim.notify = notify
vim.ui.input = builtin_input
vim.fn.confirm = builtin_confirm
vim.fn.getreg = real_getreg
vim.fn.setreg = real_setreg

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
