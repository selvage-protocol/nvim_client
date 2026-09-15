-- The vocabulary this client shares with the VS Code one, pinned.
--
-- The two clients are different editors, not different products: the same intent is the same
-- English sentence in both, and only the presentation around it — the `selvage: ` prefix, the
-- gutter, the way a question is drawn — is the editor's own business (`AGENTS.md` §4,
-- `DESIGN.md` §4.3). A sentence that drifts on one side and not the other is what this file
-- exists to stop.
--
-- Pinned here is the vocabulary itself: the phrase Neovim reports for each `:Command`, and
-- every sentence this front-end shows a user — the literals it notifies, each with the level it
-- notifies it at, and the questions the two commands ask before giving a live session up, which
-- are `vim.fn.confirm` dialogs and a warning notification where there is nobody to answer them.
-- Which sentence is said at *which* moment is `test/lua/session.lua`'s and
-- `test/lua/commands.lua`'s, which drive the plugin; this file is the words alone.
--
-- What is not here, so that this header does not claim more than it covers:
--
-- - The wording a question is asked with (`vim.ui.input`, the picker's `vim.ui.select`), the
--   layout of the peers list and the buttons the confirm dialog offers are presentation, and the
--   editor's. `test/lua/commands.lua` pins the buttons with the commands they belong to.
-- - The companion's own failure messages (`lua/selvage/companion.lua`) reach `notify` as a
--   variable rather than as a literal of this file: counted, not pinned.
-- - The expression that fills a hole: `%s` in a pinned sentence is that hole, so the pin is on
--   the words around it.
--
-- Three messages are variables — the connect failure, the companion's failure to start, and the
-- question said where there is nobody to answer it — and their number is pinned, so a fourth
-- cannot arrive unnoticed.
--
--   nvim --headless -l test/lua/vocabulary.lua      (or scripts/test-lua.sh)

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

--- Compares two lists of lines, as the lines each has and the other does not, so that a drifted
--- sentence is the only thing a failure prints.
local function check_lines(name, got, want)
  local pinned = {}
  for _, line in ipairs(want) do
    pinned[line] = true
  end
  local here = {}
  for _, line in ipairs(got) do
    here[line] = true
  end
  local extra = {}
  for _, line in ipairs(got) do
    if not pinned[line] then
      extra[#extra + 1] = line
    end
  end
  local missing = {}
  for _, line in ipairs(want) do
    if not here[line] then
      missing[#missing + 1] = line
    end
  end
  if #extra == 0 and #missing == 0 then
    print('ok   ' .. name)
    return
  end
  failures = failures + 1
  table.sort(extra)
  table.sort(missing)
  print(
    ('FAIL %s\n  not pinned:\n    %s\n  pinned and not here:\n    %s'):format(
      name,
      #extra == 0 and '(nothing)' or table.concat(extra, '\n    '),
      #missing == 0 and '(nothing)' or table.concat(missing, '\n    ')
    )
  )
end

--- The canonical English phrase for each command, as `nvim_create_user_command`'s `desc`. The
--- command names are this editor's idiom; the phrase is the one both clients name the intent by.
---
--- `SelvageFetch` is the one command the other client has no counterpart for, and the divergence
--- is deliberate: the mirror is a real directory that this editor's own extensions — ripgrep,
--- ctags, a language server — read for themselves, and the other client, whose filesystem
--- provider fetches a file when it is read, has nothing of the kind to name. The README says why;
--- `AGENTS.md` §4 is the rule.
local TITLES = {
  SelvageHost = 'Host a session',
  SelvageJoin = 'Join a session from an invite link',
  SelvageCopyInvite = 'Copy the invite link',
  SelvageOpen = 'Open a document from the room',
  SelvageLeave = 'Leave the session',
  SelvageDisplayName = 'Set the name other participants see',
  SelvagePeers = "List the room's participants",
  SelvageFetch = "Fetch the room's content into the mirror",
}

--- Every sentence this front-end notifies, with the level it notifies it at, and the two
--- questions a live session is asked. A sentence whose words change, or a moment whose level
--- changes, breaks this list and has to be changed here deliberately. A sentence said at two
--- moments — an empty session and an empty room both say `join a session first` — is listed
--- once: what is pinned is the words and the level, not how often they are said.
local MESSAGES = {
  -- Hosting and joining.
  { 'INFO', 'room %s is open; copy the invite link to let someone join (:SelvageCopyInvite)' },
  { 'INFO', 'you are already hosting room %s; the invite link is on the clipboard' },
  { 'INFO', 'joined room %s; opening %s' },
  { 'INFO', 'joined room %s; opening %s; %d more, :SelvageOpen to choose' },
  { 'INFO', 'joined room %s' },
  { 'INFO', 'joined room %s; the room has no open documents yet' },
  { 'WARN', 'you are hosting room %s; joining another session ends this room for everyone' },
  { 'WARN', 'you are in room %s; joining another session leaves it' },
  { 'WARN', 'you are in room %s; hosting a session means leaving it first' },
  -- The room's documents, and the invite.
  { 'INFO', 'the room has no open documents yet' },
  { 'INFO', 'you are hosting, so the files you open are the ones the room has' },
  { 'WARN', 'join a session first' },
  { 'WARN', 'no shared document matches "%s"; :SelvageOpen alone offers them' },
  { 'WARN', '"%s" matches several: %s' },
  { 'INFO', 'the invite link is on the clipboard' },
  { 'WARN', 'there is no invite link: only the connection that opened the room has one' },
  -- Leaving.
  { 'INFO', 'left the session' },
  { 'WARN', 'not in a session' },
  -- The display name.
  { 'INFO', 'no display name is set yet' },
  { 'INFO', 'the name others see is "%s"; :SelvageDisplayName <name> to change it' },
  { 'INFO', 'display name set to "%s"' },
  { 'ERROR', 'a name is needed; the session was not started' },
  { 'ERROR', 'this name is %s; a name is refused rather than shortened' },
  { 'ERROR', 'this name is %s; a name is refused rather than shortened (from %s, so %s; set a shorter one)' },
  { 'ERROR', 'no display name is set and there is no one to ask; set vim.g.selvage_display_name or SELVAGE_DISPLAY_NAME, or run :SelvageDisplayName' },
  -- The list of participants.
  { 'WARN', 'no other participants yet' },
  -- What the room's own reports say.
  { 'WARN', 'the host left the room; it closes in %ds unless they come back' },
  { 'INFO', '%s is hosting again' },
  { 'WARN', 'the room is gone (%s)' },
  { 'ERROR', '%s (%s)' },
  { 'ERROR', 'the editor would not apply the room\'s change to %s; the file may be read-only' },
  { 'WARN', '%s was out of step with the room; the room\'s copy has been put back' },
  { 'ERROR', 'could not save %s; the file on disk is behind the room%s' },
  { 'ERROR', 'the connection ended and the session is over; it could not be re-established' },
  -- What this front-end refuses on its own.
  { 'ERROR', '%s is not valid UTF-8, so it is not shared' },
  { 'WARN', '%s is outside %s, the folder this session shares, so it is not shared' },
  { 'ERROR', 'the companion exited with %s' },
  { 'WARN', 'already %s room %s; leave that session first' },
  { 'ERROR', 'a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080' },
  { 'ERROR', 'an invite link is needed' },
  -- The mirror: the room's listing as a real directory, and the content fetched into it.
  { 'INFO', "the room's files are mirrored at %s; :SelvageFetch fetches their content" },
  { 'WARN', "%d of the room's files could not be mirrored, starting with %s" },
  { 'WARN', "%s is not in the room, so it is not shared; the mirror holds the room's files and is removed when the session ends" },
  { 'WARN', '%s is not in the room, so the mirror did not write it; save it outside the mirror to keep it' },
  { 'WARN', 'the room carries no file mutations yet' },
  { 'WARN', '%s is no longer in the room; the host no longer has it' },
  { 'WARN', "%s is inside the mirror, which holds the room's files, so it is not written; write outside the mirror to keep it" },
  { 'ERROR', '%s could not be written into the mirror' },
  { 'INFO', 'you are hosting, so the files a mirror would hold are already on your disk' },
  { 'INFO', 'the room lists no files to fetch' },
  { 'INFO', 'fetching opens them in the room, so every peer receives them' },
  { 'WARN', 'no file the room lists matches "%s"; :SelvageOpen and completion name them' },
  { 'INFO', 'fetched the files' },
  { 'WARN', 'fetched the files; these had not arrived within %ds: %s' },
  { 'WARN', 'the session ended before the files were fetched' },
}

--- The calls whose first argument is a sentence a user reads: the front-end's own `notify`, and
--- the question a live session is asked, which is what `confirm_leave` puts to the person.
local CALLS = { notify = true, confirm_leave = true }

--- The source as tokens, with comments and whitespace left out: words, punctuation and string
--- literals. A sentence quoted in a comment is documentation, and nothing can show it to a user.
local function tokens(source)
  local out = {}
  local index = 1
  local length = #source
  while index <= length do
    local char = source:sub(index, index)
    if source:sub(index, index + 1) == '--' then
      if source:sub(index + 2, index + 3) == '[[' then
        index = (source:find(']]', index + 4, true) or length) + 2
      else
        index = (source:find('\n', index + 2, true) or length) + 1
      end
    elseif char == "'" or char == '"' then
      local start = index
      index = index + 1
      while index <= length do
        local here = source:sub(index, index)
        if here == '\\' then
          index = index + 2
        elseif here == char then
          index = index + 1
          break
        else
          index = index + 1
        end
      end
      out[#out + 1] = { kind = 'string', text = source:sub(start, index - 1) }
    elseif char:match('%a') then
      local word = source:match('^[%w_]+', index)
      out[#out + 1] = { kind = 'word', text = word }
      index = index + #word
    elseif char:match('%s') then
      index = index + 1
    else
      out[#out + 1] = { kind = 'punct', text = char }
      index = index + 1
    end
  end
  return out
end

--- Every call of one of `names` in a token list, as the tokens of each argument. A name after
--- `function` is a definition and a name after `.` or `:` is another table's function, which is
--- how `notify` inside the front-end's own `vim.notify` wrapper is told from a call of it.
local function calls(list, names)
  local found = {}
  for at, token in ipairs(list) do
    local before = list[at - 1]
    local after = list[at + 1]
    local called = token.kind == 'word'
      and names[token.text] ~= nil
      and after ~= nil
      and after.text == '('
      and (before == nil or (before.text ~= 'function' and before.text ~= '.' and before.text ~= ':'))
    if called then
      local args = {}
      local current = {}
      local depth = 0
      local index = at + 1
      while index <= #list do
        local each = list[index]
        if each.kind == 'punct' and (each.text == '(' or each.text == '{') then
          depth = depth + 1
        elseif each.kind == 'punct' and (each.text == ')' or each.text == '}') then
          depth = depth - 1
          if depth == 0 then
            break
          end
        elseif each.kind == 'punct' and each.text == ',' and depth == 1 then
          args[#args + 1] = current
          current = {}
        end
        if index > at + 1 then
          current[#current + 1] = each
        end
        index = index + 1
      end
      args[#args + 1] = current
      found[#found + 1] = { name = token.text, args = args }
    end
  end
  return found
end

--- The text of an argument, as it is written and with nothing between the tokens.
local function written(arg)
  local parts = {}
  for _, token in ipairs(arg) do
    parts[#parts + 1] = token.text
  end
  return table.concat(parts)
end

local function unescape(literal)
  return (literal:sub(2, -2):gsub('\\(.)', function(char)
    if char == 'n' then
      return '\n'
    end
    return char
  end))
end

--- The sentence an argument holds: the literal itself, or the literal in parentheses with the
--- `:format` that fills its holes. A sentence assembled by concatenation, or one that came from
--- a variable, is not a literal here.
local function sentence_of(arg)
  if #arg == 1 and arg[1].kind == 'string' then
    return unescape(arg[1].text)
  end
  if #arg > 3 and arg[1].text == '(' and arg[2].kind == 'string' and arg[3].text == ')' then
    return unescape(arg[2].text)
  end
  return nil
end

--- The level a `notify` call names, or the information it is at when it names none.
local function level_of(call)
  if call.args[2] == nil then
    return 'INFO'
  end
  local text = written(call.args[2])
  return text:match('(%u+)$') or text
end

-- -- the phrase each command is described by --------------------------------------------
--
-- Neovim's own command table, which is the whole of what a `desc` is: the words `:SelvageHost`
-- and the palette in any UI show. A command whose `desc` is not the shared phrase, or a command
-- that appears or goes, changes this map.

local described = {}
for name, command in pairs(vim.api.nvim_get_commands({})) do
  if name:sub(1, 7) == 'Selvage' then
    -- `nvim_get_commands` carries a user command's `desc` in `definition`.
    described[name] = command.definition
  end
end
local described_lines = {}
for name, phrase in pairs(described) do
  described_lines[#described_lines + 1] = ('%s = %s'):format(name, phrase)
end
local titled_lines = {}
for name, phrase in pairs(TITLES) do
  titled_lines[#titled_lines + 1] = ('%s = %s'):format(name, phrase)
end
check_lines('every command is described by the phrase both clients use', described_lines, titled_lines)

-- -- the sentences this front-end can show a user ---------------------------------------
--
-- The literals `lua/selvage/init.lua` notifies, which is where the words of a moment are
-- written. Reading them out of the file rather than out of a session is what makes the pin
-- cover the moments no headless run can reach as well as the ones it can.

local source = table.concat(vim.fn.readfile('lua/selvage/init.lua'), '\n')
check('the front-end is where this test reads it', #source > 0, true)

local scanned = calls(tokens(source), CALLS)

-- The level a question carries when it is notified instead of drawn: the one call that says a
-- question where there is nobody to answer it is in the same file, and reading its level here is
-- what keeps the questions' own level checked rather than asserted by this file.
local question_level = nil
for _, call in ipairs(scanned) do
  local named = call.name == 'notify' and sentence_of(call.args[1] or {}) == nil
  if named and written(call.args[1] or {}) == 'question' then
    question_level = level_of(call)
  end
end
check('the question said where there is nobody to answer it is notified', question_level ~= nil, true)

local found = {}
local variables = 0
for _, call in ipairs(scanned) do
  local sentence = sentence_of(call.args[1] or {})
  if sentence == nil then
    variables = variables + 1
  else
    local level = call.name == 'confirm_leave' and question_level or level_of(call)
    found[('%s %s'):format(level, sentence)] = true
  end
end

local found_lines = {}
for line in pairs(found) do
  found_lines[#found_lines + 1] = line
end
local pinned_lines = {}
for _, message in ipairs(MESSAGES) do
  pinned_lines[#pinned_lines + 1] = ('%s %s'):format(message[1], message[2])
end
check_lines('every sentence this front-end shows is the shared one', found_lines, pinned_lines)

check('the messages that are not literals are the three this file names', variables, 3)

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
