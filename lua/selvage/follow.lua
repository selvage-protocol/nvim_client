-- Following a participant.
--
-- A follow keeps landing where a peer is until something ends it. Neovim has no viewport-only
-- state — the next redraw pulls the viewport back over the cursor — so following is being where
-- they are rather than watching from elsewhere, and a local edit of a shared document ends it
-- because the next keystroke lands where the caret is. A landing is bounded: a document that never
-- draws the peer's caret is named rather than waited for in silence.
local end_follow = require('selvage.bar').end_follow
local refresh_indicators = require('selvage.bar').refresh_indicators
local set_indicator = require('selvage.bar').set_indicator
local notify = require('selvage.notify').notify
local notify_words = require('selvage.notify').notify_words
local seconds = require('selvage.notify').seconds
local land = require('selvage.peers').land
local peer_path = require('selvage.peers').peer_path
local peer_row = require('selvage.peers').peer_row
local resolve_peer = require('selvage.peers').resolve_peer
local row_name = require('selvage.peers').row_name
local queries = require('selvage.queries')
local in_session = require('selvage.state').in_session
local state = require('selvage.state').state

local M = {}

--- How long a landing that has opened a document waits for the peer's caret before giving up.
---
--- A landing takes its document from the room's own presence and opens it, and what resolves the
--- caret is the room's text arriving over the ordinary sync — a frame or two away in a working
--- session. What this bounds is silence rather than work: a room that never sends the text, or
--- anchors this replica never resolves, would otherwise leave the establishment standing for ever
--- with nothing said. A landing that arrives clears the wait, so a session that works never
--- reaches the deadline — it is not a sleep, it is the end of a wait no frame answered.
--- `vim.g.selvage_landing_timeout_ms` sets it for a run that knows better than the default.
---
--- @return integer milliseconds
local function landing_timeout_ms()
  local configured = tonumber(vim.g.selvage_landing_timeout_ms)
  if configured ~= nil and configured > 0 then
    return configured
  end
  return 10000
end

--- Arms the one deadline a stalled landing gets.
---
--- `subject` is the establishment itself — the follow table or the pending go-to table — and its
--- identity is the guard: a landing that arrives clears the slot, a second follow or go-to fills
--- it with its own table, and a timer that finds either is one whose establishment has already
--- been answered or replaced, and is not this one's to refuse. The document the wait stands in is
--- carried too, so a peer who moves from one document into another is waiting somewhere else and
--- the deadline for the first has nothing left to measure. `kind` is which establishment it is, so
--- the deadline ends the right one, and the session counter keeps a timer armed in a room that has
--- since gone from speaking into the next one.
---
--- @param subject table
--- @param kind 'follow'|'goTo'
--- @param label string
local function wait_for_caret(subject, kind, label)
  local wait = {
    subject = subject,
    kind = kind,
    label = label,
    path = peer_path(subject.peerId),
    generation = state.generation,
  }
  state.landing_wait = wait
  vim.defer_fn(function()
    if state.landing_wait ~= wait or state.generation ~= wait.generation then
      return
    end
    state.landing_wait = nil
    if wait.kind == 'follow' then
      -- The establishment is refused rather than left standing: the chip would say the follow
      -- is where the peer is, which is the one thing this deadline is the witness it never did.
      end_follow('stopped')
    else
      state.pending_go_to = nil
    end
    local waited = seconds(landing_timeout_ms())
    if wait.kind == 'follow' then
      notify(
        ("%s's caret did not arrive within %ds; stopped following."):format(wait.label, waited),
        vim.log.levels.WARN
      )
    else
      notify(("%s's caret did not arrive within %ds."):format(wait.label, waited), vim.log.levels.WARN)
    end
  end, landing_timeout_ms())
  return wait
end

--- Ends a wait whose establishment has been answered: a landing, a terminal refusal or a
--- departure clears it, so the deadline is left for the state that is still waiting alone.
local function caret_arrived()
  state.landing_wait = nil
end

--- Whether the deadline standing is this stall's own: the same establishment waiting in the same
--- document. A landing that arrived cleared the slot, and a peer who moved into another document
--- left the deadline behind — both are a wait this landing has not got, so a new one is armed, and
--- the timer that finds its own replaced stands down on that identity alone.
local function waiting_in(subject)
  local wait = state.landing_wait
  return wait ~= nil and wait.subject == subject and wait.path == peer_path(subject.peerId)
