-- Which buffer is shared under which room path.
--
-- A host's own files are the room's documents: `share` decides whether a buffer is one the room
-- may carry — its bytes are text, it is a regular file, it lies inside the folder the session was
-- started in — and opens it in the room. A refusal is said once per path, in the words the other
-- client uses, because a refusal nobody hears is indistinguishable from a plugin doing nothing.
-- `let_go` is the other direction: a buffer that stops being held while the session goes on.
local api = vim.api
local uv = vim.uv or vim.loop

local Document = require('selvage.document')
local mirror = require('selvage.mirror')
local utf16 = require('selvage.utf16')
local end_follow = require('selvage.bar').end_follow
local notify = require('selvage.notify').notify
local draw_presence = require('selvage.presence').draw_presence
local schedule_selection = require('selvage.presence').schedule_selection
local queries = require('selvage.queries')
local document_for_buf = require('selvage.state').document_for_buf
local in_session = require('selvage.state').in_session
local state = require('selvage.state').state

local M = {}

--- Stops holding a document while the session goes on: the buffer stops reporting and the room
--- is told, which is what releases the hold.
---
--- The send belongs here rather than in `Document:on_detach`, which also fires when the
--- session ends: every `:SelvageLeave` would put a `close` on the wire for each document it
--- is letting go of, and the companion would hear about a room it is already leaving.
---
--- @param document table
local function let_go(document)
  document:detach()
  if state.process ~= nil then
    state.process:send({ type = 'close', path = document.path })
  end
  state.documents[document.path] = nil
end


--- A wiped buffer is not a buffer anymore: the room is told, and the path stops being held
--- here. Without this the room keeps the document for the life of the session, offering
--- edits to a `Document` that answers every one of them `ok = false`, and the companion
--- retries until it reports a refusal about a buffer the user closed.
---
--- @param event table
local function document_wiped(event)
  local document = document_for_buf(event.buf)
  if document == nil then
    return
  end
  let_go(document)
end

--- The folder this session's grant is rooted at: where the person stood when they started it.
--- Called as a session starts, before the buffer in front of them is shared.
---
--- The root is kept as a prefix — `/` separators, no trailing slash — so a buffer's own path
--- can be measured against it with one comparison. `getcwd()` answers with the directory in
--- force in this window, so a `:lcd` or `:tcd` made before the session is where the session
--- started, which is the folder the person chose to invite from.
local function capture_root()
  state.root = vim.fn.getcwd():gsub('\\', '/'):gsub('/+$', '')
end

--- Says, once per path, that a file is not the room's to share because it lies outside the
--- session's grant. Neovim shows no workspace the way the other client's window does, so
--- nothing else here tells a person which folder the room can see: a refusal nobody hears is
--- indistinguishable from a plugin that is not sharing at all.
local function refuse_outside(path)
  if state.outside[path] ~= nil then
    return
  end
  state.outside[path] = true
  notify(
    ('%s is outside %s, the folder this session shares, so it is not shared.'):format(
      path,
      state.root == '' and '/' or state.root
    ),
    vim.log.levels.WARN
  )
end

--- Says, once per buffer, that a buffer with no file is not the room's to share. Hosting from
--- an untitled buffer and typing is the newcomer's silence: the room never hears it, and
--- nothing else here says so. A buffer that was never meant to be a file, such as help, is not
--- one a person types into for the room, so it is left unsaid.
local function refuse_unfiled(bufnr)
  if state.unfiled[bufnr] ~= nil or vim.bo[bufnr].buftype ~= '' then
    return
  end
  local root = state.root
  if root == nil then
    return
  end
  state.unfiled[bufnr] = true
  notify(
    ('this buffer has no file, so it is not shared; the folder this session shares is %s.'):format(
      root == '' and '/' or root
    ),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that a buffer's name is not a regular file and so is not the room's
--- to share. The serve path a peer's ask takes refuses every link (`companion/grant.ts`
--- reads with `O_NOFOLLOW`); the share path must not read straight through one and publish
--- the target's bytes. The name is read with `lstat`, which reports the link itself.
local function refuse_link(path)
  if state.linked[path] ~= nil then
    return
  end
  state.linked[path] = true
  notify(('%s is not a regular file, so it is not shared.'):format(path), vim.log.levels.WARN)
end

