-- The invite link: what a host hands out and what a guest pastes.
--
-- A page link carries the room and the token in its query and the key in its fragment; the wire
-- link a guest dials carries the same three. Nothing here decides what an invite means — that is
-- the companion's — but a link typed into a command line reaches the editor's registers and ShaDa,
-- so this is also where one is taken back out of them.
local api = vim.api

local notify = require('selvage.notify').notify
local can_prompt = require('selvage.prompt').can_prompt
local in_session = require('selvage.state').in_session
local is_peer = require('selvage.state').is_peer
local state = require('selvage.state').state

local M = {}

local hand_on_invite

--- The page a server's room is linked at: the server's own origin, over the scheme a browser
--- speaks. One address decides the whole invite — the page the guest opens and the socket they
--- join on are the same host — so a room cannot be linked at a page that dials another server.
local function page_origin(base)
  local wanted = vim.trim(base or ''):gsub('/+$', '')
  if wanted:match('^wss://') ~= nil then
    return 'https://' .. wanted:sub(7)
  end
  if wanted:match('^ws://') ~= nil then
    return 'http://' .. wanted:sub(6)
  end
  return wanted
end

--- Percent-encodes a query value the way the page builds its link: the unreserved
--- characters stand, everything else rides as uppercase `%XX`.
local function encode_component(text)
  return (tostring(text):gsub('[^A-Za-z0-9%.%-%_~]', function(char)
    return ('%%%02X'):format(string.byte(char))
  end))
end

