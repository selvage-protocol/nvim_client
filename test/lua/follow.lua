-- Going to a participant, and following one, against a stubbed companion.
--
--   nvim --headless -l test/lua/follow.lua      (or scripts/test-lua.sh)
--
-- `test/lua/session.lua` covers what a session does with buffers and presence; this covers
-- what it does with people — landing where a peer is, staying there while they move, and
-- every way the follow ends. Every wait here is on the effect with a deadline that reports
-- what it saw; nothing sleeps and hopes.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime! plugin/selvage.lua')

-- A name for the sessions this file starts.
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

--- Replaces the companion with one that records what it is asked to send and answers
--- nothing, so that a test can say what a session did without a process on the other end
--- of a pipe.
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

--- The notice, if any, added since `from` that contains `needle`.
local function said_since(from, needle)
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      return notices[index].message
    end
  end
  return nil
end

local function last_of(kind)
  for index = #sent, 1, -1 do
    if sent[index].type == kind then
      return sent[index]
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

--- Waits for a message of `kind` whose `field` is `value` to be sent after `before` of
--- them were already on record. The publish a landing arms is deferred by the coalescing
--- interval, so this polls the record rather than assuming the turn.
local function wait_for_sent(kind, field, value, before)
  local found = vim.wait(2000, function()
    for index = before + 1, #sent do
      if sent[index].type == kind and sent[index][field] == value then
        return true
      end
    end
    return false
  end, 50)
  return found
end

local function cursor()
  local position = vim.api.nvim_win_get_cursor(0)
  -- A string, because positions are tables and `==` on two tables is identity.
  return ('%d,%d'):format(position[1], position[2])
end

vim.fn.mkdir('.tmp', 'p')

-- -- going to a participant ------------------------------------------------------
--
-- A host holding two files, with two peers in the room. Offsets are over
-- `alpha\nbeta\ngamma\n`: offset 7 is the `e` in `beta` (row 1, byte column 1), offset 13
-- the `m` in `gamma` (row 2, byte column 2). The second file holds `one\ntwo\n`, where
-- offset 4 starts `two` (row 1, byte column 0).

local file1 = '.tmp/lua-follow-one.txt'
local file2 = '.tmp/lua-follow-two.txt'
vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, file1)
vim.fn.writefile({ 'one', 'two' }, file2)
vim.cmd('edit ' .. vim.fn.fnameescape(file1))
local buf1 = vim.api.nvim_get_current_buf()

