-- Selvage for Neovim: the commands, and which buffers a session shares.
--
-- Everything that decides anything about a document is in the companion process
-- (`companion/`, driving the vendored engine and bridge). What is here is which buffer is
-- shared under which room path, and the wiring between the two.

local companion = require('selvage.companion')
local Document = require('selvage.document')

local api = vim.api

local M = {}

local state = {
  process = nil,
  status = 'idle',
  role = nil,
  room = nil,
  invite = nil,
  --- @type table<string, table> room path to document
  documents = {},
  group = nil,
  -- Whether the next document the room names is still the one to put in front of the user.
  -- Set when a guest joins; cleared by the first document shown.
  auto_open = false,
}

--- The room paths this session holds, ordered so that completion and a prompt agree.
function M.documents()
  local paths = vim.tbl_keys(state.documents)
  table.sort(paths)
  return paths
end

--- Where the session stands, for a statusline or a script.
function M.session()
  return {
    status = state.status,
    role = state.role,
    room = state.room,
    invite = state.invite,
    documents = M.documents(),
  }
end

--- The text of a shared document, as the room holds it.
function M.text(path)
  local document = state.documents[path]
  return document and document:text() or nil
end

local function notify(message, level)
  vim.notify('selvage: ' .. message, level or vim.log.levels.INFO)
end

--- The room path a buffer is shared under, or nil when it is not one to share.
local function room_path(bufnr)
  if vim.bo[bufnr].buftype ~= '' then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  local relative = vim.fn.fnamemodify(name, ':.')
  -- `:.` leaves the path absolute when it is not under the working directory. The directory
  -- the session was started in is the grant (`DESIGN.md` §4.2); anything outside it is not
  -- this room's to share.
  if relative:sub(1, 1) == '/' then
    return nil
  end
  return (relative:gsub('\\', '/'))
end

local function share(bufnr, path)
  if state.process == nil or state.documents[path] ~= nil then
    return
  end
  local document = Document.new(bufnr, path, function(message)
    state.process:send(message)
  end)
  state.documents[path] = document
  document:attach()
  state.process:send({ type = 'open', path = path, text = document:text() })
end

--- The buffer a guest holds the room's document in. It has nowhere on disk to go.
local function guest_buffer(path)
  local name = 'selvage://' .. path
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end
  local bufnr = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].modifiable = true
  return bufnr
end

local function share_current()
  local bufnr = api.nvim_get_current_buf()
  local path = room_path(bufnr)
  if path ~= nil then
    share(bufnr, path)
  end
end

--- Puts a buffer in the window the user is looking at.
local function show(bufnr)
  if bufnr == nil or not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return pcall(api.nvim_win_set_buf, 0, bufnr)
end