--- Percent-decodes a query value, turning `+` into a space as a form would.
local function decode_component(text)
  local spaced = tostring(text):gsub('+', ' ')
  return (spaced:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Reads the room and its token out of a query string. Keys match whole, so a `bedroom=`
--- lookalike does not pass, and empty values do not count.
local function query_parts(query, fragment)
  local found = {}
  for pair in tostring(query):gmatch('[^&]+') do
    local key, value = pair:match('^([^=]*)=(.*)$')
    if (key == 'room' or key == 'token') and found[key] == nil then
      if value ~= nil and value ~= '' then
        found[key] = decode_component(value)
      end
    end
  end
  if found.room == nil or found.room == '' or found.token == nil or found.token == '' then
    return nil
  end
  -- §5.1's fragment is not a parameter and never a parameter's value: it is the two keys an
  -- invite carries, opaque to everything that only joins a room. It is kept as it arrived,
  -- because handing the link on has to hand it on whole.
  found.fragment = fragment or ''
  return found
end

--- The fragment of a link as it is written, `#` included, and the address before it.
local function split_fragment(text)
  local hash = text:find('#', 1, true)
  if hash == nil then
    return text, ''
  end
  return text:sub(1, hash - 1), text:sub(hash)
end

--- Splits a wire invite into the server base and the room/token it carries, or
--- answers nil when the value has no wire-invite shape.
local function parse_wire_invite(text)
  local trimmed = vim.trim(text or '')
  if trimmed:match('^wss?://%S+$') == nil then
    return nil
  end
  local address, fragment = split_fragment(trimmed)
  local mark = address:find('?', 1, true)
  if mark == nil then
    return nil
  end
  local parts = query_parts(address:sub(mark + 1), fragment)
  if parts == nil then
    return nil
  end
  return {
    base = (address:sub(1, mark - 1):gsub('/session$', '')),
    room = parts.room,
    token = parts.token,
    fragment = parts.fragment,
  }
end

--- Reads a pasted page link back into what this client acts on — the address the guest dials and
--- the query and fragment it hands on — or answers nil when the value has no page-link shape.
---
--- The query crosses to the engine as it arrived rather than as the room and token read out of
--- it: a link that repeats `room` or `token` is refused there by name (`PROTOCOL.md` §5.1), and a
--- rewrite built from the first of each would hand it a link it can no longer refuse. So what is
--- read here is the shape a paste has to have to be offered at all, and the two values are read
--- only to say whether the link names them.
local function parse_page_link(text)
  local trimmed = vim.trim(text or '')
  if trimmed:match('^https?://%S+$') == nil then
    return nil
  end
  local address, fragment = split_fragment(trimmed)
  local mark = address:find('?', 1, true)
  if mark == nil then
    return nil
  end
  if query_parts(address:sub(mark + 1), fragment) == nil then
    return nil
  end
  return {
    origin = address:sub(1, mark - 1),
    query = address:sub(mark + 1),
    fragment = fragment or '',
  }
end

--- The guest link for a room: the page the room's own server serves, carrying room and token.
--- The link *is* the server — its origin is the address the guest dials — so it carries nothing
--- else.
local function build_page_link(room, token, base, fragment)
  return page_origin(base)
    .. '/?room='
    .. encode_component(room)
    .. '&token='
    .. encode_component(token)
    .. (fragment or '')
end

--- The wire URL an invite joins on: a page link resolves to the server its own origin names,
--- while a `ws://` invite — a room whose server serves no page, or a guest that reached one
--- that way — joins as it stands.
---
--- The page's query crosses over as it arrived, and never as the two values read out of it: the
--- engine that reads the link next (`wireInvite` into `parseInvite`) refuses a link that repeats
--- `room` or `token`, naming the parameter (`PROTOCOL.md` §5.1), and rebuilding the query from
--- the first of each would hand it a link it can no longer refuse.
local function resolve_invite_to_wire(link)
  local page = parse_page_link(link)
  if page == nil then
    return link
  end
  local server = (page.origin:gsub('^https://', 'wss://'):gsub('^http://', 'ws://'))
  return (server:gsub('/+$', '')) .. '/session?' .. page.query .. (page.fragment or '')
end

--- Whether a typed value has an invite link's shape: the page link the host copies,
--- or a WebSocket address naming a room and its token. The names match whole with a
--- non-empty value, so a `bedroom=` lookalike or an empty value does not pass.
local function is_invite_link(text)
  return parse_wire_invite(text) ~= nil or parse_page_link(text) ~= nil
end

--- The refusal a value that is not an invite link earns, whoever asked: the box a bare
--- `:SelvageJoin` opens, and the argument an explicit one carries. One sentence for both, so the
--- same paste is answered the same way however it arrived, and a truncated one fails here rather
--- than later as whatever the engine said — nobody can tell "bad paste" from "server down" from
--- an ECONNREFUSED.
local function refuse_invite()
  notify(
    'that does not look like a Selvage invite link. Paste the whole link the host sent you — it looks like https://page/?room=…&token=…. A ws://host:8080/session?room=…&token=… link still joins.',
    vim.log.levels.ERROR
  )
end

--- What the clipboard holds, when it holds an invite: the host has just sent the link and pasting
--- it is the next thing the person does. Only a link that names a room is offered, so a stray
--- address in the clipboard is not joined by mistake.
local function clipboard_invite()
  local ok, text = pcall(vim.fn.getreg, '+')
  if not ok or text == nil or text == '' then
    ok, text = pcall(vim.fn.getreg, '"')
  end
  if not ok or type(text) ~= 'string' then
    return ''
  end
  text = vim.trim(text)
  if is_invite_link(text) then
    return text
  end
  return ''
end

--- Puts this session's invite on the clipboard and the unnamed register, and answers what
--- became of it: `'copied'` when the system clipboard took the link, `'register'` and the
--- reason when only this Neovim's own registers did, `'no-session'` when there is no session
--- to hand one on from, and `'no-invite'` when the session stands but this connection holds no
--- link for it.
---
--- Nothing is consumed here: the link is derived from the session every time it is asked for,
--- so one copy leaves the next one with just as much to put on the clipboard.
---
--- What a host copies is its page link, never the wire address it holds. A guest holds the
--- token it joined with — the invite *is* the permission — so the link its host sent is the
--- guest's to hand on, as it stands: the page link keeps the origin the host sent it from, and
--- a guest that reached the room over `ws://` has no other address for it.
hand_on_invite = function()
  -- An invite that outlived its session is not one to hand on: a failed join leaves the link
  -- remembered, and a room nobody is in is not a room to invite anyone to.
  if not in_session() then
    return 'no-session'
  end
  local invite = state.invite
  if invite == nil then
    return 'no-invite'
  end
  local link = invite
  if not is_peer() then
    local wire = parse_wire_invite(invite)
    if wire == nil then
      return 'no-invite'
    end
    link = build_page_link(wire.room, wire.token, wire.base, wire.fragment)
  end
  vim.fn.setreg('"', link)
  state.handed_invite = link
  -- The system clipboard is not this editor's to command: a Neovim with no clipboard provider
  -- takes the link into the unnamed register and nowhere else on the machine, so a sentence
  -- saying the clipboard has it would claim what the code cannot do. The unnamed register is
  -- written first and stands either way, so the link is never lost, only less reachable.
  local copied, why = pcall(vim.fn.setreg, '+', link)
  if not copied then
    return 'register', tostring(why)
  end
  return 'copied'
end

--- The invite to join on, asked for when the command was given none. What the box returns is
--- checked here; what arrived as an argument is checked before the name is resolved, in
--- `M.join`, and both say the same sentence (`refuse_invite`).
local function resolve_invite(callback)
  if not can_prompt() then
    notify('an invite link is needed.', vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = 'Join a Selvage session: ', default = clipboard_invite() }, function(input)
    local invite = vim.trim(input or '')
    if invite == '' then
      return
    end
    if not is_invite_link(invite) then
      refuse_invite()
      return
    end
    callback(invite)
  end)
