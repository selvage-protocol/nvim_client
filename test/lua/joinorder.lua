-- A guest's join says one summary sentence whatever order the room speaks in.
--
-- The batching in `test/lua/join.lua` covers the grant-first order: the listing
-- lands before the documents, so its counts join the summary. A room may also
-- name its documents first and publish its listing after — and its text later
-- still — and that order escaped the batching: the summary went out without
-- the mirror, the listing earned its own mirror sentence, and the landing's
-- empty buffer earned the unfetched hint. Three notices for one join.
--
-- The join is one summary plus errors, in every order: a listing that arrives
-- after the summary stays silent (the mirror is `require('selvage').session()`
-- `.mirror`), and the landing the join opened itself never earns the hint.
--
--   nvim --headless -l test/lua/joinorder.lua      (or scripts/test-lua.sh)

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

local sent = {}
local handlers = nil
local responder = nil

package.loaded['selvage.companion'] = {
  start = function(given)
    handlers = given
    return {
      send = function(_, message)
        sent[#sent + 1] = message
        if responder ~= nil then
          responder(message)
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

-- -- documents first, listing after, text never ----------------------------------
--
-- The room names four documents before it publishes its listing, and answers
-- no hold: the landing opens empty and stays empty. Before the fix this was
-- the summary, the mirror sentence and the unfetched hint; now it is the
-- summary and nothing else.

selvage.leave()
local before = #notices
selvage.join('ws://127.0.0.1:1/session?room=r-late&token=t')
handle({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-late' })
handle({
  type = 'report',
  report = { kind = 'documents', documents = { 'ra.lua', 'rb.lua', 'rc.lua', 'rd.lua' } },
})
handle({ type = 'report', report = { kind = 'grant', paths = { 'ra.lua', 'rb.lua', 'rc.lua', 'rd.lua' } } })
handle({ type = 'report', report = { kind = 'peers', peers = {} } })

check('a late listing joins as one summary, not three notices', #notices, before + 1)
local summary = notices[#notices] ~= nil and notices[#notices].message or ''
check('  naming the room and the landing', summary:find('Joined room r-late; opening ra.lua; 3 more', 1, true) ~= nil, true)
check('  at info level', notices[#notices] ~= nil and notices[#notices].level or nil, vim.log.levels.INFO)

local mirror_said = false
local hint_said = false
for index = before + 1, #notices do
  if notices[index].message:find('mirrored at', 1, true) ~= nil then
    mirror_said = true
  end
  if notices[index].message:find('empty until fetched', 1, true) ~= nil then
    hint_said = true
  end
end
check('  with no mirror sentence of its own', mirror_said, false)
check('  and no unfetched hint for the landing', hint_said, false)

-- The mirror is still there, without having been announced: discoverable
-- through the session rather than through a notice.
check('  while the mirror is still discoverable', selvage.session().mirror ~= nil, true)

-- A file opened afterwards still earns the one hint the session gives: the
-- landing's silence is the join's, not a session that never hints.
local root = selvage.session().mirror
local hinted = #notices
vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/rb.lua'))
local hints = 0
for index = hinted + 1, #notices do
  if notices[index].message:find('empty until fetched', 1, true) ~= nil then
    hints = hints + 1
  end
end
check('a file opened after the join still earns the session hint once', hints, 1)

selvage.leave()

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
