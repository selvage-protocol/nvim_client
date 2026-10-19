-- The server a room is minted on, and the address that holds one.
--
-- A bare `:SelvageHost` uses `vim.g.selvage_server_url`, else the address the last host used, which
-- outlives this Neovim in a file beside the mirrors; with neither it asks once, starting from the
-- demo default. An address that is really an invite — a query and a fragment — is refused and
-- taken back out of the editor's registers, because pasting one here is the mistake that costs a
-- key, and `:SelvageChangeServer` reports rather than pretends when the global is what is in force.
local forget_invite = require('selvage.invite').forget_invite
local notify = require('selvage.notify').notify
local can_prompt = require('selvage.prompt').can_prompt

local M = {}

--- The server a bare `:SelvageHost` asks about when nothing was configured and nothing was
--- remembered: the public demo, whose live state is `ai_notes/docs/runbook-prod-demo.md`. The
--- value is a domain on its own on purpose — it is what a person would type — and
--- `normalise_server_address` is what makes it a connection: a bare domain means the secure
--- server, `wss://selvage-demo.dontblameme.dev`, on the port TLS uses. An overridable default,
--- never a commitment — the answer is remembered, and an explicit argument and
--- `vim.g.selvage_server_url` always win — so moving the demo is this one line.
local DEFAULT_SERVER_URL = 'selvage-demo.dontblameme.dev'

--- A scheme at the start of a typed value: `ws`, `wss`, `http`, `https`. Its presence is what
--- separates a URL from an address someone typed out of their head, and the bare form is the
--- one that has to be completed rather than refused.
local function has_scheme(text)
  return text:match('^%a[%w+.-]*://') ~= nil
end

--- The address the engine dials, from whatever was typed in a server-address position.
---
--- A person types a host, not a URL: `selvage-demo.dontblameme.dev` means the published shape,
--- which is TLS, so a bare address means `wss://<host>`. The endpoint path is not part of a
--- server address — the engine appends `/session` to the base it is given — so an address that
--- already names the endpoint loses it, or the room would be dialled at `/session/session`,
--- and a trailing slash is not a second server. Any other path is kept: a server behind a
--- prefix was addressed deliberately, not mistyped.
local function normalise_server_address(text)
  local trimmed = vim.trim(text or '')
  if trimmed == '' then
    return ''
  end
  local addressed = has_scheme(trimmed) and trimmed or ('wss://' .. trimmed)
  addressed = (addressed:gsub('/+$', ''))
  return (addressed:gsub('/session$', ''))
end

--- The host `authority` names, or nil when it names none.
---
--- The engine parses the address as a URL, and a URL reads no host out of what it refuses: a port
--- on its own (`:8080`), an empty or unclosed bracketed address (`[]`, `[::1`), a port that is
--- not a number or is past 65535, credentials, and whitespace anywhere in the authority.
local function authority_host(authority)
  if authority:find('[%s@]') ~= nil then
    return nil
  end
  local host, port = authority, ''
  local bracketed, after = authority:match('^(%[[^%]]*%])(.*)$')
  if bracketed ~= nil then
    host, port = bracketed, after
  else
    host, port = authority:match('^([^:]*)(.*)$')
  end
  if host == nil or host == '' or host == '[]' then
    return nil
  end
  if port ~= '' and port ~= ':' then
    local digits = port:match('^:(%d+)$')
    if digits == nil or tonumber(digits) > 65535 then
      return nil
    end
  end
  return host
end

--- Whether `text` is a server address the companion's engine can dial.
---
--- The engine owns that reading (`sessionBase` in the vendored engine): a `ws`, `wss`, `http` or
--- `https` scheme, a host, and none of the parts a server address never carries — credentials, a
--- query or a fragment, the last two being a link's room, token and key.
local function is_server_address(text)
  local scheme, rest = text:match('^(%a[%w+.-]*)://(.*)$')
  if scheme == nil then
    return false
  end
  scheme = scheme:lower()
  if scheme ~= 'ws' and scheme ~= 'wss' and scheme ~= 'http' and scheme ~= 'https' then
    return false
  end
  local authority, remainder = rest:match('^([^/?#]*)(.*)$')
  if authority == nil or remainder:find('[?#]') ~= nil then
    return false
  end
  return authority_host(authority) ~= nil
end

--- Refuses `address` when it is not a server address, saying so in the reader's own words, and
--- answers whether it did.
---
--- The argument, the setting, the box's answer and the remembered address all take a server
--- address, never an invite link: a link's query carries the room and its token and its fragment
--- the room key, so accepting one would write the key beside the mirrors under `stdpath` and hand
--- it to the next host as the address to dial. Nothing but an address is written.
local function refuse_server_address(address)
  if is_server_address(normalise_server_address(address)) then
    return false
  end
  local text = vim.trim(address or '')
  if text:find('[?#]') ~= nil then
    -- An invite pasted into a server-address position is an invite: its query is the room and its
    -- token and its fragment the key, and ShaDa writes the histories to disk, so it is taken out
    -- of them here exactly as one typed into `:SelvageJoin` is (`forget_invite`).
    forget_invite(text)
    notify(
      'that is an invite link, not a server address. Paste the address the server printed when it started, not the link you send to your guest.',
      vim.log.levels.ERROR
    )
  else
    notify(
      'that does not look like a server address. Paste the address the server printed when it started, e.g. selvage.example or ws://127.0.0.1:8080.',
      vim.log.levels.ERROR
    )
  end
  return true