selvage.host('ws://127.0.0.1:1')
handlers().on_message({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-follow' })
local path1 = last_of('open') and last_of('open').path
check('the first file is opened in the room', last_of('open') ~= nil, true)

vim.cmd('edit ' .. vim.fn.fnameescape(file2))
local buf2 = vim.api.nvim_get_current_buf()
local path2 = last_of('open') and last_of('open').path
check('  and the second file with it', path1 ~= path2, true)

local function peers_report(peers)
  handlers().on_message({ type = 'report', report = { kind = 'peers', peers = peers } })
end

local function presence(cursors)
  handlers().on_message({ type = 'presence', cursors = cursors })
end

local function cursor_for(peer_id, path, head, colour)
  return {
    peerId = peer_id,
    label = peer_id == 'p-ada' and 'Ada' or 'Bob',
    role = 'guest',
    path = path,
    anchor = head,
    head = head,
    colour = colour or '#61afef',
    fill = '#61afef40',
  }
end

peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

local before_go = #notices
selvage.go_to('Ada')
check('going to a peer shows their document', vim.api.nvim_get_current_buf(), buf1)
check('  with the cursor on their caret', cursor(), '2,1')
check('  and says nothing about it', #notices, before_go)

selvage.go_to('p-bob')
check('a peer id names the peer too', vim.api.nvim_get_current_buf(), buf2)
check('  with the cursor on their caret', cursor(), '2,0')

local before_unknown = #notices
selvage.go_to('Nobody')
check(
  'a name nobody carries says so',
  said_since(before_unknown, 'no participant matches "Nobody"') ~= nil,
  true
)

-- Two people can share a display name and the room does not forbid it, so the refusal
-- disambiguates with the identity: the shortest id prefix that tells them apart.
peers_report({
  { peer_id = 'p-ada1', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-ada2', display_name = 'Ada', role = 'guest' },
})
local before_several = #notices
selvage.go_to('Ada')
check(
  'a name two peers share is refused with both told apart',
  said_since(before_several, '"Ada" matches several: Ada (p-ada1), Ada (p-ada2)') ~= nil,
  true
)
-- The full id still names either of them exactly.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

-- A peer the room names whose caret is not drawn is someone in no document this client
-- holds: there is nothing to land on, so the command refuses rather than landing at zero.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
local before_nodoc = #notices
selvage.go_to('Cara')
check(
  'a peer in no document refuses the jump',
  said_since(before_nodoc, 'nothing to go to: Cara is not in a document') ~= nil,
  true
)
check('  and leaves the window where it was', vim.api.nvim_get_current_buf(), buf2)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})

-- With no name and several participants the user is asked which: the rows name the role
-- and the document, and choosing one lands on them. Cancelling lands nowhere.
local select = vim.ui.select
local offered, prompt, formatted = nil, nil, nil
vim.ui.select = function(items, opts, on_choice)
  offered, prompt = items, opts.prompt
  formatted = {}
  for _, item in ipairs(items) do
    formatted[#formatted + 1] = opts.format_item(item)
  end
  on_choice(items[2], 2)
end
selvage.go_to('')
vim.ui.select = select
check('a bare go-to asks which participant', prompt, 'selvage: go to which participant?')
check('  offering every participant', offered ~= nil and #offered, 2)
check(
  '  each row naming the document they are in',
  formatted ~= nil and formatted[1]:find(path1, 1, true) ~= nil,
  true
)
check('  and lands on the one chosen', vim.api.nvim_get_current_buf(), buf2)
check('  with the cursor on their caret', cursor(), '2,0')

select = vim.ui.select
local asked = 0
vim.ui.select = function(_, _, on_choice)
  asked = asked + 1
  on_choice(nil)
end
local before_cancel = #notices
selvage.go_to('')
vim.ui.select = select
check('cancelling the picker asks once and lands nowhere', asked, 1)
check('  and says nothing', #notices, before_cancel)

-- With no name and one participant, that one: no question to ask.
peers_report({ { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' } })
presence({ cursor_for('p-ada', path1, 7) })
local before_single = #notices
selvage.go_to('')
check('a bare go-to with one participant lands directly', vim.api.nvim_get_current_buf(), buf1)
check('  with the cursor on their caret', cursor(), '2,1')
check('  and says nothing about it', #notices, before_single)

check(
  'completion offers the participants by name',
  table.concat(vim.fn.getcompletion('SelvageGoTo ', 'cmdline'), ','),
  'Ada'
)
check(
  '  and so does the follow',
  table.concat(vim.fn.getcompletion('SelvageFollow A', 'cmdline'), ','),
  'Ada'
)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

-- A caret the report drew and the buffer lost is a landing that cannot be made: the room
-- knew where they were and the buffer is gone, so the jump refuses rather than landing at
-- zero. Deleting a `selvage://`-less file buffer leaves the document entry behind — no
-- watcher answers for it — which is exactly the stale entry this exercises.
vim.api.nvim_buf_delete(buf1, { force = true })
local before_stale = #notices
selvage.go_to('Ada')
check(
  'a caret that no longer resolves refuses the jump',
  said_since(before_stale, "nothing to go to: Ada's caret does not resolve here") ~= nil,
  true
)

-- With no session there is no room to name anyone in, and a room with nobody in it is a
-- different answer from a room with nobody drawn in it.
selvage.leave()
local before_nosession = #notices
selvage.go_to('Ada')
check(
  'with no session going anywhere says there is none',
  said_since(before_nosession, 'join a session first') ~= nil,
  true
)
selvage.follow('Ada')
check(
  '  and so does following',
  said_since(before_nosession, 'join a session first') ~= nil,
  true
)
check('following nothing is nothing', selvage.following(), nil)
check('  and the statusline says nothing either', selvage.statusline(), '')

-- -- following a participant --------------------------------------------------------
--
-- A guest now, holding the room's documents: the peer moves, changes document, is edited
-- around, edits nothing themselves, leaves, and is renamed. The window follows the peer's
-- caret through all of it until something ends the follow.

vim.cmd('edit ' .. vim.fn.fnameescape(file1))
selvage.join('ws://127.0.0.1:1/room#tok')
handlers().on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-gfollow' })
handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'g/one.txt', 'g/two.txt' } },
})
peers_report({ { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' } })

--- The room's text for a held document, as an `applyEdit` carrying the version the shadow
--- counts: what the sync sends a guest that opened the buffer before the text arrived.
local applied_ids = 0
local function arrive(path, text)
  applied_ids = applied_ids + 1
  handlers().on_message({
    type = 'applyEdit',
    id = applied_ids,
    path = path,
    start = 0,
    ['end'] = 1,
    text = text,
    version = 0,
  })
end

arrive('g/one.txt', 'alpha\nbeta\ngamma\n')
arrive('g/two.txt', 'one\ntwo\n')
presence({ cursor_for('p-ada', 'g/one.txt', 7) })

check('following nobody before anything begins', selvage.following(), nil)

local before_follow = #notices
local selections_before = count_type('selection')
selvage.follow('Ada')
check('following lands on the peer', vim.fn.bufname('%'), 'selvage://g/one.txt')
check('  with the cursor on their caret', cursor(), '2,1')
check(
  '  and says so once the landing is made',
  said_since(before_follow, 'following Ada') ~= nil,
  true
)
check('  which the session reports', selvage.following(), 'Ada')
check('  which the global reports by peer id', vim.g.selvage_following, 'p-ada')
check(
  '  which the window reports with the way to stop',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow# following Ada — :SelvageStopFollowing to stop %*'
)
check('  which the statusline reports', selvage.statusline(), 'following Ada')
check(
  '  in the colour the bridge gave the peer',
  vim.api.nvim_get_hl(0, { name = 'SelvageFollow' }).bg,
  tonumber('61afef', 16)
)
check(
  '  and the landing reaches the room through the coalesced publish',
  wait_for_sent('selection', 'path', 'g/one.txt', selections_before),
  true
)

-- The peer moves: the next frame moves the follower's caret with them.
local notices_after_landing = #notices
presence({ cursor_for('p-ada', 'g/one.txt', 13) })
check('a frame that moves the peer moves the follower', cursor(), '3,2')
check('  in the same document', vim.fn.bufname('%'), 'selvage://g/one.txt')
check('  without saying so again', #notices, notices_after_landing)

-- The peer changes document: the follow goes through the ordinary open path again, leaving
-- the previous document open and landing in the new one.
presence({ cursor_for('p-ada', 'g/two.txt', 4) })
check('a peer changing document takes the follow with them', vim.fn.bufname('%'), 'selvage://g/two.txt')
check('  with the cursor on their caret', cursor(), '2,0')
check(
  '  and the previous document stays open',
  vim.fn.bufnr('selvage://g/one.txt') ~= -1,
  true
)

-- A remote edit is not a local one: the room's text moving under the follow re-lands it
-- and never ends it.
local two_text = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('selvage://g/two.txt'), 0, -1, true), '\n')
check('the room text is what the follow holds', two_text, 'one\ntwo')
applied_ids = applied_ids + 1
local before_remote = #notices
handlers().on_message({
  type = 'applyEdit',
  id = applied_ids,
  path = 'g/two.txt',
  start = 7,
  ['end'] = 7,
  text = '!',
  version = 1,
})
check('the remote edit is answered', last_of('applied') and last_of('applied').ok, true)
check('  and the follow stands through it', selvage.following(), 'Ada')
check('  saying nothing', #notices, before_remote)
check('  on the peer caret still', cursor(), '2,0')

-- Back to the first document, and then an edit of the follower's own in the other shared
-- document: any shared document, not only the one followed, because the follow would yank
-- the caret back onto the keystroke either way.
presence({ cursor_for('p-ada', 'g/one.txt', 13) })
check('the follow comes back with the peer', vim.fn.bufname('%'), 'selvage://g/one.txt')
local before_other_edit = #notices
vim.api.nvim_buf_set_lines(vim.fn.bufnr('selvage://g/two.txt'), 0, 0, false, { 'ONE' })
check('the edit reached the room', last_of('change') and last_of('change').path, 'g/two.txt')
check(
  'a local edit in another shared document ends the follow',
  said_since(before_other_edit, 'stopped following Ada') ~= nil,
  true
)
check('  which the session reports', selvage.following(), nil)
check('  which the global reports', vim.g.selvage_following, nil)
check('  which the window reports', vim.api.nvim_get_option_value('winbar', { win = 0 }), '')
check('  which the statusline reports', selvage.statusline(), '')

-- An edit in the followed document itself ends it the same way.
local before_refollow = #notices
selvage.follow('Ada')
check('following again says so again', said_since(before_refollow, 'following Ada') ~= nil, true)
local before_own_edit = #notices
vim.api.nvim_buf_set_lines(vim.fn.bufnr('selvage://g/one.txt'), 0, 0, false, { 'ALPHA' })
check(
  'a local edit in the followed document ends the follow',
  said_since(before_own_edit, 'stopped following Ada') ~= nil,
  true
)
check('  and the buffer keeps the edit', table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('selvage://g/one.txt'), 0, 1, true), '\n'), 'ALPHA')

-- Stopping through the command and through the indicator's own sentence: the indicator is
-- the stop control's label, and the command is the control.
selvage.follow('Ada')
vim.cmd('SelvageStopFollowing')
local before_stop = #notices
selvage.follow('Ada')
vim.cmd('SelvageStopFollowing')
check(
  'stopping through the command says so',
  said_since(before_stop, 'stopped following Ada') ~= nil,
  true
)
check('  and takes the indicator down', vim.api.nvim_get_option_value('winbar', { win = 0 }), '')
local before_nothing = #notices
vim.cmd('SelvageStopFollowing')
check(
  'stopping with nothing to stop says so',
  said_since(before_nothing, 'not following anyone') ~= nil,
  true
)

-- The peer leaving ends the follow with their name on it. The membership report is what
-- says so: presence alone cannot tell a departure from a frame with nothing to draw.
selvage.follow('Ada')
local before_leave = #notices
peers_report({})
check(
  'the peer leaving ends the follow',
  said_since(before_leave, 'Ada left the room, so following stopped') ~= nil,
  true
)
check('  which the session reports', selvage.following(), nil)
check('  and the indicator with it', vim.api.nvim_get_option_value('winbar', { win = 0 }), '')

-- A rename keeps the follow: the target is the peer id, which a rename does not change.
peers_report({ { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' } })
presence({ cursor_for('p-ada', 'g/one.txt', 13) })
selvage.follow('Ada')
peers_report({ { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' } })
presence({
  {
    peerId = 'p-ada',
    label = 'Ada Lovelace',
    role = 'guest',
    path = 'g/one.txt',
    anchor = 13,
    head = 13,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('a rename keeps the follow', selvage.following(), 'Ada Lovelace')
check(
  '  and re-labels the indicator',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow# following Ada Lovelace — :SelvageStopFollowing to stop %*'
)

-- A deliberate navigation ends a follow: going somewhere stops following first.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  {
    peerId = 'p-ada',
    label = 'Ada Lovelace',
    role = 'guest',
    path = 'g/one.txt',
    anchor = 13,
    head = 13,
    colour = '#61afef',
    fill = '#61afef40',
  },
  cursor_for('p-bob', 'g/two.txt', 4, '#98c379'),
})
local before_goto = #notices
selvage.go_to('Bob')
check(
  'going somewhere while following stops the follow first',
  said_since(before_goto, 'stopped following Ada Lovelace') ~= nil,
  true
)
check('  and lands where asked', vim.fn.bufname('%'), 'selvage://g/two.txt')
check('  with the cursor on their caret', cursor(), '2,0')
check('  and follows nobody now', selvage.following(), nil)

-- Following someone else re-targets; following the same peer re-lands, saying nothing new.
local before_retarget = #notices
selvage.follow('Ada Lovelace')
check(
  'following while following re-targets with the new name',
  said_since(before_retarget, 'following Ada Lovelace') ~= nil,
  true
)
check('  which the global reports', vim.g.selvage_following, 'p-ada')
local retarget_notices = #notices
selvage.follow('Bob')
check('  and again for the other peer', said_since(retarget_notices, 'following Bob') ~= nil, true)
check('  which the global reports anew', vim.g.selvage_following, 'p-bob')
local idempotent_notices = #notices
selvage.follow('Bob')
check('following the peer already followed re-lands silently', #notices, idempotent_notices)
check('  on their caret', cursor(), '2,0')

-- Following a peer the room names but draws nothing for refuses, establishing nothing.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
selvage.stop_following()
local before_follow_nodoc = #notices
selvage.follow('Cara')
check(
  'following a peer in no document refuses',
  said_since(before_follow_nodoc, 'nothing to follow: Cara is not in a document') ~= nil,
  true
)
check('  establishing nothing', selvage.following(), nil)
check('  and raising no indicator', vim.api.nvim_get_option_value('winbar', { win = 0 }), '')

-- -- landing where the text has not arrived yet --------------------------------------
--
-- The room names a document nobody here has text for. The buffer the listing made is empty
-- and the peer is already there: the jump goes through the ordinary open path — the buffer
-- the room offered — and the follow lands again once the text arrives.

handlers().on_message({
  type = 'report',
  report = { kind = 'documents', documents = { 'g/one.txt', 'g/two.txt', 'g/late.txt' } },
})
check(
  'a document opened later does not steal the window',
  vim.fn.bufname('%'),
  'selvage://g/two.txt'
)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-zed', display_name = 'Zed', role = 'guest' },
})
presence({
  {
    peerId = 'p-zed',
    label = 'Zed',
    role = 'guest',
    path = 'g/late.txt',
    anchor = 2,
    head = 2,
    colour = '#e06c75',
    fill = '#e06c7540',
  },
})
selvage.go_to('Zed')
check(
  'jumping where the text has not arrived shows the room document',
  vim.fn.bufname('%'),
  'selvage://g/late.txt'
)
check('  the buffer the listing offered', vim.fn.bufnr('selvage://g/late.txt') ~= -1, true)

-- The text arrives; the follow that starts now lands where the caret resolves rather than
-- where the empty buffer clamped it.
arrive('g/late.txt', 'hey\n')
selvage.follow('Zed')
check('following into arrived text lands on the caret', cursor(), '1,2')
check('  in the arrived document', vim.fn.bufname('%'), 'selvage://g/late.txt')
check('  saying so', selvage.following(), 'Zed')

selvage.leave()
vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
