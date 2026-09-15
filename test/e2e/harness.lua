-- What both e2e drivers need: bounded waits, the environment the orchestrator passes, and the
-- result file it reads back.
--
-- Every wait here has a deadline and reports what it actually saw when it expires. A run that
-- fails says which condition never became true and what the buffer held instead.

local M = {}

M.role = 'driver'

--- @return string
local function required(name)
  local value = vim.env[name]
  if value == nil or value == '' then
    error(name .. ' is not set; this script is run by test/e2e/run.ts')
  end
  return value
end

M.env = {
  required = required,
  optional = function(name)
    local value = vim.env[name]
    if value == nil or value == '' then
      return nil
    end
    return value
  end,
}

M.seed_path = nil
M.result_file = nil
M.deadline_ms = 20000
M.reconnect_deadline_ms = 40000

function M.setup(role)
  M.role = role
  M.seed_path = required('SELVAGE_E2E_SEED_PATH')
  M.result_file = required('SELVAGE_E2E_RESULT_FILE')
  M.invite_file = required('SELVAGE_E2E_INVITE_FILE')
  M.markers = {
    host = required('SELVAGE_E2E_MARKER_HOST'),
    guest = required('SELVAGE_E2E_MARKER_GUEST'),
    host2 = required('SELVAGE_E2E_MARKER_HOST_2'),
    guest2 = required('SELVAGE_E2E_MARKER_GUEST_2'),
    mirror = required('SELVAGE_E2E_MARKER_MIRROR'),
  }
  M.joined_file = required('SELVAGE_E2E_JOINED_FILE')
  M.ack_file = required('SELVAGE_E2E_ACK_FILE')
  -- The guest writes this once the mirror's own phases are done, and the host waits for it before
  -- it reads its own file for the marker: an edit saved in the mirror is a message still on its
  -- way to the room until the host has it.
  M.mirror_done_file = required('SELVAGE_E2E_MIRROR_DONE_FILE')
  -- The granted path is required rather than optional: it is the reason this proof runs, and a
  -- driver that quietly skipped the phase because an environment variable was missing would
  -- report a pass for a claim nothing exercised.
  M.granted_path = required('SELVAGE_E2E_GRANTED_PATH')
  M.granted_text = required('SELVAGE_E2E_GRANTED_TEXT')
  M.granted_done_file = required('SELVAGE_E2E_GRANTED_DONE_FILE')
  -- The listing's own phase: the host creates one path and deletes another while the session is
  -- hosted, and the guest writes this file once both have reached its listing and its mirror.
  M.created_path = required('SELVAGE_E2E_CREATED_PATH')
  M.created_text = required('SELVAGE_E2E_CREATED_TEXT')
  M.removed_path = required('SELVAGE_E2E_REMOVED_PATH')
  M.removed_text = required('SELVAGE_E2E_REMOVED_TEXT')
  M.delete_open_ready_file = required('SELVAGE_E2E_DELETE_OPEN_READY_FILE')
  M.watch_done_file = required('SELVAGE_E2E_WATCH_DONE_FILE')
  M.control_file = M.env.optional('SELVAGE_E2E_CONTROL_FILE')
  M.deadline_ms = tonumber(M.env.optional('SELVAGE_E2E_DEADLINE_MS') or '20000')
  M.reconnect_deadline_ms = tonumber(M.env.optional('SELVAGE_E2E_RECONNECT_DEADLINE_MS') or '40000')
  M.outcome = { role = role }
end

