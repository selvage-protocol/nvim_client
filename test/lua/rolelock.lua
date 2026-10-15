-- The role lock: a room that seats this connection as a `viewer` and the buffer policy that
-- follows it, against a stubbed companion.
--
--   nvim --headless -l test/lua/rolelock.lua      (or scripts/test-lua.sh)
--
-- `PROTOCOL.md` §13.4 gives a connection its role from the applied state and never from the seat,
-- and §13.9 makes a viewer's own content unpublishable. What this file pins is the front-end's
-- half: the room's documents become read-only when the state says `viewer`, the room's own edits
-- still land, a report that is not the state's word does not move the role, and leaving gives the
-- buffer back the `modifiable` it had. The companion's half — what a state does to the replica —
-- is `test/composed-reconnect.test.ts` and `test/companion.test.ts`.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime! plugin/selvage.lua')

vim.g.selvage_display_name = 'Test User'

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local sent = {}
local handlers = nil
local next_id = 0

local function message_id()
  next_id = next_id + 1
  return next_id
end

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

local function handle(message)
  handlers.on_message(message)
end

local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

--- The notices added since `from`, as one string, so a count and a wording are both readable.
local function said_since(from)
  local said = {}
  for index = from + 1, #notices do
    said[#said + 1] = notices[index].message
  end
  return table.concat(said, '\n')
end

local selvage = require('selvage')

-- A host is asked before leaving whenever there is someone to ask; this file's sessions are
-- guests, and answering the question keeps the file's own leave from waiting on a prompt.
vim.fn.confirm = function()
  return 1
end

vim.fn.mkdir('.tmp', 'p')
local MIRROR_PATH = 'notes/rolelock.txt'

--- Joins a room the way a real companion reports one: the seat's status, then the listing, the
--- documents and the membership. The landing is the first document, which is what a guest's
--- window ends up holding.
local function join()
  selvage.join('ws://127.0.0.1:1/session?room=r-rolelock&token=t')
  handle({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-rolelock' })
  handle({ type = 'report', report = { kind = 'grant', paths = { MIRROR_PATH } } })
  handle({ type = 'report', report = { kind = 'documents', documents = { MIRROR_PATH } } })
  handle({ type = 'report', report = { kind = 'peers', peers = {} } })
  return vim.api.nvim_get_current_buf()
end

-- -- the seat's read is not the state's word ------------------------------------------
--
-- At the seat no state has committed this connection's key, and the status carries the `guest` a
-- key no state has committed is read as (`nvim_client/docs/`). Nothing is read-only yet: the
-- editor refuses a keystroke because the *state* said `viewer`, and nothing has.

local buf = join()
-- The join has said its own summary sentence; what is asserted below is what the *role* adds to it.
local seated = #notices
check('the seat names this connection', selvage.session().role, 'guest')
check('  and the room\'s document is the person\'s to edit', vim.bo[buf].modifiable, true)
check('  with nothing said about a role', said_since(seated), '')

-- -- the state seats it as a viewer ---------------------------------------------------
--
-- The report is the companion's own word that the applied state gave this connection a different
-- role than the seat carried (§13.4). Every room document this window holds becomes read-only,
-- and the reason is said once.

local before = #notices
handle({ type = 'report', report = { kind = 'role', role = 'viewer' } })
check('the state\'s role is what this session has', selvage.session().role, 'viewer')
check('  so the room\'s buffer is read-only', vim.bo[buf].modifiable, false)
check(
  '  and the reason is said once',
  said_since(before):find('you are a viewer in this room, so its documents are read-only.', 1, true)
    ~= nil,
  true
)
check('  at warning level', notices[#notices] ~= nil and notices[#notices].level or nil,
  vim.log.levels.WARN)

--- The buffer's text, which a refusal must leave where it was.
local function lines()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, true), '\n')
end

local held = lines()
local typed = pcall(vim.api.nvim_buf_set_lines, buf, -1, -1, true, { 'a keystroke' })
check('a keystroke is refused by the editor', typed, false)
check('  and the buffer is where it was', lines(), held)

-- -- the same report again says nothing ------------------------------------------------
--
-- A report is a change and not a repeat, and a front-end that said the sentence again on every
-- one would nag for the life of the session.

before = #notices
handle({ type = 'report', report = { kind = 'role', role = 'viewer' } })
check('a repeated role report says nothing', said_since(before), '')
check('  and the lock stands', vim.bo[buf].modifiable, false)

-- -- the seat roles map is not the local key's role ------------------------------------
--
-- A `peers` report carries the room's membership with the role each seat is read as, and this
-- connection's own seat is in it: at the seat, before any state commits its key, that read is
-- `guest`. It is a different fact from the role the applied state gives this key, and it is the
-- state's word the editor acts on.

before = #notices
handle({
  type = 'report',
  report = {
    kind = 'peers',
    self = { peer_id = 'p-me', display_name = 'Test User', role = 'guest' },
    peers = {
      { peer_id = 'p-me', display_name = 'Test User', role = 'guest' },
      { peer_id = 'p-host', display_name = 'Ada', role = 'host' },
    },
  },
})
check('a membership report does not move the role', selvage.session().role, 'viewer')
check('  so the lock stands', vim.bo[buf].modifiable, false)
check('  and nothing is said again', said_since(before), '')

-- -- the room's own edit is not a keystroke --------------------------------------------
--
-- §13.9 refuses what a viewer *publishes*, never what it receives, so the room's text lands in the
-- buffer while it is read-only — the flag is the session's, and the document writes through it.

handle({
  type = 'applyEdit',
  id = message_id(),
  path = MIRROR_PATH,
  start = 0,
  ['end'] = 0,
  text = 'from the room',
  version = 0,
})
check('the room\'s edit lands in a read-only buffer', lines(), 'from the room')
check('  and the buffer is read-only again', vim.bo[buf].modifiable, false)
--- The last message of one kind this session sent, so a later message of another kind — a
--- `selection`, say — does not read as the answer being asserted about.
local function last_of(kind)
  for index = #sent, 1, -1 do
    if sent[index].type == kind then
      return sent[index]
    end
  end
  return nil
end

local applied = last_of('applied')
check('  and the answer says it was applied', applied ~= nil and applied.type or nil, 'applied')
check('  truthfully', applied ~= nil and applied.ok or nil, true)

-- -- the state gives it back -----------------------------------------------------------
--
-- A later state that gives this connection another role is the other direction of the same
-- report, and what the buffer gets back is the `modifiable` it had — not `true`, which would
-- hand a person a buffer they had deliberately made uneditable. The person's own change is made
-- while the session holds no lock, the only moment it can be told from the session's.

handle({ type = 'report', report = { kind = 'role', role = 'guest' } })
vim.bo[buf].modifiable = false
handle({ type = 'report', report = { kind = 'role', role = 'viewer' } })
check('a buffer the person had made uneditable is still locked', vim.bo[buf].modifiable, false)
before = #notices
handle({ type = 'report', report = { kind = 'role', role = 'guest' } })
check('the state\'s new role is what this session has', selvage.session().role, 'guest')
check('  and the buffer has what the person had', vim.bo[buf].modifiable, false)
vim.bo[buf].modifiable = true
handle({ type = 'report', report = { kind = 'role', role = 'viewer' } })
check('the lock is taken again', vim.bo[buf].modifiable, false)
check('  without saying the sentence twice', said_since(before):find('read-only', 1, true), nil)
handle({ type = 'report', report = { kind = 'role', role = 'guest' } })
check('  and given back as it was', vim.bo[buf].modifiable, true)

-- -- leaving gives the buffer back -----------------------------------------------------

selvage.leave()
check('the room\'s document is the person\'s again', vim.bo[buf].modifiable, true)
check('  and the session holds none', #selvage.documents(), 0)

vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
