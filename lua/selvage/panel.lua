-- The room as the web page's faces and sidebar show it, in a split on the left: everyone in it,
-- then the files the room offers with a badge for each person in them. `:SelvagePeers` opens it.

local api = vim.api

local M = {}

local WIDTH = 36

--- The panel's buffer, what each of its lines stands for, and the window it acts in.
local panel = { buf = nil, rows = {}, target = nil, group = nil }

local function selvage()
  return require('selvage')
end

local function paint()
  pcall(api.nvim_set_hl, 0, 'SelvagePanelName', { bold = true, default = true })
  pcall(api.nvim_set_hl, 0, 'SelvagePanelMuted', { link = 'Comment', default = true })
  pcall(api.nvim_set_hl, 0, 'SelvagePanelFolder', { link = 'Directory', default = true })
  pcall(api.nvim_set_hl, 0, 'SelvagePanelHere', { bold = true, default = true })
end

local function buffer_valid()
  return panel.buf ~= nil and api.nvim_buf_is_valid(panel.buf)
end

--- The windows showing the panel, in every tab.
local function panel_windows()
  local wins = {}
  if buffer_valid() then
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(win) == panel.buf then
        wins[#wins + 1] = win
      end
    end
  end
  return wins
end

local function panel_window()
  if not buffer_valid() then
    return nil
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == panel.buf then
      return win
    end
  end
  return nil
end

--- The window the panel's keys act in: the one it was opened from while it stands, or else
--- another ordinary window in this tab, or a new one beside the panel.
local function target_window()
  local function usable(win)
    return win ~= nil
      and api.nvim_win_is_valid(win)
      and api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage()
      and api.nvim_win_get_buf(win) ~= panel.buf
      and api.nvim_win_get_config(win).relative == ''
  end
  if usable(panel.target) then
    return panel.target
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      panel.target = win
      return win
    end
  end
  local win = api.nvim_open_win(api.nvim_create_buf(true, false), false, { split = 'right', win = panel_window() or 0 })
  panel.target = win
  return win
end

--- One line of pieces `{ text, highlight }`, and where each highlight lands in its bytes.
local function line_of(pieces)
  local text, spans = '', {}
  for _, piece in ipairs(pieces) do
    if piece[2] ~= nil then
      spans[#spans + 1] = { #text, #text + #piece[1], piece[2] }
    end
    text = text .. piece[1]
  end
  return text, spans
end

--- Whether `a` comes before `b` in the web's tree: at each level the folders, then the files.
local function tree_order(a, b)
  for index = 1, math.max(#a, #b) do
    if a[index] ~= b[index] then
      local a_folder, b_folder = index < #a, index < #b
      if a_folder ~= b_folder then
        return a_folder
      end
      return (a[index] or '') < (b[index] or '')
    end
  end
  return false
end

--- The room's paths as a tree: each folder once, before what is in it, and each file under it.
local function tree(paths)
  local sorted = {}
  for _, path in ipairs(paths) do
    sorted[#sorted + 1] = vim.split(path, '/', { plain = true })
  end
  table.sort(sorted, tree_order)
  local entries, seen = {}, {}
  for _, parts in ipairs(sorted) do
    local path = table.concat(parts, '/')
    for depth = 1, #parts - 1 do
      local folder = table.concat(parts, '/', 1, depth)
      if not seen[folder] then
        seen[folder] = true
        entries[#entries + 1] = { folder = true, name = parts[depth], depth = depth - 1 }
      end
    end
    entries[#entries + 1] = { path = path, name = parts[#parts], depth = #parts - 1 }
  end
  return entries
end

--- The window the panel acts in, when there is one to ask: rendering never opens a window.
local function target_window_if_any()
  if
    panel.target ~= nil
    and api.nvim_win_is_valid(panel.target)
    and api.nvim_win_get_buf(panel.target) ~= panel.buf
  then
    return panel.target
  end
  return nil
end

local function render()
  local room = selvage().room(target_window_if_any())
  local lines, marks, rows = {}, {}, {}
  local function add(pieces, row, badges)
    local text, spans = line_of(pieces)
    lines[#lines + 1] = text
    rows[#lines] = row
    marks[#lines] = { spans = spans, badges = badges }
  end

  local by_path = {}
  for _, person in ipairs(room.people) do
    local name = { { person.name, 'SelvagePanelName' } }
    if person.you then
      name[#name + 1] = { ' (you)' }
    end
    if person.host then
      name[#name + 1] = { ' · Host', 'SelvagePanelMuted' }
    end
    local head = {
      person.host and { '♛', 'SelvageCrown' } or { ' ' },
      person.followed and { '◉', 'SelvageFollowed' } or { ' ' },
      { ' ' .. person.initials .. ' ', person.highlight },
      { ' ' },
    }
    vim.list_extend(head, name)
    add(head, person)
    local indent = (' '):rep(2 + vim.fn.strdisplaywidth(person.initials) + 3)
    local where = person.path ~= nil and ('in ' .. person.path) or 'not in a file yet'
    add({ { indent }, { where, 'SelvagePanelMuted' } }, person)
    if not person.you and person.path ~= nil then
      local list = by_path[person.path] or {}
      by_path[person.path] = list
      list[#list + 1] = person
    end
  end

  add({ { '' } }, nil)
  local entries = tree(room.files)
  if #entries == 0 then
    local empty = room.role == 'host' and 'Nothing here yet.' or 'The host has not shared any files yet.'
    add({ { '  ' }, { empty, 'SelvagePanelMuted' } }, nil)
  end
  for _, entry in ipairs(entries) do
    local indent = (' '):rep(2 + 2 * entry.depth)
    if entry.folder then
      add({ { indent }, { entry.name .. '/', 'SelvagePanelFolder' } }, nil)
    else
      local badges = {}
      for _, person in ipairs(by_path[entry.path] or {}) do
        if #badges > 0 then
          badges[#badges + 1] = { ' ' }
        end
        badges[#badges + 1] = { ' ' .. person.initials .. ' ', person.highlight }
      end
      local here = entry.path == room.here
      add(
        { { indent }, { entry.name, here and 'SelvagePanelHere' or nil } },
        { file = entry.path },
        #badges > 0 and badges or nil
      )
    end
  end
  return lines, marks, rows, room
end

local namespace = api.nvim_create_namespace('selvage.panel')

local function close()
  for _, win in ipairs(panel_windows()) do
    if #api.nvim_list_wins() > 1 then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if buffer_valid() then
    pcall(api.nvim_buf_delete, panel.buf, { force = true })
  end
  panel.buf = nil
  panel.rows = {}
  if panel.group ~= nil then
    pcall(api.nvim_del_augroup_by_id, panel.group)
    panel.group = nil
  end
end

--- Draws the panel again from the room, when it is open. A session that has ended closes it.
function M.refresh()
  if not buffer_valid() then
    return
  end
  local status = selvage().session().status
  if status ~= 'hosting' and status ~= 'joined' then
    -- Closed on the next turn: a session ends inside window events of its own.
    vim.schedule(close)
    return
  end
  paint()
  local lines, marks, rows = render()
  vim.bo[panel.buf].modifiable = true
  api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.bo[panel.buf].modified = false
  api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
  for lnum, mark in pairs(marks) do
    for _, span in ipairs(mark.spans) do
      api.nvim_buf_set_extmark(panel.buf, namespace, lnum - 1, span[1], { end_col = span[2], hl_group = span[3] })
    end
    if mark.badges ~= nil then
      api.nvim_buf_set_extmark(panel.buf, namespace, lnum - 1, 0, { virt_text = mark.badges, virt_text_pos = 'right_align' })
    end
  end
  panel.rows = rows
end

local function row_under_cursor()
  return panel.rows[api.nvim_win_get_cursor(0)[1]]
end

--- Runs `act` in the window the panel acts in, which is where going somewhere lands.
local function in_target(act)
  local win = target_window()
  api.nvim_set_current_win(win)
  act()
end

local function enter()
  local row = row_under_cursor()
  if row == nil then
    return
  end
  if row.file ~= nil then
    local room = selvage().room()
    in_target(function()
      if room.role == 'host' then
        vim.cmd.edit(vim.fn.fnameescape(room.root .. '/' .. row.file))
      else
        selvage().open(row.file)
      end
    end)
  elseif row.peerId ~= nil and not row.you then
    in_target(function()
      selvage().go_to(row.peerId)
    end)
  end
end

local function follow()
  local row = row_under_cursor()
  if row == nil or row.peerId == nil or row.you then
    return
  end
  if row.followed then
    selvage().stop_following()
    return
  end
  in_target(function()
    selvage().follow(row.peerId)
  end)
end

local function rename()
  local row = row_under_cursor()
  if row == nil or not row.you then
    return
  end
  vim.ui.input({ prompt = 'Set the name other participants see: ', default = row.label }, function(name)
    if name ~= nil and vim.trim(name) ~= '' then
      selvage().set_display_name(name)
    end
  end)
end

local function create_buffer()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  api.nvim_buf_set_name(buf, 'Selvage')
  vim.bo[buf].filetype = 'selvage'
  local function key(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  key('<CR>', enter, 'Go to them, or open the file')
  key('f', follow, 'Follow, or stop following')
  key('r', rename, 'Rename')
  key('y', function()
    selvage().copy_invite()
  end, 'Copy invite link')
  key('q', close, 'Close')
  panel.group = api.nvim_create_augroup('selvage.panel', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = panel.group,
    callback = function()
      -- On the next turn, when a window being opened shows the buffer it was opened for.
      vim.schedule(function()
        local win = api.nvim_get_current_win()
        if api.nvim_win_get_buf(win) ~= buf and api.nvim_win_get_config(win).relative == '' then
          panel.target = win
        end
        M.refresh()
      end)
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = panel.group,
    buffer = buf,
    callback = function()
      panel.buf = nil
      panel.rows = {}
      vim.schedule(function()
        if panel.buf == nil and panel.group ~= nil then
          pcall(api.nvim_del_augroup_by_id, panel.group)
          panel.group = nil
        end
      end)
    end,
  })
  return buf
end

--- Opens the panel on the left, or moves to it when it is already open in this tab.
function M.open()
  local win = panel_window()
  if win ~= nil then
    api.nvim_set_current_win(win)
    M.refresh()
    return
  end
  local from = api.nvim_get_current_win()
  if api.nvim_win_get_config(from).relative == '' then
    panel.target = from
  end
  if not buffer_valid() then
    panel.buf = create_buffer()
  end
  win = api.nvim_open_win(panel.buf, true, { split = 'left', win = -1, width = WIDTH })
  for option, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    wrap = false,
    cursorline = true,
    winfixwidth = true,
    spell = false,
    list = false,
  }) do
    vim.wo[win][0][option] = value
  end
  M.refresh()
end

M.close = close

--- The panel's buffer, or nil while it is closed.
function M.buffer()
  return buffer_valid() and panel.buf or nil
end

return M
