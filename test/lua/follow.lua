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

--- The peers the room last named, which is what the session's own row counts: everyone the
--- room lists, plus this client.
local named_peers = {}

--- The row the session itself wears in a window with no follow standing, as the indicator
--- writes it. This file runs a live session, so a row that is not the follow's is the
--- session's — the words themselves are pinned in `test/lua/session.lua`, and what is pinned
--- here is that the follow's row came down and the session's took its place.
local function session_row()
  local who = selvage.session().status == 'hosting' and 'hosting' or 'guest'
  local here = #named_peers + 1
  local count = here == 1 and '1 person in the room' or ('%d people in the room'):format(here)
  return ('%%#SelvageSession#Selvage: %s — %s%%*'):format(who, count)
end

local function peers_report(peers)
  named_peers = peers
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


-- A follow whose target leaves every document says so once: the indicator keeps saying
-- Following and the window stays put, so the change from somewhere to nowhere is news —
-- once, not per frame, and again after they came back and left.
local before_undrawn = #notices
selvage.follow('Ada')
check('following a peer lands on them', selvage.following(), 'Ada')
presence({})
check(
  'a target with no drawable caret is said once',
  said_since(before_undrawn, 'Ada is not in a document; still following.') ~= nil,
  true
)
local before_second_blank = #notices
presence({})
check('  and not per frame', said_since(before_second_blank, 'still following') ~= nil, false)
check('  while the follow stands', selvage.following(), 'Ada')
presence({ cursor_for('p-ada', path1, 7) })
check('  landing again where they came back to', cursor(), '2,1')
local before_relapse = #notices
presence({})
check(
  '  but again after they came back and left',
  said_since(before_relapse, 'Ada is not in a document; still following.') ~= nil,
  true
)
selvage.stop_following()
-- The landings above moved the window; the tests below start from where the go-to left it.
vim.api.nvim_set_current_buf(buf2)
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
check(
  'completion tells two peers sharing a name apart',
  table.concat(vim.fn.getcompletion('SelvageGoTo A', 'cmdline'), ','),
  'Ada (p-ada1),Ada (p-ada2)'
)
-- A disambiguated row names its peer back, and a typed jump to a peer in no document
-- pends on the frames rather than refusing: the room may be one presence update behind
-- the command, and refusing that would lie about a peer already somewhere.
peers_report({
  { peer_id = 'p-ada1', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-ada2', display_name = 'Ada', role = 'guest' },
})
presence({})
local before_pendname = #notices
selvage.go_to('Ada (p-ada1)')
check('a disambiguated row names its peer back, silently', #notices, before_pendname)
check('  leaving the window where it was', vim.api.nvim_get_current_buf(), buf2)
presence({
  {
    peerId = 'p-ada1',
    label = 'Ada',
    role = 'guest',
    path = path1,
    anchor = 7,
    head = 7,
    colour = '#61afef',
    fill = '#61afef40',
  },
})
check('  landing when the room draws them', vim.api.nvim_get_current_buf(), buf1)
check('  on their caret', cursor(), '2,1')
check('  still saying nothing', #notices, before_pendname)
-- The full id still names either of them exactly.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

-- The picker reads the room fresh: a peer who left between opening it and choosing matches
-- nobody now, rather than landing on the row as it stood.
local select_go = vim.ui.select
local go_choice = nil
vim.ui.select = function(items, _, on_choice)
  go_choice = { items = items, on_choice = on_choice }
end
selvage.go_to('')
vim.ui.select = select_go
check('a bare go-to still asks which participant', go_choice ~= nil and #go_choice.items, 2)
peers_report({})
local go_row = go_choice.items[1]
local before_stale_go = #notices
local _ = go_choice.on_choice(go_row)
check(
  'choosing a peer who has since left refuses cleanly',
  said_since(before_stale_go, 'no participant matches "' .. go_row.label .. '"') ~= nil,
  true
)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

-- A peer the room names whose caret is not drawn is someone in no document this client
-- holds — which reads exactly like a presence update one frame away — so the typed jump
-- pends on the frames rather than refusing, and lands when the room draws them.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
})
local before_pend = #notices
selvage.go_to('Cara')
check('a jump to a peer in no document pends silently', #notices, before_pend)
check('  leaving the window where it was', vim.api.nvim_get_current_buf(), buf1)
presence({
  cursor_for('p-ada', path1, 7),
  {
    peerId = 'p-cara',
    label = 'Cara',
    role = 'guest',
    path = path1,
    anchor = 7,
    head = 7,
    colour = '#98c379',
    fill = '#98c37940',
  },
})
check('  landing when the room draws them', vim.api.nvim_get_current_buf(), buf1)
check('  on their caret', cursor(), '2,1')
check('  still saying nothing', #notices, before_pend)

-- A newer go-to supersedes a pending one: the late frame for the old target must not yank
-- the window back to it.
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})
selvage.go_to('Cara')
selvage.go_to('Bob')
check('a newer jump lands', vim.api.nvim_get_current_buf(), buf2)
check('  on their caret', cursor(), '2,0')
local before_super = #notices
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
  {
    peerId = 'p-cara',
    label = 'Cara',
    role = 'guest',
    path = path1,
    anchor = 7,
    head = 7,
    colour = '#98c379',
    fill = '#98c37940',
  },
})
check('  and the superseded pend never yanks back', vim.api.nvim_get_current_buf(), buf2)
check('  saying nothing', #notices, before_super)

-- A peer leaving while pended matches nobody now, and the cleared pend never lands
-- afterwards: the room no longer names them, whatever a stale frame still draws.
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})
selvage.go_to('Cara')
local before_leftpend = #notices
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
check(
  'a peer leaving while pended matches nobody',
  said_since(before_leftpend, 'no participant matches "Cara"') ~= nil,
  true
)
local before_stalepend = #notices
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
  {
    peerId = 'p-cara',
    label = 'Cara',
    role = 'guest',
    path = path1,
    anchor = 7,
    head = 7,
    colour = '#98c379',
    fill = '#98c37940',
  },
})
check('  and never lands afterwards', vim.api.nvim_get_current_buf(), buf2)
check('  saying nothing', #notices, before_stalepend)

-- The picker refuses its own doc-less rows where the row says as much: the row reads `no
-- shared document open`, so the refusal answers what the user just saw. Unknown ids match
-- nobody either way.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})
local select_nodoc = vim.ui.select
local nodoc_choice = nil
vim.ui.select = function(items, _, on_choice)
  nodoc_choice = { items = items, on_choice = on_choice }
