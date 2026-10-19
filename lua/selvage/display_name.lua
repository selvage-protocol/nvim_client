-- The name other participants see.
--
-- It comes from `vim.g.selvage_display_name`, the environment, or the answer remembered from the
-- last session, and the prompt starts from the login name. A name the room would refuse is refused
-- here rather than shortened: the room's limit is in UTF-16 units, and a truncated name is not a
-- name anyone chose.
local utf16 = require('selvage.utf16')
local notify = require('selvage.notify').notify
local can_prompt = require('selvage.prompt').can_prompt
local state = require('selvage.state').state

local M = {}

--- The room's limit on a display name, counted the way the protocol counts: UTF-16 code units,
--- so an astral character costs two. A name at the limit is allowed and one over it is refused,
--- never shortened, because the room must see the name its owner chose or no name at all.
local MAX_DISPLAY_NAME = 32

--- How long `name` is beside the limit, in the unit the room counts and the sentence both
--- clients use: UTF-16 code units, so an astral character costs two.
local function over_long(name)
  return ('%d UTF-16 code units and the limit is %d'):format(utf16.len(name), MAX_DISPLAY_NAME)
end

--- Whether a name with nobody to re-ask fits the limit, saying so when it does not. A false
--- answer means what the caller was about to do did not happen, and `did` names which: the
--- name came from a setting rather than from a question, so the sentence is where that setting
--- is — the only place this refusal can be acted on.
local function acceptable(name, source, did)
  if utf16.len(name) <= MAX_DISPLAY_NAME then
    return true
  end
  notify(
    ('this name is %s; a name is refused rather than shortened, so %s. Set a shorter one in %s.'):format(
      over_long(name),
      did,
      source
    ),
    vim.log.levels.ERROR
  )
  return false
end

--- The name the room is told this client is, when one has been configured: the plugin's own
--- global first, then `SELVAGE_DISPLAY_NAME`, the variable the launcher and the runbook set.
--- Nil when there is neither, because that is the case that asks. The second value names the
--- source, so a refusal can say which setting to change.
local function configured_display_name()
  local name = vim.g.selvage_display_name
  local source = 'vim.g.selvage_display_name'
  if name == nil or vim.trim(tostring(name)) == '' then
    name = vim.env.SELVAGE_DISPLAY_NAME
    source = 'SELVAGE_DISPLAY_NAME'
  end
  if name == nil or vim.trim(tostring(name)) == '' then
    return nil
  end
  return vim.trim(tostring(name)), source
end

--- The name a prompted answer left behind, so a restart is not asked again: the other
--- half of the last server address, in a file beside it under `stdpath`. Read when a
--- session starts without a configured name, written when one is answered or set.
--- A read or write that fails is not a session's failure, so both give up silently.
local function last_display_name_file()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_display_name')
end

--- The name the file remembers, or nil when no session has answered yet or it cannot be read.
local function read_last_display_name()
  local ok, lines = pcall(vim.fn.readfile, last_display_name_file())
  if not ok or type(lines) ~= 'table' or #lines < 1 then
    return nil
  end
  local name = vim.trim(tostring(lines[1]))
  if name == '' then
    return nil
  end
  return name
end

--- Remembers `name` for the next session, in this Neovim and after it.
local function remember_last_display_name(name)
  local file = last_display_name_file()
  pcall(vim.fn.mkdir, vim.fs.dirname(file), 'p')
  pcall(vim.fn.writefile, { name }, file)
end

--- The login name, as the suggestion a prompt starts from. Nothing is ever seated under it: it
--- is what the user is offered, and `$USERNAME` is the name the other platform sets.
local function login_name()
  return vim.env.USER or vim.env.USERNAME or ''
end

