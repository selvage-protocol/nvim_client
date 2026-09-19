-- The joining half of the two-instance proof. Run by `test/e2e/run.ts`:
--
--   nvim --headless -l test/e2e/guest.lua
--
-- It knows nothing about the host but the invite link it reads out of a file, and nothing
-- about the document but what the room sends it.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.setup('guest')

local selvage = harness.load_plugin()

local invite = harness.wait_for_file('the invite', harness.deadline_ms, harness.invite_file)

-- The reconnect phase routes the guest through a relay the orchestrator can cut, so that the
-- socket that dies is the guest's and the host's connection and the room are untouched.
local proxy = harness.env.optional('SELVAGE_E2E_PROXY_ADDR')
if proxy ~= nil then
  invite = invite:gsub('^ws://[^/]+', 'ws://' .. proxy)
  harness.log('routing through the relay at', proxy)
end
harness.log('joining', invite)

selvage.join(invite)

-- The window the guest's own seed used to be lost in: the handshake names the room's documents
-- and the sync that carries their text is a later message, so this client's buffer for one
-- exists — and is counting — before the room has put anything in it. A keystroke made here must
-- leave neither the buffer nor the room behind: the room's text has to land in the buffer all
-- the same, and the buffer's text must not be published over the room's.
--
-- The relay holds the guest's own bytes back so that this happens every run; without it the
-- window is about a millisecond wide on loopback and this would be a race with the sync.
--
-- The document is waited for in the *window*, not just as a buffer: joining is what puts it in
-- front of the user, and a buffer that was created but never shown is the failure this proof
-- exists to catch.
harness.wait('the room document to open in the window', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.seed_path)
end, function()
  return vim.inspect(selvage.session())
end)

local bufnr = vim.api.nvim_get_current_buf()
harness.log('the buffer exists and holds', vim.inspect(harness.text()))
if harness.text() ~= '' then
  harness.fail('the room text arrived before the buffer could be edited; the relay lag is too small to open the window this checks')
end
vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { '[[GUEST-BEFORE-ARRIVAL]]' })
local before_arrival = harness.text()
harness.log('edited it before the room text arrived; it holds', vim.inspect(before_arrival))

-- Waited for as a change from what the buffer holds now: the room's text is nothing this driver
-- knows — it knows nothing about the document but what the room sends it — and what it is
-- waiting for is that text landing.
harness.wait('the room document to arrive', harness.deadline_ms, function()
  local text = harness.text()
  return text ~= nil and text ~= before_arrival
end, function()
  return vim.inspect(selvage.session())
end)
harness.log('joined with', vim.inspect(harness.text()))

bufnr = vim.fn.bufnr(harness.buffer_name(harness.seed_path))
if bufnr == -1 then
  harness.fail('the room document did not open as a buffer')
end

harness.write_file(harness.joined_file, 'joined')

-- The window says which end of the session this is, with no statusline configuration and no
-- count to arrange: the room holds the host and this client, and the row is written from the
-- room's own membership report. It is asserted after the document's text has landed, because a
-- file whose content has not arrived carries the mark for that too.
harness.wait('the room text to land', harness.deadline_ms, function()
  return harness.text() ~= nil and harness.text() ~= ''
end, harness.observe)
harness.wait('the window to name the session and count the room', harness.deadline_ms, function()
  return vim.api.nvim_get_option_value('winbar', { win = 0 })
    == '%#SelvageSession#Selvage: guest — 2 people in the room%*'
end, function()
  return vim.inspect(vim.api.nvim_get_option_value('winbar', { win = 0 }))
end)
harness.log('the window says', vim.inspect(vim.api.nvim_get_option_value('winbar', { win = 0 })))

harness.wait('the host edit to arrive', harness.deadline_ms, function()
  return harness.contains(harness.markers.host)
end, harness.observe)

-- The host's caret and selection, as the plugin drew them: a block at the host's own column,
-- and a range mark behind it when the host has selected something. The marks can only be the
-- host's — the bridge withholds a cursor for the local peer — and the caret carries the gutter
-- sign of the host's own display name, handed to this process by the orchestrator. The document
-- is shared on both sides, so the path the marks are addressed to exists here.
local function presence_marks()
  local namespace = vim.api.nvim_get_namespaces()['selvage.presence']
  local bufnr = vim.fn.bufnr(harness.buffer_name(harness.seed_path))
  if namespace == nil or bufnr == -1 then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
