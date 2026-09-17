-- A guest's join says one summary sentence, whatever the room holds.
--
-- Joining used to say a sentence per moment — the room and its landing, where the
-- mirror lives, and one hint per empty file opened after it — so a room of
-- several files arrived as a flood. The join now says one summary (the room, how
-- many files are mirrored where, how many of the landing fetched) and errors
-- only; the empty-file hint is said for the first file and never again.
--
--   nvim --headless -l test/lua/join.lua      (or scripts/test-lua.sh)

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

local sent = {}
local handlers = nil
local responder = nil
local next_id = 0

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
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local selvage = require('selvage')
vim.g.selvage_display_name = 'Test User'

--- The room's text for a path, as the edit the bridge computes against what the
--- buffer holds, followed by the save a document the room changed is written by.
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

--- A companion that answers every hold with the room's text, the way a real one
--- does, so the landing's documents are fetched the moment the join opens them.
local function room_holding(texts)
  return function(message)
    if message.type ~= 'open' then
      return
    end
    local text = texts[message.path]
    if text == nil then
      return
    end
    room_text(message.path, text, 0)
  end
end

--- Joins a room the way a real companion reports it: the status, then the
--- listing first (a document's buffer is named after the file the listing was
--- materialised at), then the documents, then the membership. The caller owns
--- the leave: leaving with no session says so, which is not the join's news.
local function join(documents, paths, room)
  selvage.join('ws://127.0.0.1:1/session?room=r-join&token=t')
  handle({ type = 'status', state = 'joined', role = 'guest', roomId = room or 'r-join' })
  handle({ type = 'report', report = { kind = 'grant', paths = paths } })
  handle({ type = 'report', report = { kind = 'documents', documents = documents } })
  handle({ type = 'report', report = { kind = 'peers', peers = {} } })
  return selvage.session().mirror
end

-- -- the join is one summary ------------------------------------------------------
--
-- Six files mirrored, two of them the landing, both fetched by the room's answer:
-- before the batching this was the join sentence, the mirror sentence and four
-- empty-file hints; now it is the summary and nothing else.

local GRANT = { 'a/one.lua', 'a/two.lua', 'b/three.lua', 'notes/deep.txt', 'README.md', 'src/main.rs' }
responder = room_holding({ ['a/one.lua'] = 'one\n', ['README.md'] = 'readme\n' })

selvage.leave()
local before = #notices
local root = join({ 'a/one.lua', 'README.md' }, GRANT)
check('the join says exactly one sentence', #notices, before + 1)
local summary = notices[#notices] ~= nil and notices[#notices].message or ''
check('  naming the room', summary:find('joined room r-join', 1, true) ~= nil, true)
check('  counting the mirrored files', summary:find('6 files mirrored at ' .. root, 1, true) ~= nil, true)
check('  counting the fetched landing', summary:find('2 of 2 fetched', 1, true) ~= nil, true)
check('  at info level', notices[#notices] ~= nil and notices[#notices].level or nil, vim.log.levels.INFO)

-- -- the empty-file hint is said once ------------------------------------------------
--
-- The four files nobody fetched are still empty placeholders. Opening every one
-- of them says the hint for the first and never again: the sentence is for the
-- shape, and the shape is the same on each.

local hinted = #notices
for _, path in ipairs({ 'a/two.lua', 'b/three.lua', 'notes/deep.txt', 'src/main.rs' }) do
  vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/' .. path))
end
local hints = 0
for index = hinted + 1, #notices do
  if notices[index].message:find('empty until fetched', 1, true) ~= nil then
    hints = hints + 1
  end
end
check('four empty files say the hint once', hints, 1)
check('  pointing at the command that fills them', notices[hinted + 1].message:find(':SelvageFetch', 1, true) ~= nil, true)

selvage.leave()

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
