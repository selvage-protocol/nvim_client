-- The guest's mirror of the room: the grant's shape as a real directory (`DESIGN.md` §4.2).
--
-- An editor's own extensions are separate processes. A language server, ripgrep, ctags, `fd` and a
-- tree plugin read the filesystem and cannot see a virtual path, so a guest materialises the
-- room's *shape* into a real directory and fetches a file's *content* only when something needs
-- it. The directory is a cache of the room and never a source of truth: nothing in it is written
-- back by itself, and the session that made it removes it.
--
-- Where it lives is deliberate. Not a temporary directory — this host's `/tmp` is a RAM-backed
-- tmpfs and building there has taken a machine down — and never inside the person's project, so
-- that nothing a tree plugin walks is ever this client's. `stdpath('cache')/selvage/<room>/` names
-- the room, and one directory inside it belongs to each session that mirrors it: named for the
-- process that owns it, so a directory a crashed session left behind is pruned by the next one
-- rather than mistaken for a live mirror, and a second Neovim in the same room keeps its own.
--
-- What this module does not do is decide anything about the room: it is handed a listing and a
-- path, and it turns them into files. What a buffer is named, when a document is fetched and what
-- a save means are the front-end's (`init.lua`).

local uv = vim.uv or vim.loop

local M = {}

--- The name this client's mirrors live under, inside `stdpath('cache')`.
local BASE = 'selvage'

local state = {
  --- The directory this session materialises the room into, or nil when there is none.
  root = nil,
  --- The room this mirror belongs to, so a new session never reuses a directory.
  room = nil,
  --- The paths the room's listing named, as a set: what this client turns into a file.
  listed = {},
  --- The room paths whose file this session has written.
  written = {},
}

--- Whether a process is still running. Signal 0 delivers nothing and only asks whether the
--- process is there; `EPERM` is a process that exists and is not ours, which is still a live
--- mirror and must not be pruned.
---
--- @param pid integer
--- @return boolean
local function running(pid)
  local _, err = uv.kill(pid, 0)
  return err == nil or err:match('^EPERM') ~= nil
end

--- A room id as one path segment: the room names the directory, and a room id holding a separator
--- must not become two directories.
---
--- @param room string
--- @return string
local function segment(room)
  return (room:gsub('[^%w%-_]', '-'))
end

--- Whether a listed path is one this client will turn into a file.
---
--- The listing comes from a peer, and it is not trusted: a path that leaves the root would put a
--- file outside the mirror, where the person keeps their own work, so an absolute path, a `..`
--- segment or a backslash is refused rather than materialised.
---
--- @param path any
--- @return boolean
local function writable(path)
  if type(path) ~= 'string' or path == '' or path:sub(1, 1) == '/' or path:sub(-1) == '/' then
    return false
  end
  if path:find('\\', 1, true) ~= nil or path:find('\0', 1, true) ~= nil then
    return false
  end
  for part in path:gmatch('[^/]+') do
    if part == '.' or part == '..' then
      return false
    end
  end
  return true
end

--- Makes a directory and every one above it, answering whether it is there afterwards.
---
--- @param path string
--- @return boolean
local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  return pcall(vim.fn.mkdir, path, 'p')
end

--- The kind of a directory entry, which a scan does not have to report.
---
--- @param path string
--- @return string|nil
local function kind_of(path)
  local info = uv.fs_lstat(path)
  return info ~= nil and info.type or nil
end

--- Removes a directory and everything in it, naming every entry literally.
---
--- Not `vim.fs.rm`: it enumerates with `vim.fs.dir`, which normalises the path it is given and
--- expands a defined variable in it, and then removes by the literal name. The listing this
--- client mirrors comes from a peer, and `$HOME` is an ordinary directory name on this platform —
--- so the directory that was created and the one the removal enumerates are not the same name,
--- the removal throws, and the mirror is left on disk with nothing left to remove it. The `uv`
--- layer neither normalises nor expands, which is what makes the two ends agree.
---
--- @param path string
--- @return boolean removed, whether nothing of it is left behind
local function remove_tree(path)
  local info = uv.fs_lstat(path)
  if info == nil then
    return true
  end
  if info.type ~= 'directory' then
    -- A symlink is removed, not followed: what a listing names is not something to walk into.
    return uv.fs_unlink(path) ~= nil
  end
  local scan = uv.fs_scandir(path)
  if scan ~= nil then
    while true do
      local name = uv.fs_scandir_next(scan)
      if name == nil then
        break
      end
      remove_tree(vim.fs.joinpath(path, name))
    end
  end
  return uv.fs_rmdir(path) ~= nil