end

--- The mark that carries the selection, as opposed to the caret's own: only the caret carries
--- the gutter sign.
local function host_selection()
  for _, mark in ipairs(presence_marks()) do
    if mark[4].end_row ~= nil and mark[4].sign_text == nil then
      return mark
    end
  end
  return nil
end

-- The caret is drawn on the cell *before* the host's offset — the character the caret is in
-- front of — and the host's caret is at the end of the marker line, so the block fills the
-- marker's last character rather than the empty cell after it. The mark is the host's because
-- the bridge withholds a cursor for the local peer and because its sign is the host's own name;
-- a caret published as soon as the buffer was shared, before the host moved, would carry the
-- same sign but sit at the column the insert left behind, which is why the wait is for the
-- marker's column and not for any caret at all.
local function host_caret()
  local label = vim.env.SELVAGE_E2E_HOST_DISPLAY_NAME or vim.env.USER or 'neovim'
  for _, mark in ipairs(presence_marks()) do
    if mark[2] == 0 and mark[3] == #harness.markers.host - 1 then
      local sign = mark[4].sign_text
      local mine = sign ~= nil and label:sub(1, #sign) == sign
      local block = mark[4].hl_group ~= nil
        and mark[4].end_row == 0
        and mark[4].end_col == #harness.markers.host
      if block and mine then
        return mark
      end
    end
  end
  return nil
end

harness.wait('the host caret to be drawn at its column', harness.deadline_ms, function()
  return host_caret() ~= nil
end, function()
  return 'no caret at the host marker; marks: ' .. vim.inspect(presence_marks())
end)
harness.log('the host caret is drawn at its column')

-- The selection arrives the same way: a range mark, in the host's colour, from the marker's
-- start to the host caret's offset — `[anchor, head)`, which a selection keeps whatever the
-- caret's block does with its cell.
harness.wait('the host selection to be drawn', harness.deadline_ms, function()
  local mark = host_selection()
  return mark ~= nil
    and mark[2] == 0
    and mark[3] == 0
    and mark[4].end_row == 0
    and mark[4].end_col == #harness.markers.host
end, function()
  return 'no selection over the host marker; marks: ' .. vim.inspect(presence_marks())
end)
harness.log('the host selection is drawn')

vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { harness.markers.guest })
harness.log('made the guest edit; buffer now', vim.inspect(harness.text()))

harness.wait('both edits to be in this buffer', harness.deadline_ms, function()
  return harness.contains(harness.markers.host) and harness.contains(harness.markers.guest)
end, harness.observe)

harness.record('phase1', harness.text())
harness.log('phase 1 converged:', vim.inspect(harness.text()))

-- The document this window was editing when the room's listing arrived is a file in the mirror
-- too, holding what the room and this window converged on: a guest that hears which documents the
-- room holds before it hears what the room grants opens them as `selvage://` buffers, and the
-- listing turns each of those into the file it names.
if harness.mirror() == nil then
  harness.fail('the guest has no mirror for the room document it is editing')
end
local mirrored_seed = harness.mirror() .. '/' .. harness.seed_path
harness.wait('the mirrored seed document to hold the converged text', harness.deadline_ms, function()
  -- The file on disk is the buffer Neovim wrote line by line, so it ends in the newline the last
  -- line is written with; the room's text carries no newline of its own, which is why the two
  -- differ by exactly that byte (the same read `mirror.holds` makes).
  return harness.file_text(mirrored_seed) == harness.text() .. '\n'
end, function()
  return vim.inspect(harness.file_text(mirrored_seed))
end)
harness.log('the mirrored seed document holds', vim.inspect(harness.file_text(mirrored_seed)))

harness.wait_ack('phase1', harness.deadline_ms)

-- -- a path the room grants and nobody has opened yet ---------------------------------
--
-- The room's grant is a listing and never content: this path is offered and no buffer exists
-- for it, so `documents()` — what this session holds — does not name it. It is opened here the
-- way a person opens it, through `:SelvageOpen`'s own path, and its text can then only have
-- come from the host's working copy: the host never opened the file, and the room asked for it
-- because this editor did.
harness.wait('the room to grant the path the host never opened', harness.deadline_ms, function()
  for _, path in ipairs(selvage.offered()) do
    if path == harness.granted_path then
      return true
    end
  end
  return false
end, function()
  return ('offered %s; held %s'):format(vim.inspect(selvage.offered()), vim.inspect(selvage.documents()))
end)