end

--- The last server address a host was started on, so the next bare `:SelvageHost` reuses
--- it without asking. The file below is what outlives this Neovim; this is what answers
--- without reading it twice in one process. `vim.g.selvage_server_url` is the setting that
--- uses another address instead.
local last_server = nil

--- The file the last server address is kept in across restarts: the other client remembers it
--- in its global state, and a bare `:SelvageHost` starts its question from it all the same. A
--- file beside the mirrors under `stdpath`, read when the question is asked and written when a
--- host starts, so a restart forgets nothing. A read or write that fails is not a session's
--- failure, so both give up silently.
local function last_server_file()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'selvage', 'last_server')
end

--- The address the file remembers, or nil when no host has been started yet or it cannot be read.
local function read_last_server()
  local ok, lines = pcall(vim.fn.readfile, last_server_file())
  if not ok or type(lines) ~= 'table' or #lines < 1 then
    return nil
  end
  local address = vim.trim(tostring(lines[1]))
  if address == '' then
    return nil
  end
  return address
end

--- Remembers `address` for the next host, in this Neovim and after it: a bare host
--- reuses it without asking, and an argument or `vim.g.selvage_server_url` uses another.
local function remember_last_server(address)
  last_server = address
  local file = last_server_file()
  pcall(vim.fn.mkdir, vim.fs.dirname(file), 'p')
  pcall(vim.fn.writefile, { address }, file)
end

--- Writes the address the next host reuses: completed, refused when it is not a server address,
--- remembered in this Neovim and in the file, and confirmed. Only the next host, never a live
--- room.
local function write_server(address)
  if refuse_server_address(address) then
    return false
  end
  address = normalise_server_address(address)
  remember_last_server(address)
  notify(('will host on %s next. Leave this session and host again to move there.'):format(address))
  return true
end

--- The box the first-run question and `:SelvageChangeServer`'s change both ask through: the
--- server address, starting from `default`. Answers `callback(address)` for a non-empty,
--- trimmed reply; a cancelled or emptied one calls nothing, so the caller's own state stands.
local function ask_server_url(default, callback)
  vim.ui.input({
    prompt = 'Selvage server to host on (selvaged printed it when it started): ',
    default = default,
  }, function(input)
    local address = vim.trim(input or '')
    if address == '' then
      return
    end
    callback(address)
  end)
end

--- The server to mint a room on: the configured address, else the remembered one with no
--- question asked, else one question starting from the demo default (`DEFAULT_SERVER_URL`).
--- Asked once, then reused: an argument or `vim.g.selvage_server_url` uses another, and
--- writes it down as the remembered one.
local function resolve_server_url(callback)
  local configured = vim.g.selvage_server_url
  if configured ~= nil and vim.trim(tostring(configured)) ~= '' then
    callback(vim.trim(tostring(configured)))
    return
  end
  local remembered = last_server or read_last_server()
  if remembered ~= nil then
    callback(remembered)
    return
  end
  if not can_prompt() then
    notify('a server address is needed, e.g. :SelvageHost ws://127.0.0.1:8080.', vim.log.levels.ERROR)
    return
  end

  ask_server_url(DEFAULT_SERVER_URL, callback)
end

--- The palette-reachable answer to "how do I change which server I am using", without hosting
--- first: reports the server the next host uses and offers to change it through the same box
--- the first-run question asks. `vim.g.selvage_server_url` outranks the remembered address
--- (`resolve_server_url()`), so writing the remembered one while it is set would be silently
--- ignored by the next host; this says the global is in force instead of pretending to change
--- anything. Either way the write only reaches the *next* host, never a live room.
function M.change_server(url)
  local wanted = vim.trim(url or '')
  local configured = vim.g.selvage_server_url
  local configured_str = configured ~= nil and normalise_server_address(tostring(configured)) or ''
  if configured_str ~= '' then
    notify(
      ('the "vim.g.selvage_server_url" setting fixes the server at %s; change it in your config to use a different one.'):format(
        configured_str
      )
    )
    return
  end
  if wanted ~= '' then
    write_server(wanted)
    return
  end
  local current = last_server or read_last_server()
  if current == nil then
    notify('no server is remembered yet; the next host asks.')
  else
    notify(('the next host uses %s.'):format(normalise_server_address(current)))
  end
  if not can_prompt() then
    return
  end
  -- The box and its answer are completed before either is used, so the address this command
  -- reports is the address the next host dials, bare host or not.
  local base = normalise_server_address(current or DEFAULT_SERVER_URL)
  ask_server_url(base, function(address)
    -- Answering with the address already in force changes nothing, and anything else is written
    -- the way an argument is — refused in the same words when it is not a server address.
    if normalise_server_address(address) == base then
      return
    end
    write_server(address)
  end)
end

M.normalise_server_address = normalise_server_address
M.refuse_server_address = refuse_server_address
M.remember_last_server = remember_last_server
M.resolve_server_url = resolve_server_url

return M
