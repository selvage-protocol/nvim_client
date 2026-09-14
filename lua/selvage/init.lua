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
}

--- Where the session stands, for a statusline or a script.
function M.session()
  return {
    status = state.status,
    role = state.role,
    room = state.room,
    invite = state.invite,
    documents = vim.tbl_keys(state.documents),
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
  elseif message.state == 'error' then
    notify(tostring(message.message), vim.log.levels.ERROR)
  end
end

local function on_report(report)
  if report.kind == 'documents' then
    if state.role == 'guest' then
      for _, path in ipairs(report.documents) do
        share(guest_buffer(path), path)
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
  state.documents = {}
  state.status = 'idle'
  state.role = nil
  state.room = nil
  state.invite = nil
  if state.group ~= nil then
    api.nvim_del_augroup_by_id(state.group)
    state.group = nil
  end
end

local function ensure()
  if state.process ~= nil then
    return state.process
  end
  local process, err = companion.start({
    on_message = on_message,
    on_exit = function(code)
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
  state.process:send({ type = 'leave' })
  state.process:stop()
  state.process = nil
  reset()
  notify('left the session')
end

--- The name other participants see.
function M.display_name()
  return vim.g.selvage_display_name or (vim.env.USER or 'neovim')
end

return M
