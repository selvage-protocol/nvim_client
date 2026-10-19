-- Materialising the room's files, for a guest.
--
-- The mirror holds the room's shape; a file's content arrives only when something asks for it, and
-- a fetch is that ask made wide. `:SelvageFetch` names a file or a directory and this holds them
-- all, bounded by how many paths one session will keep open at once (`MAX_FETCH_ALL_PATHS`, the
-- same number the other client refuses at) and by a deadline that says what had not arrived.
local uv = vim.uv or vim.loop

local mirror = require('selvage.mirror')
local notify = require('selvage.notify').notify
local notify_words = require('selvage.notify').notify_words
local seconds = require('selvage.notify').seconds
local guest_buffer = require('selvage.share').guest_buffer
local resolve = require('selvage.share').resolve
local share = require('selvage.share').share
local in_session = require('selvage.state').in_session
local state = require('selvage.state').state

local M = {}

--- How many unarrived paths a fetch that ran out of time names.
local FETCH_NAMES = 3

--- How long a fetch waits, in total, for the room's content to arrive.
---
--- The room has to answer every hold and send every document it holds, and a fetch of a whole
--- project is a lot of both: this bounds silence rather than work, and it is given room to scale
--- with how much was asked for. A fetch that reaches it says what it got rather than failing,
--- because content that is late is still content. `vim.g.selvage_fetch_timeout_ms` sets it for a
--- run that knows better than the default.
---
--- @param count integer how many paths the fetch names
--- @return integer milliseconds
local function fetch_timeout_ms(count)
  local configured = tonumber(vim.g.selvage_fetch_timeout_ms)
  if configured ~= nil and configured > 0 then
    return configured
  end
  return math.min(60000, 5000 + 500 * count)
end

