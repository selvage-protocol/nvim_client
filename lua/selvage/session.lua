-- The session's own bookkeeping: the documents it holds, the mirror it watches, and its end.
--
-- Everything here happens to buffers and files rather than to the room: a wiped buffer stops being
-- held, a file in the mirror is read into the room or has a save routed for it, and `reset` puts
-- the editor back the way it was when the room is gone. `:SelvageLeave` and a room that died take
-- the same path; what differs is only what is said and whether the mirror is kept.
local api = vim.api

local mirror = require('selvage.mirror')
local clear_indicator = require('selvage.bar').clear_indicator
local end_follow = require('selvage.bar').end_follow
local forget_invite = require('selvage.invite').forget_invite
local notify = require('selvage.notify').notify
local peer_row = require('selvage.peers').peer_row
local clear_presence = require('selvage.presence').clear_presence
local publish_file_peers = require('selvage.presence').publish_file_peers
local schedule_selection = require('selvage.presence').schedule_selection
local document_wiped = require('selvage.share').document_wiped
local guest_buffer = require('selvage.share').guest_buffer
local let_go = require('selvage.share').let_go
local notice_unfetched = require('selvage.share').notice_unfetched
local refuse_mirror_write = require('selvage.share').refuse_mirror_write
local refuse_mutation = require('selvage.share').refuse_mutation
local refuse_unlisted = require('selvage.share').refuse_unlisted
local share = require('selvage.share').share
local buffer_empty = require('selvage.state').buffer_empty
local is_peer = require('selvage.state').is_peer
local state = require('selvage.state').state

local M = {}

--- Re-opens the documents this session holds whose room path the mirror now has a file for.
---
--- The room's grant and its open-document set are two messages, and which of them arrives first is
--- the server's to decide: the grant is restated in a `doc.granted` straight after `room.joined`,
--- so a guest usually hears which documents the room holds before it hears what the room grants,
--- and a `selvage://` buffer made in that window becomes the file the listing names for it. A
--- republished listing that names a path the guest already holds goes the same way.
---
--- What the buffer holds is carried into the file it is opened as, and the room's text this client
--- holds is saved into it, because re-pointing a document is not a document that starts over: a
--- buffer that began empty would tell the companion the document is empty for as long as the room
--- takes to answer, and a peer's caret resolved against it would be drawn in the wrong column.
local function remirror_documents()
  for path, document in pairs(state.documents) do
    if
      document ~= nil
      and mirror.granted(path)
      and api.nvim_buf_get_name(document.bufnr) ~= mirror.buffer_name(path)
    then
      local old = document.bufnr
      local lines = api.nvim_buf_get_lines(old, 0, -1, true)
      local held_text = #lines > 1 or lines[1] ~= ''
      local bufnr = guest_buffer(path)
      if bufnr ~= old then
        document:detach()
        state.documents[path] = nil
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        if api.nvim_buf_is_valid(old) then
          -- A window showing the buffer that is going away is pointed at the one replacing it,
          -- so that closing the room's copy does not move the person somewhere else. The move
          -- is the session's own placement rather than an open, so the unfetched hint stays
          -- silent for it the way it does for the landing's `show`.
          state.suppress_unfetched = true
          for _, win in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == old then
              pcall(api.nvim_win_set_buf, win, bufnr)
            end
          end
          state.suppress_unfetched = false
          pcall(api.nvim_buf_delete, old, { force = true })
        end
        share(bufnr, path)
        local replaced = state.documents[path]
        if replaced ~= nil and held_text then
          -- The file the buffer is now opened as holds what this client holds for the room. An
          -- empty placeholder is left alone: there is nothing to write that the file does not
          -- already hold.
          replaced:save(true)
        end
      end
    end
  end
end

