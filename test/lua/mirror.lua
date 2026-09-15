-- The guest's mirror in a real headless Neovim: the room's listing as a real directory, the
-- content fetched into it, and what happens at the edges of that.
--
--   nvim --headless -l test/lua/mirror.lua      (or scripts/test-lua.sh)
--
-- `DESIGN.md` §4.2 is the rule. A guest materialises the grant's *shape* so that anything that
-- reads the filesystem — ripgrep, ctags, a language server, a tree plugin — sees the whole room,
-- and fetches a file's *content* when something needs it. The directory is a cache: the room is
-- the truth, the session ends by removing it, and nothing in it is written back on its own.
--
-- What is pinned here is this client's half of that: where the directory is and how long it
-- lives, what the listing materialises, which buffer a room path is opened in, how content
-- reaches the file, what a save does and what a write the room knows nothing about does, and
-- the one command that fetches a file, a directory or the whole listing. The companion's half —
-- the room's text arriving — is `test/companion.test.ts`, and the two together are
-- `test/e2e/guest.lua`.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime! plugin/selvage.lua')

local uv = vim.uv or vim.loop

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- Where this client's mirrors live, which is the real one: the directory the plugin writes is
--- the directory this file reads, and every session it starts is removed on the way out.
local CACHE = vim.fn.stdpath('cache') .. '/selvage'

--- A companion that records what it is asked to send, and — when a responder is installed —
--- answers the way the room does. Everything about a document is the companion's in a real
--- session, so a stub that answers is the only way to reach the front-end's half of the fetch.
local sent = {}
local handlers = nil
local responder = nil
local next_id = 0

--- A fresh id for a message this file's stub sends, the way the companion numbers one.
local function message_id()
  next_id = next_id + 1
  return next_id
