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

harness.wait('the room document to arrive', harness.deadline_ms, function()
  local text = harness.text()
  return text ~= nil and text ~= '\n'
end, function()
  return vim.inspect(selvage.session())
end)
harness.log('joined with', vim.inspect(harness.text()))

local bufnr = vim.fn.bufnr('selvage://' .. harness.seed_path)
if bufnr == -1 then
  harness.fail('the room document did not open as a buffer')
end

harness.write_file(harness.joined_file, 'joined')

harness.wait('the host edit to arrive', harness.deadline_ms, function()
  return harness.contains(harness.markers.host)
end, harness.observe)

vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { harness.markers.guest })
harness.log('made the guest edit; buffer now', vim.inspect(harness.text()))

harness.wait('both edits to be in this buffer', harness.deadline_ms, function()
  return harness.contains(harness.markers.host) and harness.contains(harness.markers.guest)
end, harness.observe)

harness.record('phase1', harness.text())
harness.log('phase 1 converged:', vim.inspect(harness.text()))
harness.wait_ack('phase1', harness.deadline_ms)

if harness.control_file ~= nil then
  harness.wait_for_file(
    'the orchestrator to signal the network blip is over',
    harness.reconnect_deadline_ms,
    harness.control_file
  )
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