--- The room path a user's words name: the room path, its `selvage://` buffer name, or a
--- suffix of the path at a directory boundary. A host above a folder called `workspace`
--- publishes `workspace/README.md`; a guest who types `README.md` means that one.
local function resolve(wanted)
  wanted = wanted:gsub('^selvage://', '')
  if state.documents[wanted] ~= nil then
    return wanted, {}
  end
  local matches = {}
  for _, candidate in ipairs(M.documents()) do
    if candidate:sub(-(#wanted + 1)) == '/' .. wanted then
      matches[#matches + 1] = candidate
    end
  end
  if #matches == 1 then
    return matches[1], matches
  end
  return nil, matches
end

local function choose(paths)
  vim.ui.select(paths, { prompt = 'selvage: open which document?' }, function(choice)
    if choice ~= nil then
      show(state.documents[choice].bufnr)
    end
  end)
end

--- Opens one of the room's documents in the current window.
---
--- With no argument and one document, that document; with several, the user is asked which.
function M.open(path)
  local paths = M.documents()
  if #paths == 0 then
    notify('no shared documents; join a session first', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(path or '')
  if wanted == '' then
    if #paths == 1 then
      show(state.documents[paths[1]].bufnr)
    else
      choose(paths)
    end
    return
  end
  local resolved, candidates = resolve(wanted)
  if resolved == nil then
    if #candidates > 1 then
      notify('"' .. wanted .. '" matches several: ' .. table.concat(candidates, ', '), vim.log.levels.WARN)
    else
      notify('no shared document matches "' .. wanted .. '"; :SelvageOpen alone offers them', vim.log.levels.WARN)
    end
    return
  end
  show(state.documents[resolved].bufnr)
end

--- A host shares what it opens for as long as the session lasts.
local function watch_buffers()
  state.group = api.nvim_create_augroup('SelvageHost', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.group,
    callback = function(event)
      local path = room_path(event.buf)
      if path ~= nil then
        share(event.buf, path)
      end
    end,
  })
end

local function on_status(message)
  state.status = message.state
  state.role = message.role
  state.room = message.roomId
  if message.invite ~= nil then
    state.invite = message.invite
  end
  if message.state == 'hosting' then
    notify('hosting ' .. tostring(message.roomId) .. '; :SelvageCopyInvite to share it')
    share_current()
    watch_buffers()
  elseif message.state == 'joined' then
    notify('joined ' .. tostring(message.roomId))
    state.auto_open = true
  elseif message.state == 'error' then
    notify(tostring(message.message), vim.log.levels.ERROR)
  end
end

local function on_report(report)
  if report.kind == 'documents' then
    if state.role == 'guest' then
      local first = nil
      for _, path in ipairs(report.documents) do
        local bufnr = guest_buffer(path)
        first = first or bufnr
        share(bufnr, path)
      end
      -- Once, for the report that follows the join: the room's document set is what the user
      -- who just ran `:SelvageJoin` asked to be shown. A document the host opens later gets a
      -- buffer and waits for `:SelvageOpen` — stealing the window then would interrupt
      -- whatever the guest is already editing.
      if state.auto_open and first ~= nil then
        state.auto_open = false
        if vim.g.selvage_open_on_join ~= false then
          show(first)
          if #report.documents > 1 then
            notify(('opened %s; %d more, :SelvageOpen to choose'):format(report.documents[1], #report.documents - 1))
          end
        end
      end
    end
  elseif report.kind == 'roomGone' then
    notify('the room is gone: ' .. tostring(report.reason), vim.log.levels.WARN)
  elseif report.kind == 'hostDetached' then
    notify('the host disconnected; the room lasts ' .. tostring(report.graceMs) .. 'ms', vim.log.levels.WARN)
  elseif report.kind == 'sessionError' then
    notify(tostring(report.code) .. ': ' .. tostring(report.message), vim.log.levels.ERROR)
  elseif report.kind == 'applyRefused' or report.kind == 'divergence' then
    notify(report.kind .. ' on ' .. tostring(report.path), vim.log.levels.WARN)
  elseif report.kind == 'saveFailed' then
    notify('could not write ' .. tostring(report.path), vim.log.levels.WARN)
  end
end

local function on_message(message)
  if message.type == 'applyEdit' then
    local document = state.documents[message.path]
    local ok = document ~= nil and document:apply(message) or false
    state.process:send({ type = 'applied', id = message.id, ok = ok })
  elseif message.type == 'save' then
    local document = state.documents[message.path]
    local ok = document == nil or document:save()
    state.process:send({ type = 'saved', id = message.id, ok = ok })
  elseif message.type == 'status' then
    on_status(message)
  elseif message.type == 'report' then
    on_report(message.report)
  end
end

local function reset()
  -- The session is over, so every buffer it shared stops reporting: a callback left attached
  -- would keep sending into a companion that is gone.
  for _, document in pairs(state.documents) do
    document:detach()
  end
  state.documents = {}
  state.status = 'idle'
  state.role = nil
  state.room = nil
  state.invite = nil
  state.auto_open = false
  if state.group ~= nil then
    api.nvim_del_augroup_by_id(state.group)
    state.group = nil
  end
end

local function ensure()
  if state.process ~= nil then
    return state.process
  end
  local process, err
  process, err = companion.start({
    on_message = on_message,
    on_exit = function(code)
      -- A companion this session stopped is no longer its process — `leave` forgets it before
      -- stopping it, and the stop is not waited for — so its exit is not news, whether the
      -- process went on its own or had to be killed. A process the session still knows is one
      -- that went by itself, and that is worth a word when it did not exit cleanly.
      if state.process ~= process then
        return
      end
      state.process = nil
      reset()
      if code ~= 0 then
        notify('the companion exited with ' .. code, vim.log.levels.ERROR)
      end
    end,
  })
  if process == nil then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  state.process = process
  return process
end

--- Mints a room on `url` and shares the current buffer.
function M.host(url)
  if url == nil or url == '' then
    notify('a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080', vim.log.levels.ERROR)
    return
  end
  local process = ensure()
  if process ~= nil then
    process:send({ type = 'host', serverUrl = url, displayName = M.display_name() })
  end
end

--- Joins the room an invite link names.
function M.join(invite)
  if invite == nil or invite == '' then
    notify('an invite link is needed', vim.log.levels.ERROR)
    return
  end
  local process = ensure()
  if process ~= nil then
    process:send({ type = 'join', invite = invite, displayName = M.display_name() })
  end
end

--- Puts the invite on the clipboard and the unnamed register.
function M.copy_invite()
  if state.invite == nil then
    notify('there is no invite: this session is not hosting one', vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('"', state.invite)
  pcall(vim.fn.setreg, '+', state.invite)
  notify(state.invite)
end

--- Leaves the session and stops the companion.
function M.leave()
  if state.process == nil then
    return
  end
  local process = state.process
  state.process = nil
  process:send({ type = 'leave' })
  process:stop()
  reset()
  notify('left the session')
end

--- The name other participants see.
function M.display_name()
  return vim.g.selvage_display_name or (vim.env.USER or 'neovim')
end

return M
