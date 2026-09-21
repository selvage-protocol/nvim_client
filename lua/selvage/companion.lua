-- The companion process: one per Neovim instance, started on the first command that needs it.
--
-- Newline-delimited JSON both ways (`README.md`, "The local IPC"). Neovim hands `on_stdout` a
-- list of strings split on `\n` where the last element is a partial line, so a line is
-- reassembled here the way `companion/ipc.ts` reassembles the other direction's: to the same
-- byte bound, and with the chunks of a line kept apart until the newline that ends it arrives.

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

--- How many bytes a line from the companion may hold before it is shed rather than collected.
---
--- The same number `companion/ipc.ts` refuses to accumulate past: a whole-document `open` is one
--- JSON line, so a bound below that would refuse real work, and no bound at all lets one runaway
--- write — or a companion whose framing has gone wrong — grow this process's memory for as long
--- as it keeps writing. Past it the line is shed to the newline that ends it, and said once.
local MAX_LINE_BYTES = 32 * 1024 * 1024

--- Starts the companion.
--- @param handlers table on_message(message), on_exit(code)
--- @param command string[]|nil the process to run; the companion itself unless a test needs one
---   that does not go on its own when its stdin is closed
function M.start(handlers, command)
  local self = setmetatable({
    -- The chunks of the line being reassembled, and how many bytes they hold. A line arrives in
    -- chunks of at most 128 KiB and may be a whole document, so appending each chunk to one
    -- string would copy everything before it every time; they are joined once, when the newline
    -- that ends the line arrives.
    pending = {},
    pending_bytes = 0,
    -- Whether the line that ran past `MAX_LINE_BYTES` is being shed to its newline.
    dropping = false,
    queue = {},
    flushing = false,
    exited = false,
  }, Companion)
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

--- Takes one callback's worth of what the companion wrote.
---
--- Neovim splits the stream on `\n` and hands over the tail of the line the call before left
--- unfinished as `data[1]`, every element before the last as a whole line, and the last as the
--- next unfinished tail. A line is therefore the chunks collected for it plus `data[1]`, and it
--- is whole exactly when the call carries a line after it.
function Companion:receive(data, on_message)
  if #data == 0 then
    return
  end
  if self.dropping then
    -- The tail of the line being shed, which carries no newline of its own: a call holding
    -- nothing but it is that line still running, and the newline that ends it is in the first
    -- whole line the next such call carries.
    if #data == 1 then
      return
    end
    self.dropping = false
  else
    self.pending[#self.pending + 1] = data[1]
    self.pending_bytes = self.pending_bytes + #data[1]
  end
  if #data == 1 then
    -- Nothing ended in this call, so the line is still the one being collected — and past the
    -- bound it is one nothing will read: what is collected goes, and the rest of the line with
    -- it, rather than being gathered chunk by chunk until a newline that may never come.
    if self.pending_bytes > MAX_LINE_BYTES then
      self.dropping = true
      self.pending = {}
      self.pending_bytes = 0
      vim.notify(
        ('selvage: the companion wrote a line past %d bytes with no newline in it; dropping it'):format(
          MAX_LINE_BYTES
        ),
        vim.log.levels.WARN
      )
    end
    return
  end
  for index = 2, #data do
    local line = table.concat(self.pending)
    self.pending = { data[index] }
    self.pending_bytes = #data[index]
    if line:gsub('%s', '') ~= '' then
      if #line > MAX_LINE_BYTES then
        -- A whole line past the bound, delivered in one call: nothing this process answers is
        -- that long, so it goes the way a shed one does.
        vim.notify(
          ('selvage: the companion wrote a line past %d bytes; dropping it'):format(MAX_LINE_BYTES),
          vim.log.levels.WARN
        )
      else
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