for _, path in ipairs(selvage.documents()) do
  if path == harness.granted_path then
    harness.fail('the granted path was already held before anyone opened it')
  end
end

-- -- the mirror: the room's shape, as a directory anything can read -----------------------
--
-- This is what the mirror is for. The listing is materialised before a byte of content is
-- fetched: a tree plugin, `fd`, `rg --files` and a language server's project scan see the whole
-- project, and a path whose content has not been fetched is a file that is there and empty.
-- Both halves are asserted here — the file exists, and it holds nothing — and the `rg` further
-- down is what "any extension works" means: a program outside this editor reads this disk.
local mirror = harness.mirror()
if mirror == nil then
  harness.fail('the guest has no mirror; the room offered ' .. vim.inspect(selvage.offered()))
end
if vim.fn.isdirectory(mirror) ~= 1 then
  harness.fail('the mirror is not a directory: ' .. vim.inspect(mirror))
end
local cache = vim.fn.stdpath('cache')
if mirror:sub(1, #cache + 1) ~= cache .. '/' then
  harness.fail('the mirror is not under stdpath(cache): ' .. vim.inspect(mirror))
end
if mirror:sub(1, #vim.fn.getcwd() + 1) == vim.fn.getcwd() .. '/' then
  harness.fail('the mirror is inside the project this window is in: ' .. vim.inspect(mirror))
end
local mirrored_granted = mirror .. '/' .. harness.granted_path
harness.wait('the granted path to be materialised in the mirror', harness.deadline_ms, function()
  return vim.fn.filereadable(mirrored_granted) == 1
end, function()
  return 'the mirror holds ' .. vim.inspect(vim.fn.glob(mirror .. '/*', false, true))
end)
if harness.file_text(mirrored_granted) ~= '' then
  harness.fail('a path nobody fetched holds content: ' .. vim.inspect(harness.file_text(mirrored_granted)))
end
harness.log("the mirror holds the room's shape, and", harness.granted_path, 'is empty in it')

-- The path the host will delete while the session is hosted is mirrored now, so that its removal
-- below is about the listing losing a path rather than about a file that was never there.
local mirrored_removed = mirror .. '/' .. harness.removed_path
harness.wait('the path the host will delete to be materialised', harness.deadline_ms, function()
  return vim.fn.filereadable(mirrored_removed) == 1
end, function()
  return 'the mirror holds ' .. vim.inspect(vim.fn.glob(mirror .. '/*', false, true))
end)

selvage.open(harness.granted_path)
harness.wait('the granted path to open in the window', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.granted_path)
end, function()
  return 'the window holds ' .. vim.inspect(vim.fn.bufname('%'))
end)
local granted_buf = vim.api.nvim_get_current_buf()

-- Waited for as the host's own text: nothing this driver knows is in the buffer, and an empty
-- buffer is exactly the failure the read is here to rule out.
harness.wait("the host's text for the granted path to arrive", harness.deadline_ms, function()
  return harness.text_of(harness.granted_path) == harness.granted_text
end, function()
  return vim.inspect(harness.text_of(harness.granted_path))
end)
harness.log('the granted path holds', vim.inspect(harness.text_of(harness.granted_path)))

-- The guest writes into it, so the host's copy of a file it never opened becomes something this
-- window wrote. The room's text for a path off the host's disk is the file's own bytes, which end
-- in a newline, so this buffer's last line is empty and the file's final newline *is* that line:
-- replacing it is the edit whose range ends past the end of the room's text, and the one this
-- proof would read as an invented newline if the client got that range wrong.
--
-- Both sides are asserted byte for byte in the orchestrator's gate; what is checked here is that
-- this buffer and the room's text for the path are the same bytes.
vim.api.nvim_buf_set_lines(granted_buf, -2, -1, true, { harness.markers.guest })
harness.wait('the guest marker to land in the granted document', harness.deadline_ms, function()
  return harness.text_of(harness.granted_path)
    == harness.granted_text .. harness.markers.guest
end, function()
  return vim.inspect(harness.text_of(harness.granted_path))
end)
harness.record('granted', harness.text_of(harness.granted_path))
harness.write_file(harness.granted_done_file, 'go')
harness.log('the granted path reads', vim.inspect(harness.text_of(harness.granted_path)))

-- The content the room sent for a path this window opened is *in the mirror's file*, because that
-- is what makes it native: the buffer is the file, and the save that follows a document the room
-- changed wrote it there. A program started outside this editor — ripgrep, ctags, a language
-- server — reads the bytes this window is editing. The file is not the room's text: Neovim writes
-- every line followed by a newline, so a file holds one more than the text it was written from.
harness.wait("the mirror's file to hold what the room sent", harness.deadline_ms, function()
  return harness.file_text(mirrored_granted)
    == harness.granted_text .. harness.markers.guest .. '\n'
end, function()
  return vim.inspect(harness.file_text(mirrored_granted))
end)
harness.log('the mirror file holds', vim.inspect(harness.file_text(mirrored_granted)))

-- And a program that walks the directory finds it there, which is the claim the mirror makes and
-- a buffer could never make. `rg` is not installed everywhere, so a run without it records that
-- it did not run rather than passing a proof nothing exercised.
local rg_found = false
if vim.fn.executable('rg') == 1 then
  local hits = vim.fn.systemlist({ 'rg', '-l', '--fixed-strings', harness.markers.guest, mirror })
  harness.log('rg over the mirror found', vim.inspect(hits))
  rg_found = vim.v.shell_error == 0 and vim.tbl_contains(hits, mirrored_granted)
  if not rg_found then
    harness.fail(('rg over the mirror found %s, which does not include %s'):format(vim.inspect(hits), mirrored_granted))
  end
end

-- -- a save in the mirror reaches the host -------------------------------------------------
--
-- The buffer is a real file, so `:w` is what a person does to it. This client routes the save to
-- the room and writes the file itself, and the host's own working copy becomes this text — the
-- path was only ever a name in the listing until this window opened it.
vim.api.nvim_win_set_buf(0, granted_buf)
vim.api.nvim_buf_set_lines(granted_buf, -1, -1, true, { harness.markers.mirror })
vim.cmd('write')
harness.wait('the save to be written into the mirror file', harness.deadline_ms, function()
  return harness.file_text(mirrored_granted)
    == harness.granted_text .. harness.markers.guest .. '\n' .. harness.markers.mirror .. '\n'
end, function()
  return vim.inspect(harness.file_text(mirrored_granted))
end)
harness.wait('the buffer to be saved', harness.deadline_ms, function()
  return vim.bo[granted_buf].modified == false
end, function()
  return 'modified=' .. tostring(vim.bo[granted_buf].modified)
end)
harness.log('saving in the mirror wrote', vim.inspect(harness.file_text(mirrored_granted)))
harness.record('mirror', harness.file_text(mirrored_granted), {
  root = mirror,
  rgFound = rg_found,
})
harness.write_file(harness.mirror_done_file, 'go')
harness.wait_ack('mirror', harness.deadline_ms)

-- -- a document held open while the host deletes it ------------------------------------------
--
-- Delete-while-open needs two live editors: the guest holds the path the host is about to
-- delete, with its text arrived, and signals the host to delete it. What is proved is badge,
-- don't prune — the buffer stays with its text — rather than the room yanking it away.
selvage.open(harness.removed_path)
harness.wait('the path the host will delete to open', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.removed_path)
end, function()
  return 'the window holds ' .. vim.inspect(vim.fn.bufname('%'))
end)
harness.wait("the host's text for the path it will delete to arrive", harness.deadline_ms, function()
  return harness.text_of(harness.removed_path) == harness.removed_text
end, function()
  return vim.inspect(harness.text_of(harness.removed_path))
end)
-- The save is what puts the text into the mirror's file: signalling on the text alone would let
-- the host delete while the save is still on its way, and the save arriving after the listing
-- shrank would write the file the removal just deleted back again.
harness.wait('the save to write the path it will delete into the mirror', harness.deadline_ms, function()
  -- The file is the buffer Neovim writes, line by line, so it ends in the newline the last line is
  -- written with: the room's text for this path is the host's file bytes, which already end in one.
  return harness.file_text(mirror .. '/' .. harness.removed_path) == harness.removed_text .. '\n'
end, function()
  return vim.inspect(harness.file_text(mirror .. '/' .. harness.removed_path))
end)
local delete_open_buf = vim.api.nvim_get_current_buf()
harness.write_file(harness.delete_open_ready_file, 'go')
harness.log('holding', harness.removed_path, 'open while the host deletes it')