end
package.loaded['selvage.companion'] = {
  start = function(given)
    handlers = given
    return {
      send = function(_, message)
        sent[#sent + 1] = message
        if responder ~= nil then
          responder(message)
        end
      end,
      stop = function() end,
    }
  end,
}
local function handle(message)
  handlers.on_message(message)
end

local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local selvage = require('selvage')
vim.g.selvage_display_name = 'Test User'

--- The notice, if any, a command added since `from`.
local function said_since(from, needle)
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      return notices[index].message
    end
  end
  return nil
end

--- The content a file holds, which is the only thing a tool that reads the mirror sees.
local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return table.concat(lines, '\n') .. (#lines > 0 and '\n' or '')
end

--- A process id nothing is using: a mirror a session that crashed left behind is pruned by the
--- process that owned it, so a test has to be able to name a dead one.
local function dead_pid()
  for pid = 1000000, 1100000 do
    local _, err = uv.kill(pid, 0)
    if err ~= nil and err:match('^ESRCH') ~= nil then
      return pid
    end
  end
  return nil
end

--- Joins a room: the status, then the reports a real companion sends as a session starts, in the
--- order it sends them — the listing first, because a document's buffer is named after the file
--- the listing was materialised at.
local function join(documents, paths, room)
  selvage.leave()
  selvage.join('ws://127.0.0.1:1/session?room=r-mirror&token=t')
  handle({
    type = 'status',
    state = 'joined',
    role = 'guest',
    roomId = room or 'r-mirror',
  })
  handle({ type = 'report', report = { kind = 'grant', paths = paths } })
  handle({ type = 'report', report = { kind = 'documents', documents = documents } })
  handle({ type = 'report', report = { kind = 'peers', peers = {} } })
  return selvage.session().mirror
end

--- The document version the front-end counts for a path: one per local change it reported since
--- `from`, one per remote edit this stub applied. An `applyEdit` is computed against it, and a
--- range for a version the front-end has left is refused — `sent` holds every session this file
--- ran, so the changes are counted from where the document was opened.
---
--- @param path string
--- @param applied integer
--- @param from integer the index in `sent` the document was opened at
--- @return integer
local function version_of(path, applied, from)
  local version = applied
  for index = from + 1, #sent do
    local message = sent[index]
    if message.type == 'change' and message.path == path then
      version = version + 1
    end
  end
  return version
end

--- The room's text for a path, as the edit the bridge would compute against what the buffer
--- holds: the whole document replaced, which is the one range that does not care what is there,
--- followed by the save a document the room changed is written by.
local function room_text(path, text, version)
  local body = text:gsub('\n$', '')
  handle({
    type = 'applyEdit',
    id = message_id(),
    path = path,
    start = 0,
    ['end'] = #body + 1,
    text = body,
    version = version,
  })
  handle({ type = 'save', id = message_id(), path = path })
end

--- A companion that answers every hold with the room's text for that path, the way a real one
--- does: the text as an `applyEdit`, then the `save` that follows a document the room changed.
--- Each open is answered against the version the document has at that moment.
local function room_holding(texts)
  local opened = {}
  return function(message)
    if message.type ~= 'open' then
      return
    end
    local text = texts[message.path]
    if text == nil then
      return
    end
    opened[message.path] = opened[message.path] or { from = #sent, applied = 0 }
    local entry = opened[message.path]
    room_text(message.path, text, version_of(message.path, entry.applied, entry.from))
    entry.applied = entry.applied + 1
  end
end

--- The message, if any, of a kind this session sent.
local function sent_of(kind)
  for _, message in ipairs(sent) do
    if message.type == kind then
      return message
    end
  end
  return nil
end

--- The buffer holding a mirror file, or -1.
local function buffer_of(name)
  return vim.fn.bufnr(name)
end

--- The text a buffer holds, as the room counts it.
local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n') .. '\n'
end

local GRANT = { 'README.md', 'notes/deep.txt', 'src/main.rs', 'src/util.rs' }

-- -- where the mirror lives, and how long for -------------------------------------------
--
-- Not a temporary directory and not inside the person's project: this host's `/tmp` is a
-- RAM-backed tmpfs, and a directory inside the project is one a tree plugin would show the
-- person's own files beside. `stdpath('cache')/selvage/<room>/` names the room, and the session
-- inside it is named for the process that owns it.

check('no session, no mirror', selvage.session().mirror, nil)

local root = join({}, GRANT)
check('a guest joining a room that lists files has a mirror', type(root) == 'string', true)
check('  under stdpath(cache)', root:sub(1, #CACHE + 1), CACHE .. '/')
check('  named for the room', root:find('/r-mirror/', 1, true) ~= nil, true)
check('  and it is a directory', vim.fn.isdirectory(root), 1)
check('  outside the working directory the person is in', root:sub(1, #vim.fn.getcwd() + 1) == vim.fn.getcwd() .. '/', false)
check('  and `session()` reports it, because nothing else tells a person where the room is', selvage.session().mirror, root)

selvage.leave()
check('a session that ends removes its mirror', vim.fn.isdirectory(root), 0)
check('  and reports none', selvage.session().mirror, nil)

-- A host has nothing to mirror: the room's files are its own working copy.
selvage.host('ws://127.0.0.1:1')
handle({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-mirror' })
handle({ type = 'report', report = { kind = 'grant', paths = GRANT } })
check('a host materialises nothing: the files are already on its disk', selvage.session().mirror, nil)

-- -- a mirror a crashed session left behind ----------------------------------------------
--
-- The directory is named for the process that owns it, so a session can tell a mirror nobody is
-- using from one a second Neovim in the same room is working in. The stale one goes; the live
-- one stays, because it is not this session's to delete.

local room_dir = CACHE .. '/r-pruned'
local dead = dead_pid()
check('the test can name a process id nothing is using', type(dead), 'number')
local stale = room_dir .. '/' .. dead .. '-stale'
vim.fn.mkdir(stale, 'p')
vim.fn.writefile({ 'left behind' }, stale .. '/x.txt')
local live = room_dir .. '/' .. uv.os_getpid() .. '-other'
vim.fn.mkdir(live, 'p')

join({}, GRANT, 'r-pruned')
check('a mirror a crashed session left behind is gone', vim.fn.isdirectory(stale), 0)
check('  and one a live process owns is left alone', vim.fn.isdirectory(live), 1)
selvage.leave()
vim.fs.rm(room_dir, { recursive = true, force = true })

-- -- the shape the listing is materialised as --------------------------------------------
--
-- Every listed path exists, with the directories on the way to it, so that a tree plugin, `fd`,
-- `rg --files` and `:find` walk the whole project rather than what happens to be open. A path
-- whose content has not been fetched is there and empty.

root = join({}, GRANT)
for _, path in ipairs(GRANT) do
  check(('the listing materialises %s'):format(path), vim.fn.filereadable(root .. '/' .. path), 1)
  check(('  and %s is empty until something fetches it'):format(path), read(root .. '/' .. path), '')
end
check('  and the directory above a nested path exists', vim.fn.isdirectory(root .. '/notes'), 1)

-- A path that is already on disk is not clobbered: the room's content is fetched into it, and a
-- listing the room publishes again is not a fetch.
vim.fn.writefile({ 'a tool was here' }, root .. '/README.md')
before = #notices
handle({ type = 'report', report = { kind = 'grant', paths = GRANT } })
check('a path that already exists is left as it is', read(root .. '/README.md'), 'a tool was here\n')
check('  and republishing the listing says nothing about it', #notices, before)

-- A name that would leave the root is refused rather than written: the listing comes from a
-- peer, and `..` in it would put a file outside the mirror, where the person keeps their work.
before = #notices
join({}, { '../escaped.txt', 'notes/deep.txt' })
root = selvage.session().mirror
check('a listed path that leaves the mirror is not materialised', vim.fn.filereadable(root .. '/../escaped.txt'), 0)
check('  and the paths beside it are', vim.fn.filereadable(root .. '/notes/deep.txt'), 1)
check('  and the person is told which one was not', said_since(before, 'could not be mirrored, starting with ../escaped.txt') ~= nil, true)

-- -- which buffer a room path is opened in -----------------------------------------------
--
-- A listed path's buffer *is* the mirror's file: a language server, ctags and ripgrep then see
-- the file the person is editing. A document the room holds that its listing does not name has
-- no file to be, and keeps the `selvage://` buffer it had before the mirror.

root = join({}, GRANT)
selvage.open('notes/deep.txt')
check("a listed path's buffer is the mirror's file", vim.fn.bufname('%'), root .. '/notes/deep.txt')
check('  and that is a real file on disk', vim.fn.filereadable(vim.fn.bufname('%')), 1)
check('  opened by the room path as a suffix', selvage.documents()[1], 'notes/deep.txt')
selvage.leave()

join({ 'held-but-not-listed.txt' }, GRANT)
check(
  'a document the listing does not name keeps a selvage:// buffer',
  vim.fn.bufname('%'),
  'selvage://held-but-not-listed.txt'
)
check(
  '  and it has no file in the mirror',
  read(selvage.session().mirror .. '/held-but-not-listed.txt'),
  nil
)

-- -- a listing that arrives after the room named a document -------------------------------
--
-- The room's open-document set and its grant are two messages, and the grant is restated in a
-- `doc.granted` straight after `room.joined`: a guest usually hears which documents the room
-- holds before it hears what the room grants, and the buffers it made in that window become the
-- files the listing names for them. The text is carried over, because re-pointing a document is
-- not a document that starts over, and the file is given what this client holds for the room.
local unlisted = join({ 'notes/deep.txt' }, {}, 'r-late')
check('a document opened before the listing is a selvage:// buffer', vim.fn.bufname('%'), 'selvage://notes/deep.txt')
check('  and there is no mirror to put it in yet', unlisted, nil)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'typed before the listing' })

root = selvage.session().mirror
handle({ type = 'report', report = { kind = 'grant', paths = GRANT } })
root = selvage.session().mirror
local late = vim.api.nvim_get_current_buf()
check("a listing that names it opens it as the mirror's file", vim.api.nvim_buf_get_name(late), root .. '/notes/deep.txt')
check('  and that file is on disk', vim.fn.filereadable(root .. '/notes/deep.txt'), 1)
check('  and the buffer it replaced is gone', vim.fn.bufnr('selvage://notes/deep.txt'), -1)
check('  and the document is still held', table.concat(selvage.documents(), ','), 'notes/deep.txt')
check('  and what the buffer held is still there', buffer_text(late), 'typed before the listing\n')
check('  and the file holds it, because this client holds it for the room', read(root .. '/notes/deep.txt'), 'typed before the listing\n')

-- -- content reaches the file ------------------------------------------------------------
--
-- A document the room changed is written by the save policy that already exists: the companion
-- asks for a save once the room has settled, and for a mirrored document that save is what puts
-- the room's text on disk — which is what makes it fetched for anything reading the filesystem.

root = join({}, GRANT)
selvage.open('notes/deep.txt')
local buf = vim.api.nvim_get_current_buf()
check('the placeholder opened empty', buffer_text(buf), '\n')

handle({
  type = 'applyEdit',
  id = message_id(),
  path = 'notes/deep.txt',
  start = 0,
  ['end'] = 1,
  text = 'the room wrote this',
  version = 0,
})
check("the room's text lands in the buffer", buffer_text(buf), 'the room wrote this\n')
check('  and nothing is on disk yet', read(root .. '/notes/deep.txt'), '')

handle({ type = 'save', id = message_id(), path = 'notes/deep.txt' })
check('the save the room settles on writes it into the mirror', read(root .. '/notes/deep.txt'), 'the room wrote this\n')
check('  and it answers the companion', sent[#sent].type, 'saved')
check('  and the buffer is not left modified', vim.bo[buf].modified, false)

-- The placeholder is not a source of truth: a file a tool wrote into the mirror is read back into
-- the buffer like any file, and the room's copy is what replaces it — which is what the mirror
-- trades for native tooling (`DESIGN.md` §4.2).
selvage.leave()
root = join({}, GRANT)
vim.fn.writefile({ 'a tool wrote this' }, root .. '/notes/deep.txt')
selvage.open('notes/deep.txt')
buf = vim.api.nvim_get_current_buf()
check('a file a tool overwrote is read back into the buffer', buffer_text(buf), 'a tool wrote this\n')
handle({
  type = 'applyEdit',
  id = message_id(),
  path = 'notes/deep.txt',
  start = 0,
  ['end'] = #'a tool wrote this' + 1,
  text = 'the room wrote this',
  version = 0,
})
handle({ type = 'save', id = message_id(), path = 'notes/deep.txt' })
check("  and the room's copy is what the file holds", read(root .. '/notes/deep.txt'), 'the room wrote this\n')

-- -- a save in the mirror ----------------------------------------------------------------
--
-- The editor's own write never lands in the mirror: `:w` is routed, and the file is given what
-- this client holds for the room — so a buffer that has drifted from the room cannot put its
-- own text into the cache that ripgrep, ctags and a language server read.

local probe = vim.api.nvim_create_augroup('SelvageMirrorProbe', { clear = true })
local editor_wrote = false
vim.api.nvim_create_autocmd('BufWritePre', {
  group = probe,
  pattern = root .. '/*',
  callback = function()
    editor_wrote = true
  end,
})

local before = #notices
vim.api.nvim_buf_set_lines(buf, -1, -1, true, { 'and the person typed this' })
vim.cmd('write')
check("a save in the mirror is not the editor's write path", editor_wrote, false)
check('  and the file holds what the client holds for the room', read(root .. '/notes/deep.txt'), 'the room wrote this\nand the person typed this\n')
check('  and the buffer is saved', vim.bo[buf].modified, false)
check('  and nobody was told anything was wrong', #notices, before)
vim.api.nvim_del_augroup_by_id(probe)

-- -- what the room knows nothing about ----------------------------------------------------
--
-- A tool that creates a file in the mirror made a file on this disk and nothing else. It is not
-- shared, the person is told, and a save into it is refused rather than written into a directory
-- the session deletes — which is the honest failure mode of a real directory.

local stray = root .. '/stray.txt'
vim.fn.writefile({ 'mine' }, stray)
before = #notices
vim.cmd('edit ' .. vim.fn.fnameescape(stray))
check(
  'a file in the mirror the room does not list is not shared',
  said_since(before, 'stray.txt is not in the room, so it is not shared') ~= nil,
  true
)
before = #notices
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
vim.cmd('write')
check('  and a save into it is refused rather than written', read(stray), 'mine\n')
check('  and the person is told why', said_since(before, 'save it outside the mirror to keep it') ~= nil, true)
check('  and the buffer is left with the edit, unsaved', vim.bo.modified, true)
check('  and the room was never told about it', selvage.text('stray.txt'), nil)

-- -- what a host does with all of this ----------------------------------------------------
--
-- A host's files are its own working copy; it has no mirror and no fetch, and the commands say
-- which of the two it is talking about.

selvage.leave()
selvage.host('ws://127.0.0.1:1')
handle({ type = 'status', state = 'hosting', role = 'host', roomId = 'r-mirror' })
handle({ type = 'report', report = { kind = 'grant', paths = GRANT } })
check('  and no mirror to put it in', selvage.session().mirror, nil)
selvage.leave()

check('every mirror this file started was removed', vim.fn.isdirectory(CACHE .. '/r-mirror'), 0)
check('  and the room directory with it', vim.fn.isdirectory(CACHE .. '/r-pruned'), 0)

vim.notify = notify
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
