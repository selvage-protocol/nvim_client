-- The hosting half of the `selvage/2` proof. Run by `test/e2e/run-version-2.ts`:
--
--   nvim --headless -l test/e2e/host2.lua
--
-- A real Neovim, the real plugin, a real companion process, a real `selvaged --serve-version-2`
-- and, on the far side, a second Neovim. It hosts at version 2 because `vim.g.selvage_wire_version`
-- says so, hands the invite on through a file, and then makes and waits for edits with bounded
-- deadlines — the two directions the version's own handshake is what makes possible.
--
-- It needs none of the version-1 driver's phases: no grant, no mirror, no reconnect. What is being
-- proved is the version, and a phase that is not about the version would be a second proof with the
-- first one's evidence.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'host'
harness.result_file = assert(vim.env.SELVAGE_E2E_RESULT_FILE)
harness.invite_file = assert(vim.env.SELVAGE_E2E_INVITE_FILE)
harness.deadline_ms = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '20000')
harness.seed_path = assert(vim.env.SELVAGE_E2E_SEED_PATH)
harness.markers = {
  host = assert(vim.env.SELVAGE_E2E_MARKER_HOST),
  guest = assert(vim.env.SELVAGE_E2E_MARKER_GUEST),
}
harness.outcome = { role = 'host' }

local selvage = harness.load_plugin()

vim.g.selvage_wire_version = '2'
vim.cmd('edit ' .. vim.fn.fnameescape(harness.seed_path))
local bufnr = vim.api.nvim_get_current_buf()
harness.log('opened', harness.seed_path, 'as buffer', bufnr, 'hosting at selvage/2')

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

-- §13.4: the role a connection has in a version-2 room is the room state's word about its key, and
-- the state is what the host itself signed. Reading it here is what makes the rest of this driver
-- about a room rather than about a socket that happened to open.
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
harness.done()
