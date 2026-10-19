-- What this front-end says, and the words it says it in.
--
-- `notify` is the one way a sentence reaches the person, so the `selvage: ` prefix and the level
-- an unqualified moment is said at are decided here rather than at each of the calls. `seconds` is
-- how a deadline is spelled, because the room's deadlines are named in whole seconds in both
-- clients. `notify_words` says one of the companion's own sentences, which is what keeps the two
-- clients saying the same thing: the words arrive from the companion and are filled in here.
local state = require('selvage.state').state

local M = {}

--- The leave question's own words until the companion's arrive, the same ones it sends: a host is
--- never let go without it.
local LEAVE_WORDS = {
  leave = {
    question = 'Leaving ends the room for everyone and stops the invite link.',
    confirm = 'Leave anyway',
    cancel = 'Cancel',
  },
}

local function notify(message, level)
  vim.notify('selvage: ' .. message, level or vim.log.levels.INFO)
end

--- Says one of the companion's sentences (`words` in `companion/room.ts`), its `%s` filled with
--- the arguments. The companion's words are its first message, so they are here before any
--- session has a participant to go to or a file to download.
local function notify_words(group, key, level, ...)
  local sentence = state.words ~= nil and state.words[group] ~= nil and state.words[group][key] or nil
  if type(sentence) == 'string' then
    notify(select('#', ...) > 0 and sentence:format(...) or sentence, level)
  end
end

--- Says a presence draw that went wrong, once per sentence: a draw that keeps failing runs again
--- at every cursor move and presence report, and the same warning repeated per redraw is noise
--- rather than news — a different sentence names a different failure and is said again.
local function notify_draw_failure(message)
  if state.draw_failures[message] then
    return
  end
  state.draw_failures[message] = true
  notify(message, vim.log.levels.WARN)
end

--- A duration as a person reads it: whole seconds, rounded, which is the unit the room's
--- deadlines are named in and the one the other client shows.
local function seconds(ms)
  return math.max(0, math.floor((tonumber(ms) or 0) / 1000 + 0.5))
end


M.LEAVE_WORDS = LEAVE_WORDS
M.notify = notify
M.notify_draw_failure = notify_draw_failure
M.notify_words = notify_words
M.seconds = seconds

return M