-- -- the room's listing changes under the session ------------------------------------------
--
-- The host creates a file under the folder it shares and deletes another. Both are changes to
-- the room's listing, and a guest follows it: the path that appeared is offered, is a file in the
-- mirror, and opens in this window with the host's own text in it — text only the host's working
-- copy can have supplied. The path that went leaves the listing and the mirror, and takes the
-- directory that became empty with it.
harness.wait('the room to list the path the host created', harness.deadline_ms, function()
  return vim.tbl_contains(selvage.fetchable(), harness.created_path)
end, function()
  return 'listed ' .. vim.inspect(selvage.fetchable())
end)

local mirrored_created = mirror .. '/' .. harness.created_path
harness.wait('the created path to be materialised in the mirror', harness.deadline_ms, function()
  return vim.fn.filereadable(mirrored_created) == 1
end, function()
  return 'the mirror holds ' .. vim.inspect(vim.fn.glob(mirror .. '/*', false, true))
end)
selvage.open(harness.created_path)
harness.wait('the created path to open in the window', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.created_path)
end, function()
  return 'the window holds ' .. vim.inspect(vim.fn.bufname('%'))
end)
harness.wait("the host's text for the created path to arrive", harness.deadline_ms, function()
  return harness.text_of(harness.created_path) == harness.created_text
end, function()
  return vim.inspect(harness.text_of(harness.created_path))
end)
harness.wait("the save that follows it to write the mirror's file", harness.deadline_ms, function()
  -- The room's text for the created path is the bytes the host wrote, which end in a newline; the
  -- mirror's file is that text written out line by line, so it ends in one more.
  return harness.file_text(mirrored_created) == harness.created_text .. '\n'
end, function()
  return vim.inspect(harness.file_text(mirrored_created))
end)
harness.wait('the deleted path to leave the listing', harness.deadline_ms, function()
  return not vim.tbl_contains(selvage.fetchable(), harness.removed_path)
end, function()
  return 'listed ' .. vim.inspect(selvage.fetchable())
end)
harness.wait('the deleted path to go from the mirror', harness.deadline_ms, function()
  return harness.file_text(mirrored_removed) == nil
end, function()
  return vim.inspect(harness.file_text(mirrored_removed))
end)
harness.log('the created path reads', vim.inspect(harness.text_of(harness.created_path)))