end
selvage.go_to('')
vim.ui.select = select_nodoc
local nodoc_row = nil
for _, item in ipairs(nodoc_choice.items) do
  if item.peerId == 'p-cara' then
    nodoc_row = item
  end
end
check('a bare go-to still offers the peer in no document', nodoc_row ~= nil, true)
local before_nodoc_pick = #notices
nodoc_choice.on_choice(nodoc_row)
check(
  'choosing them refuses with it',
  said_since(before_nodoc_pick, 'nothing to go to: Cara is not in a document') ~= nil,
  true
)
check('  leaving the window where it was', vim.api.nvim_get_current_buf(), buf2)
local before_unknown_id = #notices
selvage.go_to('p-zzz')
check(
  'an unknown peer id matches nobody going',
  said_since(before_unknown_id, 'no participant matches "p-zzz"') ~= nil,
  true
)
selvage.follow('p-zzz')
check(
  '  or following',
  said_since(before_unknown_id, 'no participant matches "p-zzz"') ~= nil,
  true
)
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

-- A caret the report drew and the buffer lost re-opens where the host's own file still is:
-- the room knew where they were and the file is still on disk, so the jump shows it again
-- rather than refusing. Deleting a file buffer leaves the document entry behind — no
-- watcher answers for it — which is exactly the stale entry this exercises.
vim.api.nvim_buf_delete(buf1, { force = true })
local before_stale = #notices
selvage.go_to('Ada')
check(
  'a jump to a caret whose buffer is gone re-opens the host file',
  (vim.fn.bufname('%'):find('lua-follow-one', 1, true) ~= nil),
  true
)
check('  on their caret', cursor(), '2,1')
check(
  '  saying the hold the re-open takes, the way a fetch does',
  said_since(before_stale, path1 .. ' is opened in the room, so every peer receives it.') ~= nil,
  true
)
check('  and only that', #notices, before_stale + 1)
buf1 = vim.api.nvim_get_current_buf()

-- A host never creates on a peer's behalf: a caret drawn where the file has since gone is
-- refused with what could not be opened rather than opened into being, and a link
-- pointing out of the folder is outside it — the open resolves the path before measuring
-- it against the grant, so a peer naming the link reads the refusal rather than the file
-- it points at.
local gone_file = '.tmp/lua-follow-gone.txt'
vim.fn.writefile({ 'here', 'gone' }, gone_file)
vim.cmd('edit ' .. vim.fn.fnameescape(gone_file))
local gone_path = last_of('open') and last_of('open').path
check('the gone file is held', gone_path ~= nil, true)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-mallory', display_name = 'Mallory', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-mallory', gone_path, 1),
})
vim.api.nvim_buf_delete(vim.fn.bufnr(vim.fn.getcwd() .. '/' .. gone_file), { force = true })
vim.fn.delete(gone_file)
local mallory_buf = vim.api.nvim_get_current_buf()
local before_missing = #notices
selvage.go_to('Mallory')
check(
  'a jump to no readable file refuses with what could not be opened',
  said_since(before_missing, 'could not open ' .. gone_path .. ' from the room: there is no readable file there') ~= nil,
  true
)
check(
  '  creating nothing',
  vim.fn.bufnr(vim.fn.getcwd() .. '/' .. gone_file),
  -1
)
check('  leaving the window where it was', vim.api.nvim_get_current_buf(), mallory_buf)