--- Runs `callback(name)` with the name a session starting now should use: the configured
--- value, else the remembered answer, else one question whose answer is written down.
---
--- With neither the global nor the environment set, the user is asked once with `vim.ui.input`,
--- pre-filled with the login name, and the answer becomes the global and the remembered file,
--- so neither this Neovim nor the next one asks again. The pre-fill is a suggestion and nothing
--- more: it is not an answer, so a cancelled or emptied prompt refuses the session rather than
--- seating a room under a name nobody chose. Nobody to ask is the same refusal said
--- differently — a process without a UI starts no room rather than guessing one.
---
--- Every one of those names has to fit the room's limit. A name the user typed is asked for again
--- with its length; one that came from the global or the environment has nobody to re-ask, so it
--- stops the session rather than being shortened.
local function resolve_display_name(callback)
  local configured, source = configured_display_name()
  if configured ~= nil then
    if acceptable(configured, source, 'the session was not started') then
      callback(configured)
    end
    return
  end
  local remembered = read_last_display_name()
  if remembered ~= nil and utf16.len(remembered) <= MAX_DISPLAY_NAME then
    callback(remembered)
    return
  end
  if not can_prompt() then
    notify(
      'no display name is set and there is no one to ask; set vim.g.selvage_display_name or SELVAGE_DISPLAY_NAME, or run :SelvageDisplayName.',
      vim.log.levels.ERROR
    )
    return
  end
  -- An empty answer is asked again with the refusal leading the prompt, the way VS Code's box
  -- stays open under `a name is needed.`; a cancelled prompt starts nothing and says nothing,
  -- as Escape does there.
  local function ask(lead)
    vim.ui.input(
      {
        prompt = ('%sThe name other participants see (at most %d characters): '):format(
          lead or '',
          MAX_DISPLAY_NAME
        ),
        default = login_name(),
      },
      function(input)
      if input == nil then
        return
      end
      local name = vim.trim(input)
      if name == '' then
        ask('A name is needed. ')
        return
      end
      if utf16.len(name) > MAX_DISPLAY_NAME then
        notify(
          ('this name is %s; a name is refused rather than shortened.'):format(over_long(name)),
          vim.log.levels.ERROR
        )
        ask()
        return
      end
      vim.g.selvage_display_name = name
      remember_last_display_name(name)
      callback(name)
    end)
  end
  ask()
end

--- The name other participants see, when one is in force: the plugin's global, the
--- environment's name, or the remembered answer — which is what a session starting now
--- would use without asking. Nil when there is none of those: nothing is invented here —
--- a name nobody chose is not a name, and the login name is only ever what the prompt
--- starts from — so a script reading this can tell that the next host or join will ask,
--- or refuse where there is no one to ask. It reports whatever was configured, so a name
--- over the room's limit comes back too; that one stops a session rather than being
--- shortened, and `:SelvageDisplayName` says so.
function M.display_name()
  local configured = configured_display_name()
  if configured ~= nil then
    return configured
  end
  return read_last_display_name()
end

--- Sets the name other participants see, and says when it takes effect.
---
--- Before a session the name rides in the `host`/`join` handshake. During one the change is sent
--- now, as `session.rename`, and the room is told with `peer.renamed`: the sign and
--- `:SelvagePeers` re-label from that event, so the name in force is the room's answer rather
--- than anything held here. With no name, it reports the one now in force instead of setting an
--- empty one. A name over the room's limit is refused with its length, before either, since a
--- session cannot join under one and a report of it as the name in force would be a lie.
function M.set_display_name(name)
  local wanted = vim.trim(name or '')
  if wanted == '' then
    local name = M.display_name()
    if name == nil then
      notify('no display name is set yet.')
    else
      local _, source = configured_display_name()
      if source ~= nil and not acceptable(name, source, 'the next session will not start') then
        return
      end
      notify(('the name others see is "%s"; :SelvageDisplayName <name> to change it.'):format(name))
    end
    return
  end
  if utf16.len(wanted) > MAX_DISPLAY_NAME then
    notify(
      ('this name is %s; a name is refused rather than shortened.'):format(over_long(wanted)),
      vim.log.levels.ERROR
    )
    return
  end
  vim.g.selvage_display_name = wanted
  remember_last_display_name(wanted)
  if state.process ~= nil then
    state.process:send({ type = 'rename', displayName = wanted })
  end
  notify(('display name set to "%s".'):format(wanted))
end


M.resolve_display_name = resolve_display_name

return M
