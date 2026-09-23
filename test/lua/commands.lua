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
-- A Neovim with no clipboard provider has the unnamed register and not the system one. That is
-- the machine's business, not a session's, so it is the one thing the stub decides per run.
local clipboard_refuses = false
vim.fn.setreg = function(register, value)
  registers[register] = value
  if register == '+' and clipboard_refuses then
    error("E354: Invalid register name: '+'")
  end
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

-- The hosts below own the state they read: the data home is sandboxed to this checkout
-- from the start, so a bare command never answers from the person's own remembered
-- addresses, and what they write is nowhere the person's own Neovim would read.
vim.env.XDG_DATA_HOME = vim.fn.getcwd() .. '/.tmp/lua-commands-data'
vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-commands-data', 'rf')

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

-- With somebody to ask, an unremembered command asks once, starting from the demo
-- default. The answer is then reused without asking — across restarts — until an
-- explicit address or the setting uses another.
answer_with('ws://127.0.0.1:7777')
vim.cmd('SelvageHost')
check('a bare :SelvageHost asks for an address', prompted ~= nil, true)
check('  in the plugin\u{2019}s words', prompted and prompted.prompt:find('Selvage server to host on', 1, true) ~= nil, true)
check('  starting from the demo default', prompted and prompted.default, 'ws://100.64.0.3:8080')
check('  and hosts on the answer', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7777')

-- The answer is remembered, so the next bare host proceeds on it with no question.
prompted = nil
vim.cmd('SelvageHost')
check('  a remembered address is not asked about', prompted, nil)
check('    and hosting again uses it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7777')

-- The address outlives this Neovim: it is written when a host starts, so a restart — a fresh
-- plugin with no memory of its own — proceeds on the file with no question either. Another
-- address arrives explicitly, which is the escape hatch that changes what is remembered.
vim.cmd('SelvageHost ws://127.0.0.1:7778')
check('a host writes the address down', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7778')
-- A restart loads the plugin with the real prompt in place, not this file's stand-in, so the
-- input is put back before the reload: otherwise the fresh plugin mistakes the stand-in for
-- the built-in and believes there is someone to ask where there is no one.
vim.ui.input = builtin_input
package.loaded['selvage'] = nil
selvage = require('selvage')
prompted = nil
vim.cmd('SelvageHost')
check('  a restart proceeds on the address last used', prompted, nil)
check('    and hosting again uses it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:7778')

-- An explicit address beats the remembered one: nothing is asked, and what was explicit
-- becomes what the next bare host reuses.
answer_with(function(opts)
  return opts.default
end)
vim.cmd('SelvageHost ws://127.0.0.1:5555')
check('an explicit address is not asked about', prompted, nil)
check('  and is the one hosted on', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:5555')
prompted = nil
vim.cmd('SelvageHost')
check('  and the next bare host reuses it without asking', prompted, nil)
check('    and hosts on it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:5555')

-- A configured address is not asked about at all, as it is in the other client.
vim.g.selvage_server_url = 'ws://127.0.0.1:9999'
prompted = nil
vim.cmd('SelvageHost')
check('a configured address is not asked about', prompted, nil)
check('  and is the one hosted on', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:9999')
vim.g.selvage_server_url = nil

-- -- a typed address is completed, not refused ---------------------------------------
--
-- A person types a host, not a URL. `selvage-demo.dontblameme.dev` is the published shape — TLS, and
-- the engine's own `/session` — while an address that already names the endpoint keeps it from
-- being dialled twice (`/session/session` is nobody's server), and a path someone typed is
-- theirs and is left alone. `:SelvageChangeServer` completes what it is given and reports the
-- address it wrote, so the two entry points cannot disagree about what a hostname means.

local remembered_file = vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_server')

vim.cmd('SelvageHost selvage-demo.dontblameme.dev')
check(
  'a bare host means the TLS server',
  last_of('host') and last_of('host').serverUrl,
  'wss://selvage-demo.dontblameme.dev'
)
vim.cmd('SelvageHost selvage-demo.dontblameme.dev/')
check(
  '  a trailing slash is not a second server',
  last_of('host') and last_of('host').serverUrl,
  'wss://selvage-demo.dontblameme.dev'
)
vim.cmd('SelvageHost wss://selvage-demo.dontblameme.dev/session')
check(
  '  an address that names the endpoint is dialled once',
  last_of('host') and last_of('host').serverUrl,
  'wss://selvage-demo.dontblameme.dev'
)
vim.cmd('SelvageHost wss://selvage-demo.dontblameme.dev/prefix')
check(
  '  a path someone typed is kept',
  last_of('host') and last_of('host').serverUrl,
  'wss://selvage-demo.dontblameme.dev/prefix'
)
vim.cmd('SelvageHost ws://127.0.0.1:1234')
check(
  '  an address with a scheme is left as it is',
  last_of('host') and last_of('host').serverUrl,
  'ws://127.0.0.1:1234'
)
check(
  '  and the completed address is the one remembered',
  table.concat(vim.fn.readfile(remembered_file), '\n'),
  'ws://127.0.0.1:1234'
)

before = #notices
vim.cmd('SelvageChangeServer selvage-demo.dontblameme.dev')
check(
  'changing the server completes a bare host the same way',
  said_since(before, 'will host on wss://selvage-demo.dontblameme.dev next.') ~= nil,
  true
)
check(
  '  and writes the completed address down',
  table.concat(vim.fn.readfile(remembered_file), '\n'),
  'wss://selvage-demo.dontblameme.dev'
)
before = #notices
prompted = nil
vim.cmd('SelvageChangeServer')
check(
  '  a bare :SelvageChangeServer reports it completed too',
  said_since(before, 'the next host uses wss://selvage-demo.dontblameme.dev.') ~= nil,
  true
)
check(
  '  and its box starts from what would be dialled',
  prompted and prompted.default,
  'wss://selvage-demo.dontblameme.dev'
)

-- The box's answer is completed like an argument is: what the command reports is the address
-- the next host dials, never a bare host the host itself would have to complete.
before = #notices
answer_with('selvage.example')
vim.cmd('SelvageChangeServer')
check(
  '  an answer typed into the box is completed before it is reported',
  said_since(before, 'will host on wss://selvage.example next.') ~= nil,
  true
)
check(
  '    and written down completed',
  table.concat(vim.fn.readfile(remembered_file), '\n'),
  'wss://selvage.example'
)

-- -- :SelvageChangeServer reports the address in force and offers to change it ----------
--
-- The palette-reachable answer to "how do I change which server I am using", without hosting
-- first, against a known remembered address: an explicit host pins it back to
-- 'ws://127.0.0.1:5555', undoing what the configured host above left behind.

vim.cmd('SelvageHost ws://127.0.0.1:5555')
vim.ui.input = builtin_input
local last_server_file = vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_server')

before = #notices
prompted = nil
answer_with('ws://127.0.0.1:6666')
vim.cmd('SelvageChangeServer')
check(
  'a bare :SelvageChangeServer reports the remembered address',
  said_since(before, 'the next host uses ws://127.0.0.1:5555.') ~= nil,
  true
)
check('  and asks through the same box the first run does', prompted ~= nil, true)
check('  in the plugin\u{2019}s words', prompted and prompted.prompt:find('Selvage server to host on', 1, true) ~= nil, true)
check('  starting from the address in force', prompted and prompted.default, 'ws://127.0.0.1:5555')
check(
  '  and the change is confirmed',
  said_since(before, 'will host on ws://127.0.0.1:6666 next. Leave this session and host again to move there.')
    ~= nil,
  true
)
check('  and remembered for the next host', table.concat(vim.fn.readfile(last_server_file), '\n'), 'ws://127.0.0.1:6666')
prompted = nil
vim.cmd('SelvageHost')
check('    and a bare host reuses it without asking', prompted, nil)
check('      and hosts on it', last_of('host') and last_of('host').serverUrl, 'ws://127.0.0.1:6666')

-- Submitting the box unchanged changes nothing: a dismissed or unedited answer is not a change.
before = #notices
answer_with(function(opts)
  return opts.default
end)
vim.cmd('SelvageChangeServer')
check(
  'answering with the address already in force writes nothing',
  said_since(before, 'will host on') == nil,
  true
)
check('  and it is still what the next host uses', table.concat(vim.fn.readfile(last_server_file), '\n'), 'ws://127.0.0.1:6666')

-- Nothing remembered and nothing configured: the report says so, and the box starts from the
-- demo default, exactly as the first :SelvageHost question does.
vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-commands-data', 'rf')
vim.ui.input = builtin_input
package.loaded['selvage'] = nil
selvage = require('selvage')
before = #notices
answer_with(function(opts)
  return opts.default
end)
vim.cmd('SelvageChangeServer')
check(
  'nothing remembered is reported as such',
  said_since(before, 'no server is remembered yet; the next host asks.') ~= nil,
  true
)
check('  and the box starts from the demo default', prompted and prompted.default, 'ws://100.64.0.3:8080')

-- An explicit argument sets the address directly: no box is opened.
before = #notices
prompted = nil
vim.cmd('SelvageChangeServer ws://127.0.0.1:4444')
check('an explicit argument opens no box', prompted, nil)
check(
  '  and writes the address down',
  said_since(before, 'will host on ws://127.0.0.1:4444 next. Leave this session and host again to move there.')
    ~= nil,
  true
)
check('  remembered for the next host', table.concat(vim.fn.readfile(last_server_file), '\n'), 'ws://127.0.0.1:4444')

-- A configured address outranks the remembered one: the command says so and changes nothing,
-- neither for a bare invocation nor for an explicit argument — writing the memento while the
-- setting is in force would be a change the next host silently ignores.
vim.g.selvage_server_url = 'ws://127.0.0.1:9999'
before = #notices
prompted = nil
vim.cmd('SelvageChangeServer')
check(
  'a configured address is reported as being in force',
  said_since(before, 'the "vim.g.selvage_server_url" setting fixes the server at ws://127.0.0.1:9999') ~= nil,
  true
)
check('  and no box is opened', prompted, nil)
check(
  '  and the remembered address is untouched',
  table.concat(vim.fn.readfile(last_server_file), '\n'),
  'ws://127.0.0.1:4444'
)

before = #notices
vim.cmd('SelvageChangeServer ws://127.0.0.1:1234')
check(
  'an explicit argument is trapped by the setting too',
  said_since(before, 'the "vim.g.selvage_server_url" setting fixes the server at ws://127.0.0.1:9999') ~= nil,
  true
)
check(
  '  the argument is not written while the setting outranks it',
  table.concat(vim.fn.readfile(last_server_file), '\n'),
  'ws://127.0.0.1:4444'
)
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

-- The host copies the page link now, never the wire address: the clipboard offer is
-- that link, and the companion dials the wire URL its own origin resolves to.
clipboard = 'https://selvage.example:8443/?room=r-one&token=t'
before = #notices
vim.cmd('SelvageJoin')
check('  a page link is offered too', prompted and prompted.default, clipboard)
check(
  '  and joins the server its origin names',
  last_of('join') and last_of('join').invite,
  'wss://selvage.example:8443/session?room=r-one&token=t'
)

-- The origin is the whole address, so the scheme says which socket it means: a page served in
-- the clear names a server in the clear.
clipboard = 'http://127.0.0.1:8080/?room=r-plain&token=t'
vim.cmd('SelvageJoin')
check(
  '  a cleartext page link joins the cleartext server',
  last_of('join') and last_of('join').invite,
  'ws://127.0.0.1:8080/session?room=r-plain&token=t'
)

-- The link *is* the server, so a link that names one in its query names nothing: `server` is
-- an unknown parameter, ignored the way an unknown query parameter is, and the origin stands.
clipboard = 'https://selvage.example/?room=r-older&token=t&server=ws%3A%2F%2F127.0.0.1%3A9'
vim.cmd('SelvageJoin')
check(
  '  a stale server= parameter moves the link nowhere',
  last_of('join') and last_of('join').invite,
  'wss://selvage.example/session?room=r-older&token=t'
)

clipboard = 'a note the person copied instead'
vim.cmd('SelvageJoin')
check('  a clipboard that is not an invite is not offered', prompted and prompted.default, '')

-- -- a pasted invite with the wrong shape is refused before any dial ------------------
--
-- A truncated paste is the newcomer's failure, and the engine would report it as an
-- address problem. The prompt refuses it in the other client's words instead, and
-- nothing is sent: the address suffix stays for failures that really are the address's.

clipboard = ''
answer_with('ws://127.0.0.1:8080/session?room=r-one')
local joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'a truncated paste is refused at the prompt',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check(
  '  in the other client\u{2019}s words',
  said_since(before, 'Paste the whole link the host sent you') ~= nil,
  true
)
check('  at error level', notices[before + 1] ~= nil and notices[before + 1].level or nil, vim.log.levels.ERROR)
check('  and nothing is dialled', count_type('join'), joins_before)

answer_with('wss://example.com/session?room=r-one')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'a paste without a token is refused too',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check('  and nothing is dialled either', count_type('join'), joins_before)

-- Substring matching is not parameter matching: `?bedroom=x&token=y` contains `room=`
-- without naming a room, and `?room=&token=t` names one with nothing in it. Both are
-- refused at the prompt rather than reaching the engine's own refusal.
answer_with('ws://127.0.0.1:8080/session?bedroom=x&token=t')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'a lookalike parameter is refused too',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check('  and nothing is dialled for it either', count_type('join'), joins_before)

answer_with('ws://127.0.0.1:8080/session?room=&token=t')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'an empty room value is refused too',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check('  and nothing is dialled for it either', count_type('join'), joins_before)

-- A truncated page link is refused the same way, before any dial.
answer_with('https://selvage-demo.dontblameme.dev/?room=r-one')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'a truncated page link is refused too',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check('  and nothing is dialled for it either', count_type('join'), joins_before)

-- A whole page link pasted at the prompt joins on the wire URL it names.
answer_with('https://selvage.example:8443/?room=r-two&token=t2')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin')
check(
  'a pasted page link joins the room it names',
  last_of('join') and last_of('join').invite,
  'wss://selvage.example:8443/session?room=r-two&token=t2'
)
check('  and says nothing about it', said_since(before, 'That does not look like') == nil, true)

-- -- an invite that arrives as an argument is checked before anything else --------------
--
-- The prompt is not the only way an invite arrives: `:SelvageJoin <link>` hands one straight
-- over, and a wrong one there was resolved as a name first, so the person answered a question
-- about a room that was never going to open and the engine then heard an address it could not
-- use. An argument is refused before anything is asked or dialled, with the box's own sentence.
--
-- No name is configured and there is nobody to ask: were the name resolved first, this would
-- refuse with the name's own sentence rather than the link's.

vim.g.selvage_display_name = nil
vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-commands-data', 'rf')
vim.ui.input = builtin_input
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin ws://127.0.0.1:1/other')
check(
  'a mistyped argument is refused',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check(
  '  at error level, where the box refuses',
  notices[before + 1] ~= nil and notices[before + 1].level or nil,
  vim.log.levels.ERROR
)
check(
  '  and the name is never asked for',
  said_since(before, 'No display name is set') == nil,
  true
)
check('  with nothing dialled', count_type('join'), joins_before)

-- The page link's shape is checked the same way: a truncated one is the paste a person
-- always makes, and it fails here rather than at the server.
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin https://selvage-demo.dontblameme.dev/?room=r-one')
check(
  'a truncated page link argument is refused too',
  said_since(before, 'that does not look like a Selvage invite link') ~= nil,
  true
)
check('  and nothing is dialled for it either', count_type('join'), joins_before)

-- A conforming argument still joins, and still takes its name on the way in: an explicit
-- page link is dialled as the wire URL it resolves to.
answer_with('Ada')
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin https://selvage.example:8443/?room=r-arg&token=t')
check(
  'a conforming argument joins',
  last_of('join') and last_of('join').invite,
  'wss://selvage.example:8443/session?room=r-arg&token=t'
)
check('  after asking for the name once', prompted ~= nil, true)
check('  and joins under it', last_of('join') and last_of('join').displayName, 'Ada')
check('  saying nothing about the link', said_since(before, 'That does not look like') == nil, true)

-- A wire link as an argument joins as it is.
vim.g.selvage_display_name = 'Test User'
joins_before = count_type('join')
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r-arg&token=t')
check(
  '  and a wire argument too',
  last_of('join') and last_of('join').invite,
  'ws://127.0.0.1:1/session?room=r-arg&token=t'
)

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


-- -- the wire version a host is pinned to ------------------------------------------------
--
-- `PROTOCOL.md` §2: an unpinned client that can speak `selvage/2` mints it where the server's
-- `/meta` seats it, so the global is a *pin* and not a default. Nothing rides in the request for a
-- front-end that has pinned nothing — the companion asks the server and decides — and a join is
-- untouched: the version a join speaks is the link's, whatever this says.

local function carries_wire(kind)
  return vim.json.encode(last_of(kind)):find('"wire"', 1, true) ~= nil
end

vim.g.selvage_wire_version = 2
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('the number two pins the encrypted wire', last_of('host') and last_of('host').wire, 'selvage/2')

vim.g.selvage_wire_version = '2'
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and so does its string form', last_of('host') and last_of('host').wire, 'selvage/2')

vim.g.selvage_wire_version = 'selvage/2'
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and the spelling the protocol uses', last_of('host') and last_of('host').wire, 'selvage/2')

vim.g.selvage_wire_version = 1
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('the number one pins the readable wire', last_of('host') and last_of('host').wire, 'selvage/1')

vim.g.selvage_wire_version = 'selvage/1'
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and its spelled form too', last_of('host') and last_of('host').wire, 'selvage/1')

vim.g.selvage_wire_version = 'auto'
vim.cmd('SelvageHost ws://127.0.0.1:1')
check("  and the other client's default of 'auto' pins nothing", carries_wire('host'), false)

vim.g.selvage_wire_version = true
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and neither does a value no version grammar accepts', carries_wire('host'), false)

vim.g.selvage_wire_version = nil
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  and an unset global pins nothing', carries_wire('host'), false)

vim.g.selvage_wire_version = 'selvage/2'
local joins_before_pin = count_type('join')
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r-pin&token=t')
check('a join goes out with the pin set', count_type('join'), joins_before_pin + 1)
check('  and carries no version', carries_wire('join'), false)
vim.g.selvage_wire_version = nil


-- -- a session being opened -----------------------------------------------------------
--
-- A second host or join half a second after the first is a double invocation, not a live
-- room to refuse: the companion's refusal sentence describes the room still standing,
-- so the commands hold the second one back while the first is in flight.

vim.g.selvage_display_name = 'Test User'
vim.cmd('SelvageHost ws://127.0.0.1:1')
local hosts_opening = count_type('host')
handlers().on_message({ type = 'status', state = 'connecting' })
local before_opening = #notices
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('a second host while connecting sends nothing', count_type('host'), hosts_opening)
check(
  '  and says a session is being opened',
  said_since(before_opening, 'a session is already being opened.') ~= nil,
  true
)
local joins_opening = count_type('join')
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r&token=t')
check('  and a join behind it sends nothing either', count_type('join'), joins_opening)
handlers().on_message({ type = 'status', state = 'idle' })
-- -- the name, as the read form reports it -------------------------------------------
--
-- Nothing configured and nothing remembered is no name: the read form says so rather than
-- naming the login name, which is only ever what the prompt starts from.

vim.g.selvage_display_name = nil
vim.env.SELVAGE_DISPLAY_NAME = nil
vim.fn.delete(vim.fn.getcwd() .. '/.tmp/lua-commands-data', 'rf')
check('the name in force is nil when nothing is configured', selvage.display_name(), nil)

vim.cmd('SelvageDisplayName')
check(
  '  and the read form says there is none',
  said_since(before, 'no display name is set yet') ~= nil,
  true
)
check('  rather than reporting a name nobody chose', said_since(before, 'The name others see is') == nil, true)
check('  and the global is left unset', vim.g.selvage_display_name, nil)

-- A prompted name is written down, so a restart is not asked again. The file is the name's
-- memory across restarts; the global is this Neovim's.
answer_with('  Ada  ')
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('a prompted name names the session, trimmed', last_of('host') and last_of('host').displayName, 'Ada')
check('  and becomes the global', vim.g.selvage_display_name, 'Ada')
local remembered_file = vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_display_name')
check('  and is written down', table.concat(vim.fn.readfile(remembered_file), '\n'), 'Ada')
check('  and the read form reports it', selvage.display_name(), 'Ada')

-- A fresh process has no global of its own: with nothing configured it proceeds on the file
-- with no question.
vim.g.selvage_display_name = nil
check('  and the read form reports the remembered one', selvage.display_name(), 'Ada')
prompted = nil
vim.cmd('SelvageHost ws://127.0.0.1:1')
check('  a restart is not asked about the name', prompted, nil)
check('    and goes under the remembered one', last_of('host') and last_of('host').displayName, 'Ada')

-- The explicit change writes through: setting the name replaces what is remembered.
vim.cmd('SelvageDisplayName Grace')
check('  an explicit change is remembered too', table.concat(vim.fn.readfile(remembered_file), '\n'), 'Grace')
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
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r-next&token=t')
check('a join while hosting asks first', confirmations, 1)
check(
  '  naming what joining it does, never the room id',
  question and question.text,
  'you are hosting this session; joining another session ends this room for everyone.'
)
check('  offering to leave and join', question and question.choices, '&Leave and join\n&Cancel')
check('  a declined question joins nothing', count_type('join'), joins_before)
check('  and leaves the session alone', selvage.session().status, 'hosting')

confirmation = 1
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r-next&token=t')
check('  an accepted question gives the session up', last_of('leave') ~= nil, true)
check(
  '  and joins the new room',
  last_of('join') and last_of('join').invite,
  'ws://127.0.0.1:1/session?room=r-next&token=t'
)

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
  'you are in this session; hosting a session means leaving it first.'
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
check(
  '  and puts the page link on the clipboard',
  registers['+'],
  'http://127.0.0.1:2/?room=r-again&token=t'
)
check('  and the unnamed register too', registers['"'], registers['+'])
check('  and never the wire address', registers['+']:find('ws://', 1, true), nil)

-- A room that opens copies its page link without being asked: the host's next move is
-- pasting it to a guest. `:SelvageCopyInvite` stays for later copies.
selvage.leave()
vim.cmd('SelvageHost ws://127.0.0.1:7')
registers = {}
before = #notices
report_status('hosting', 'r-fresh', 'ws://127.0.0.1:7/session?room=r-fresh&token=t7')
check(
  'a room that opens puts the page link on the clipboard',
  registers['+'],
  'http://127.0.0.1:7/?room=r-fresh&token=t7'
)
check('  and the unnamed register too', registers['"'], registers['+'])
check(
  '  and never the wire address',
  registers['+'] ~= nil and registers['+']:find('ws://', 1, true),
  nil
)
check(
  '  and says so',
  said_since(before, 'the room is open. Send this link') ~= nil
    and said_since(before, 'on the clipboard.') ~= nil,
  true
)

-- A room links at the server that serves it: a plain server's page is plain too, because the
-- link and the socket are the same address over the two schemes a browser and a socket use.
report_status('hosting', 'r-demo', 'ws://100.64.0.3:8080/session?room=r-demo&token=t')
registers = {}
vim.cmd('SelvageCopyInvite')
check(
  '  a room links at the server that serves it',
  registers['+'],
  'http://100.64.0.3:8080/?room=r-demo&token=t'
)

-- A TLS room links at its own https origin: this is the link a person sends, and the page it
-- opens dials the same host. There is no second address for it to name, which is what a page
-- setting used to be — and how a room on one server came to be linked at another's page.
report_status('hosting', 'r-tls', 'wss://selvage-demo.dontblameme.dev/session?room=r-tls&token=ttls')
registers = {}
vim.cmd('SelvageCopyInvite')
check(
  '  a TLS room links at its own page',
  registers['+'],
  'https://selvage-demo.dontblameme.dev/?room=r-tls&token=ttls'
)

-- A server behind a prefix keeps it: the page is served where the socket is answered.
report_status('hosting', 'r-prefix', 'wss://selvage.example/prefix/session?room=r-prefix&token=tp')
registers = {}
vim.cmd('SelvageCopyInvite')
check(
  '  and a server behind a prefix keeps it',
  registers['+'],
  'https://selvage.example/prefix/?room=r-prefix&token=tp'
)

-- The page is no longer an address of its own, so the global that used to move it moves
-- nothing: a link that could be sent to a page dialling another server is the defect this
-- removes.
vim.g.selvage_web_origin = 'https://custom.example:9443/'
registers = {}
vim.cmd('SelvageCopyInvite')
check(
  '  a page-origin global moves the link nowhere',
  registers['+'],
  'https://selvage.example/prefix/?room=r-prefix&token=tp'
)
vim.g.selvage_web_origin = nil

-- A process with nobody to answer the modal question cannot be asked, so the session it holds is
-- not given up: the consequence is said and nothing else happens.
vim.ui.input = builtin_input
joins_before = count_type('join')
before = #notices
vim.cmd('SelvageJoin ws://127.0.0.1:1/session?room=r-other&token=t')
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
  said_since(before, 'you are the host — the files you open are the ones your guests see') ~= nil,
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
check('a refused host is reported', said_since(before, 'already hosting; leave that session first.') ~= nil, true)
handlers().on_message({ type = 'refused', what = 'join', roomId = 'r-open' })
check('  and a refused join', said_since(before, 'already in a session; leave that session first.') ~= nil, true)

-- -- a guest holds the token it joined with ------------------------------------------
--
-- The invite is the permission the guest entered the room with, so the link the host sent is
-- the guest's to hand on. A page link keeps the origin the host sent it from; a guest that
-- reached the room over `ws://` has no page for it, so that link is what it passes on.

selvage.leave()
vim.cmd('SelvageJoin https://selvage-demo.dontblameme.dev/?room=r-page&token=tpage')
report_status('joined', 'r-page')
registers = {}
vim.cmd('SelvageCopyInvite')
check(
  'a guest joined by page link copies that link',
  registers['+'],
  'https://selvage-demo.dontblameme.dev/?room=r-page&token=tpage'
)
check('  and the unnamed register too', registers['"'], registers['+'])

selvage.leave()
local wire_invite = 'ws://127.0.0.1:8080/session?room=r-wire&token=twire'
vim.cmd('SelvageJoin ' .. wire_invite)
report_status('joined', 'r-wire')
registers = {}
vim.cmd('SelvageCopyInvite')
check('a guest that joined by wire copies the wire link', registers['+'], wire_invite)

-- -- a session that stands but holds no link to hand on -----------------------------
--
-- A room is open and this connection has no invite for it, because the server that seated it
-- sent no token. `host or join a room first` is the sentence for a window in no session at all
-- — said here it is a contradiction, and one that sends the person looking for the room they
-- are already in. Each of the three moments says what actually happened.

selvage.leave()
before = #notices
vim.cmd('SelvageHost ws://127.0.0.1:51')
report_status('hosting', 'r-noinvite')
check(
  'a room that opens with no link in hand says what is missing',
  said_since(before, 'the room is open, but this connection holds no invite link to send.') ~= nil,
  true
)
registers = {}
before = #notices
vim.cmd('SelvageCopyInvite')
check(
  '  and copying says the same rather than that there is no room',
  said_since(before, 'this session holds no invite link to copy.') ~= nil,
  true
)
check(
  '  and never the sentence for a window in no session',
  said_since(before, 'host or join a room first'),
  nil
)
check('  and nothing was copied', registers['+'], nil)
before = #notices
vim.cmd('SelvageHost ws://127.0.0.1:52')
check(
  '  and hosting again says what is missing too',
  said_since(before, 'you are already hosting this session, but this connection holds no invite link to send.')
    ~= nil,
  true
)

-- A Neovim whose system clipboard refuses the link still has the unnamed register, and the
-- sentence says so rather than claiming a copy the editor could not make.
clipboard_refuses = true
registers = {}
before = #notices
vim.cmd('SelvageHost ws://127.0.0.1:53')
report_status('hosting', 'r-noclip', 'ws://127.0.0.1:53/session?room=r-noclip&token=t5')
check(
  'a clipboard that refuses the link is reported, not claimed',
  said_since(before, 'the invite link could not be copied (') ~= nil,
  true
)
check(
  '  and the reason it gives is the one Neovim gave',
  said_since(before, 'E354: Invalid register name') ~= nil,
  true
)
check(
  '  and the notice never says the link is on the clipboard',
  said_since(before, 'it is on the clipboard'),
  nil
)
check(
  '  and the unnamed register holds it',
  registers['"'],
  'http://127.0.0.1:53/?room=r-noclip&token=t5'
)
before = #notices
vim.cmd('SelvageCopyInvite')
check(
  '  and copying says the same',
  said_since(before, 'the invite link could not be copied (') ~= nil,
  true
)
check(
  '  and does not claim it either',
  said_since(before, 'the invite link is on the clipboard'),
  nil
)
clipboard_refuses = false

-- Nothing to copy is a session that is not there, and the sentence says that rather than
-- blaming the connection that minted the room.
selvage.leave()
registers = {}
before = #notices
vim.cmd('SelvageCopyInvite')
check(
  'copying with no session says there is none',
  said_since(before, 'there is no invite link; host or join a room first.') ~= nil,
  true
)

vim.notify = notify
vim.ui.input = builtin_input
vim.fn.confirm = builtin_confirm
vim.fn.getreg = real_getreg
vim.fn.setreg = real_setreg

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