local link_file = '.tmp/lua-follow-link.txt'
local link_target = vim.fn.stdpath('cache') .. '/selvage-link-target.txt'
vim.fn.delete(link_file)
vim.fn.writefile({ 'inside' }, link_file)
vim.fn.writefile({ 'outside' }, link_target)
vim.cmd('edit ' .. vim.fn.fnameescape(link_file))
local link_path = last_of('open') and last_of('open').path
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-nancy', display_name = 'Nancy', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-nancy', link_path, 1),
})
vim.api.nvim_buf_delete(vim.fn.bufnr(vim.fn.getcwd() .. '/' .. link_file), { force = true })
vim.fn.delete(link_file)
vim.uv.fs_symlink(link_target, vim.fn.getcwd() .. '/' .. link_file)
local nancy_buf = vim.api.nvim_get_current_buf()
local before_outside = #notices
selvage.go_to('Nancy')
check(
  'a jump through a link out of the folder refuses as outside it',
  said_since(before_outside, 'could not open ' .. link_path .. ' from the room: the path is not one this window shares') ~= nil,
  true
)
check(
  '  opening neither the link nor its target',
  vim.fn.bufnr(vim.fn.getcwd() .. '/' .. link_file),
  -1
)
check('  leaving the window where it was', vim.api.nvim_get_current_buf(), nancy_buf)
vim.fn.delete(vim.fn.getcwd() .. '/' .. link_file)

-- A standing follow whose document will not open says so once: every frame retries the
-- same refusal, and the second saying carries nothing the first did not.
local tmp_file = '.tmp/lua-follow-unopen.txt'
vim.fn.writefile({ 'tmp' }, tmp_file)
vim.cmd('edit ' .. vim.fn.fnameescape(tmp_file))
local tmp_path = last_of('open') and last_of('open').path
check('the tmp file is held', tmp_path ~= nil, true)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-tmp', display_name = 'Tmp', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-tmp', tmp_path, 1),
})
selvage.follow('Tmp')
check('following into the tmp file lands on the caret', cursor(), '1,1')
vim.api.nvim_buf_delete(vim.fn.bufnr(vim.fn.getcwd() .. '/' .. tmp_file), { force = true })
vim.fn.delete(tmp_file)
local before_unopen = #notices
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-tmp', tmp_path, 1),
})
check(
  'a follow whose document will not open says so once',
  said_since(before_unopen, 'could not open ' .. tmp_path .. ' from the room: there is no readable file there') ~= nil,
  true
)
check('  and stands through it', selvage.following(), 'Tmp')
local after_first_warn = #notices
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-tmp', tmp_path, 1),
})
check('  saying nothing the second frame', #notices, after_first_warn)
check('  still standing', selvage.following(), 'Tmp')
selvage.stop_following()
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
presence({
  cursor_for('p-ada', path1, 7),
  cursor_for('p-bob', path2, 4, '#98c379'),
})

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
selvage.join('ws://127.0.0.1:1/session?room=r-gfollow&token=t')
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
    ['end'] = 0,
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
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Ada — click or :SelvageStopFollowing to stop %X%*'
)
check('  which the statusline reports', selvage.statusline(), 'following Ada')
-- The indicator's colour is the peer's marker colour: what the caret wears.
local ada_marker = nil
for _, peer in ipairs(selvage.peers()) do
  if peer.peerId == 'p-ada' then
    ada_marker = peer.colour
  end
