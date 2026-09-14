-- The companion process: one per Neovim instance, started on the first command that needs it.
--
-- Newline-delimited JSON both ways (`README.md`, "The local IPC"). Neovim hands `on_stdout` a
-- list of strings split on `\n` where the last element is a partial line, so the reassembly
-- here is the mirror of `companion/ipc.ts`'s.

local M = {}

--- @class selvage.Companion
--- @field job integer
local Companion = {}
Companion.__index = Companion

--- The repository root, from this file's own path: lua/selvage/companion.lua is three
--- directories down from it.
local function root()
  local here = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
end

--- Starts the companion.
--- @param handlers table on_message(message), on_exit(code)
function M.start(handlers)
  local self = setmetatable({ pending = '', queue = {}, flushing = false }, Companion)
  local node = vim.fn.exepath('node')
  if node == '' then
    return nil, 'node is not on PATH; the companion needs Node 22.18 or newer'
  end
  local entry = root() .. '/companion/main.ts'
  if vim.fn.filereadable(entry) == 0 then
    return nil, 'the companion is missing at ' .. entry
  end
  self.job = vim.fn.jobstart({ node, entry }, {
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
      handlers.on_exit(code)
    end,
  })
  if self.job <= 0 then
    return nil, 'could not start the companion (' .. node .. ' ' .. entry .. ')'
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
      if ok then
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
    if self.job == nil then
      return
    end
    local batch = table.concat(self.queue)
    self.queue = {}
    vim.fn.chansend(self.job, batch)
  end)
end

function Companion:stop()
  local job = self.job
  self.job = nil
  self.queue = {}
  if job ~= nil then
    -- Closing stdin is what the companion reads as "leave the room"; it exits on its own.
    pcall(vim.fn.chanclose, job, 'stdin')
    vim.fn.jobstop(job)
  end
end

return M