harness.record('watch', harness.text_of(harness.created_path), {
  mirrorHoldsCreated = harness.file_text(mirrored_created) == harness.created_text .. '\n',
  listingNamesCreated = vim.tbl_contains(selvage.fetchable(), harness.created_path),
  mirrorHoldsRemoved = harness.file_text(mirrored_removed) ~= nil,
  listingNamesRemoved = vim.tbl_contains(selvage.fetchable(), harness.removed_path),
  deleteOpenBufferValid = vim.api.nvim_buf_is_valid(delete_open_buf),
  deleteOpenTextKept = harness.text_of(harness.removed_path) == harness.removed_text,
  deleteOpenStillOffered = vim.tbl_contains(selvage.offered(), harness.removed_path),
})
harness.write_file(harness.watch_done_file, 'go')
harness.wait_ack('watch', harness.deadline_ms)

-- The host says the marker has landed in its own copy of the file. The guest cannot leave before
-- it has: this window's edit is a message still on its way to the room, and a process that exits
-- takes it with it — which is the same reason phase 1 is acked.
harness.wait_ack('granted', harness.deadline_ms)

-- -- following the host's caret across a remote edit -------------------------------------
--
-- The guest follows the host by peer id, lands where they are, and then tracks them while
-- they edit: the host appends a line and moves its caret onto it, and this window's cursor
-- has to end up on that line — through the room's text arriving and the caret following it.
-- Stopping goes through the indicator's own command. The marker reads the same in both
-- drivers; it is choreography, not product vocabulary.
--
-- The host stages itself in the seed document before signalling: landing where it is only
-- proves anything if where it is stays put until the follow starts.
harness.wait_for_file(
  'the host to stage itself in the seed document',
  harness.deadline_ms,
  harness.ack_file .. '.follow-host-ready'
)
local own_name = vim.env.SELVAGE_DISPLAY_NAME
harness.wait('the host to be drawn in the room', harness.deadline_ms, function()
  for _, peer in ipairs(selvage.peers()) do
    if peer.label ~= own_name and peer.path ~= nil then
      return true
    end
  end
  return false
end, function()
  return vim.inspect(selvage.peers())
end)
local host_peer = nil
for _, peer in ipairs(selvage.peers()) do
  if peer.label ~= own_name then
    host_peer = peer
  end
