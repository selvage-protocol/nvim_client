-- What the companion says.
--
-- The companion process owns everything that decides anything about a document, and this is the
-- other end of that conversation: status changes, room reports and the presence that follows them,
-- each arm reading only the fields it needs. A misshapen message is a bug in the same user's own
-- process rather than an attack, so it is said and dropped rather than answered blindly.
local companion = require('selvage.companion')
local mirror = require('selvage.mirror')
local end_follow = require('selvage.bar').end_follow
local refresh_indicator_for = require('selvage.bar').refresh_indicator_for
local refresh_indicators = require('selvage.bar').refresh_indicators
local set_indicator = require('selvage.bar').set_indicator
local watch_follow_window = require('selvage.bar').watch_follow_window
local peer_highlight = require('selvage.colour').peer_highlight
local follow_frame = require('selvage.follow').follow_frame
local retry_go_to = require('selvage.follow').retry_go_to
local hand_on_invite = require('selvage.invite').hand_on_invite
local say_not_copied = require('selvage.invite').say_not_copied
local notify = require('selvage.notify').notify
local peer_row = require('selvage.peers').peer_row
local draw_presence = require('selvage.presence').draw_presence
local schedule_selection = require('selvage.presence').schedule_selection
local watch_presence = require('selvage.presence').watch_presence
local drop_documents = require('selvage.session').drop_documents
local remirror_documents = require('selvage.session').remirror_documents
local reset = require('selvage.session').reset
local watch_mirror = require('selvage.session').watch_mirror
local let_go = require('selvage.share').let_go
local note_role = require('selvage.share').note_role
local reveal = require('selvage.share').reveal
local share_current = require('selvage.share').share_current
local watch_buffers = require('selvage.share').watch_buffers
local is_peer = require('selvage.state').is_peer
local state = require('selvage.state').state

local M = {}

--- The companion message types this session already named as unknown, so the version-skew
--- warning is said once per type rather than once per message.
local warned_message_types = {}
--- What a host or join that could not open says, as one sentence a person can act on.
---
--- A refusal the protocol named is said from its code rather than repeated from the server's
--- message, which answers with a value the person never chose to see: `no such room: <room id>`
--- names what could not be found and not the way back from it. A connection that never got as
--- far as a handshake carries no code — the engine has only its own words about a socket — and
--- the two causes of one are the server at that address and the address itself, so a host is
--- told to check the address it dialled and a guest the link it pasted.
---
--- `connect` names which of the two this was — `{ what = 'host', address = … }` or
--- `{ what = 'join' }` — because the two say different sentences.
---
--- The two failures that are neither: a link whose fragment it will not read (`PROTOCOL.md`
--- §5.1). There is no connection to describe, and the companion's message is already the whole
--- sentence — what is wrong with the link — so it is said as it stands rather than behind a
--- sentence about a dial that never happened.
---
--- @param connect table|nil `what` and, for a host, `address`
--- @param code string|nil the protocol's own code for a refusal — or the companion's own, for the
--- local refusal above — absent for a socket
--- @param message string|nil the failure's own words
--- @return string
local function connect_failure(connect, code, message)
  if code == 'invite_refused' then
    return tostring(message or '')
  end
  local what = connect and connect.what or 'join'
  local why
  if code == 'room_unknown' then
    why = 'That invite names a room the server does not have. Ask the host for a fresh invite.'
  elseif code == 'token_invalid' then
    why = 'That invite is no longer valid. Ask the host for a fresh invite.'
  elseif code == 'x.server_full' or code == 'try_again_later' then
    -- The server's capacity policy, said from its code and not from the reason beside it:
    -- `x.server_full` is the mint refusal this client's server names (`§2.1`), and
    -- `try_again_later` is the `1013` a handshake close at that cap is read as (`closeCode`).
    why = 'The server is full. Try again in a few minutes.'
  elseif code == 'x.room_full' then
    why = 'The room is full — it seats no more people.'
  elseif code == 'room_gone' then
    why = 'That room is gone.'
  elseif tostring(message or ''):find('^server full') ~= nil then
    -- The reason regex, kept as the fallback for a close whose number never reached this
    -- client: before the engine read the close code this wording was the only signal, and a
    -- server whose 1013 carries it is still recognised here.
    why = 'The server is full. Try again in a few minutes.'
  elseif code == nil or code == '' or code == 'hello_required' then
    if what == 'host' then
      why = 'No server answered — check the address is the one the server printed, and that the server is running.'
    else
      why = 'No server answered — check the invite is complete, and that the server is running at the address it names.'
    end
  else
    why = tostring(message or '')
  end
  if what == 'host' then
    return ('could not host on %s. %s'):format(tostring(connect.address or ''), why)
  end
  return 'could not join the session. ' .. why
