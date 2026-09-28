-- The room's panel `:SelvagePeers` opens, against a stubbed companion.
--
--   nvim --headless -l test/lua/panel.lua      (or scripts/test-lua.sh)
--
-- The panel is the web page's faces and sidebar in a split: everyone in the room with their
-- initials in their seat's colour, then the room's files with a badge for each person in them.
-- Its keys act in the window it was opened from. Every wait here is on the effect, with a deadline.

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

local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local selvage = require('selvage')

local function last_of(kind)
  for index = #sent, 1, -1 do
    if sent[index].type == kind then
      return sent[index]
    end
  end
  return nil
end

local function words()
  handlers.on_message({
    type = 'words',
    words = vim.json.decode(table.concat(vim.fn.readfile('test/lua/words.json'), '\n')),
  })
end

local ME = { peer_id = 'p-me', display_name = 'Test User', role = 'host', roster = 'Test User', initials = 'Te', colour = '#cba6f7' }
local ADA = { peer_id = 'p-ada', display_name = 'Ada Lovelace', role = 'guest', roster = 'Ada Lovelace', initials = 'Ad', colour = '#94e2d5' }
local BOB = { peer_id = 'p-bob', display_name = 'Bob', role = 'guest', roster = 'Bob', initials = 'Bo', colour = '#89b4fa' }

local function room(peers, self)
  handlers.on_message({
    type = 'report',
    report = { kind = 'peers', peers = peers, self = self or ME, identity = 'Sharing “panel”' },
  })
end

local function panel_buf()
  return require('selvage.panel').buffer()
end

local function panel_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == panel_buf() then
      return win
    end
  end
  return nil
end

local function lines()
  return vim.api.nvim_buf_get_lines(panel_buf(), 0, -1, false)
end

--- The highlight drawn over the text `needle` on line `lnum`, or nil.
local function highlight_on(lnum, needle)
  local line = lines()[lnum] or ''
  local from = line:find(needle, 1, true)
  if from == nil then
    return nil
  end
  local ns = vim.api.nvim_get_namespaces()['selvage.panel']
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
    if mark[3] == from - 1 and mark[4].hl_group ~= nil then
      return mark[4].hl_group
    end
  end
  return nil
end

