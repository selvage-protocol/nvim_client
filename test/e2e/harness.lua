-- What the two e2e instances need: bounded waits, the environment the orchestrator passes, and
-- the result file it reads back.
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
}

M.seed_path = nil
M.result_file = nil
M.deadline_ms = 20000

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

--- Records what this instance reached, so the orchestrator can compare the two.
function M.record(phase, text, extra)
  local entry = { text = text }
  for key, value in pairs(extra or {}) do
    entry[key] = value
  end
  M.outcome[phase] = entry
  M.write_file(M.result_file, vim.json.encode(M.outcome))
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

--- The row a window wears, as it reads. The `winbar` is an evaluated string — highlight items,
--- `%f`, `%{…}` — so what a driver compares is the text a person sees rather than the items it is
--- written with.
function M.row(win)
  local raw = vim.api.nvim_get_option_value('winbar', { win = win or 0 })
  return vim.api.nvim_eval_statusline(raw, { winid = win or 0 }).str
end

--- The text the plugin holds for the shared document, as the room counts it.
function M.text()
  return require('selvage').text(M.seed_path)
end

--- A file's bytes, or nil when there is no file at all. Unlike `read_file`, an empty file reads as
--- an empty string, and a file that is one newline reads as one byte, which a line-wise read
--- cannot say.
function M.file_text(path)
  local handle = io.open(path, 'rb')
  if handle == nil then
    return nil
  end
  local contents = handle:read('*a')
  handle:close()
  return contents
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
