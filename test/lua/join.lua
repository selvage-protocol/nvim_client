-- A guest's join says one summary sentence, whatever the room holds.
--
-- Joining used to say a sentence per moment — the room and its landing, where the
-- mirror lives, and one hint per empty file opened after it — so a room of
-- several files arrived as a flood. The join now says one summary (the room, the
-- document it opened, and how many others it holds) and errors only; the
-- empty-file hint is said for the first file and never again.
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
-- Six files mirrored, two of them the landing, both fetched by the room's answer: before the
-- batching this was the join sentence, the mirror sentence and four empty-file hints, and now
-- it is one sentence and nothing else. What the sentence says is the landing and how many
-- other documents the room holds: where the mirror lives and how much of it has arrived read
-- as a row of counts, and the session's own row and `:SelvageOpen` are where a person looks.

local GRANT = { 'a/one.lua', 'a/two.lua', 'b/three.lua', 'notes/deep.txt', 'README.md', 'src/main.rs' }
responder = room_holding({ ['a/one.lua'] = 'one\n', ['README.md'] = 'readme\n' })

selvage.leave()
local before = #notices
local root = join({ 'a/one.lua', 'README.md' }, GRANT)
check('the join says exactly one sentence', #notices, before + 1)
local summary = notices[#notices] ~= nil and notices[#notices].message or ''
check('  saying the landing, never the room id', summary:find('joined the room — opening a/one.lua', 1, true) ~= nil, true)
check('  counting the room\'s other documents', summary:find('1 more in the room', 1, true) ~= nil, true)
check('  and nothing about the mirror', summary:find('mirror', 1, true) == nil, true)
check('  at info level', notices[#notices] ~= nil and notices[#notices].level or nil, vim.log.levels.INFO)

-- -- a remote edit arms the caret again ---------------------------------------------
--
-- A room document's buffer exists as soon as the handshake names it, and the room's text is a
-- later message: the caret the plugin publishes in between is a caret for a document the
-- companion does not hold yet, and the bridge drops one of those rather than inventing a
-- document for it. A `nvim_buf_set_text` fires no `TextChanged`, so the edit that fills the
-- buffer is the only moment left to publish the caret again. Without that publish a peer who has
-- not moved is a peer whose caret nobody draws: the host's row cannot name them and `:SelvageGoTo`
-- has nothing to go to.
--- The `selection` messages this session sent for `path`: the caret it has told the room about.
local function selections_for(path)
  local count = 0
  for _, message in ipairs(sent) do
    if message.type == 'selection' and message.path == path then
      count = count + 1
    end
  end
  return count
end

-- The caret the landing's own buffer publishes, armed when it was opened: waited for rather than
-- assumed, because the assertion below is about what an edit adds to it.
vim.wait(2000, function()
  return selections_for('a/one.lua') > 0
end, 20)
local heard = selections_for('a/one.lua')
check('the caret of a document the room opened is published', heard > 0, true)

handle({
  type = 'applyEdit',
  id = message_id(),
  path = 'a/one.lua',
  start = 0,
  ['end'] = 0,
  text = 'one\n',
  version = 1,
})
check(
  'a remote edit arms the caret again, so the peer nobody could see is seen',
  vim.wait(2000, function()
    return selections_for('a/one.lua') > heard
  end, 20),
  true
)

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
