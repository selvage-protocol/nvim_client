-- The hosting half of the two-instance proof. Run by `test/e2e/run.ts`:
--
--   nvim --headless -l test/e2e/host.lua
--
-- A real Neovim, the real plugin, a real companion process, a real `selvaged`, and on the far side
-- a second Neovim. It mints the room, hands the link on through a file, and then makes and waits
-- for edits with bounded deadlines — the two directions the room's own handshake is what makes
-- possible.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'host'
harness.result_file = assert(vim.env.SELVAGE_E2E_RESULT_FILE)
harness.invite_file = assert(vim.env.SELVAGE_E2E_INVITE_FILE)
harness.deadline_ms = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '20000')
harness.seed_path = assert(vim.env.SELVAGE_E2E_SEED_PATH)
harness.markers = {
  host = assert(vim.env.SELVAGE_E2E_MARKER_HOST),
  guest = assert(vim.env.SELVAGE_E2E_MARKER_GUEST),
  host2 = assert(vim.env.SELVAGE_E2E_MARKER_HOST_2),
  guest2 = assert(vim.env.SELVAGE_E2E_MARKER_GUEST_2),
  granted = assert(vim.env.SELVAGE_E2E_MARKER_GRANTED),
}
--- The path the orchestrator wrote into this window's own folder before the session started and
--- nothing here opens until the guest has read it: a name in the listing and never content until
--- somebody asks, which is the whole of what this phase is about.
harness.granted_path = assert(vim.env.SELVAGE_E2E_GRANTED_PATH)
harness.reconnect_deadline_ms = tonumber(vim.env.SELVAGE_E2E_RECONNECT_DEADLINE_MS or '60000')
--- Written by the orchestrator once the network blip is over; the reconnect phase runs only
--- when this run has a relay to cut.
harness.control_file = vim.env.SELVAGE_E2E_CONTROL_FILE
harness.outcome = { role = 'host' }

local selvage = harness.load_plugin()

vim.cmd('edit ' .. vim.fn.fnameescape(harness.seed_path))
local bufnr = vim.api.nvim_get_current_buf()
harness.log('opened', harness.seed_path, 'as buffer', bufnr)

selvage.host(harness.env.required('SELVAGE_E2E_SERVER_URL'))

harness.wait('the room to be minted', harness.deadline_ms, function()
  return selvage.session().invite ~= nil
end, function()
  return vim.inspect(selvage.session())
end)

-- The connection's own invite is `§5.1`'s wire form, and the link a person is handed is the page
-- link its origin serves with the same fragment on it. `:SelvageCopyInvite` is what a host does
-- with it, so it is what this driver does: the guest joins the link the host would have pasted.
local invite = selvage.session().invite
harness.log('the connection holds', invite)
selvage.copy_invite()
local link = vim.fn.getreg('"')
harness.log('the page link it hands on:', link)
harness.write_file(harness.invite_file, link)

-- §13.4: the role a connection has is the room state's word about its key, and the state is what
-- the host itself signed. Reading it here is what makes the rest of this driver about a room rather
-- than about a socket that happened to open.
harness.wait('the session to read its own role from the state it published', harness.deadline_ms, function()
  return selvage.session().role == 'host'
end, function()
  return vim.inspect(selvage.session())
end)

harness.wait_for_file('the guest to report it has joined', harness.deadline_ms, vim.env.SELVAGE_E2E_JOINED_FILE)

vim.api.nvim_buf_set_lines(bufnr, 0, 0, true, { harness.markers.host })
harness.log('made the host edit; buffer now', vim.inspect(harness.text()))

harness.wait('the guest edit to arrive', harness.deadline_ms, function()
  return harness.contains(harness.markers.guest)
end, harness.observe)

-- The room's text is the file's here: writing it is what makes the guest's edit a saved file
-- rather than a buffer that happened to agree, which is the claim a guest's edit has to earn.
vim.cmd('write')
harness.log('wrote', harness.seed_path, 'holding', vim.inspect(harness.file_text(harness.seed_path)))

-- The guest's own edit is a message on its way to the room until this side has it. The guest
-- cannot leave before that — a process that exits takes its unsent frame with it — so the one
-- thing this side has to say to the other is that it has arrived.
harness.write_file(vim.env.SELVAGE_E2E_GUEST_ACK_FILE, 'seen')

harness.record('edit', harness.text(), {
  invite = invite,
  link = link,
  role = selvage.session().role,
})

-- -- a file this window never opened -------------------------------------------------------
--
-- `granted/never-opened.txt` is in the folder this session shares and in no buffer of this
-- window: the guest opens it, which is a hold the room carries, and the path is a name and
-- nothing else until this side reads it. That read is the bridge's own (`seedRequested`), and
-- what it finds in the guest's copy can only be this file's bytes.
harness.wait_for_file(
  'the guest to read the path this window never opened',
  harness.deadline_ms + 20000,
  vim.env.SELVAGE_E2E_GRANTED_DONE_FILE
)
local held_before = vim.tbl_contains(selvage.documents(), harness.granted_path)
harness.log('the granted path was open in this window before now:', held_before)
vim.cmd('edit ' .. vim.fn.fnameescape(harness.granted_path))
harness.wait('the guest marker to arrive in the granted path', harness.deadline_ms, function()
  local text = harness.text_of(harness.granted_path)
  return text ~= nil and text:find(harness.markers.granted, 1, true) ~= nil
end, function()
  return vim.inspect(harness.text_of(harness.granted_path))
end)
harness.record('granted', harness.text_of(harness.granted_path), { heldBeforeGuest = held_before })
harness.write_file(vim.env.SELVAGE_E2E_GRANTED_ACK_FILE, 'seen')
harness.log('the granted path reads', vim.inspect(harness.text_of(harness.granted_path)))

-- -- the guest's socket is cut and comes back ------------------------------------------------
--
-- The blip is a real TCP close on the guest's own socket, through the relay the orchestrator
-- put in its path; this window's connection and the room are untouched. The guest is the side
-- that has to re-establish, and what is proved here is that both windows end on the same text
-- after it does — the room's own handshake is what makes the second edit possible at all.
if harness.control_file ~= nil then
  harness.wait_for_file(
    'the orchestrator to signal the network blip is over',
    harness.reconnect_deadline_ms,
    harness.control_file
  )
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, true, { harness.markers.host2 })
  harness.log('made the second host edit')
  harness.wait('the guest edit made after the blip', harness.reconnect_deadline_ms, function()
    return harness.contains(harness.markers.guest2)
  end, harness.observe)
  harness.record('phase2', harness.text())
  harness.write_file(vim.env.SELVAGE_E2E_PHASE2_ACK_FILE, 'seen')
  harness.log('phase 2 converged:', vim.inspect(harness.text()))
end

-- The guest's side of every phase above is a message on its way to the room until this window
-- has it, and a process that exits takes its unsent frame with it. The guest says it is done
-- before it goes, so that its leave is the last thing that happens here.
harness.wait_for_file(
  'the guest to say it is done',
  harness.deadline_ms + 20000,
  vim.env.SELVAGE_E2E_GUEST_DONE_FILE
)

selvage.leave()
vim.wait(500)
harness.done()