--- The room paths a fetch's argument names — the whole listing, one path of it, or a directory of
--- it — and the subset of them this mirror has a file for. Nil targets and the paths it matched
--- when the words name nothing the room lists.
---
--- The count is what the cap is applied to, and it is the room's listing rather than the mirror's
--- subset: a listed path the mirror refused — one no host would publish, or one past this client's
--- own bounds — is a path the room still names, and VS Code counts the same set (`listed()`,
--- `extension.ts`), so the two clients refuse at the same point. A path with nowhere to be written
--- is left out of the hold, so a fetch never waits out its time on one, and the caller names it
--- back in the words the other client refuses one with (`M.fetch`).
---
--- The argument is read against the *listing* rather than against everything the room offers: a
--- document the room holds and its listing does not name has no file in the mirror, so there is
--- nothing to fetch for it.
---
--- @param wanted string
--- @return string[]|nil targets, string[] named, string[]|nil candidates
local function fetch_targets(wanted)
  local listed = {}
  for _, path in ipairs(state.grant) do
    listed[path] = true
  end
  local named = {}
  local candidates = nil
  if wanted == '' then
    named = state.grant
  else
    local prefix = wanted .. '/'
    for _, path in ipairs(state.grant) do
      if path == wanted then
        named = { path }
        break
      end
      if path:sub(1, #prefix) == prefix then
        named[#named + 1] = path
      end
    end
    if #named == 0 then
      -- A word that names no listed path is resolved the way `:SelvageOpen` resolves one: an exact
      -- name, or the one suffix at a directory boundary. `resolve` searches everything the room
      -- offers, so a hit has to be a path the listing names as well: a document the room holds
      -- open and its listing does not name is not a file a fetch has anywhere to write.
      local resolved, matches = resolve(wanted)
      candidates = matches
      if resolved ~= nil and listed[resolved] then
        named = { resolved }
      end
    end
    if #named == 0 then
      -- The listing reaches nothing this argument names, which is the only state the no-match
      -- refusal at the caller is true in.
      return nil, named, candidates
    end
  end
  local targets = {}
  for _, path in ipairs(named) do
    if mirror.granted(path) then
      targets[#targets + 1] = path
    end
  end
  return targets, named, nil
end

--- The paths of `pending` whose content the mirror does not hold yet, dropping the ones it does.
---
--- Fetched is the file, not a message: a path counts once the room's content has been written into
--- it, which is what a save does and what a fetch waits for. An empty file is not evidence of
--- anything, because an empty placeholder and an empty room document look exactly alike — so a
--- path this client holds but whose room's text never arrived is reported as not arrived, rather
--- than read back off disk as an answer.
---
--- @param pending table<string, boolean>
--- @return string[] unfetched
local function unfetched(pending)
  local left = {}
  for path in pairs(pending) do
    if mirror.written(path) then
      pending[path] = nil
    else
      left[#left + 1] = path
    end
  end
  return left
end

--- The most paths one fetch holds at once. Every held path is a `doc.open` every peer absorbs and
--- a `Y.Text` every replica keeps, so a whole listing — or one directory of it — past this refuses
--- with a sentence naming a narrower target instead of holding the room sequentially, each path up
--- to `fetch_timeout_ms`. The twin of VS Code's `MAX_FETCH_ALL_PATHS`: the same number, the same
--- words and the same base, the room's listing — every path it names, and not the subset this
--- mirror kept — so the two clients refuse at the same point.
local MAX_FETCH_ALL_PATHS = 100

--- Fetches the room's content into the mirror: one file, a directory of them, or all of it.
---
--- A file's content arrives the way any shared document's does — the path is held in the room, the
--- host reads its working copy when the room asks, and the text comes back — so a fetch takes a
--- hold on what it names and opens it as a buffer without putting it in front of the user. What
--- writes the file is the same save that follows a document the room changed, which is why the
--- wait is for the file and not for a message: content is fetched when it is on disk and not
--- before, and a search over the mirror sees exactly that.
---
--- The command returns while the room answers: the completion is a later notice, said when
--- the files are on disk or when the wait runs out, so a slow room never holds the editor.
---
--- A path the room's listing names and this mirror kept no file for has nowhere for the room's text
--- to land, so it is refused on its own, in the words the other client refuses one with
--- (`fetchFromRoom`, `extension.ts`). The listing named it, so that refusal is not
--- `no file the room lists matches`, which is for an argument the listing does not reach at all.
---
--- @param path string|nil one path, a directory of them, or nil for the whole listing
function M.fetch(path)
  if not in_session() then
    notify('join a session first.', vim.log.levels.WARN)
    return
  end
  if state.role == 'host' then
    notify('your files are already on your disk, so there is nothing to fetch while you host.', vim.log.levels.INFO)
    return
  end
  -- What a fetch answers about is the listing, and the listing is not the mirror: a room that
  -- names a path this mirror wrote no file for lists files, and the refusal below says so.
  if #state.grant == 0 then
    notify('the room lists no files to fetch.', vim.log.levels.INFO)
    return
  end
  local wanted = vim.trim(path or '')
  local targets, named, candidates = fetch_targets(wanted)
  -- A hold of every path the room names would put the whole listing — or one directory of it —
  -- into every replica at once, so past the cap the fetch refuses rather than truncates: it names a
  -- narrower target, and the room keeps its open-document set. The count is the room's listing and
  -- not the subset this mirror kept, so the two clients refuse at the same point; what is held once
  -- the cap passes is the subset with a file to be written. The whole listing and a directory are
  -- told apart, because the next step differs.
  if #named > MAX_FETCH_ALL_PATHS then
    if wanted == '' then
      notify(
        ('fetching all %d listed files at once would hold every one in the room; fetch a file or a directory instead (at most %d at once).'):format(
          #named,
          MAX_FETCH_ALL_PATHS
        ),
        vim.log.levels.ERROR
      )
    else
      notify(
        ('%d files under %s is more than one fetch holds (at most %d at once); name a narrower directory.'):format(
          #named,
          wanted,
          MAX_FETCH_ALL_PATHS
        ),
        vim.log.levels.ERROR
      )
    end
    return
  end
  if targets == nil then
    if candidates ~= nil and #candidates > 1 then
      notify(
        ('"%s" matches several: %s.'):format(wanted, table.concat(candidates, ', ')),
        vim.log.levels.WARN
      )
    else
      notify(
        ('no file the room lists matches "%s"; :SelvageOpen and completion name them.'):format(wanted),
        vim.log.levels.WARN
      )
    end
    return
  end
  local pending = {}
  local opening = 0
  for _, target in ipairs(targets) do
    if state.documents[target] == nil then
      opening = opening + 1
    end
  end
  if opening > 0 then
    -- A fetch is a hold: every path it takes joins the room's open-document set, so every peer
    -- receives it and, with a mirror, materialises it. Said before it happens, because a fetch of
    -- a whole listing is a whole project published and the sentence after it is too late to be a
    -- choice (`DESIGN.md` §4.2). A single path names itself; the plural is for the listing.
    if #targets == 1 then
      notify_words('download', 'one', nil, targets[1])
    else
      notify_words('download', 'many')
    end
  end
  -- A listed path this mirror has no file for: there is nowhere for the room's text to arrive, so
  -- it is named back rather than held, and the file-bound completion below is never waited out on
  -- it. Said once per path, and past the cap the whole request is already refused.
  local refused = 0
  for _, name in ipairs(named) do
    if not mirror.granted(name) then
      refused = refused + 1
      notify(
        ('could not fetch %s from the room: the file could not be mirrored.'):format(name),
        vim.log.levels.ERROR
      )
    end
  end
  if #targets == 0 then
    return
  end
  for _, target in ipairs(targets) do
    pending[target] = true
    local document = state.documents[target]
    if document == nil then
      share(guest_buffer(target), target)
    elseif not mirror.holds(target, document:text()) then
      -- A document this session already holds: the file is given what this client holds for the
      -- room, so that fetching a path whose file a tool overwrote is a fetch and not a no-op.
      -- The file is given what this client holds for the room, which is the room's text to
      -- the fetch's own accounting: writing it counts as fetched.
      document:save(true)
    end
  end
  -- The wait is a deferred re-check, not a foreground one: a fetch of a whole project holds
  -- the editor for up to a minute if the room is slow, and the command should return while
  -- the room answers. What is already held is said at once; the rest is said when it arrives
  -- or when the wait runs out.
  local timeout = fetch_timeout_ms(#targets)
  local generation = state.generation
  local deadline = uv.hrtime() + timeout * 1000000
  local function revisit()
    -- A fetch a later session outlived is that session's silence: the room it asked is gone,
    -- and its deadline must not speak into the one that replaced it. A session that ended
    -- with nothing after it still ends the wait the same way the foreground one did.
    if state.generation ~= generation and in_session() then
      return
    end
    if not in_session() then
      notify('the session ended before the files were fetched.', vim.log.levels.WARN)
      return
    end
    local left = unfetched(pending)
    if #left == 0 then
      -- The files this fetch could hold are on disk. A path it refused above is not one of them,
      -- and the other client says nothing here either, so the success is not claimed over it.
      if refused == 0 then
        notify('fetched the files.')
      end
      return
    end
    if uv.hrtime() >= deadline then
      if #targets == 1 then
        -- The one file asked for is the whole fetch, so nothing was fetched.
        notify(('%s did not arrive within %ds.'):format(left[1], seconds(timeout)), vim.log.levels.WARN)
      elseif #left == 1 then
        notify(
          ('fetched the files; %s had not arrived within %ds.'):format(left[1], seconds(timeout)),
          vim.log.levels.WARN
        )
      else
        notify(
          ('fetched the files; these had not arrived within %ds: %s.'):format(
            seconds(timeout),
            table.concat(vim.list_slice(left, 1, math.min(#left, FETCH_NAMES)), ', ')
          ),
          vim.log.levels.WARN
        )
      end
      return
    end
    vim.defer_fn(revisit, 50)
  end
  revisit()
end

-- -- going to a participant, and following one ------------------------------------
--
-- `:SelvageGoTo` lands where a participant is; `:SelvageFollow` keeps landing there as
-- they move, until something ends it. The landing moves the follower's caret: Neovim has
-- no durable viewport-only state — the next redraw pulls the viewport back over the
-- cursor — so following is being where they are, not watching from elsewhere. What
-- follows from that is the break rule: a local edit of a shared document ends the follow,
-- because the next keystroke lands where the caret is.



return M