end

--- Ends the session: every buffer it shared stops reporting, presence goes, and the front-end
--- is back to nothing shared. `land` is for a room that died under the person (`roomGone`,
--- `disconnected`): the buffers and the window still showing them are the room's, and the room
--- is not. Every other ending leaves them where they are — the person asked, and a leave does
--- not close the room for anyone else.
---
--- `keep_mirror` is for a room that closed under a guest rather than being left: the directory is
--- then kept and its path returned, because it holds work the room never received and deleting it
--- would leave the person with nowhere to recover it. A leave, a new session and a host's own
--- files are not that, and their mirror is removed as before.
---
--- @param land boolean|nil
--- @param keep_mirror boolean|nil
--- @return string|nil the kept mirror's path, when one was kept
--- Takes an invite back out of what this Neovim keeps on disk.
---
--- An invite is the room's permission, and a `selvage/2` one carries the room key in its fragment
--- (`PROTOCOL.md` §5.1, §12): a client **SHOULD NOT** put one anywhere it would not put the code,
--- and ShaDa writes the command-line and input histories and the unnamed register (with register
--- `0`, which `setreg('"')` fills too) to a file that outlives the room. So a link typed into
--- `:SelvageJoin` or its prompt leaves the histories once it has been read, and the one a copy put in
--- the registers leaves them when the session ends — unless something else has been yanked since,
--- which is the person's and is left alone. The system clipboard is not ShaDa's and is the handing
--- on the person asked for, so it is not touched.
---
--- @param link string|nil the invite, as it was typed or copied
--- @param registers boolean|nil whether the registers are scrubbed as well as the histories
local function forget_invite(link, registers)
  if type(link) ~= 'string' or link == '' then
    return
  end
  for _, kind in ipairs({ ':', '@' }) do
    local last = vim.fn.histnr(kind)
    for index = last, math.max(1, last - vim.o.history), -1 do
      if vim.fn.histget(kind, index):find(link, 1, true) ~= nil then
        vim.fn.histdel(kind, index)
      end
    end
  end
  if registers then
    for _, name in ipairs({ '"', '0' }) do
      if vim.fn.getreg(name) == link then
        vim.fn.setreg(name, '')
      end
    end
  end
end

-- Quitting Neovim with a session still open reaches no `reset`, and `VimLeavePre` is the last
-- moment before ShaDa is written, so the copied link is taken back there too.
api.nvim_create_autocmd('VimLeavePre', {
  group = api.nvim_create_augroup('SelvageInvite', { clear = true }),
  callback = function()
    forget_invite(state.handed_invite, true)
  end,
})

--- Says why `hand_on_invite` did not put the link on the clipboard.
local function say_not_copied(handed, why)
  if handed == 'register' then
    notify(('invite link is in register " (clipboard failed: %s).'):format(why), vim.log.levels.WARN)
  elseif handed == 'no-invite' then
    notify('no invite link for this session.', vim.log.levels.WARN)
  else
    notify('not in a session.', vim.log.levels.WARN)
  end
end


M.forget_invite = forget_invite
M.hand_on_invite = hand_on_invite
M.is_invite_link = is_invite_link
M.refuse_invite = refuse_invite
M.resolve_invite = resolve_invite
M.resolve_invite_to_wire = resolve_invite_to_wire
M.say_not_copied = say_not_copied

return M