--- Watches the mirror's files, for a guest.
---
--- Reading one is how a person or a plugin opens the room's file, and it goes through the same
--- share `:SelvageOpen` uses: the room is what has the content, and the host reads its working
--- copy when this client asks for it. A name under the mirror that is neither in the room's listing
--- nor a document this session holds is a file on this disk and nothing else, and is said so once.
---
--- Saving one is the session's to route, not the editor's. `BufWriteCmd` suppresses the write the
--- editor would have made, and the document's own save gives the file the text this client holds
--- for the room. A path the room knows nothing about is refused rather than written into a
--- directory the session deletes.
---
--- A write of *part* of a buffer reaches none of that: `:[range]write {file}` runs `FileWriteCmd`
--- and `:write >> {file}` runs `FileAppendCmd`, and both are matched against the file being
--- written rather than against the buffer. Either one naming a file inside the mirror would put
--- the buffer's own lines into the room's files with the room hearing nothing, so they are
--- refused here. A file outside the mirror is the person's own and is left to the editor.
local function watch_mirror()
  local root = mirror.root()
  if root == nil then
    return
  end
  state.mirror_group = api.nvim_create_augroup('SelvageMirror', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path == nil then
        return
      end
      -- A document this session holds is the room's whether or not the listing still names it:
      -- the listing is what it mirrors, and the open-document set is a fact of its own.
      if mirror.granted(path) or state.documents[path] ~= nil then
        share(event.buf, path)
        local file = mirror.file(path)
        if file ~= nil and mirror.granted(path) and vim.fn.filereadable(file) == 0 then
          refuse_mutation(path)
        end
        if mirror.granted(path) and not mirror.written(path) and buffer_empty(event.buf) then
          notice_unfetched(path)
        end
      elseif state.unmutated[path] == nil then
        refuse_unlisted(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path == nil then
        return
      end
      local document = state.documents[path]
      if document == nil then
        refuse_mirror_write(path)
        return
      end
      if not document:save() then
        notify(('%s could not be written into the mirror.'):format(path), vim.log.levels.ERROR)
      end
    end,
  })
  -- A partial write or an append, to a file this session's mirror holds: the pattern is the file
  -- being written, so a target outside the mirror never reaches this.
  for _, name in ipairs({ 'FileWriteCmd', 'FileAppendCmd' }) do
    api.nvim_create_autocmd(name, {
      group = state.mirror_group,
      pattern = root .. '/*',
      callback = function(event)
        local target = event.file or ''
        if target:sub(1, #root + 1) == root .. '/' then
          target = target:sub(#root + 2)
        end
        notify(
          ('%s is inside the mirror, which holds the room\'s files, so it is not written; write outside the mirror to keep it.'):format(target),
          vim.log.levels.WARN
        )
      end,
    })
  end
  -- A file mutation has no frame, so it is refused where the editor names it: a new file,
  -- and a buffer renamed onto a mirror name, each say so once per path. A file outside the
  -- mirror is the person's own and is left alone.
  api.nvim_create_autocmd('BufNewFile', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path ~= nil then
        refuse_mutation(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufFilePost', {
    group = state.mirror_group,
    pattern = root .. '/*',
    callback = function(event)
      if state.suppress_rename then
        return
      end
      local path = mirror.room_path(api.nvim_buf_get_name(event.buf))
      if path ~= nil then
        refuse_mutation(path)
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = state.mirror_group,
    callback = document_wiped,
  })
end

--- Lets every document this session shares go. A session ends while the companion stays up —
--- `:SelvageLeave` is one way, and a new host or join another, since the companion's own
--- `connect()` leaves the session before it (`status idle`) — so the paths of the session that
--- just ended have to stop counting as shared. They would otherwise make `share` return early
--- and never send the `open` that puts them in the new room, while the companion, which does
--- start clean, holds nothing.
---
--- Detaching is what makes this the end of the document rather than a leak: a `Document` left
--- attached would keep reporting the buffer beside the one the new session makes for it. A
--- refusal goes the same way, so the next session looks at the buffer again.
local function forget_documents()
  for _, document in pairs(state.documents) do
    -- The room's documents are the room's; a buffer that leaves the session is the person's
    -- again, with the `modifiable` it had before the session took it — a buffer the person had
    -- made uneditable stays uneditable, and one the session made read-only for a viewer is
    -- editable again.
    document:set_read_only(false)
    document:detach()
  end
  state.documents = {}
  state.unshareable = {}
  state.outside = {}
  state.unfiled = {}
  state.linked = {}
end

local function room_buffers()
  if not is_peer() then
    return nil
  end
  local held = {}
  for _, document in pairs(state.documents) do
    if api.nvim_buf_is_valid(document.bufnr) then
      held[#held + 1] = document.bufnr
    end
  end
  return held
end

--- Points every window showing one of `bufnrs` at one new empty buffer, so that wiping them
--- closes no window and leaves nothing of the room on screen.
---
--- @param bufnrs integer[]
local function land_windows(bufnrs)
  local landing = nil
  for _, win in ipairs(api.nvim_list_wins()) do
    if vim.tbl_contains(bufnrs, api.nvim_win_get_buf(win)) then
      if landing == nil then
        landing = api.nvim_create_buf(true, false)
      end
      pcall(api.nvim_win_set_buf, win, landing)
    end
  end
end

--- A room that dies under a person leaves no window showing it.
---
--- The room's buffers are the room's, and when the room is gone they are nobody's: a window still
--- showing one reads as a room that is still there. What the person has not changed goes with it
--- — its text is the room's, and the session that could write it has ended — while a buffer
--- holding their own unsaved changes is kept in the buffer list and said so: the session can no
--- longer save it, so dropping it would drop their text, and silence would hide where it went.
--- (`:SelvageLeave` and a new host or join are not this: the room lives on, and the person asked.)
local function land_room_buffers(held)
  if held == nil or #held == 0 then
    return
  end
  land_windows(held)
  local kept = 0
  for _, bufnr in ipairs(held) do
    if api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        kept = kept + 1
      else
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
  if kept == 1 then
    notify('1 buffer with unsaved changes was kept; :ls lists it.', vim.log.levels.WARN)
  elseif kept > 1 then
    notify(
      ('%d buffers with unsaved changes were kept; :ls lists them.'):format(kept),
      vim.log.levels.WARN
    )
  end
end

--- Takes away the documents whose paths the listing left: the host no longer has the file, and a
--- buffer left standing on it would go on sharing a document no folder holds, its autosave writing
--- the file back into the mirror (`PROTOCOL.md` §13.3 lets a client keep holding it, and says it
--- may not offer it).
---
--- A buffer is wiped the way a dead room's are, and the wipe releases the hold. One holding the
--- person's own unsaved changes stays where it is, because wiping it would drop their text, and
--- stops being the room's instead: it is let go of, and the mirror's refusal of an unlisted name is
--- not said over it again. Either way the path is not offered until a listing names it again.
---
--- @param paths string[] held paths
local function drop_documents(paths)
  if state.following ~= nil then
    local row = peer_row(state.following.peerId)
    for _, path in ipairs(paths) do
      if row ~= nil and row.path == path then
        end_follow('gone')
        break
      end
    end
  end
  local wiped = {}
  for _, path in ipairs(paths) do
    local document = state.documents[path]
    state.dropped[path] = true
    if vim.bo[document.bufnr].modified then
      let_go(document)
      state.unlisted[path] = true
      notify(
        ('%s is no longer in the room; your unsaved copy is kept but no longer shared.'):format(path),
        vim.log.levels.WARN
      )
    else
      wiped[#wiped + 1] = document.bufnr
      notify(('%s is no longer in the room, so it was closed.'):format(path), vim.log.levels.WARN)
    end
  end
  land_windows(wiped)
  for _, bufnr in ipairs(wiped) do
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end
  -- A kept buffer can still be the one in front of the person, and no window moved to say its
  -- caret is no longer in the room.
  schedule_selection()
end

local function reset(land, keep_mirror)
  local held = land and room_buffers() or nil
  local kept = keep_mirror and mirror.root() or nil
  -- The session is over before anything else moves, and the indicators go with it: landing a
  -- dead room's buffers switches windows, and a switch is a `BufEnter` — an indicator that
  -- still read a live session would put its row back on a session that is gone. Setting the
  -- status first is what makes that switch read the session as ended, and the rows are put
  -- back here rather than left for a window that may never be entered again.
  state.status = 'idle'
  state.reconnecting = false
  state.host_away = nil
  state.self_seat = nil
  state.identity = nil
  clear_indicator()
  -- A callback left attached would keep sending into a companion that is gone.
  forget_documents()
  clear_presence()
  state.peers = {}
  state.room_peers = {}
  state.cursors = {}
  -- The seam a file-list plugin reads is emptied with the session: a badge for a peer is not
  -- something to leave standing over a room that is gone.
  publish_file_peers()
  for _, name in pairs(state.peer_groups) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  for _, name in pairs(state.peer_fills) do
    pcall(api.nvim_set_hl, 0, name, {})
  end
  state.peer_groups = {}
  state.peer_fills = {}
  state.peer_paints = {}
  state.peer_count = 0
  state.generation = state.generation + 1
  state.selection_armed = false
  state.selection_path = nil
  -- The follow goes with the session, silently: leaving, the room going and the
  -- connection ending say their own sentence, and none of them is about the follow. A
  -- pending go-to goes with it, for the same reason and with the same silence.
  end_follow('silent')
  state.pending_go_to = nil
  state.landing_wait = nil
  land_room_buffers(held)
  state.role = nil
  state.viewer_said = false
  state.room = nil
  forget_invite(state.handed_invite, true)
  state.handed_invite = nil
  state.invite = nil
  state.auto_open = false
  state.join_said = false
  state.join_mirror = nil
  state.join_empty = false
  state.join_listed = false
  state.suppress_unfetched = false
  -- The grant belongs to the session, and a session that has ended grants nothing: the folder it
  -- was rooted at, the listing the room carried, and the mirror those two made on disk. The room
  -- is the truth and the directory is a cache of it, so a mirror is removed unless `keep_mirror`
  -- says the room closed under the person and the cache holds the only copy of their work.
  state.root = nil
  state.grant = {}
  state.room_documents = {}
  state.unlisted = {}
  state.unwritable = {}
  state.unmutated = {}
  state.dropped = {}
  state.unfetched = {}
  mirror.teardown(keep_mirror)
  if state.group ~= nil then
    api.nvim_del_augroup_by_id(state.group)
    state.group = nil
  end
  if state.mirror_group ~= nil then
    api.nvim_del_augroup_by_id(state.mirror_group)
    state.mirror_group = nil
  end
  if state.presence_group ~= nil then
    api.nvim_del_augroup_by_id(state.presence_group)
    state.presence_group = nil
  end
  if state.follow_group ~= nil then
    api.nvim_del_augroup_by_id(state.follow_group)
    state.follow_group = nil
  end
  state.saved_winbars = {}
  return kept
end

--- Ends the session this front-end is in, leaving the companion process for what comes next: one
--- process serves every session a Neovim instance runs, and only `:SelvageLeave` stops it. The
--- companion hears the `leave` and answers with `status idle`, which is the same teardown again
--- from the other side; a front-end that has already forgotten the session does not notice.
local function end_session()
  if state.process ~= nil then
    state.process:send({ type = 'leave' })
  end
  reset()
end

--- Puts this session's page link on the clipboard and the unnamed register; defined below,
--- declared here because the host confirm above runs before its definition loads.
local hand_on_invite

--- Whether a document the room changes is written. Nothing is sent when the plugin's global says
--- nothing, so the companion's own default — write it — stands, as the other client's setting
--- defaults to on.
local function auto_save()
  local configured = vim.g.selvage_auto_save
  if type(configured) == 'boolean' then
    return configured
  end
  return nil
end


M.auto_save = auto_save
M.drop_documents = drop_documents
M.end_session = end_session
M.remirror_documents = remirror_documents
M.reset = reset
M.watch_mirror = watch_mirror

return M
