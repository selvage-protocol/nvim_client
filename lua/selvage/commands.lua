-- The commands themselves: hosting, joining, copying the link, and leaving.
--
-- Each is the decision a person makes about a session: a second host asks before it takes the room
-- from everyone in it, a join reaches for a link, and a leave asks before it ends a room for its
-- guests. The name and phrase each command is registered under are in `plugin/selvage.lua`, which
-- is also where they are declared, so what is here is only what a command does.
local resolve_display_name = require('selvage.display_name').resolve_display_name
local forget_invite = require('selvage.invite').forget_invite
local hand_on_invite = require('selvage.invite').hand_on_invite
local is_invite_link = require('selvage.invite').is_invite_link
local refuse_invite = require('selvage.invite').refuse_invite
local resolve_invite = require('selvage.invite').resolve_invite
local resolve_invite_to_wire = require('selvage.invite').resolve_invite_to_wire
local say_not_copied = require('selvage.invite').say_not_copied
local ensure = require('selvage.messages').ensure
local LEAVE_WORDS = require('selvage.notify').LEAVE_WORDS
local notify = require('selvage.notify').notify
local can_prompt = require('selvage.prompt').can_prompt
local normalise_server_address = require('selvage.server').normalise_server_address
local refuse_server_address = require('selvage.server').refuse_server_address
local remember_last_server = require('selvage.server').remember_last_server
local resolve_server_url = require('selvage.server').resolve_server_url
local auto_save = require('selvage.session').auto_save
local end_session = require('selvage.session').end_session
local reset = require('selvage.session').reset
local capture_root = require('selvage.share').capture_root
local in_session = require('selvage.state').in_session
local state = require('selvage.state').state

local M = {}

--- The question a session that is already live needs before another one replaces it: giving up a
--- room is the person's call, and a join or a host that took one from them silently could take the
--- room from everyone in it. Answered yes only by the button that names it; a process with nobody
--- to ask cannot be asked, so the question is said and the answer is no.
local function confirm_leave(question, button)
  if not can_prompt() then
    notify(question, vim.log.levels.WARN)
    return false
  end
  local cancel = (state.words or LEAVE_WORDS).leave.cancel
  -- Opened with a line break: a command line taller than one line drops a question that fits it.
  return vim.fn.confirm('\n' .. question, ('&%s\n&%s'):format(button, cancel), 2, 'Warning') == 1
end

--- Mints a room and shares the current buffer.
---
--- Hosting while hosting is reaching for the invite, not asking for a room: a second room would
--- end the first for everyone in it, and nobody asked for that. Hosting while a guest means
--- leaving the room first, which is the person's call and so a question.
function M.host(url)
  local wanted = vim.trim(url or '')
  if state.status == 'hosting' then
    local handed, why = hand_on_invite()
    if handed == 'copied' then
      notify('already hosting, invite link copied.')
    else
      say_not_copied(handed, why)
    end
    return
  end
  -- A session being opened is one in flight: a second host behind it earns the companion's
  -- refusal, whose sentence describes a live room rather than a double invocation half a
  -- second apart.
  if state.status == 'connecting' then
    notify('a session is already being opened.', vim.log.levels.WARN)
    return
  end
  local function with_url(address)
    -- Whatever was typed — an argument, an answer to the first-run question, a remembered one — is
    -- refused and completed here, so one place decides what a bare host means and the command that
    -- reports an address reports the address a host would dial.
    if refuse_server_address(address) then
      return
    end
    -- A session is given up only for an address that passed: an invite link pasted into this
    -- command or its box is refused before the question, so it costs no room.
    if in_session() then
      local can_leave = confirm_leave(
        'you are in this session; hosting a session means leaving it first.',
        'Leave and host'
      )
      if not can_leave then
        return
      end
      end_session()
    end
    address = normalise_server_address(address)
    remember_last_server(address)
    resolve_display_name(function(display_name)
      local process = ensure()
      if process ~= nil then
        capture_root()
        state.connect = { what = 'host', address = address }
        process:send({
          type = 'host',
          serverUrl = address,
          displayName = display_name,
          autoSave = auto_save(),
          root = state.root,
        })
      end
    end)
  end
  if wanted ~= '' then
    with_url(wanted)
    return
  end
  resolve_server_url(with_url)
end

--- Joins the room an invite link names.
---
--- A session already live is given up first, and only when the person says so: joining another
--- room ends this one for everyone in it, and a mistyped link must not do that on its own. A
--- mistyped one does nothing at all: it is refused here, before the name is asked for, before a
--- live session is given up for it and before anything is dialled.
function M.join(invite)
  local wanted = vim.trim(invite or '')
  -- An argument that is not an invite link cannot join whatever the session is doing, so it is
  -- answered at once rather than behind a name prompt: a question put in front of a failure
  -- reads as a join in progress, and the name it collects would outlive it.
  if wanted ~= '' and not is_invite_link(wanted) then
    refuse_invite()
    return
  end
  -- As hosting one: a second join behind a session being opened earns the companion's
  -- refusal for a room that was never live.
  if state.status == 'connecting' then
    notify('a session is already being opened.', vim.log.levels.WARN)
    return
  end
  if in_session() then
    local can_leave
    if state.role == 'host' then
      can_leave = confirm_leave(
        'you are hosting this session; joining another session ends this room for everyone.',
        'Leave and join'
      )
    else
      can_leave = confirm_leave(
        'you are in this session; joining another session leaves it.',
        'Leave and join'
      )
    end
    if not can_leave then
      return
    end
    end_session()
  end
  local function with_invite(link)
    -- The link has been read, so the command line or the prompt it was typed into has no more use
    -- for it, and ShaDa would keep it past the room (`forget_invite`).
    forget_invite(link)
    resolve_display_name(function(display_name)
      local process = ensure()
      if process ~= nil then
        capture_root()
        -- The invite this guest joined by is kept as it arrived: it is the permission the
        -- room was entered with, so it is the guest's to hand on (`:SelvageCopyInvite`).
        state.invite = link
        state.connect = { what = 'join' }
        process:send({
          type = 'join',
          -- The companion dials the wire URL: a pasted page link resolves to its
          -- room's server here, while a `ws://` link joins as it always has.
          invite = resolve_invite_to_wire(link),
          displayName = display_name,
          autoSave = auto_save(),
        })
      end
    end)
  end
  if wanted ~= '' then
    with_invite(wanted)
    return
  end
  resolve_invite(with_invite)
end

--- Puts the invite on the clipboard and the unnamed register, and says so.
function M.copy_invite()
  local handed, why = hand_on_invite()
  if handed == 'copied' then
    notify('invite link copied.')
  else
    say_not_copied(handed, why)
  end
end

--- Leaves the session and stops the companion.
---
--- The guard is the session, not the process: a companion outlives the session it held — a
--- connection the engine gave up on and a room that goes both leave it running for the next host
--- or join — so a process alone would say there was something left to leave.
function M.leave()
  if not in_session() then
    notify('not in a session.', vim.log.levels.WARN)
    return
  end
  -- A host leaving ends the room for everyone in it, so the host is asked first, the way the web
  -- page asks. A guest leaves at once, and so does a host with nobody there to answer.
  if state.status == 'hosting' and can_prompt() then
    local leave = (state.words or LEAVE_WORDS).leave
    if not confirm_leave(leave.question, leave.confirm) then
      return
    end
  end
  local process = state.process
  state.process = nil
  if process ~= nil then
    process:send({ type = 'leave' })
    process:stop()
  end
  reset()
  notify('left the session.')
end



return M