--- The room path a buffer is shared under, and the absolute name it is refused for when it
--- is not one to share.
---
--- The grant is the folder the session was started in (`DESIGN.md` §4.2), so a name is
--- measured against that and never against the working directory, which `:cd` moves at any
--- moment. A name is absolute — Neovim resolves it when it sets one — and the separator in
--- the prefix is what keeps a sibling whose name merely begins with the grant's out of it.
--- A file outside the grant comes back as the second value so the refusal can be said;
--- anything that is not a file buffer comes back as neither, so its own refusal can be.
local function room_path(bufnr)
  if vim.bo[bufnr].buftype ~= '' then
    return nil, nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil, nil
  end
  local root = state.root
  if root == nil then
    return nil, nil
  end
  local absolute = (name:gsub('\\', '/'))
  local prefix = root .. '/'
  if absolute:sub(1, #prefix) == prefix then
    return absolute:sub(#prefix + 1), nil
  end
  if absolute:sub(1, 1) == '/' or absolute:match('^%a:/') ~= nil then
    return nil, absolute
  end
  return nil, nil
end

--- The largest file a session carries, mirroring `MAX_GRANT_FILE_BYTES` in the grant's own rules
--- (`vendor/bridge/grant.ts`, and `MAX_GRANT_PATH_BYTES` is mirrored the same way in
--- `mirror.lua`). A file past it is one the companion refuses for its size before it reads a byte,
--- so the share path does not read one either.
local MAX_FILE_BYTES = 1024 * 1024

--- Whether a session may carry the file a buffer is named for: its **bytes**, as they stand on
--- disk, are text — no NUL byte, and well-formed UTF-8. The same gate the companion applies to a
--- peer's request for the file (`companion/grant.ts`, `decodableText`), reached from the other
--- side of the same question.
---
--- The buffer's own text cannot stand in for it. Neovim reads a file whose bytes are not UTF-8 as
--- Latin-1 (`'fileencodings'`' own fallback, which is how a `.bin` opens at all), so the buffer
--- holds a transliteration: every byte became a character, and the text the buffer reports is
--- well-formed UTF-8 whatever the file was. That text is what a session publishes, and a peer's
--- later edit made the room's save policy write it back over the host's own file — the file's
--- original bytes survive that round trip only because the same `'fileencoding'` converts them
--- back, which stops being true the moment a peer types a character it cannot hold.
---
--- `true` when the bytes are text, `false` when they are not, and nil when the file could not be
--- read in one piece at all — a file that moved under the read is not a prefix of itself to judge,
--- and what a buffer holds for it is not what the bytes say.
---
--- @param name string the file the buffer is named for
--- @return boolean|nil
local function file_is_text(name)
  local fd = uv.fs_open(name, 'r', tonumber('644', 8))
  if fd == nil then
    return nil
  end
  local bytes
  local ok = pcall(function()
    local opened = uv.fs_fstat(fd)
    -- The descriptor is what the bytes are read from, so the size is read there as well: a name
    -- may have been another file's by the time it is opened.
    if opened == nil or opened.type ~= 'file' then
      return
    end
    local chunks = {}
    local read = 0
    while read < opened.size do
      local chunk = uv.fs_read(fd, opened.size - read, read)
      if chunk == nil or #chunk == 0 then
        break
      end
      chunks[#chunks + 1] = chunk
      read = read + #chunk
    end
    -- Fewer bytes than the descriptor holds is not a prefix of the file to judge: it is a file
    -- that moved under the read, and what it holds now is not what the buffer was read from.
    if read == opened.size then
      bytes = table.concat(chunks)
    end
  end)
  uv.fs_close(fd)
  if not ok or bytes == nil then
    return nil
  end
  return bytes:find('\0', 1, true) == nil and utf16.valid(bytes)
end

--- Says, once per path, that a file a person opened is not one a room can carry: its bytes are not
--- text. The companion says the same thing about the same file when a peer asks the room for it.
local function refuse_binary(path)
  if state.unshareable[path] ~= nil then
    return
  end
  state.unshareable[path] = true
  notify(
    ('%s is a binary file, and a room carries text, so it is not shared.'):format(path),
    vim.log.levels.ERROR
  )
end

--- Says, once per path, that a file could not be read, so nothing was shared for it. A file that
--- moved between the buffer's own read and this one is one whose bytes are not known, and what a
--- session cannot judge is not carried: the text the buffer holds for it may be a transliteration
--- of bytes it no longer has (`file_is_text`). Entering the buffer again looks again, so this is
--- said once rather than once per visit.
local function refuse_unreadable(path)
  if state.unshareable[path] ~= nil then
    return
  end
  state.unshareable[path] = true
  notify(('%s could not be read, so it is not shared.'):format(path), vim.log.levels.WARN)
end

--- A `viewer`'s editor is read-only in the room.
---
--- §13.9 gives a viewer its own edit and publishes none of it, so a buffer that accepted one
--- would show text the room never receives — a keystroke the person believes is shared, which is
--- worse than a refusal. What the room sends is not refused (`PROTOCOL.md` §13.9), so the read-only
--- flag is the document's own to take and to write through (`document.lua`), and a keystroke is the
--- one thing it stops. The room state seats a viewer, and only the room state can: the role is
--- its own word about this connection's key (§13.4).
local function apply_read_only(document)
  if document == nil then
    return
  end
  document:set_read_only(state.role == 'viewer')
end

--- Every room document this session holds, read-only or not as the role says. Called where a
--- role arrives and where a document does, so a viewer that joined an empty room and one that
--- joined a full one end up the same.
local function apply_read_only_to_room()
  for _, document in pairs(state.documents) do
    apply_read_only(document)
  end
end

--- The role this session has, where the room's own state says it: at the seat, and again if the
--- state gives this connection another one afterwards (§13.4).
---
--- The sentence is said once, here, because this is where the role first reaches the editor — a
--- room state may seat the connection as a viewer only after the join, and a person who is
--- handed a read-only editor is owed the reason for it.
local function note_role(role)
  if role == nil or role == state.role then
    return
  end
  state.role = role
  apply_read_only_to_room()
  if role == 'viewer' and not state.viewer_said then
    state.viewer_said = true
    notify('you are a viewer in this room, so its documents are read-only.', vim.log.levels.WARN)
  end
end

local function share(bufnr, path)
  if state.process == nil or state.documents[path] ~= nil then
    return
  end
  -- The buffer's name is read with `lstat` before its text is: a link inside the grant
  -- would otherwise be read straight through and its target's bytes published to the room,
  -- which the serve path a peer's ask takes refuses. Anything but a regular file — a link,
  -- a directory, a socket — is refused the way a file outside the grant is. A name with
  -- nothing behind it is a file the person has not written yet, and shares empty.
  local behind = uv.fs_lstat(api.nvim_buf_get_name(bufnr))
  if behind ~= nil and behind.type ~= 'file' then
    refuse_link(path)
    return
  end
  -- The same text `Document.new` will shadow, read once. The companion decodes its stdin as
  -- UTF-8, so a buffer whose bytes are not UTF-8 would reach the room as U+FFFD; refusing it
  -- here keeps the `open` out of the room and every later `change` with it.
  local text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n')
  if not utf16.valid(text) then
    if state.unshareable[path] == nil then
      state.unshareable[path] = true
      notify(('%s is not valid UTF-8, so it is not shared.'):format(path), vim.log.levels.ERROR)
    end
    return
  end
  -- A buffer's text is not the file's bytes: Neovim decodes a file it cannot read as UTF-8 into
  -- one, so a buffer can hold text that reads as valid UTF-8 while the file it was read from
  -- holds a binary. The room is refused the file it cannot carry rather than the transliteration
  -- of it — the same refusal a peer asking for the path is given, from the same question.
  --
  -- A file past the bound is not read at all: the companion judges the text the buffer holds and
  -- refuses one past the session's own bound, in words that say so. What that leaves is a file
  -- past the bound whose decoded text is not (a UTF-16 file, say), and that one is carried: its
  -- text is the file's rather than a transliteration of it, so nothing is written back over the
  -- file that the file did not hold.
  if behind ~= nil and behind.size <= MAX_FILE_BYTES then
    local bytes_are_text = file_is_text(api.nvim_buf_get_name(bufnr))
    if bytes_are_text == false then
      refuse_binary(path)
      return
    end
    if bytes_are_text == nil then
      refuse_unreadable(path)
      return
    end
  end
  local document = Document.new(bufnr, path, function(message)
    -- The change goes first: the document's version has already moved, so nothing after this
    -- line may stand between the edit and the room.
    state.process:send(message)
    -- A local edit of a shared document ends a follow: with the caret moved by the follow,
    -- typing and following are in direct conflict, and the keystroke has already chosen the
    -- place. A remote edit never reaches this closure — `Document:apply` writes the buffer
    -- under its own flag and sends nothing — so only an edit made here ends one.
    if message.type == 'change' and state.following ~= nil then
      end_follow('typed')
    end
  end)
  state.documents[path] = document
  document:attach()
  apply_read_only(document)
  state.process:send({ type = 'open', path = path, text = text })
  -- The document may already have a peer's caret resolved against it, and this buffer's own
  -- caret is worth publishing the moment the room holds it.
  draw_presence(state.cursors)
  schedule_selection()
end

--- The buffer a guest holds the room's document in.
---
--- For a path the room's grant names, that is the mirror's file: a real path on disk, so that a
--- language server, ripgrep, ctags and every plugin that reads one sees the file the person is
--- editing. The file is read into the buffer the way `:edit` reads it, so the buffer really is a
--- file buffer — its `:w` is the session's to route, and a plugin that looks at the buffer finds
--- the file behind it. A document the grant does not name has nowhere to go and stays a
--- `selvage://` buffer.
---
--- @param path string the room path
--- @return integer bufnr
local function guest_buffer(path)
  local name = mirror.buffer_name(path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end
  if name == 'selvage://' .. path then
    local bufnr = api.nvim_create_buf(true, true)
    state.suppress_rename = true
    local ok, err = pcall(api.nvim_buf_set_name, bufnr, name)
    state.suppress_rename = false
    if not ok then
      error(err)
    end
    vim.bo[bufnr].modifiable = true
    return bufnr
  end
  local bufnr = api.nvim_create_buf(true, false)
  state.suppress_rename = true
  local named, name_err = pcall(api.nvim_buf_set_name, bufnr, name)
  state.suppress_rename = false
  if not named then
    error(name_err)
  end
  api.nvim_buf_call(bufnr, function()
    vim.cmd('silent noautocmd edit!')
  end)
  -- `noautocmd` keeps the session's own hooks and the person's out of the way while the buffer is
  -- made, and it also suppresses what the `filetypedetect` group does on `BufRead`: the buffer is
  -- named for a real file and would hold no `filetype`, and so no syntax. Detection is therefore
  -- asked for directly, by the same name the buffer carries.
  local filetype = vim.filetype.match({ buf = bufnr, filename = name })
  if filetype ~= nil then
    vim.bo[bufnr].filetype = filetype
  end
  vim.bo[bufnr].modifiable = true
  return bufnr
end

--- Says, once per path, that a file inside the mirror is not one the room knows: a tool that
--- created it there made a file on this disk and nothing else, and a person who edits it should
--- hear that before they think the room has it.
---
--- @param path string the room path as the mirror's file names it
local function refuse_unlisted(path)
  if state.unlisted[path] ~= nil then
    return
  end
  state.unlisted[path] = true
  notify(
    ("%s is not in the room, so it is not shared. Save a copy outside the room's folder to keep it."):format(path),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that the mirror would not write a file: the room has no document for it,
--- so a save would put a file into a cache the session deletes and the room would never hold.
--- The buffer keeps the text, so the person can still save it somewhere of their own choosing.
---
--- @param path string the room path as the mirror's file names it
local function refuse_mirror_write(path)
  if state.unwritable[path] ~= nil then
    return
  end
  state.unwritable[path] = true
  notify(
    ("%s is not in the room, so this save was not shared. Save a copy outside the room's folder to keep it."):format(path),
    vim.log.levels.WARN
  )
end

--- Says, once per path, that the room has no frame for a file mutation, so the file is refused
--- where the editor names it.
---
--- @param path string the room path as the mirror's file names it
local function refuse_mutation(path)
  if state.unmutated[path] ~= nil then
    return
  end
  state.unmutated[path] = true
  notify('the room carries no file mutations yet.', vim.log.levels.WARN)
end

--- Says, once per path, that a mirror file opened empty holds nothing yet because its content
--- has not been fetched: the shape is materialised and the content is not, so an empty file is
--- the expected sight, and `:SelvageFetch` is what fills it.
---
--- Said for the first such file in a session and never again: the sentence is for the shape,
--- and the shape is the same on every empty file, so one hint per file is a flood with
--- the file count. The paths are all still recorded, so a file fetched later is not news.
--- The join's own landing is the exception: while it is placed the hint is suppressed
--- outright, unrecorded, so the first file opened afterwards still earns it.
local function notice_unfetched(path)
  if state.suppress_unfetched then
    return
  end
  if state.unfetched[path] ~= nil then
    return
  end
  local first = next(state.unfetched) == nil
  state.unfetched[path] = true
  if first then
    notify(('this file is empty until fetched; :SelvageFetch %s fills it.'):format(path))
  end
end

--- Shares the buffer in the window, or says why it is not the room's to share.
local function share_current()
  local bufnr = api.nvim_get_current_buf()
  local path, refused = room_path(bufnr)
  if path ~= nil then
    share(bufnr, path)
  elseif refused ~= nil then
    refuse_outside(refused)
  else
    refuse_unfiled(bufnr)
  end
end

--- Puts a buffer in the window the user is looking at. Answers the window, or nil when it could
--- not.
local function show(bufnr)
  if bufnr == nil or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local win = api.nvim_get_current_win()
  if not pcall(api.nvim_win_set_buf, win, bufnr) then
    return nil
  end
  return win
end

--- The room path a user's words name: the room path, its `selvage://` buffer name, its file in
--- the mirror, or a suffix of the path at a directory boundary. A host above a folder called
--- `workspace` publishes `workspace/README.md`; a guest who types `README.md` means that one.
---
--- The search is over what the room offers, so a path the grant named and nobody has opened is
--- as nameable as one with a buffer behind it.
---
--- @param wanted string
--- @return string|nil resolved, string[] matches
local function resolve(wanted)
  wanted = wanted:gsub('^selvage://', '')
  local root = mirror.root()
  if root ~= nil and wanted:sub(1, #root + 1) == root .. '/' then
    wanted = wanted:sub(#root + 2)
  end
  local offered = queries.offered()
  for _, candidate in ipairs(offered) do
    if candidate == wanted then
      return wanted, {}
    end
  end
  local matches = {}
  for _, candidate in ipairs(offered) do
    if candidate:sub(-(#wanted + 1)) == '/' .. wanted then
      matches[#matches + 1] = candidate
    end
  end
  if #matches == 1 then
    return matches[1], matches
  end
  return nil, matches
end

--- Puts a room path in the window: the buffer this session already holds for it, or the buffer
--- a guest's room path is shown in when the room offers it and nobody has opened it yet.
---
--- A granted path goes through exactly what a room document goes through — a buffer and an `open`
--- the companion turns into a hold — because the room is what has the content: the host reads its
--- working copy when it is asked, and a path with no `Document` behind it is not one this session
--- holds. The buffer is the mirror's file when the grant names the path, and a `selvage://` one
--- when it does not.
local function reveal(path)
  local document = state.documents[path]
  if document ~= nil then
    return show(document.bufnr) ~= nil
  end
  local bufnr = guest_buffer(path)
  share(bufnr, path)
  return show(bufnr) ~= nil
end

local function choose(paths)
  vim.ui.select(paths, { prompt = 'selvage: open which document?' }, function(choice)
    if choice ~= nil then
      reveal(choice)
    end
  end)
end

--- Opens one of the room's documents in the current window.
---
--- With no argument and one document, that document; with several, the user is asked which.
--- What is offered is the room's grant unioned with the documents the room holds open and the
--- ones this session holds, so a path the host listed and nobody has opened yet is offered too,
--- and so is a path a peer holds open that this window has no buffer for.
---
--- A host is refused: the room's documents are the host's own files, already in its buffer list,
--- and the command means the copy the room holds that a window does not have. Its own set is not
--- lost — `:SelvagePeers` and `require('selvage').session()` still report it.
function M.open(path)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('you are the host — the files you open are the ones your guests see.', vim.log.levels.INFO)
    return
  end
  local paths = queries.offered()
  if #paths == 0 then
    notify('no one in the room has a file open yet.', vim.log.levels.INFO)
    return
  end
  local wanted = vim.trim(path or '')
  if wanted == '' then
    if #paths == 1 then
      reveal(paths[1])
    else
      choose(paths)
    end
    return
  end
  local resolved, candidates = resolve(wanted)
  if resolved == nil then
    if #candidates > 1 then
      notify(
        ('"%s" matches several: %s.'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no shared document matches "%s"; :SelvageOpen alone offers them.'):format(wanted),
        vim.log.levels.WARN
      )
    end
    return
  end
  reveal(resolved)
end

--- A host shares what it opens for as long as the session lasts.
local function watch_buffers()
  state.group = api.nvim_create_augroup('SelvageHost', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = state.group,
    callback = function(event)
      local path, refused = room_path(event.buf)
      if path ~= nil then
        share(event.buf, path)
      elseif refused ~= nil then
        refuse_outside(refused)
      else
        refuse_unfiled(event.buf)
      end
    end,
  })
  -- A wiped buffer is not a buffer anymore: the room is told, and the path stops being held
  -- here. See `document_wiped`.
  api.nvim_create_autocmd('BufWipeout', {
    group = state.group,
    callback = document_wiped,
  })
end


M.capture_root = capture_root
M.document_wiped = document_wiped
M.guest_buffer = guest_buffer
M.let_go = let_go
M.note_role = note_role
M.notice_unfetched = notice_unfetched
M.refuse_mirror_write = refuse_mirror_write
M.refuse_mutation = refuse_mutation
M.refuse_unlisted = refuse_unlisted
M.resolve = resolve
M.reveal = reveal
M.share = share
M.share_current = share_current
M.show = show
M.watch_buffers = watch_buffers

return M