function M.log(...)
  local parts = {}
  for _, part in ipairs({ ... }) do
    parts[#parts + 1] = type(part) == 'string' and part or vim.inspect(part)
  end
  io.stdout:write(('[%s] %s\n'):format(M.role, table.concat(parts, ' ')))
  io.stdout:flush()
end

function M.write_file(path, contents)
  local handle = assert(io.open(path, 'w'))
  handle:write(contents)
  handle:close()
end

function M.read_file(path)
  local handle = io.open(path, 'r')
  if handle == nil then
    return nil
  end
  local contents = handle:read('*a')
  handle:close()
  if contents == '' then
    return nil
  end
  return contents
end

--- Records what this instance reached, so the orchestrator can compare the two. `extra` is
--- whatever else the phase has to say — the host's granted phase reports whether it was holding
--- the file before the guest read it, which is what makes the phase about the host's disk
--- rather than about an ordinary open.
function M.record(phase, text, extra)
  local entry = { text = text }
  for key, value in pairs(extra or {}) do
    entry[key] = value
  end
  M.outcome[phase] = entry
  M.write_file(M.result_file, vim.json.encode(M.outcome))
end

--- The host says a phase has landed on its side. Until it has, the guest cannot leave: an edit
--- the guest has made is a message still on its way to the room, and a process that exits takes
--- it with it.
function M.ack(phase)
  M.write_file(M.ack_file .. '.' .. phase, 'ok')
end

function M.wait_ack(phase, deadline_ms)
  return M.wait_for_file('the host to confirm ' .. phase, deadline_ms, M.ack_file .. '.' .. phase)
end

--- Waits for `condition` with a deadline, reporting `observe()` when it expires.
function M.wait(label, deadline_ms, condition, observe)
  M.log('waiting for ' .. label .. ' (deadline ' .. deadline_ms .. 'ms)')
  local ok = vim.wait(deadline_ms, condition, 50)
  if not ok then
    local seen = observe and observe() or '(nothing observed)'
    M.fail(('timed out after %dms waiting for %s; observed: %s'):format(deadline_ms, label, seen))
  end
  M.log('  ' .. label .. ': reached')
  return true
end

function M.wait_for_file(label, deadline_ms, path)
  local contents
  M.wait(label, deadline_ms, function()
    contents = M.read_file(path)
    return contents ~= nil
  end, function()
    return 'no ' .. path
  end)
  return (contents:gsub('%s+$', ''))
end

function M.fail(message)
  M.outcome.error = message
  if M.result_file ~= nil then
    M.write_file(M.result_file, vim.json.encode(M.outcome))
  end
  M.log('FAILED: ' .. message)
  -- Vim's own non-zero exit: it tears the jobs down on the way out, where `os.exit` would leave a
  -- companion process with nowhere to report to — and with no one left to stop it.
  vim.cmd('cq')
end

--- The text the plugin holds for the shared document, as the room counts it.
function M.text()
  return require('selvage').text(M.seed_path)
end

--- The directory this session mirrors the room into, or nil when it has none. The guest's half of
--- this proof is about what a program outside this editor can read, and this is where it reads it.
function M.mirror()
  return require('selvage').session().mirror
end

--- The name the buffer for a room path carries: the file the mirror holds it at, or a
--- `selvage://` name for a path the room's listing does not name. A driver waits for a buffer by
--- name, so it has to wait for what the buffer is actually called.
function M.buffer_name(path)
  local root = M.mirror()
  if root == nil then
    return 'selvage://' .. path
  end
  return root .. '/' .. path
end

--- A file's bytes, or nil when there is no file at all. Unlike `read_file`, an empty file reads as
--- an empty string — a mirrored path whose content has not been fetched is exactly that, and a
--- driver has to tell it apart from a path that is not there — and a file that is one newline
--- reads as one byte, which a line-wise read cannot say.
function M.file_text(path)
  local handle = io.open(path, 'rb')
  if handle == nil then
    return nil
  end
  local contents = handle:read('*a')
  handle:close()
  return contents
end

--- The text the plugin holds for any room path, as the room counts it.
function M.text_of(path)
  return require('selvage').text(path)
end

function M.contains(marker)
  local text = M.text()
  return text ~= nil and text:find(marker, 1, true) ~= nil
end

function M.observe()
  return vim.inspect(M.text())
end

--- Loads the real plugin out of this checkout.
function M.load_plugin()
  local root = vim.env.SELVAGE_E2E_PLUGIN_ROOT
  if root == nil or root == '' then
    error('SELVAGE_E2E_PLUGIN_ROOT is not set')
  end
  vim.opt.runtimepath:prepend(root)
  vim.cmd('runtime! plugin/selvage.lua')
  return require('selvage')
end

function M.done()
  M.log('OK')
  vim.cmd('qall!')
end

return M