end

--- Removes the mirror directories no live process owns, so that a session that crashed does not
--- leave a directory a later session could take for the room. Only this client's own naming is
--- touched: anything else under the room's directory is left where it is.
---
--- @param dir string
local function prune(dir)
  local scan = uv.fs_scandir(dir)
  if scan == nil then
    return
  end
  while true do
    local name = uv.fs_scandir_next(scan)
    if name == nil then
      break
    end
    local pid = tonumber(name:match('^(%d+)-'))
    local entry = vim.fs.joinpath(dir, name)
    if pid ~= nil and not running(pid) and kind_of(entry) == 'directory' then
      remove_tree(entry)
    end
  end
end

--- Creates every listed path, and the directories on the way to it, as a file that is there and
--- empty: a tree plugin, `rg --files` and `:find` walk the whole project, and a path whose content
--- has not been fetched is a name with nothing behind it yet.
---
--- A path that is already on disk is left alone, whatever it holds — a file this session already
--- hydrated, or one a tool put there — because the room's content is fetched into it, not over it
--- blindly. A path that exists as something other than a file cannot be materialised; it is
--- reported rather than replaced.
---
--- @param root string
--- @param paths string[]
--- @param blocked string[]
local function materialise(root, paths, blocked)
  local made = {}
  for _, path in ipairs(paths) do
    local file = vim.fs.joinpath(root, path)
    local dir = vim.fs.dirname(file)
    if made[dir] == nil then
      made[dir] = ensure_dir(dir)
    end
    if made[dir] then
      local info = uv.fs_stat(file)
      if info == nil then
        if not pcall(vim.fn.writefile, {}, file) then
          blocked[#blocked + 1] = path
        end
      elseif info.type ~= 'file' then
        blocked[#blocked + 1] = path
      end
    else
      blocked[#blocked + 1] = path
    end
  end
end

--- Where the mirror for `room` lives, and the directory this session's own mirror sits in.
---
--- @param room string
--- @return string
local function room_dir(room)
  return vim.fs.joinpath(vim.fn.stdpath('cache'), BASE, segment(room))
end

--- The mirror directory this session is materialising the room into, or nil when there is none.
---
--- @return string|nil
function M.root()
  return state.root
end

--- The file a listed path is materialised at, or nil when this session mirrors nothing for it.
---
--- A path the room's listing does not name has no file here, whatever the room holds open: its
--- buffer stays a `selvage://` one, because a mirror that grew a file for every open document
--- would show a tree plugin files the room never listed.
---
--- @param path string
--- @return string|nil
function M.file(path)
  if state.root == nil or not state.listed[path] then
    return nil
  end
  return vim.fs.joinpath(state.root, path)
end

--- The room path an editor name addresses, when the name is inside this session's mirror. Nil for
--- anything else, including the mirror's own directory, which no room path names.
---
--- @param name string
--- @return string|nil
function M.room_path(name)
  if state.root == nil or type(name) ~= 'string' then
    return nil
  end
  local prefix = state.root .. '/'
  if name:sub(1, #prefix) ~= prefix then
    return nil
  end
  local path = name:sub(#prefix + 1)
  if path == '' or not writable(path) then
    return nil
  end
  return path
end

--- Whether the room's listing names this path, and so whether this session mirrors it.
---
--- @param path string
--- @return boolean
function M.granted(path)
  return state.listed[path] == true
end

--- The name a guest's buffer for a room path carries: the mirror's file for a listed path, and a
--- `selvage://` name for a document the room holds but its listing does not name.
---
--- @param path string
--- @return string
function M.buffer_name(path)
  return M.file(path) or ('selvage://' .. path)
end

--- Materialises the room's listing, taking a mirror directory for this session if it does not
--- have one yet.
---
--- Called on every listing the room publishes, which replaces the one before it. The first
--- meaningful listing takes the directory; a later one adds its paths to it, and never throws
--- away content that has already been fetched into it.
---
--- @param room string|nil the room id, as the status named it
--- @param paths string[] the listing, in the order the room carries it
--- @return string|nil root, string[] blocked, boolean created
function M.setup(room, paths)
  if type(room) ~= 'string' or room == '' then
    return nil, {}, false
  end
  local blocked = {}
  local wanted = {}
  for _, path in ipairs(paths or {}) do
    if writable(path) then
      wanted[#wanted + 1] = path
    else
      blocked[#blocked + 1] = tostring(path)
    end
  end
  if state.root ~= nil and state.room ~= room then
    M.teardown()
  end
  local created = false
  if state.root == nil then
    if #wanted == 0 then
      return nil, blocked, false
    end
    local dir = room_dir(room)
    if not ensure_dir(dir) then
      return nil, blocked, false
    end
    prune(dir)
    state.root = vim.fs.joinpath(dir, ('%d-%x'):format(uv.os_getpid(), uv.hrtime()))
    state.room = room
    state.written = {}
    created = true
  end
  state.listed = {}
  for _, path in ipairs(wanted) do
    state.listed[path] = true
  end
  materialise(state.root, wanted, blocked)
  return state.root, blocked, created
end

--- Removes this session's mirror. The room is the truth, so nothing in the directory is worth
--- keeping, and a directory that outlived its session is a cache a later one would have to
--- reason about. The room's own directory goes too once nothing is left in it, so that a cache
--- nobody is using does not grow one empty directory per room forever.
function M.teardown()
  local root = state.root
  local room = state.room
  state.root = nil
  state.room = nil
  state.listed = {}
  state.written = {}
  if root == nil then
    return
  end
  if not remove_tree(root) then
    -- The directory could not be emptied; say so, because a mirror nobody can remove is a cache
    -- nobody can reason about, and a silent one would look like a mirror that is still in use.
    vim.notify(
      ('selvage: could not remove the mirror at %s; leaving it for a later session to prune'):format(root),
      vim.log.levels.WARN
    )
  end
  if room ~= nil then
    -- The room's directory is not recursively removed: a second Neovim mirroring the same room
    -- owns its own directory inside it, and removing that one would delete a live session's
    -- files. Removing a directory only succeeds when it is empty, which is exactly the test.
    uv.fs_rmdir(room_dir(room))
  end
end

--- Records that this session has written a room path's file, which is what makes it fetched: the
--- content that reached the file came from the room, through a document that holds it.
---
--- @param path string
function M.wrote(path)
  if state.listed[path] then
    state.written[path] = true
  end
end

--- Whether this session has written the path's file. It is per session rather than per call: the
--- mirror directory is this session's own, so a file written at any point in it is one the room's
--- content reached.
---
--- @param path string
--- @return boolean
function M.written(path)
  return state.written[path] == true
end

--- Whether the path's file already holds `text`, read the way this client writes it: the lines of
--- a text whose final newline ends the last one.
---
--- This is what says a file is current without having to have watched it being written, so a fetch
--- of a path this session already has does not write it again. It cannot tell an empty file from
--- an empty document, which is why nothing decides a fetch's completion by it — see `unfetched`
--- in `init.lua`.
---
--- @param path string
--- @param text string
--- @return boolean
function M.holds(path, text)
  local file = M.file(path)
  if file == nil then
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then
    return false
  end
  local body = text:gsub('\n$', '')
  local wanted = body == '' and {} or vim.split(body, '\n', { plain = true })
  if #lines ~= #wanted then
    return false
  end
  for index = 1, #lines do
    if lines[index] ~= wanted[index] then
      return false
    end
  end
  return true
end

return M