end
check(
  '  in the colour of the peer marker',
  ada_marker ~= nil
    and vim.api.nvim_get_hl(0, { name = 'SelvageFollow' }).bg == tonumber(ada_marker:sub(2), 16),
  true
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
check('the room text is what the follow holds', two_text, 'one\ntwo\n')
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
check('  which the window reports', vim.api.nvim_get_option_value('winbar', { win = 0 }), session_row())
check('  which the statusline reports', selvage.statusline(), 'Selvage: guest — 2 people in the room')

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

-- The client counts LF: a remote edit carrying CRLF bytes is still the room's text, so the
-- follow stands through it, while typing CRLF locally ends it all the same. The versions
-- are counted by hand: `g/two.txt` arrived at 0, took one remote edit and one local one
-- (a local change counts too), so the next one applies at 3.
presence({ cursor_for('p-ada', 'g/one.txt', 13) })
selvage.follow('Ada')
local before_crlf_remote = #notices
applied_ids = applied_ids + 1
local crlf_id = applied_ids
handlers().on_message({
  type = 'applyEdit',
  id = crlf_id,
  path = 'g/two.txt',
  start = 7,
  ['end'] = 7,
  text = '!\r\n',
  version = 3,
})
check('a remote CRLF edit is answered', last_of('applied') and last_of('applied').ok, true)
check('  and the follow stands through it', selvage.following(), 'Ada')
check('  saying nothing', #notices, before_crlf_remote)
local before_crlf_local = #notices
vim.api.nvim_buf_set_lines(vim.fn.bufnr('selvage://g/two.txt'), -1, -1, true, { 'x\r', 'y' })
check(
  'typing CRLF locally ends it all the same',
  said_since(before_crlf_local, 'stopped following Ada') ~= nil,
  true
)
presence({ cursor_for('p-ada', 'g/one.txt', 13) })

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
check(
  '  and takes the indicator down',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  session_row()
)
local before_nothing = #notices
vim.cmd('SelvageStopFollowing')
check(
  'stopping with nothing to stop says so',
  said_since(before_nothing, 'not following anyone') ~= nil,
  true
)

-- The indicator doubles as the stop control: what a click on it runs is the stop command's
-- own handler, looked up by the Vim function name the winbar's `%0@...@` label names. A click
-- reaches Neovim when 'mouse' is set, and Neovim — unlike Vim — sets it by default (`nvi`),
-- so a mouse-reporting terminal stops the follow with no configuration; a terminal without
-- one still has `:SelvageStopFollowing` and typing. Here the handler is called the way
-- the click would call it.
selvage.follow('Ada')
check(
  'the click label names a Vim function that exists',
  vim.fn.exists('*SelvageStopFollowing'),
  1
)
local before_click = #notices
local clicked = pcall(function()
  return vim.fn.SelvageStopFollowing(0, 1, 'l', '')
end)
check('the indicator answers a click', clicked, true)
if clicked then
  check(
    '  stopping the follow',
    said_since(before_click, 'stopped following Ada') ~= nil,
    true
  )
  check('  which the session reports', selvage.following(), nil)
  check('  which the global reports', vim.g.selvage_following, nil)
  check('  and takes the indicator down', vim.api.nvim_get_option_value('winbar', { win = 0 }), session_row())
end

-- Leaving the window does not end the follow: the indicator rides along instead.
selvage.follow('Ada')
vim.cmd('split')
check(
  'the split window carries the indicator',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Ada — click or :SelvageStopFollowing to stop %X%*'
)
check('  and the follow stands through the switch', selvage.following(), 'Ada')
vim.cmd('close')
check(
  'coming back keeps the indicator',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Ada — click or :SelvageStopFollowing to stop %X%*'
)
check('  and the follow with it', selvage.following(), 'Ada')
selvage.stop_following()

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
check('  and the indicator with it', vim.api.nvim_get_option_value('winbar', { win = 0 }), session_row())

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
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Ada Lovelace — click or :SelvageStopFollowing to stop %X%*'
)
-- The re-label comes from the membership report itself, not the next presence frame: a peer
-- who renames and goes idle reads correctly indefinitely.
peers_report({ { peer_id = 'p-ada', display_name = 'Ada', role = 'guest' } })
check('a rename on the peers report alone re-labels the follow', selvage.following(), 'Ada')
check(
  '  and the indicator with it',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Ada — click or :SelvageStopFollowing to stop %X%*'
)
peers_report({ { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' } })
check('  and back again while the peer stays silent', selvage.following(), 'Ada Lovelace')

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

-- The indicator is the window's, but the editor swaps its row per buffer: moving it — by
-- re-target or by hand — saves every buffer's own row and puts it back on leaving, so no
-- buffer keeps the indicator behind it and stopping takes down every copy standing.
local one_buf = vim.fn.bufnr('selvage://g/one.txt')
local two_buf = vim.fn.bufnr('selvage://g/two.txt')
vim.api.nvim_win_set_buf(0, one_buf)
check(
  'the indicator follows the window across documents',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Bob — click or :SelvageStopFollowing to stop %X%*'
)
-- A split showing the same buffer keeps its own copy: leaving the buffer in one window
-- must not take the indicator down in the other.
vim.cmd('vsplit')
local split_wins = vim.api.nvim_list_wins()
check('the split shows the same document', #split_wins, 2)
local other_win = split_wins[1] == vim.api.nvim_get_current_win() and split_wins[2] or split_wins[1]
vim.api.nvim_win_set_buf(0, two_buf)
check(
  'the window left behind is put back while its sibling keeps the indicator',
  vim.api.nvim_get_option_value('winbar', { win = other_win }),
  '%#SelvageFollow#%0@SelvageStopFollowing@ Following Bob — click or :SelvageStopFollowing to stop %X%*'
)
vim.cmd('only')
vim.api.nvim_win_set_buf(0, two_buf)
selvage.stop_following()
vim.api.nvim_win_set_buf(0, one_buf)
check(
  'stopping leaves no row in the buffer left',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  session_row()
)
vim.api.nvim_win_set_buf(0, two_buf)
check(
  '  nor in the one stopped in',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  session_row()
)

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
check('  and raising no indicator', vim.api.nvim_get_option_value('winbar', { win = 0 }), session_row())

-- The follow picker reads the room fresh too. A peer still here but in no document refuses
-- with it; one who left it matches nobody now — not "not in a document" for a peer who is
-- not in the room at all.
local select_follow = vim.ui.select
local follow_choice = nil
vim.ui.select = function(items, _, on_choice)
  follow_choice = { items = items, on_choice = on_choice }
end
selvage.follow('')
vim.ui.select = select_follow
local follow_row = nil
for _, item in ipairs(follow_choice.items) do
  if item.peerId == 'p-ada' then
    follow_row = item
  end
end
check('a bare follow still asks which participant', follow_row ~= nil, true)
presence({})
local before_stale_follow = #notices
follow_choice.on_choice(follow_row)
check(
  'choosing a peer now in no document refuses with it',
  said_since(before_stale_follow, 'nothing to follow: Ada Lovelace is not in a document') ~= nil,
  true
)
check('  establishing nothing', selvage.following(), nil)
vim.ui.select = select_follow
peers_report({
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
})
local before_left_pick = #notices
follow_choice.on_choice(follow_row)
check(
  'choosing a peer who has since left matches nobody',
  said_since(before_left_pick, 'no participant matches "Ada Lovelace"') ~= nil,
  true
)
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
  { peer_id = 'p-cara', display_name = 'Cara', role = 'guest' },
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

-- A first landing that lands nowhere refuses instead of establishing: the peer's buffer
-- wiped after the frame that drew it leaves a drawn caret with no buffer behind it, and a
-- follow standing there has no indicator and no stop state.
selvage.stop_following()
vim.api.nvim_buf_delete(vim.fn.bufnr('selvage://g/late.txt'), { force = true })
local winbar_no_follow = vim.api.nvim_get_option_value('winbar', { win = 0 })
local before_ghost = #notices
selvage.follow('Zed')
check(
  'a follow that lands nowhere refuses instead of standing a ghost',
  said_since(before_ghost, "nothing to follow: Zed's caret does not resolve here") ~= nil,
  true
)
check('  establishing nothing', selvage.following(), nil)
check('  and raising no indicator', vim.g.selvage_following, nil)
check(
  '  leaving the window as it was',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  winbar_no_follow
)
check('  and never saying it landed', said_since(before_ghost, 'following Zed'), nil)

-- The text arriving over the sync retries a pending jump: a wiped buffer re-opens on the
-- attempt and lands when the room's text arrives, with no new presence frame needed. The
-- draw comes first — presence only draws documents held here, so the stale row the wipe
-- leaves behind is what the jump opens from.
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
vim.api.nvim_buf_delete(vim.fn.bufnr('selvage://g/one.txt'), { force = true })
local before_heal = #notices
selvage.go_to('Ada Lovelace')
check(
  'a jump to a wiped buffer opens it and pends',
  vim.fn.bufname('%') ~= 'selvage://g/one.txt',
  true
)
check(
  '  saying the hold the opening takes, the way a fetch does',
  said_since(before_heal, 'g/one.txt is opened in the room, so every peer receives it.') ~= nil,
  true
)
check('  and only that', #notices, before_heal + 1)
arrive('g/one.txt', 'alpha\nbeta\ngamma\n')
check(
  'landing when the text arrives with no new frame',
  vim.fn.bufname('%'),
  'selvage://g/one.txt'
)
check('  saying nothing new on arrival', #notices, before_heal + 1)

-- The marks go with the membership: a peer the room no longer names leaves no caret
-- behind even before the next presence frame redraws.
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
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
})
local presence_ns = vim.api.nvim_get_namespaces()['selvage.presence']
check(
  'the departed peer takes their marks with them',
  #vim.api.nvim_buf_get_extmarks(vim.fn.bufnr('selvage://g/two.txt'), presence_ns, 0, -1, {}),
  0
)
-- The membership report is the room's own list: a peer it no longer names is gone even
-- before the next presence frame redraws, and completion stops offering them with it.
peers_report({
  { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest' },
  { peer_id = 'p-bob', display_name = 'Bob', role = 'guest' },
})
local departed = true
for _, peer in ipairs(selvage.peers()) do
  if peer.peerId == 'p-zed' then
    departed = false
  end
end
check('a departed peer leaves the listing on the next membership report', departed, true)
check(
  '  and completion with it',
  table.concat(vim.fn.getcompletion('SelvageFollow Z', 'cmdline'), ','),
  ''
)
local before_gone_follow = #notices
selvage.follow('Zed')
check(
  'following a departed peer matches nobody',
  said_since(before_gone_follow, 'no participant matches "Zed"') ~= nil,
  true
)

-- Leaving ends the follow silently: the session going says its own sentence, and none of
-- the follow's. `leave` says `left the session` for itself; the pin is that no sentence
-- about the follow is said alongside it.
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
local winbar_before_refollow = vim.api.nvim_get_option_value('winbar', { win = 0 })
check('  the session row stood under it', winbar_before_refollow, session_row())
selvage.follow('p-ada')
check('following again before leaving', selvage.following(), 'Ada Lovelace')
-- Leaving with the follow spread across buffers: every buffer left behind was already put
-- back on leaving it, so ending the session with one hidden drops nothing with the map.
vim.api.nvim_win_set_buf(0, vim.fn.bufnr('selvage://g/two.txt'))
local before_leave = #notices
selvage.leave()
check('leaving ends the follow', selvage.following(), nil)
check('  clears the global', vim.g.selvage_following, nil)
check(
  '  restores the window',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  ''
)
vim.api.nvim_win_set_buf(0, vim.fn.bufnr('selvage://g/one.txt'))
check(
  '  leaving no row in the buffer left behind either',
  vim.api.nvim_get_option_value('winbar', { win = 0 }),
  ''
)
check('  saying nothing about the follow', said_since(before_leave, 'following'), nil)

selvage.leave()
vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
