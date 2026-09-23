-- The joining half of the `selvage/2` proof. Run by `test/e2e/run-version-2.ts`:
--
--   nvim --headless -l test/e2e/guest2.lua
--
-- A real Neovim, the real plugin, a real companion process and a real `selvaged` on its
-- defaults, which seat both versions. It joins the link the host wrote — the page link with
-- `§5.1`'s fragment on it — waits for the room's text, edits, and waits for the host's own edit in
-- return.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'guest'
harness.result_file = assert(vim.env.SELVAGE_E2E_RESULT_FILE)
harness.invite_file = assert(vim.env.SELVAGE_E2E_INVITE_FILE)
harness.deadline_ms = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '20000')
harness.seed_path = assert(vim.env.SELVAGE_E2E_SEED_PATH)
harness.markers = {
  host = assert(vim.env.SELVAGE_E2E_MARKER_HOST),
  guest = assert(vim.env.SELVAGE_E2E_MARKER_GUEST),
}
harness.outcome = { role = 'guest' }

local selvage = harness.load_plugin()

local invite = harness.wait_for_file('the host to hand on its invite', harness.deadline_ms, harness.invite_file)
harness.log('the host is inviting with', invite)

selvage.join(invite)

-- The listing and the role arrive in the state the host signed; the text arrives through the
-- hold this connection takes on the document and the sync that answers it. Waiting for the text
-- is waiting for all three, because none of them is a thing this side can be told without the
-- others.
harness.wait('the room\'s text to arrive', harness.deadline_ms, function()
  local text = harness.text()
  return text ~= nil and text ~= ''
end, harness.observe)

-- §5.1: the fragment is what makes this a `selvage/2` join at all, and it is read before a socket
-- is opened. A room pinned to the version seats no connection that cannot read it, so a join that
-- reached this line reached it as a version-2 connection.
local role = selvage.session().role
harness.log('joined as', role, 'holding', vim.inspect(harness.text()))

harness.write_file(vim.env.SELVAGE_E2E_JOINED_FILE, 'joined')

-- The host's edit is made after this file, so what arrives here is a live edit and not part of the
-- seed: this is the host -> guest direction.
harness.wait('the host edit to arrive', harness.deadline_ms, function()
  return harness.contains(harness.markers.host)
end, harness.observe)

-- The guest's own edit: it publishes only once a state commits its key (§13.1's step 4), which is
-- the host's answer to this connection's announcement — the guest -> host direction.
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, #vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), -1, true, {
  harness.markers.guest,
})
harness.log('made the guest edit; buffer now', vim.inspect(harness.text()))

-- A local edit is a frame on its way to the room, and leaving takes an unsent one with it: this
-- waits for the host to say it holds the edit before this process ends, which is what makes the
-- guest -> host direction something this run observed rather than something it hoped for.
harness.wait_for_file('the host to hold the guest edit', harness.deadline_ms, vim.env.SELVAGE_E2E_GUEST_ACK_FILE)

harness.record('edit', harness.text(), { invite = invite, link = invite, role = role })
harness.done()
