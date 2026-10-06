-- The two runtime floors this plugin states in its README, in one place: the Neovim its API is
-- written against, and the Node whose TypeScript type stripping the companion's entry point is
-- launched for. `plugin/selvage.lua` checks the first as the plugin is set up,
-- `selvage.companion` checks both before it starts a job, and `selvage.health` reports both.
--
-- A version is compared by its numbers rather than with `vim.version()`'s own operators: those
-- are newer than the floor this module exists to test.

local M = {}

--- The Neovim this plugin needs, `major.minor`.
M.neovim = '0.12'

--- The Node this plugin needs, `major.minor`.
M.node = '22.18'

--- How long `node --version` is given before it is killed. Node answers at once, so this is only
--- reached by a `node` that does not answer at all — a wrapper waiting on a network mount, say —
--- and the editor must not wait on that.
local PROBE_TIMEOUT_MS = 5000

--- The numbers a version text starts with: `v22.18.0`, `22.18`, `0.12.5-dev`. A text that starts
--- with anything else is nil rather than a guess: the version a program prints is the one its
--- `--version` begins with, and a number further in is something else's.
--- @param text string
--- @return table|nil {major, minor, patch}
function M.parse(text)
  if type(text) ~= 'string' then
    return nil
  end
  local major, minor, patch = text:match('^%s*v?(%d+)%.(%d+)%.?(%d*)')
  if major == nil then
    return nil
  end
  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = patch ~= '' and tonumber(patch) or 0,
  }
end

--- Whether a found version is at or above a floor: each one a text or a `vim.version()` table.
--- The floors are `major.minor`, which is the granularity compared; a patch either side names is
--- not. A version that cannot be read is not a supported one.
--- @param found string|table|nil
--- @param floor string|table
--- @return boolean
function M.at_least(found, floor)
  local have = type(found) == 'table' and found or M.parse(found)
  local want = type(floor) == 'table' and floor or M.parse(floor)
  if have == nil or want == nil or type(have.major) ~= 'number' then
    return false
  end
  if have.major ~= want.major then
    return have.major > want.major
  end
  return (have.minor or 0) >= (want.minor or 0)
end

--- The one sentence a version below a floor is refused with: what is needed and what was found,
--- so the reader can act on it without asking again.
--- @param what string the program, named as a reader would: `Neovim`, `Node`
--- @param floor string
--- @param found string
--- @return string
function M.refusal(what, floor, found)
  return ('this plugin needs %s %s or newer; this is %s.'):format(what, floor, found)
end

--- The sentence a machine with no `node` on `PATH` is refused with.
--- @return string
function M.no_node()
  return ('node is not on PATH; the companion needs Node %s or newer.'):format(M.node)
end

--- The version `exe --version` printed — its first line, which is where a `--version` puts it —
--- or nil and why it could not be read.
---
--- Bounded: a `node` that never answers is killed rather than holding the editor, and one that
--- does not run at all is a sentence rather than a traceback out of a job that was never started.
--- @param exe string
--- @return string|nil, string|nil
function M.read_version(exe)
  local ok, answer = pcall(
    vim.system,
    { exe, '--version' },
    { text = true, timeout = PROBE_TIMEOUT_MS }
  )
  if not ok then
    return nil, ('%s could not be run: %s.'):format(exe, tostring(answer))
  end
  local out = answer:wait()
  -- `wait` answers nil when the process is still there after the timeout and the kill that
  -- follows it: a probe that cannot be ended is a refusal, not an error out of this function.
  if out == nil then
    return nil, ('%s --version did not answer and would not stop.'):format(exe)
  end
  if out.code ~= 0 then
    return nil, ('%s --version did not answer (exit %s).'):format(exe, tostring(out.code))
  end
  -- The first line alone, so that what a wrapper prints after the version cannot reach a
  -- sentence a user reads as one line.
  local line = out.stdout:match('^[^\n]*')
  if line == '' then
    return nil, ('%s --version answered nothing.'):format(exe)
  end
  return line
end

--- Why the Node named would not run the companion, or nil when it would.
--- @param exe string
--- @return string|nil
function M.node_refusal(exe)
  local text, why = M.read_version(exe)
  if text == nil then
    return why
  end
  local found = vim.trim(text)
  if M.at_least(found, M.node) then
    return nil
  end
  return M.refusal('Node', M.node, found)
end

--- Why this Neovim would not run the plugin, or nil when it would.
--- @return string|nil
function M.neovim_refusal()
  local found = vim.version()
  if M.at_least(found, M.neovim) then
    return nil
  end
  return M.refusal(
    'Neovim',
    M.neovim,
    ('%d.%d.%d'):format(found.major, found.minor, found.patch or 0)
  )
end

return M
