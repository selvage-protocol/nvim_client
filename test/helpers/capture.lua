-- Test-only observability for the Lua suite's scratch artifacts.
--
-- The Nix sandbox deletes the writable work copy when the check returns, so a file a Lua test
-- writes under `.tmp/` is gone before anything can read it. These calls run immediately before
-- a test destroys such a path, and once more before `os.exit`, and write what was there to
-- stderr as one bounded JSON line per frame. The flake forwards that stderr into the build log,
-- so the bytes outlive the sandbox, while the derivation's `$out` stays one stable line.
--
-- The stream is a set of frames. Each captured path emits a header (`h`), one data frame (`d`)
-- per 2 KiB chunk for a regular file, and a footer (`f`) whose `sha256` is over the
-- concatenated base64 text rather than the raw bytes, so a digest is always over ASCII.
-- `finish` emits a census (`c`) whose `sha256` covers every earlier frame body; that is what
-- lets a decoder tell a truncated, missing, duplicated or edited stream from an intact one.
-- Every call is cooperative: nothing here installs an autocmd or intercepts a delete.
--
-- This is test-only. It is not required by `lua/selvage/`, it is never on the plugin's runtime
-- path, and only `test/lua/*.lua` load it.

local M = {}

local MARK = 'SELVAGE-CAPTURE '
local CHUNK = 2048
local LINE_MAX = 4096
local MAX_BYTES = 4 * 1024 * 1024
local MAX_ENTRIES = 8192
local MAX_DEPTH = 16

local invocation = nil
local index = 0
local total_frames = 0
local total_bytes = 0
local bodies = {}
local failed = nil

local function raw_writer(line)
  local written, write_err = io.stderr:write(line)
  if not written then
    error('stderr write: ' .. tostring(write_err), 0)
  end
  local flushed, flush_err = io.stderr:flush()
  if not flushed then
    error('stderr flush: ' .. tostring(flush_err), 0)
  end
  return true
end
local writer = raw_writer

--- Point the frames at another sink. The decoder test drives the producer in-process; the
--- suite leaves this alone and the frames go to the process's own stderr.
function M.set_writer(fn)
  writer = fn or raw_writer
end

local function quote(value)
  local escaped = tostring(value):gsub('[%c"\\]', function(byte)
    if byte == '"' then
      return '\\"'
    end
    if byte == '\\' then
      return '\\\\'
    end
    return ('\\u%04x'):format(string.byte(byte))
  end)
  return '"' .. escaped .. '"'
end

local function bump(site, path, message)
  local text = ('site=%s path=%s: %s'):format(tostring(site), tostring(path), tostring(message))
  if failed == nil then
    failed = text
  end
end

local function write_line(body)
  local ok, result, err = pcall(writer, MARK .. body .. '\n')
  if not ok then
    bump('writer', 'stderr', result)
  elseif not result then
    bump('writer', 'stderr', err or 'no write acknowledgement')
  end
end