end
harness.log('following', vim.inspect(host_peer))
selvage.follow(host_peer.peerId)
harness.wait('the landing on the host', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.seed_path)
end, function()
  return 'the window holds ' .. vim.inspect(vim.fn.bufname('%'))
end)
harness.write_file(harness.ack_file .. '.follow-ready', 'go')
local follow_marker = '[[FOLLOW-CARET]]'
harness.wait('the host edit to arrive', harness.deadline_ms, function()
  return harness.contains(follow_marker)
end, harness.observe)
harness.wait('the follow to track the host caret onto the marker line', harness.deadline_ms, function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_buf_get_lines(0, 0, -1, true)[row] == follow_marker
end, function()
  return 'cursor at ' .. vim.inspect(vim.api.nvim_win_get_cursor(0))
end)
if selvage.following() == nil then
  harness.fail('the follow ended while the host moved; the room edit must not end one')
end
local winbar = vim.api.nvim_get_option_value('winbar', { win = 0 })
if winbar == nil or winbar:find('Following ', 1, true) == nil then
  harness.fail(('the indicator is not standing while following; winbar holds %s'):format(vim.inspect(winbar)))
end
harness.log('tracked the host onto', vim.inspect(follow_marker), 'under', vim.inspect(winbar))
vim.cmd('SelvageStopFollowing')
if selvage.following() ~= nil then
  harness.fail('stopping through the command left the follow standing')
end
harness.record('follow', vim.inspect(vim.api.nvim_win_get_cursor(0)), {
  tracked = true,
  stopped = true,
})
harness.wait_ack('follow', harness.deadline_ms)
harness.write_file(harness.ack_file .. '.follow-done', 'go')

if harness.control_file ~= nil then
  -- The blip is a real TCP close on this client's own socket, and the row is where a person
  -- would see it: the connection is being re-established, and a session that says nothing while
  -- its socket is gone is the silence the row exists to end. The engine retries on its own and
  -- a seat is what says the room is back, so the word is sampled on the poll this wait already
  -- runs (every 50 ms, against a 500 ms retry: the window is not a race) and the control file is
  -- what says the blip is over.
  local saw_reconnecting = false
  harness.wait(
    'the orchestrator to signal the network blip is over',
    harness.reconnect_deadline_ms,
    function()
      if
        not saw_reconnecting
        and vim.api.nvim_get_option_value('winbar', { win = 0 }):find('Selvage: reconnecting…', 1, true)
          ~= nil
      then
        saw_reconnecting = true
        harness.log('the window said the connection was being re-established')
      end
      return harness.read_file(harness.control_file) ~= nil
    end,
    function()
      return 'the window holds ' .. vim.inspect(vim.api.nvim_get_option_value('winbar', { win = 0 }))
    end
  )
  if not saw_reconnecting then
    harness.fail('the dropped socket was never said on the window; the reconnect was invisible')
  end
  harness.wait('the window to name the session again after the blip', harness.reconnect_deadline_ms, function()
    return vim.api.nvim_get_option_value('winbar', { win = 0 }):find('Selvage: guest — ', 1, true) ~= nil
  end, function()
    return 'the window holds ' .. vim.inspect(vim.api.nvim_get_option_value('winbar', { win = 0 }))
  end)
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { harness.markers.guest2 })
  harness.log('made the second guest edit')
  harness.wait('the host edit made after the blip', harness.reconnect_deadline_ms, function()
    return harness.contains(harness.markers.host2)
  end, harness.observe)
  harness.record('phase2', harness.text())
  harness.log('phase 2 converged:', vim.inspect(harness.text()))
  harness.wait_ack('phase2', harness.reconnect_deadline_ms)
end

selvage.leave()
vim.wait(500)
harness.done()