end

local function on_status(message)
  state.status = message.state
  -- The role is the room state's word about this connection's key (§13.4), and a state that gives
  -- it another one arrives after the seat: the companion sends that as a report of its own, and
  -- `note_role` is where both reach the editor.
  note_role(message.role)
  state.room = message.roomId
  -- A status is this session's own word: whatever the connection was doing before it, the
  -- companion has just said where the session stands.
  state.reconnecting = false
  if message.invite ~= nil then
    state.invite = message.invite
  end
  if message.state == 'idle' then
    -- The session is over, whoever ended it: `:SelvageLeave` has reset before it hears this, and
    -- a room that goes or a connection the engine gave up on reaches here from the companion,
    -- which has already let the engine go.
    reset()
  elseif message.state == 'connecting' then
    -- The session is being opened: the row says so, and the result replaces it. Watched
    -- before the session stands, because the switches that swap the row are already
    -- happening — the address and the name were answered before this arrived.
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'hosting' then
    -- A host's next move is pasting the link to a guest, so the room copies its page
    -- link without being asked; `:SelvageCopyInvite` stays for later copies. What is
    -- copied is never the wire address: only the page link leaves this editor.
    local handed, why = hand_on_invite()
    if handed == 'copied' then
      notify('hosting, invite link copied.')
    else
      say_not_copied(handed, why)
    end
    share_current()
    watch_buffers()
    watch_presence()
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'joined' then
    -- The join is said over the `documents` report that follows this one: the sentence carries
    -- what the landing did with the room's documents, and that is the report's news.
    state.auto_open = true
    state.join_said = false
    state.join_empty = false
    state.join_listed = false
    watch_presence()
    watch_follow_window()
    refresh_indicators()
  elseif message.state == 'error' then
    -- A connection that failed, or a refusal the companion decided before it dialled anything:
    -- a version the server's `/meta` does not seat (`§2`, `§10`) and a link whose fragment it will
    -- not read (`§5.1`) both reach here, and both already carry the companion's own sentence.
    notify(connect_failure(state.connect, message.code, message.message), vim.log.levels.ERROR)
    -- Nothing is standing after it, so the row goes with the failure: the notification is
    -- what says why, and a word about a session that is not open would outlive it.
    refresh_indicators()
  end
end