local function emit(body)
  if #MARK + #body + 1 > LINE_MAX then
    error('frame over the line bound')
  end
  total_frames = total_frames + 1
  bodies[#bodies + 1] = body
  write_line(body)
end

local function absolute(path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return vim.fn.getcwd() .. '/' .. path
end

local function mode_of(stat)
  if stat.mode == nil then
    return nil
  end
  if type(stat.mode) == 'number' then
    return ('%o'):format(stat.mode)
  end
  return tostring(stat.mode)
end

local function header(site, path, kind, mode, size, target, chunks)
  local parts = {
    '{"k":"h"',
    ',"inv":' .. quote(invocation or ''),
    ',"site":' .. quote(site),
    ',"i":' .. index,
    ',"p":' .. quote(vim.base64.encode(path)),
    ',"t":' .. quote(kind),
  }
  if mode ~= nil then
    parts[#parts + 1] = ',"m":' .. quote(mode)
  end
  if size ~= nil then
    parts[#parts + 1] = ',"s":' .. tostring(size)
  end
  if target ~= nil then
    parts[#parts + 1] = ',"l":' .. quote(vim.base64.encode(target))
  end
  parts[#parts + 1] = ',"n":' .. tostring(chunks) .. '}'
  return table.concat(parts)
end

local function data_frame(chunk_index, encoded)
  return '{"k":"d","i":' .. index .. ',"j":' .. chunk_index .. ',"b":' .. quote(encoded) .. '}'
end

local function footer(chunks, bytes, encoded_all)
  return '{"k":"f","i":' .. index
    .. ',"n":' .. tostring(chunks)
    .. ',"bytes":' .. tostring(bytes)
    .. ',"sha256":' .. quote(vim.fn.sha256(encoded_all)) .. '}'
end

local function record(site, path, kind, mode, size, target)
  index = index + 1
  if kind ~= 'file' then
    emit(header(site, path, kind, mode, size, target, 0))
    emit(footer(0, 0, ''))
    return
  end
  local file = io.open(path, 'rb')
  if file == nil then
    error('cannot open for read')
  end
  local bytes, read_err = file:read('*a')
  local closed, close_err = file:close()
  if bytes == nil then
    error('read: ' .. tostring(read_err))
  end
  if closed == nil then
    error('close: ' .. tostring(close_err))
  end
  if #bytes > MAX_BYTES then
    error('over the per-file byte bound')
  end
  local chunks = {}
  for offset = 1, #bytes, CHUNK do
    chunks[#chunks + 1] = vim.base64.encode(bytes:sub(offset, offset + CHUNK - 1))
  end
  emit(header(site, path, 'file', mode, #bytes, nil, #chunks))
  for at, encoded in ipairs(chunks) do
    emit(data_frame(at, encoded))
  end
  emit(footer(#chunks, #bytes, table.concat(chunks)))
  total_bytes = total_bytes + #bytes
end

local function walk(site, root, state)
  local handle = vim.uv.fs_scandir(root)
  if handle == nil then
    error('cannot list directory')
  end
  local names = {}
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if name == nil then
      break
    end
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    state.entries = state.entries + 1
    if state.entries > MAX_ENTRIES then
      error('over the per-capture entry bound')
    end
    local child = root .. '/' .. name
    local stat, err = vim.uv.fs_lstat(child)
    if stat == nil then
      error('lstat: ' .. tostring(err))
    end
    if stat.type == 'directory' then
      record(site, child, 'dir', mode_of(stat), stat.size, nil)
      if state.depth >= MAX_DEPTH then
        error('over the walk depth bound')
      end
      state.depth = state.depth + 1
      walk(site, child, state)
      state.depth = state.depth - 1
    elseif stat.type == 'link' then
      local target, err = vim.uv.fs_readlink(child)
      if target == nil then
        error('readlink: ' .. tostring(err))
      end
      record(site, child, 'link', mode_of(stat), stat.size, target)
    elseif stat.type == 'file' then
      record(site, child, 'file', mode_of(stat), stat.size, nil)
    else
      error('unsupported type: ' .. tostring(stat.type))
    end
  end
end

local function capture_one(site, path)
  local stat, err, errname = vim.uv.fs_lstat(path)
  if stat == nil then
    local code = errname or tostring(err or '')
    if code:match('ENOENT') == nil then
      error('lstat: ' .. tostring(err or code))
    end
    record(site, path, 'absent', nil, nil, nil)
    return
  end
  if stat.type == 'file' then
    record(site, path, 'file', mode_of(stat), stat.size, nil)
  elseif stat.type == 'directory' then
    record(site, path, 'dir', mode_of(stat), stat.size, nil)
    walk(site, path, { entries = 0, depth = 0 })
  elseif stat.type == 'link' then
    local target, link_err = vim.uv.fs_readlink(path)
    if target == nil then
      error('readlink: ' .. tostring(link_err))
    end
    record(site, path, 'link', mode_of(stat), stat.size, target)
  else
    error('unsupported type: ' .. tostring(stat.type))
  end
end

--- Name the invocation now beginning. Every frame this process emits carries it, and `finish`
--- closes the invocation with a census over them.
function M.begin(name)
  invocation = tostring(name)
  index = 0
  total_frames = 0
  total_bytes = 0
  bodies = {}
  failed = nil
  emit('{"k":"b","inv":' .. quote(invocation) .. '}')
end

--- Record one owned path's state. An absent path is a record, not a miss, and a link is read
--- with `readlink` alone: the target is never followed, so a link out of the folder is retained
--- as a link. A failure is remembered and `finish` then fails the run, after the test's own
--- cleanup has run.
function M.capture(site, path)
  local target = absolute(path)
  local ok, err = pcall(capture_one, tostring(site), target)
  if not ok then
    bump(site, target, err)
  end
end

--- Census the invocation: its capture count, frame count, byte total and the digest over every
--- frame body in order. An invocation that recorded no path is a failure too: a stream that names
--- a run but says nothing about it cannot be told from a truncated one, so it is never green.
--- Raises after writing the census when any capture failed, so a read that could not be made is
--- never silently green and the test's cleanup has still run.
function M.finish()
  if index == 0 then
    bump('finish', 'records', 'no captured records')
  end
  local digest_input = table.concat(bodies, '\n')
  if #bodies > 0 then
    digest_input = digest_input .. '\n'
  end
  local body = '{"k":"c","inv":' .. quote(invocation or '')
    .. ',"caps":' .. tostring(index)
    .. ',"frames":' .. tostring(total_frames)
    .. ',"bytes":' .. tostring(total_bytes)
    .. ',"sha256":' .. quote(vim.fn.sha256(digest_input))
    .. ',"ok":' .. tostring(failed == nil) .. '}'
  write_line(body)
  if failed ~= nil then
    error('capture failed: ' .. failed, 0)
  end
end

return M
