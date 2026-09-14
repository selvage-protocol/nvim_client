-- The hosting half of the two-instance proof. Run by `test/e2e/run.ts`:
--
--   nvim --headless -l test/e2e/host.lua
--
-- A real Neovim, the real plugin, a real companion process and a real `selvaged`. It opens a
-- real file, hosts it, hands the invite to the guest through a file, and then makes and waits
-- for edits with bounded deadlines.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.setup('host')

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

local invite = selvage.session().invite
harness.log('invite:', invite)
harness.write_file(harness.invite_file, invite)

-- The host's edit has to happen after the guest is in the room, or it would arrive as part of
-- the seed rather than as a live edit and prove nothing about the host -> guest direction.
harness.wait_for_file('the guest to report it has joined', harness.deadline_ms, harness.joined_file)

vim.api.nvim_buf_set_lines(bufnr, 0, 0, true, { harness.markers.host })
harness.log('made the host edit; buffer now', vim.inspect(harness.text()))
-- A caret and a selection for the guest to see. Where either is only reaches the room through
-- the events that move the caret, and a headless Neovim moves nothing on its own, so the
-- events are made the way keystrokes would. The selection is over the marker this driver just
-- wrote, which is the text the guest waits for before it looks.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('normal! v')
vim.api.nvim_win_set_cursor(0, { 1, #harness.markers.host })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })
vim.api.nvim_exec_autocmds('ModeChanged', { buffer = bufnr })

harness.wait('the guest edit to arrive', harness.deadline_ms, function()
  return harness.contains(harness.markers.guest)
end, harness.observe)

harness.record('phase1', harness.text())
harness.ack('phase1')
harness.log('phase 1 converged:', vim.inspect(harness.text()))

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
  harness.ack('phase2')
  harness.log('phase 2 converged:', vim.inspect(harness.text()))
end

selvage.leave()
vim.wait(500)
harness.done()