end

--- Attempts one landing of the standing follow. Indicates only on success: a miss leaves the
--- indicator where it was, so refusing an establishment touches nothing a standing follow owns.
--- Nothing is said when a follow begins, as on the web: the window's `Following` chip shows it.
--- Returns what `land` returned.
local function land_follow()
  local following = state.following
  if following == nil then
    return false, 'unknown'
  end
  -- The target is the peer id, so a rename keeps the follow and re-labels it.
  local row = peer_row(following.peerId)
  if row ~= nil then
    following.label = row.label
    following.colour = row.colour or following.colour
  end
  local ok, reason, err = land(following.peerId)
  if ok then
    set_indicator()
    caret_arrived()
  end
  return ok, reason, err
end

--- Lands the follow again on a new frame: the peer moved, or their text arrived. A frame the
--- room draws no document in for them is a frame with nothing to land on — they are between
--- documents — so the follow stands, saying so once on the first such frame and never per frame.
--- A frame where the room *does* name their document and the caret has not resolved is 'waiting':
--- the opening and the text arriving are frames away, and saying anything there would be a
--- sentence about a moment rather than about a person.
local function follow_frame()
  local following = state.following
  if following == nil then
    return false
  end
  local ok, reason, err = land_follow()
  if ok then
    -- Drawable again: the next undrawable stretch is news again too.
    following.gone_warned = false
    return true
  end
  if reason == 'waiting' then
    -- The stall this deadline exists for: the room has the document and its text has not
    -- resolved the caret here yet. Armed once per document and not per frame, so frames that name
    -- the peer without resolving them are not what the wait measures; a landing clears it above.
    -- A frame that moves them into another document is a wait of its own, so the deadline standing
    -- for the first is replaced: left alone it would expire over the second.
    if not waiting_in(following) then
      wait_for_caret(following, 'follow', following.label)
    end
  else
    -- Every other miss has a sentence of its own or nothing to wait for: a peer between
    -- documents, an open the room refused. The wait belongs to the stall above alone.
    caret_arrived()
  end
  if reason == 'open-failed' then
    -- Said once per document: every frame retries the same refusal, and the second saying
    -- carries nothing the first did not.
    local path = peer_path(following.peerId)
    if following.open_warned_for ~= path then
      following.open_warned_for = path
      notify(
        ('could not open %s from the room: %s.'):format(tostring(path), tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
  if reason == 'unknown' and not following.gone_warned then
    -- The first frame with no drawable caret: the indicator keeps saying Following and
    -- the window stays put, so the change from somewhere to nowhere is said once rather
    -- than never, and never per frame. A document opened here whose text still arrives is
    -- 'waiting', not 'unknown', and stays silent: a frame away from landing.
    following.gone_warned = true
    notify(('%s is not in a document; still following.'):format(following.label))
  end
  return false
end

--- Follows the peer, landing now and again on every frame until something ends it.
---
--- The first landing establishes the follow — the indicator, the sentence and `vim.g` all
--- happen on it — so a first landing that lands nowhere refuses instead of establishing: a
--- follow standing nowhere has no indicator and no stop state, which is the branch's own
--- contract broken silently. A failed re-target puts the standing follow back as it was;
--- the attempt itself says and indicates nothing, so there is nothing to put back with it.
---
--- A first landing that is still *on its way* is not that: a peer in a room document this window
--- has not opened has their document opened by the landing — the buffer and the hold — and then
--- waits a frame for the caret the hold's text resolves, which is the state 'waiting'.
local function begin_follow(row)
  -- A peer the room's presence puts in no document is in none this client can reach: there is
  -- nowhere to land, so the command refuses rather than landing at zero. The room's own word is
  -- what this reads: a presence entry the companion could not resolve a caret in still carries
  -- the document the room names for the peer, which is what a follow opens to reach them.
  if row.path == nil then
    notify(('nothing to follow: %s is not in a document.'):format(row.label), vim.log.levels.WARN)
    return
  end
  -- A pending go-to is superseded: the follow is the newer navigation, and a late frame
  -- for the old target must not yank the window back to it.
  state.pending_go_to = nil
  caret_arrived()
  local previous = state.following
  state.following = {
    peerId = row.peerId,
    label = row.label,
    colour = row.colour,
    open_warned_for = nil,
  }
  local ok, reason, err = land_follow()
  if not ok and reason ~= 'waiting' then
    state.following = previous
    -- A window the landing attempt entered drew the bar with the refused follow on it.
    refresh_indicators()
    if reason == 'open-failed' then
      notify(
        ('could not open %s from the room: %s.'):format(tostring(peer_path(row.peerId) or row.path), tostring(err)),
        vim.log.levels.ERROR
      )
    else
      notify(("nothing to follow: %s's caret does not resolve here."):format(row.label), vim.log.levels.WARN)
    end
  elseif reason == 'waiting' then
    -- The establishment is on its way rather than refused, and this is the deadline it gets:
    -- the document is opened and its text is what the caret resolves against.
    wait_for_caret(state.following, 'follow', row.label)
  end
end

--- Holds a go-to whose landing cannot be made yet: the peer is in no document this client
--- holds, which reads exactly like a presence update one frame away, or their document
--- opened here a frame ago and its text still arrives. A pending landing is a one-shot
--- follow: every room event that could have brought the text tries it again, and the first
--- landing, refusal or departure clears it. It holds no resources — one slot, replaced by
--- the next go-to, cleared by a follow — and reports nothing while it waits: waiting is not
--- a failure yet. What bounds it is the deadline a document already opened gets: the peer's
--- document is here and the caret has not resolved against it, so the room's text is the
--- effect being waited on and silence is what the deadline answers.
local function pend_go_to(row)
  state.pending_go_to = { peerId = row.peerId, label = row.label }
  if row.path ~= nil then
    wait_for_caret(state.pending_go_to, 'goTo', row.label)
  else
    -- A peer in no document has nothing to resolve a caret against, so there is no stall to
    -- bound yet: the presence frame that puts them in one is what arms the deadline.
    caret_arrived()
  end
end

--- Tries the pending go-to again: presence, an applied edit, the documents and the
--- membership each call this, because any of them can be the frame the text arrived on.
local function retry_go_to()
  local pending = state.pending_go_to
  if pending == nil then
    return
  end
  local row = peer_row(pending.peerId)
  if row == nil then
    -- The room no longer names them: a peer who left between the command and the text
    -- matches nobody now, the same refusal a stale picker choice reads.
    state.pending_go_to = nil
    caret_arrived()
    notify(('no participant matches "%s".'):format(pending.label), vim.log.levels.WARN)
    return
  end
  pending.label = row.label
  if row.path == nil then
    -- Back in no document: there is no text to arrive for, so the deadline goes with the
    -- document rather than speaking for a peer who is nowhere to land.
    caret_arrived()
    return
  end
  local ok, reason, err = land(pending.peerId)
  if ok then
    state.pending_go_to = nil
    caret_arrived()
  elseif reason == 'open-failed' then
    state.pending_go_to = nil
    caret_arrived()
    notify(
      ('could not open %s from the room: %s.'):format(row.path, tostring(err)),
      vim.log.levels.ERROR
    )
  elseif reason ~= 'unknown' and reason ~= 'waiting' then
    state.pending_go_to = nil
    caret_arrived()
    notify_words('goTo', 'cursorNotFound', vim.log.levels.WARN, row.label)
  elseif not waiting_in(pending) then
    -- Still waiting on the document's text, and no deadline stands for it — or the one that did
    -- was armed for the document the peer has since left: arm the one this landing gets, so a hold
    -- the room answers with silence is not a wait without an end.
    wait_for_caret(pending, 'goTo', pending.label)
  end
end

--- Lands on the peer's caret once: the hold taken by the open is what makes the room send
--- the text, so a landing that cannot be made yet pends on the frames rather than placing
--- at offset zero, and never lands at zero for an anchor that does not resolve either.
local function go_to_row(row)
  -- A deliberate navigation ends a follow: the user chose a different place to be, and a
  -- follow that yanked them back a moment later is the behaviour people remember as
  -- broken. A pending go-to is superseded the same way: the newer navigation owns the
  -- window now, and a late frame for the old target must not take it back.
  if state.following ~= nil then
    end_follow('stopped')
  end
  state.pending_go_to = nil
  if row.path == nil then
    pend_go_to(row)
    return
  end
  local ok, reason, err = land(row.peerId)
  if ok then
    return
  end
  if reason == 'unknown' or reason == 'waiting' then
    pend_go_to(row)
  elseif reason == 'open-failed' then
    notify(
      ('could not open %s from the room: %s.'):format(row.path, tostring(err)),
      vim.log.levels.ERROR
    )
  else
    notify_words('goTo', 'cursorNotFound', vim.log.levels.WARN, row.label)
  end
end

--- Asks which participant, in the editor's own idiom: a picker over the room's rows, each
--- the name, the role and the document, disambiguated where two share a name.
local function pick_peer(prompt, on_choice)
  local peers = queries.peers()
  vim.ui.select(peers, {
    prompt = prompt,
    format_item = function(peer)
      return ('%s — %s — %s'):format(
        row_name(peers, peer),
        tostring(peer.role or 'participant'),
        tostring(peer.path or 'not in a file yet')
      )
    end,
  }, on_choice)
end

--- The words a name that matched several peers is refused with, in the shape
--- `:SelvageOpen` uses for a path.
local function several_rows(wanted, matches)
  local peers = queries.peers()
  local rows = {}
  for _, peer in ipairs(matches) do
    rows[#rows + 1] = row_name(peers, peer)
  end
  return rows
end

--- Goes to the participant `name` picks: their document shown, the cursor on their caret.
--- With no name and one participant, that one; with several, the user is asked which.
function M.go_to(name)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local peers = queries.peers()
  if #peers == 0 then
    notify('no other participants yet.', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(name or '')
  if wanted == '' then
    if #peers == 1 then
      go_to_row(peers[1])
    else
      pick_peer('selvage: go to which participant?', function(row)
        if row ~= nil then
          -- The choice is read fresh: the room may have moved since the picker opened, and
          -- a peer who left it matches nobody now. A row in no document is refused here,
          -- where the row itself says so; a typed name pends on the frames instead.
          local fresh = peer_row(row.peerId)
          if fresh == nil then
            notify(('no participant matches "%s".'):format(row.label), vim.log.levels.WARN)
          elseif fresh.path == nil then
            notify_words('goTo', 'notInFile', vim.log.levels.WARN, fresh.label)
          else
            go_to_row(fresh)
          end
        end
      end)
    end
    return
  end
  local row, err, matches = resolve_peer(wanted)
  if row ~= nil then
    go_to_row(row)
  elseif err == 'several' then
    notify(('"%s" matches several: %s.'):format(wanted, table.concat(several_rows(wanted, matches), ', ')), vim.log.levels.WARN)
  else
    notify(('no participant matches "%s".'):format(wanted), vim.log.levels.WARN)
  end
end

--- Follows the participant `name` picks, until something ends it: the user, an edit of
--- their own, the peer leaving, or the session going.
function M.follow(name)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  local peers = queries.peers()
  if #peers == 0 then
    notify('no other participants yet.', vim.log.levels.WARN)
    return
  end
  local wanted = vim.trim(name or '')
  if wanted == '' then
    if #peers == 1 then
      begin_follow(peers[1])
    else
      pick_peer('selvage: follow which participant?', function(row)
        if row ~= nil then
          -- The choice is read fresh: the room may have moved since the picker opened. A peer
          -- who left it matches nobody now; one still here but in no document refuses with
          -- it, the same refusal the typed name reads.
          local fresh = peer_row(row.peerId)
          if fresh == nil then
            notify(('no participant matches "%s".'):format(row.label), vim.log.levels.WARN)
          elseif fresh.path == nil then
            notify(('nothing to follow: %s is not in a document.'):format(fresh.label), vim.log.levels.WARN)
          else
            begin_follow(fresh)
          end
        end
      end)
    end
    return
  end
  local row, err, matches = resolve_peer(wanted)
  if row == nil then
    if err == 'several' then
      notify(('"%s" matches several: %s.'):format(wanted, table.concat(several_rows(wanted, matches), ', ')), vim.log.levels.WARN)
    else
      notify(('no participant matches "%s".'):format(wanted), vim.log.levels.WARN)
    end
    return
  end
  begin_follow(row)
end

--- Stops following, or says there is nothing to stop.
function M.stop_following()
  if state.following == nil then
    notify('not following anyone.', vim.log.levels.WARN)
    return
  end
  end_follow('stopped')
end

--- The label of the participant this window follows, or nil when it follows nobody: what
--- the indicator shows, for a statusline or a script.
function M.following()
  return state.following ~= nil and state.following.label or nil
end


M.follow_frame = follow_frame
M.retry_go_to = retry_go_to

return M