--- The badges drawn at the right of line `lnum`, as their text joined.
local function badges_on(lnum)
  local ns = vim.api.nvim_get_namespaces()['selvage.panel']
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
    if mark[4].virt_text ~= nil then
      local text = {}
      for _, chunk in ipairs(mark[4].virt_text) do
        text[#text + 1] = chunk[1]
      end
      return table.concat(text), mark[4].virt_text[1][2], mark[4].virt_text_pos
    end
  end
  return nil
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function on_line(lnum)
  vim.api.nvim_set_current_win(panel_win())
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

vim.fn.mkdir('.tmp/panel/notes', 'p')
local file1 = '.tmp/panel/notes/one.txt'
local file2 = '.tmp/panel/two.txt'
local file0 = '.tmp/panel/a.txt'
vim.fn.writefile({ 'alpha', 'beta' }, file1)
vim.fn.writefile({ 'one', 'two' }, file2)
vim.fn.writefile({ 'a' }, file0)

vim.cmd('edit ' .. file2)
local buf2 = vim.api.nvim_get_current_buf()
selvage.host('ws://127.0.0.1:1')
handlers.on_message({
  type = 'status',
  state = 'hosting',
  role = 'host',
  roomId = 'r-panel',
  invite = 'ws://127.0.0.1:1/session?room=r-panel&token=t',
})
words()
local path2 = last_of('open').path
vim.cmd('edit ' .. file0)
vim.cmd('edit ' .. file1)
local buf1 = vim.api.nvim_get_current_buf()
local path1 = last_of('open').path
local editing = vim.api.nvim_get_current_win()

room({ ADA })
handlers.on_message({
  type = 'presence',
  cursors = {
    { peerId = 'p-ada', label = 'Ada Lovelace', role = 'guest', path = path1, anchor = 7, head = 7, colour = '#94e2d5', fill = '#94e2d540' },
  },
})

-- -- what it shows --------------------------------------------------------------------

local before_open = #notices
vim.cmd('SelvagePeers')
check(':SelvagePeers opens the panel', panel_buf() ~= nil, true)
check('  and says nothing about it', #notices, before_open)
check('  on the left', vim.fn.win_screenpos(panel_win())[2], 1)
check('  and moves there', vim.api.nvim_get_current_win(), panel_win())
check('  as a buffer of its own kind', vim.bo[panel_buf()].filetype, 'selvage')
check('  which the session bar leaves alone', vim.wo[panel_win()].winbar, '')

local folder = path1:match('^(.*)/notes/one%.txt$')
check('the host comes first, crowned, as you', lines()[1], '♛  Te  Test User (you) · Host')
check('  with where you are', lines()[2], '       in ' .. path1)
check('  your initials in your own face', highlight_on(1, ' Te '), 'SelvageYou')
check('  the crown in its colour', highlight_on(1, '♛'), 'SelvageCrown')
check('then the others', lines()[3], '   Ad  Ada Lovelace')
check('  with where they are', lines()[4], '       in ' .. path1)
local ada_group = highlight_on(3, ' Ad ')
check(
  "  their initials on their seat's colour",
  ada_group and vim.api.nvim_get_hl(0, { name = ada_group }).bg,
  tonumber('94e2d5', 16)
)
check('then the files as a tree', lines()[5], '')
local tree = vim.list_slice(lines(), 6)
local n = select(2, folder:gsub('/', '')) + 1
check('  the folders first', tree[n + 1], ('  '):rep(n + 1) .. 'notes/')
check('  a file under its folder', tree[n + 2], ('  '):rep(n + 2) .. 'one.txt')
check('  then the files beside it, even one named before it', tree[n + 3], ('  '):rep(n + 1) .. 'a.txt')
check('  in order', tree[n + 4], ('  '):rep(n + 1) .. 'two.txt')
local one_line = 5 + n + 2
local badge, badge_group, badge_pos = badges_on(one_line)
check("  a person's badge on the file they are in", badge, ' Ad ')
check('    in their colour', badge_group, ada_group)
check('    at the right', badge_pos, 'right_align')
check('  and none where nobody is', badges_on(one_line + 1), nil)
check('  your own file lit', highlight_on(one_line, 'one.txt'), 'SelvagePanelHere')

--- Waits until a caret flush armed before now has had its turn: a timer due later runs later.
local function after_caret_flush()
  local flushed = false
  vim.defer_fn(function()
    flushed = true
  end, 250)
  vim.wait(2000, function()
    return flushed
  end, 10)
end

local function count_of(kind)
  local count = 0
  for _, message in ipairs(sent) do
    if message.type == kind then
      count = count + 1
    end
  end
  return count
end

vim.api.nvim_set_current_win(editing)
after_caret_flush()
local cleared = count_of('selectionCleared')
vim.cmd('SelvagePeers')
vim.api.nvim_win_set_cursor(0, { 3, 0 })
after_caret_flush()
check('your caret stays in your file while you look at the panel', count_of('selectionCleared'), cleared)
check('opening it again moves to the one already open', #vim.api.nvim_tabpage_list_wins(0), 2)
check('  and into it', vim.api.nvim_get_current_win(), panel_win())

-- -- it follows the room --------------------------------------------------------------

room({ ADA, BOB })
check('someone joining is listed at once', lines()[5], '   Bo  Bob')
check('  not in a file yet', lines()[6], '       not in a file yet')
room({ ADA })
check('  and gone again when they leave', lines()[5], '')

-- -- its keys -------------------------------------------------------------------------

vim.api.nvim_set_current_win(editing)
vim.cmd('buffer ' .. buf2)
vim.cmd('SelvagePeers')
on_line(3)
press('<CR>')
check('<CR> on a person goes to them in the window it was opened from', vim.api.nvim_get_current_win(), editing)
check('  showing their file', vim.api.nvim_get_current_buf(), buf1)
check('  on their caret', vim.api.nvim_win_get_cursor(0)[1], 2)
check('  and the panel stays', panel_win() ~= nil, true)

on_line(4)
press('f')
check('f on a person follows them', selvage.following(), 'Ada Lovelace')
check('  from the window the panel acts in', vim.api.nvim_get_current_win(), editing)
check('  and marks them in the panel', lines()[3], ' ◉ Ad  Ada Lovelace')
check('    in the colour the bar marks them', highlight_on(3, '◉'), 'SelvageFollowed')
on_line(3)
press('f')
check('f again stops following', selvage.following(), nil)
check('  and the mark goes', lines()[3], '   Ad  Ada Lovelace')

on_line(one_line + 2)
press('<CR>')
check('<CR> on a file opens it in that window', vim.api.nvim_get_current_buf(), buf2)
check('  which is the window it acts in', vim.api.nvim_get_current_win(), editing)

local asked = nil
local input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  asked = opts
  on_confirm('Grace')
end
on_line(3)
press('r')
check('r on someone else asks nothing', asked, nil)
on_line(2)
press('r')
vim.ui.input = input
check('r on yourself asks for the name', asked and asked.prompt, 'Set the name other participants see: ')
check('  starting from the one you have', asked and asked.default, 'Test User')
check('  and renames you', last_of('rename') and last_of('rename').displayName, 'Grace')

vim.fn.setreg('"', '')
on_line(1)
press('y')
check('y copies the invite link', vim.fn.getreg('"'):find('r-panel', 1, true) ~= nil, true)

on_line(one_line + 2)
vim.cmd('only')
press('<CR>')
check('with no other window left, a file opens in a new one', vim.api.nvim_get_current_buf(), buf2)
check('  beside the panel', #vim.api.nvim_tabpage_list_wins(0), 2)
editing = vim.api.nvim_get_current_win()

on_line(1)
press('q')
check('q closes it', panel_win(), nil)
check('  and leaves the window it acted in', vim.api.nvim_get_current_win(), editing)

-- -- the session ending --------------------------------------------------------------

--- Lets everything already queued for the next turn run, so what follows is the only cause.
local function settle()
  local settled = false
  vim.schedule(function()
    settled = true
  end)
  vim.wait(1000, function()
    return settled
  end, 10)
end

vim.cmd('SelvagePeers')
settle()
vim.fn.confirm = function()
  return 1
end
selvage.leave()
check(
  'leaving closes it',
  vim.wait(2000, function()
    return panel_win() == nil
  end, 10),
  true
)

-- A guest in a room that has shared nothing reads the web page's words for it.
selvage.join('ws://127.0.0.1:1/session?room=r-empty&token=t')
handlers.on_message({ type = 'status', state = 'joined', role = 'guest', roomId = 'r-empty' })
words()
local HANA = { peer_id = 'p-hana', display_name = 'Hana', role = 'host', roster = 'Hana', initials = 'Ha', colour = '#cba6f7' }
local GUEST = { peer_id = 'p-me', display_name = 'Test User', role = 'guest', roster = 'Test User', initials = 'Te', colour = '#94e2d5' }
room({ HANA }, GUEST)
vim.cmd('SelvagePeers')
check('a guest sees the host first', lines()[1], '♛  Ha  Hana · Host')
check('  then themself', lines()[3], '   Te  Test User (you)')
check('  and no files yet', lines()[6], '  The host has not shared any files yet.')
selvage.leave()

if failures > 0 then
  print(('%d FAILED'):format(failures))
  vim.cmd('cquit 1')
end
print('ALL OK')
vim.cmd('quit!')
