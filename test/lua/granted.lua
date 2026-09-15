-- The room's grant in the front-end: what a session offers, and what `:SelvageOpen` does with a
-- path nobody has opened yet.
--
--   nvim --headless -l test/lua/granted.lua      (or scripts/test-lua.sh)
--
-- The grant is the room's listing of the host's working tree (`DESIGN.md` §4.2, `PROTOCOL.md`
-- §5). It is a listing and never content: a path in it may have no buffer here and no text
-- behind it, and it becomes a `selvage://` buffer the moment somebody opens it — the host reads
-- its working copy when the room asks. `test/lua/grant.lua` covers the folder a session shares,
-- which is a different question: that one is where a *host's* buffers are measured against.
--
-- What is pinned here is the front-end's own half: the listing it holds, the union of that
-- listing with the documents the session holds, the completion and the chooser that offer them,
-- and the fact that a granted path with no buffer is offered without being counted as held.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime! plugin/selvage.lua')

local failures = 0

local function check(name, got, want)
  if got == want then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print(('FAIL %s\n  got  %s\n  want %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

--- Replaces the companion with one that records what it is asked to send and answers nothing, so
--- a test can say what a session offered without a process on the other end of a pipe.
local function stub_companion()
  local sent = {}
  local handlers = nil
  package.loaded['selvage.companion'] = {
    start = function(given)
      handlers = given
      return {
        send = function(_, message)
          sent[#sent + 1] = message
        end,
        stop = function() end,
      }
    end,
  }
  return sent, function()
    return handlers
  end
end

local notices = {}
local notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local sent, handlers = stub_companion()
local selvage = require('selvage')
vim.g.selvage_display_name = 'Test User'

local function listed(paths)
  return table.concat(paths, ',')
end

--- How many `open`s for `path` were sent since `from`.
local function opens_of(path, from)
  local count = 0
  for index = (from or 0) + 1, #sent do
    local message = sent[index]
    if message.type == 'open' and message.path == path then
      count = count + 1
    end
  end
  return count
end

--- The notice, if any, a command added since `from`.
local function said_since(from, needle)
  for index = from + 1, #notices do
    if notices[index].message:find(needle, 1, true) ~= nil then
      return notices[index].message
    end
  end
  return nil
end

--- What the command line offers for `:SelvageOpen`.
local function completions(lead)
  return table.concat(vim.fn.getcompletion('SelvageOpen ' .. lead, 'cmdline'), ',')
end

--- Joins a room: the status, then the reports a real companion sends as a session starts. The
--- room's documents come before the grant, which is the order the companion emits them in.
local function join(documents, paths)
  selvage.leave()
  selvage.join('ws://127.0.0.1:1/session?room=r-granted&token=t')
  handlers().on_message({
    type = 'status',
    state = 'joined',
    role = 'guest',
    roomId = 'r-granted',
  })
  handlers().on_message({ type = 'report', report = { kind = 'documents', documents = documents } })
  handlers().on_message({ type = 'report', report = { kind = 'peers', peers = {} } })
  handlers().on_message({ type = 'report', report = { kind = 'grant', paths = paths } })
end

local GRANT = { 'README.md', 'notes/deep.txt', 'src/main.rs', 'workspace/README.md' }

join({ 'README.md' }, GRANT)

-- -- the listing the room carries, and the union it is offered as --------------------
--
-- `documents()` is what this session *holds*: a buffer, a `Document`, and a path the room knows
-- it has open. The grant is a listing, so a path from it is offered long before anything is held
-- for it — and the union is what completion, the chooser and suffix matching read, because a
-- server that has no grant still has its open-document set.

check('the session holds only the document the room named', listed(selvage.documents()), 'README.md')
check(
  'what the room offers is the grant unioned with the documents',
  listed(selvage.offered()),
  'README.md,notes/deep.txt,src/main.rs,workspace/README.md'
)
check(
  'a granted path that was never opened is offered',
  listed(selvage.offered()):find('notes/deep.txt', 1, true) ~= nil,
  true
)
check(
  '  and is not one this session holds',
  listed(selvage.documents()):find('notes/deep.txt', 1, true),
  nil
)

-- -- the path completes, resolves and opens -------------------------------------------

check('completion offers a granted path', completions('sr'), 'src/main.rs')
check('  and one at a prefix of the room path', completions('notes/'), 'notes/deep.txt')
check('  and one above the room path', completions('workspace/'), 'workspace/README.md')
check('completion with nothing typed offers the whole union', completions(''), listed(selvage.offered()))
check('  with a lead nothing matches, nothing', completions('nothing-here'), '')

-- The path is opened by a *suffix* that names no held document, which is what a person types
-- when a host above `workspace/` publishes `workspace/README.md`.
local before = #sent
selvage.open('deep.txt')
check('a granted path is opened as a buffer of the room', vim.fn.bufname('%'), 'selvage://notes/deep.txt')
check('  and the room is asked for it', opens_of('notes/deep.txt', before), 1)
check('  and it is now one this session holds', listed(selvage.documents()), 'README.md,notes/deep.txt')
check(
  '  and the union does not list it twice',
  listed(selvage.offered()),
  'README.md,notes/deep.txt,src/main.rs,workspace/README.md'
)

-- Two room paths ending in the same name are the ambiguity the exact match wins over.
join({}, { 'a/x.txt', 'b/x.txt' })
before = #notices
selvage.open('x.txt')
check('a suffix that names several granted paths is refused', said_since(before, '"x.txt" matches several: a/x.txt, b/x.txt') ~= nil, true)

-- An exact room path is that path, however many others end the same way.
selvage.open('a/x.txt')
check('  and an exact path is opened all the same', vim.fn.bufname('%'), 'selvage://a/x.txt')

-- -- the chooser, and the one-document form -------------------------------------------

join({}, GRANT)
local chosen = nil
local prompt = nil
local builtin_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  chosen = items
  prompt = opts.prompt
  on_choice('notes/deep.txt')
end

selvage.open()
check('with several offered, the user is asked which', prompt, 'selvage: open which document?')
check(
  '  and every path the room offers is in the list',
  listed(chosen),
  'README.md,notes/deep.txt,src/main.rs,workspace/README.md'
)
check('  and the choice is opened', vim.fn.bufname('%'), 'selvage://notes/deep.txt')

-- One path offered is not a question: the command opens it.
join({}, { 'only.txt' })
selvage.open()
check('the only path the room offers is opened without asking', vim.fn.bufname('%'), 'selvage://only.txt')
check('  and it is held now', listed(selvage.documents()), 'only.txt')
vim.ui.select = builtin_select

-- -- the listing is replaced wholesale, and belongs to the session --------------------

selvage.leave()
join({ 'kept.txt' }, { 'kept.txt' })
before = #notices
handlers().on_message({
  type = 'report',
  report = { kind = 'grant', paths = { 'smaller.txt' } },
})
check('a grant report replaces the listing', listed(selvage.offered()), 'kept.txt,smaller.txt')
check('  and says nothing to the user about it', #notices, before)
handlers().on_message({ type = 'report', report = { kind = 'grant', paths = {} } })
check('an empty listing is the room granting nothing', listed(selvage.offered()), 'kept.txt')

selvage.leave()
check('a session that has ended offers nothing', listed(selvage.offered()), '')
check('  and holds nothing', listed(selvage.documents()), '')

-- The room offers nothing at all: no documents and no grant. The command says so rather than
-- asking a question with no answers.
join({}, {})
before = #notices
selvage.open()
check(
  'a room that offers nothing says so',
  said_since(before, 'the room has no open documents yet') ~= nil,
  true
)

selvage.leave()
vim.notify = notify

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
