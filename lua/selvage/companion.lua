-- The companion process: one per Neovim instance, started on the first command that needs it.
--
-- Newline-delimited JSON both ways (`README.md`, "The local IPC"). Neovim hands `on_stdout` a
-- list of strings split on `\n` where the last element is a partial line, so the reassembly
-- here is the mirror of `companion/ipc.ts`'s.

local M = {}

--- @class selvage.Companion
--- @field job integer
--- @field exited boolean the process has been reaped
local Companion = {}
Companion.__index = Companion

--- The repository root, from this file's own path: lua/selvage/companion.lua is three
--- directories down from it.
local function root()
  local here = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
end

--- How long the companion is given to leave the room on its own before it is killed.
local STOP_GRACE_MS = 2000

--- How often it is looked in on while that runs out.
local STOP_POLL_MS = 50

--- Starts the companion.
--- @param handlers table on_message(message), on_exit(code)
--- @param command string[]|nil the process to run; the companion itself unless a test needs one
---   that does not go on its own when its stdin is closed
function M.start(handlers, command)
  local self = setmetatable({ pending = '', queue = {}, flushing = false, exited = false }, Companion)
  local argv = command
  if argv == nil then
    local node = vim.fn.exepath('node')
    if node == '' then
      return nil, 'node is not on PATH; the companion needs Node 22.18 or newer'
    end
    local entry = root() .. '/companion/main.ts'
    if vim.fn.filereadable(entry) == 0 then
      return nil, 'the companion is missing at ' .. entry
    end
    -- Node prints its own ExperimentalWarning on stderr at startup, which the forwarder
    -- below would show as a session warning. It is not session output, so it is not started with.
    argv = { node, '--no-warnings', entry }
  end
  self.job = vim.fn.jobstart(argv, {
    cwd = root(),
    on_stdout = function(_, data)
      self:receive(data, handlers.on_message)
    end,
    on_stderr = function(_, data)
      local text = table.concat(data, '\n')
      if text:gsub('%s', '') ~= '' then
        vim.notify('selvage: ' .. text, vim.log.levels.WARN)
      end
    end,
    on_exit = function(_, code)
      self.job = nil
      self.exited = true
      handlers.on_exit(code)
    end,
  })
  if self.job <= 0 then
    return nil, 'could not start the companion (' .. table.concat(argv, ' ') .. ')'
  end
  return self
end

function Companion:receive(data, on_message)
  if #data == 0 then
    return
  end
  self.pending = self.pending .. data[1]
  for index = 2, #data do
    local line = self.pending
    self.pending = data[index]
    if line:gsub('%s', '') ~= '' then
      local ok, message = pcall(vim.json.decode, line)
      -- Decoded is not shaped: a bare string or number decodes fine and would fail only when
      -- something indexes it, far from the line that caused it. Said the way an undecodable
      -- line is and dropped before any handler runs.
      if ok and type(message) == 'table' and type(message.type) == 'string' then
        on_message(message)
      else
        vim.notify('selvage: unreadable message from the companion', vim.log.levels.WARN)
      end
    end
  end
end

--- Queues a message. Every send goes through the queue, so that one written from `on_bytes` —
--- where the API is restricted — and one written from a job callback keep their order.
function Companion:send(message)
  if self.job == nil then
    return
  end
  self.queue[#self.queue + 1] = vim.json.encode(message) .. '\n'
  if self.flushing then
    return
  end
  self.flushing = true
  vim.schedule(function()
    self.flushing = false
    self:flush(self.job)
  end)
end

--- Writes whatever is queued. Called on the scheduled tick, and once more on the way out so
--- that a message queued in the same tick as `:SelvageLeave` is not dropped on the floor.
function Companion:flush(job)
  if job == nil or #self.queue == 0 then
    return
  end
  local batch = table.concat(self.queue)
  self.queue = {}
  vim.fn.chansend(job, batch)
end

function Companion:stop()
  local job = self.job
  self.job = nil
  if job == nil then
    return
  end
  self:flush(job)
  -- Closing stdin is what the companion reads as "leave the room": it disconnects and exits on
  -- its own. That disconnect is a round trip to the server, so the process is given time rather
  -- than raced — killing it here would drop whatever the last edit still had in flight. The
  -- waiting is done on a timer and not in `jobwait`, because a network that has stopped
  -- answering must not hold the editor for those two seconds: `:SelvageLeave` returns at once,
  -- and the process is still killed if it has not gone by the end of the grace.
  pcall(vim.fn.chanclose, job, 'stdin')
  local remaining = STOP_GRACE_MS
  local function wait_and_kill()
    -- `on_exit` is what says the process is gone: `jobwait` cannot answer that for a job the
    -- editor has already reaped, and a killed one would be indistinguishable from a timed-out
    -- wait.
    if self.exited then
      return
    end
    remaining = remaining - STOP_POLL_MS
    if remaining <= 0 then
      -- Not gone within the grace: end it. `jobstop` on a job that has just exited is a no-op
      -- rather than an error, so this cannot race the exit callback.
      vim.fn.jobstop(job)
      return
    end
    vim.defer_fn(wait_and_kill, STOP_POLL_MS)
  end
  vim.defer_fn(wait_and_kill, STOP_POLL_MS)
end

return M