local function on_report(report)
  if state.reconnecting and (report.kind == 'documents' or report.kind == 'peers') then
    -- Both are reports of a seat — the first and every one after a reconnect — so either one
    -- is the room reachable again: the retry gets there, and the session's row says so.
    state.reconnecting = false
    refresh_indicators()
  end
  if report.kind == 'documents' then
    if is_peer() then
      -- The room's open-document set is the room's own word about who holds what, and it is
      -- not this session's set: this session holds a buffer only for a path its own window
      -- opened — the join's landing, `:SelvageOpen`, a follow, a fetch — so a path in the
      -- room's set with no buffer here is offered and opened then, the way a granted path is.
      -- A buffer and a hold for every path the room names would put every peer's open files
      -- in this editor, and the hold would keep the room naming them for the life of the
      -- session.
      local named = {}
      local first = nil
      for _, path in ipairs(report.documents) do
        named[path] = true
        -- A path the listing took away is still in the room's set while another peer holds it.
        if first == nil and not state.dropped[path] then
          first = path
        end
      end
      -- A path this window holds is not released here, however this report reads. The room's set
      -- is its own holds together with each peer's (`roomDocuments`), so a path this window
      -- opened is in it from the moment the companion has read the `open` — and this report may
      -- be one the companion computed before that read, which is a report about a room that has
      -- not heard the hold yet. Releasing on it takes back the hold the person just asked for:
      -- the buffer stands here unshared and nothing opens it again. This window's own acts are
      -- what release a hold — a wiped buffer, a listing that took the path away, leaving — and
      -- the next report names this one again, because this window holds it.
      state.room_documents = named
      -- The join is said here, where the room's document set is known, rather than when the
      -- handshake named the room: the sentence carries the landing, and a room with nothing in
      -- it is a join with a sentence of its own. The landing is the first document the room
      -- names after the join — a later one waits for `:SelvageOpen`, because taking the window
      -- then would interrupt what the guest is already editing — so a room that was empty at
      -- the join still lands the first document that fills it. It is the one document opened
      -- without being asked for, and it goes through the open `:SelvageOpen` uses.
      local lands = vim.g.selvage_open_on_join ~= false
      if state.auto_open and first ~= nil then
        state.auto_open = false
        if lands then
          -- The landing is the join's own window placement: its empty buffer is what the
          -- summary's fetched count already accounts for, so the unfetched hint stays silent.
          state.suppress_unfetched = true
          reveal(first)
          state.suppress_unfetched = false
        end
        if not state.join_said then
          state.join_said = true
          -- The landing, and — when the room holds more than one document — how many others
          -- there are. Where the mirror lives and how much of the room has arrived are not
          -- part of it: the row, `:SelvageOpen`'s completion and
          -- `require('selvage').session().mirror` answer those, and a greeting that carries
          -- a path and two counts is not read.
          if not lands then
            notify('joined the room.')
          elseif #report.documents > 1 then
            notify(
              ('joined the room, opening %s. %s open.'):format(
                report.documents[1],
                #report.documents == 2 and '1 more file is'
                  or ('%d more files are'):format(#report.documents - 1)
              )
            )
          else
            notify(('joined the room, opening %s.'):format(report.documents[1]))
          end
        end
      elseif state.auto_open and not state.join_said then
        state.join_said = true
        state.join_empty = true
        local mirror_summary = state.join_mirror
        state.join_listed = mirror_summary ~= nil
        if mirror_summary ~= nil and mirror_summary.count == 1 then
          notify(
            ('joined the room. No one has a file open yet, and 1 file is mirrored at %s.'):format(
              mirror_summary.root
            )
          )
        elseif mirror_summary ~= nil then
          notify(
            ('joined the room. No one has a file open yet, and %d files are mirrored at %s.'):format(
              mirror_summary.count,
              mirror_summary.root
            )
          )
        else
          notify('joined the room. No one has a file open yet.')
        end
      end
    end
    -- The room's document set is one of the frames a pending landing waits on: a buffer a
    -- guest opens here is what the next presence frame draws into a landing.
    retry_go_to()
    follow_frame()
  elseif report.kind == 'grant' then
    -- The room's whole grant, replacing whatever this front-end held — the same rule the server
    -- applies to `doc.grant`, and the reason a shorter listing is a smaller grant rather than an
    -- error. The listing is what `:SelvageOpen` completes over, and a room that lists five
    -- hundred files has nothing worth interrupting a person for; what a *guest* does with it is
    -- materialise it, and the one sentence that says where is said over the session's first
    -- listing rather than over every republish. The join's own listing is the exception:
    -- the summary said over the documents report carries where the mirror lives, so the
    -- first listing before the join is said records its counts and stays silent.
    local previous = {}
    for _, path in ipairs(state.grant) do
      previous[path] = true
    end
    state.grant = report.paths or {}
    local listed = {}
    for _, path in ipairs(state.grant) do
      listed[path] = true
      state.dropped[path] = nil
    end
    if is_peer() then
      local root, blocked, created, over_capacity = mirror.setup(state.room, state.grant, report.unsafe)
      if root ~= nil then
        -- What the room listed and this client did not put on disk, however it refused: a path
        -- past the mirror's capacity and a path it could not write are both missed files.
        local mirrored = #state.grant - #blocked - #over_capacity
        if created then
          watch_mirror()
        end
        if state.join_mirror == nil and not state.join_said then
          state.join_mirror = { count = mirrored, root = root }
        end
        -- A first listing that arrives after the join was said stays silent: the summary already
        -- went out, and one summary plus errors is the whole of the join's news. The mirror stays
        -- discoverable without a notice (`require('selvage').session().mirror`, `docs/mirror.md`,
        -- `:SelvageFetch` completion). The exception is a join the room had nothing open in: that
        -- guest has no document to watch and no tree to read, so a listing that arrives after the
        -- sentence is the only place the room's files reach them, and it is said once here.
        if state.join_said and state.join_empty and not state.join_listed and mirrored > 0 then
          state.join_listed = true
          local count = mirrored
          if count == 1 then
            notify(('1 file is mirrored at %s; :SelvageOpen opens it.'):format(root))
          else
            notify(('%d files are mirrored at %s; :SelvageOpen opens one.'):format(count, root))
          end
        end
        if #blocked == 1 then
          notify(("one of the room's files could not be written to disk: %s."):format(blocked[1]), vim.log.levels.WARN)
        elseif #blocked > 1 then
          notify(
            ('%d of the room\'s files could not be written to disk, starting with %s.'):format(
              #blocked,
              blocked[1]
            ),
            vim.log.levels.WARN
          )
        end
        -- The receiver's capacity, said apart from a write that failed: the room listed more
        -- than this mirror holds, and no disk was involved.
        if #over_capacity == 1 then
          notify(
            ('the room lists more files than this session mirrors; %s is left out.'):format(over_capacity[1]),
            vim.log.levels.WARN
          )
        elseif #over_capacity > 1 then
          notify(
            ('the room lists more files than this session mirrors; %d of them are left out, starting with %s.'):format(
              #over_capacity,
              over_capacity[1]
            ),
            vim.log.levels.WARN
          )
        end
        remirror_documents()
        -- A held path the previous listing named and this one does not is a file the host
        -- deleted. One the listing never named is a document shared after it, and is left alone.
        local gone = {}
        for path in pairs(state.documents) do
          if previous[path] and not listed[path] then
            gone[#gone + 1] = path
          end
        end
        table.sort(gone)
        drop_documents(gone)
        -- The grant is what `unfetched_buffer` reads, so a window already showing a buffer the
        -- listing no longer names is carrying a mark that is now wrong: the row is redrawn here
        -- rather than waiting for the next keystroke or session event.
        refresh_indicators()
      end
    end
  elseif report.kind == 'peers' then
    -- The room's own list of who is in it: everyone, not only the peers this client holds a
    -- document for and can draw a caret for.
    state.room_peers = report.peers or {}
    state.self_seat = type(report.self) == 'table' and report.self or nil
    if type(report.identity) == 'string' then
      state.identity = report.identity
    end
    local host_here = false
    for _, peer in ipairs(state.room_peers) do
      host_here = host_here or peer.role == 'host'
      if peer.colour ~= nil then
        peer_highlight({ peerId = peer.peer_id, colour = peer.colour })
      end
    end
    -- Membership is the all-clear as well as the departure. `host.attached` is the only frame
    -- that says the host is back, and a guest whose socket was down when it arrived would
    -- otherwise keep a countdown — and then a deadline that has already passed — standing for
    -- the rest of the session. A report that names the host means the host is here.
    if host_here and state.host_away ~= nil then
      state.host_away = nil
    end
    -- The report is the room's own membership, so a peer it no longer names is gone even
    -- before the next presence frame redraws: their drawn row and cursor go now, rather than
    -- offering a departed peer in completion or landing on their last caret.
    --
    -- The count is what the session's row says, so the rows standing are drawn again: one more
    -- or one fewer is the first thing a person looking for their friend wants to see.
    refresh_indicators()
    do
      local member = {}
      for _, peer in ipairs(state.room_peers) do
        member[peer.peer_id] = true
      end
      local cursors = {}
      for _, cursor in ipairs(state.cursors) do
        if member[cursor.peerId] then
          cursors[#cursors + 1] = cursor
        end
      end
      -- Redrawn, not just reassigned: the marks of a departed peer would otherwise stand
      -- until the next presence frame. The rows above stay the membership join; the draw
      -- rebuilds the same drawable metadata and clears what no cursor names anymore.
      draw_presence(cursors)
    end
    -- A peer the room no longer names has left it: the follow ends, saying so. The peer id
    -- is the target, so a rename — same id, new name — keeps following and re-labels, now,
    -- from the report rather than the next presence frame: the indicator and the eventual
    -- stop message read the new name even when the peer goes idle.
    if state.following ~= nil then
      local gone = true
      for _, peer in ipairs(state.room_peers) do
        if peer.peer_id == state.following.peerId then
          gone = false
          break
        end
      end
      if gone then
        end_follow('left')
      else
        local row = peer_row(state.following.peerId)
        if row ~= nil then
          state.following.label = row.label
          state.following.colour = row.colour or state.following.colour
          set_indicator()
        end
      end
    end
    -- Membership is one of the frames a pending landing waits on: the room naming the peer
    -- is what tells a wait for their document from a wait for someone who left.
    retry_go_to()
  elseif report.kind == 'role' then
    -- `§13.4`: the role is the applied state's word about this connection's key, and a state that
    -- gives it another one arrives after the seat — the seat's own status cannot carry it, because
    -- no state has committed the key yet. This is that change: a viewer's documents are made
    -- read-only here, and the sentence is said once (`note_role`).
    note_role(report.role)
  elseif report.kind == 'roomGone' then
    -- The room is over and the companion has let the engine go, so the session here ends with
    -- it rather than leaving buffers, marks and a statusline behind for a room nobody is in.
    -- The window is part of that: a buffer still shown for the dead room reads as one that is
    -- still there, so the room's buffers are landed as well.
    --
    -- The mirror is kept: it is a cache of the room, but whatever the person did in it during the
    -- grace is not in the room and has nowhere else to be recovered from, so the directory stays
    -- and they are told where, in the same notice.
    local sentence = tostring(report.sentence or report.reason or '')
    local kept = reset(true, true)
    if kept ~= nil then
      notify(('%s Your copy is kept at %s.'):format(sentence, kept), vim.log.levels.WARN)
    else
      notify(sentence, vim.log.levels.WARN)
    end
  elseif report.kind == 'hostDetached' then
    -- Said once; the bar keeps the countdown, which the companion ticks as `hostAway` reports.
    state.host_away = { line = tostring(report.line or '') }
    notify(tostring(report.sentence or ''), vim.log.levels.WARN)
    refresh_indicators()
  elseif report.kind == 'hostAway' then
    if state.host_away ~= nil then
      state.host_away.line = tostring(report.line or '')
      refresh_indicators()
    end
  elseif report.kind == 'hostAttached' then
    state.host_away = nil
    notify(tostring(report.sentence or ''))
    refresh_indicators()
  elseif report.kind == 'listingCut' then
    -- A walk that stopped short of the folder is a fact about the folder, and the host is the
    -- only one who can change it: the guest is told nothing, because a short listing is a
    -- listing like any other and no frame carries a cut. The companion says which bound bound it
    -- (or that its work budget ran out), and the words for each are here so a person reads what
    -- they can act on rather than a code.
    if report.cut == 'paths' then
      notify('this session shares more paths than one room listing carries, so some of its files are not in the room.', vim.log.levels.WARN)
    elseif report.cut == 'bytes' then
      notify("this session's paths are longer in total than one room listing carries, so some of its files are not in the room.", vim.log.levels.WARN)
    elseif report.cut == 'budget' then
      -- A spent budget leaves the folder unread rather than a file left out, so this one hedges
      -- where the two listing bounds do not: the walk stopped, and what it did not reach is not
      -- known to be shareable or not.
      notify("reading this session's folder took more work than one listing walk pays for, so the listing may be missing some of its files.", vim.log.levels.WARN)
    end
  elseif report.kind == 'sessionError' then
    -- The report's own sentence, and its code is not shown: a refusal the protocol named and
    -- one this session made for itself both say what happened in words already — `the room
    -- seats at most 2 peers`, `will not share .env with the room…` — and a code is a lookup,
    -- not a sentence. The one exception is the capacity policy this server states with a code
    -- of its own, which a person wants said rather than spelled out.
    if report.code == 'x.room_full' then
      notify('the room is full — it seats no more people.', vim.log.levels.ERROR)
    else
      notify(tostring(report.message or ''), vim.log.levels.ERROR)
    end
    if report.operation == 'open' and type(report.path) == 'string' then
      local document = state.documents[report.path]
      if document ~= nil then
        let_go(document)
      end
    end
  elseif report.kind == 'applyRefused' then
    notify(
      ('the editor would not apply the room\'s change to %s; the file may be read-only.'):format(
        tostring(report.path)
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'divergence' then
    notify(
      ('%s was out of step with the room; the room\'s copy has been put back.'):format(
        tostring(report.path)
      ),
      vim.log.levels.WARN
    )
  elseif report.kind == 'saveFailed' then
    -- The reason, when the report has one, is what says what to do about it: the sentence is the
    -- fact and the parenthetical is why.
    local why = report.message
    notify(
      ('could not save %s; the file on disk is behind the room%s.'):format(
        tostring(report.path),
        why == nil and '' or (' (' .. tostring(why) .. ')')
      ),
      vim.log.levels.ERROR
    )
  elseif report.kind == 'reconnecting' then
    -- The socket dropped mid-session and the engine's bounded retry is running: the room is
    -- out of reach until it seats again, and a seat reports the room's documents and its
    -- peers. Said rather than inferred from the room going quiet, because a quiet room is
    -- also what everyone else simply editing looks like.
    state.reconnecting = true
    refresh_indicators()
  elseif report.kind == 'disconnected' then
    -- The engine reconnects on its own until it runs out of attempts, and this is that end: the
    -- session is over and typing would accumulate in a replica nobody hears. The companion process
    -- is deliberately left running — `ensure` reuses it on the next host or join, and the engine on
    -- the other side of it has already finished.
    --
    -- A host is the one place no retry runs: `§9.1`'s host return is a fresh room state signed by
    -- the host key, and this client writes no host store, so a hosting session is never re-dialled.
    -- A guest reaches here only after the bounded retry gave up, which is why the two say different
    -- sentences.
    if state.role == 'host' then
      notify(
        'the connection ended and the session is over; this client cannot resume a hosting session, so it will not reconnect.',
        vim.log.levels.ERROR
      )
    else
      notify('the connection ended and the session is over; it could not be re-established.', vim.log.levels.ERROR)
    end
    reset(true)
  end
end

local function on_message(message)
  -- The companion is the same user's own process, not a remote peer, so a misshapen message
  -- is a bug rather than an attack — but one answered blindly fails inside the job callback,
  -- aborting the message with the follow and go-to retries piggybacked on it. Anything
  -- without a type is said and dropped; each arm below reads only the fields it needs.
  if type(message) ~= 'table' or type(message.type) ~= 'string' then
    notify('unreadable message from the companion.', vim.log.levels.WARN)
    return
  end
  if message.type == 'applyEdit' then
    local document = type(message.path) == 'string' and state.documents[message.path] or nil
    -- The range is applied against counted text: a start, end, text or version of the wrong
    -- type would fail inside the buffer arithmetic, aborting the message with the retries
    -- piggybacked on it. Answered false, like a version the front-end has left.
    local ok = false
    if
      document ~= nil
      and type(message.start) == 'number'
      and type(message['end']) == 'number'
      and type(message.text) == 'string'
      and type(message.version) == 'number'
    then
      ok = document:apply(message)
    end
    if ok and document ~= nil then
      -- The room's text has landed, so a file that was empty until now is not: the row's
      -- mark for it goes with the text.
      refresh_indicator_for(document.bufnr)
      -- And the caret the room has not heard: a buffer for a room document exists as soon as
      -- the handshake names it, while the text is a later message — a caret published in
      -- between is one the companion has no document for yet, and the bridge drops those
      -- rather than inventing a document. A programmatic write fires no `TextChanged`, so
      -- this apply is the only moment left to publish it again; without it a peer who has
      -- not moved is a peer whose caret nobody draws.
      schedule_selection()
    end
    state.process:send({ type = 'applied', id = message.id, ok = ok })
    -- The room's text moved under the follow: land again where the peer's caret resolves
    -- now. A remote edit is not a local one, so it never ends the follow.
    follow_frame()
    -- The text a pending go-to waited on may have arrived with this edit.
    retry_go_to()
  elseif message.type == 'save' then
    local document = type(message.path) == 'string' and state.documents[message.path] or nil
    -- A path this session holds nothing for answers false: the companion's save policy would
    -- otherwise hear that a document reached the disk it never touched.
    local ok = document ~= nil and document:save(true)
    state.process:send({ type = 'saved', id = message.id, ok = ok })
  elseif message.type == 'status' then
    -- The session's standing is a word from a fixed set: anything else leaves the guard
    -- this session's liveness is read from holding whatever it held.
    if type(message.state) == 'string' then
      on_status(message)
    else
      notify('unreadable status from the companion.', vim.log.levels.WARN)
    end
  elseif message.type == 'refused' then
    -- This process did not open a second session: one is already live. The commands ask before
    -- they send one, so this is the answer when something else did not.
    local where = message.what == 'host' and 'hosting' or 'in a session'
    notify(('already %s; leave that session first.'):format(where), vim.log.levels.WARN)
  elseif message.type == 'report' then
    if type(message.report) == 'table' then
      on_report(message.report)
    else
      notify('unreadable report from the companion.', vim.log.levels.WARN)
    end
  elseif message.type == 'words' then
    if type(message.words) == 'table' then
      state.words = message.words
    end
  elseif message.type == 'presence' then
    draw_presence(message.cursors)
    -- The peer may have moved, or arrived where this client can draw them: land again.
    follow_frame()
    -- ... or arrived where a pending go-to can land: the same frame unlocks both.
    retry_go_to()
  else
    -- A version-skewed companion's new message would otherwise desync the versions without
    -- a word. Said once per type rather than per message, so a repeated one does not flood.
    if not warned_message_types[message.type] then
      warned_message_types[message.type] = true
      notify(
        ('unknown message type from the companion: %s.'):format(message.type),
        vim.log.levels.WARN
      )
    end
  end
end

local function ensure()
  if state.process ~= nil then
    return state.process
  end
  local process, err
  process, err = companion.start({
    on_message = function(message)
      -- The handler is registered per process, so this is where a message can be attributed to
      -- the process that sent it. A companion this session has let go is not the one to believe:
      -- `leave` forgets the process before stopping it and does not wait for the stop, so the
      -- `status idle` that leave earns can still be in the pipe when the next host or join has
      -- started a process of its own and already heard `hosting` from it. An `applyEdit` from
      -- the same pipe would be answered on the wrong process just as readily.
      if state.process ~= process then
        return
      end
      on_message(message)
    end,
    on_exit = function(code)
      -- A companion this session stopped is no longer its process — `leave` forgets it before
      -- stopping it, and the stop is not waited for — so its exit is not news, whether the
      -- process went on its own or had to be killed. A process the session still knows is one
      -- that went by itself, and that is worth a word when it did not exit cleanly.
      if state.process ~= process then
        return
      end
      state.process = nil
      reset()
      if code ~= 0 then
        notify(('the companion exited with %s.'):format(tostring(code)), vim.log.levels.ERROR)
      end
    end,
  })
  if process == nil then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  state.process = process
  return process
end


M.ensure = ensure

return M
