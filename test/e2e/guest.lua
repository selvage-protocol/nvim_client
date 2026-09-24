-- The joining half of the two-instance proof. Run by `test/e2e/run.ts`:
--
--   nvim --headless -l test/e2e/guest.lua
--
-- A real Neovim, the real plugin, a real companion process and a real `selvaged`. It joins the link
-- the host wrote — the page link with `§5.1`'s fragment on it — waits for the room's text, edits,
-- and waits for the host's own edit in return.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'guest'
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
harness.granted_path = assert(vim.env.SELVAGE_E2E_GRANTED_PATH)
harness.granted_text = assert(vim.env.SELVAGE_E2E_GRANTED_TEXT)
harness.reconnect_deadline_ms = tonumber(vim.env.SELVAGE_E2E_RECONNECT_DEADLINE_MS or '60000')
harness.control_file = vim.env.SELVAGE_E2E_CONTROL_FILE
harness.outcome = { role = 'guest' }

local selvage = harness.load_plugin()

local invite = harness.wait_for_file('the host to hand on its invite', harness.deadline_ms, harness.invite_file)
harness.log('the host is inviting with', invite)

-- The reconnect phase routes this side through a relay the orchestrator can cut, so that the
-- socket that dies is this one and the host's connection and the room are untouched.
local proxy = vim.env.SELVAGE_E2E_PROXY_ADDR
if proxy ~= nil and proxy ~= '' then
  invite = invite:gsub('^(https?://)[^/]+', '%1' .. proxy)
  harness.log('routing through the relay at', proxy)
end

selvage.join(invite)

-- The listing and the role arrive in the state the host signed; the text arrives through the
-- hold this connection takes on the document and the sync that answers it. Waiting for the text
-- is waiting for all three, because none of them is a thing this side can be told without the
-- others.
harness.wait('the room\'s text to arrive', harness.deadline_ms, function()
  local text = harness.text()
  return text ~= nil and text ~= ''
end, harness.observe)

-- §5.1: the fragment carries the room key and the host key, and it is read before a socket is
-- opened. A room seats no connection that cannot read it, so a join that reached this line reached
-- it with both keys.
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

-- -- a path the room lists and nobody has opened ---------------------------------------------
--
-- The room's grant is a listing and never content: this path is offered and no buffer of this
-- window exists for it, so it is not among the documents this session holds. It is opened the way
-- a person opens it, through `:SelvageOpen`'s own path, and what arrives can only be the host's
-- working copy — the host never opened the file, and the room asked for it because this editor
-- did. The hold this window takes is the ask; the host's read is the answer.
harness.wait('the room to offer the path the host never opened', harness.deadline_ms, function()
  return vim.tbl_contains(selvage.offered(), harness.granted_path)
end, function()
  return ('offered %s; held %s'):format(vim.inspect(selvage.offered()), vim.inspect(selvage.documents()))
end)

for _, path in ipairs(selvage.documents()) do
  if path == harness.granted_path then
    harness.fail('the granted path was already held before anyone opened it')
  end
end

selvage.open(harness.granted_path)
harness.wait('the granted path to open in the window', harness.deadline_ms, function()
  return vim.fn.bufname('%') == harness.buffer_name(harness.granted_path)
end, function()
  return 'the window holds ' .. vim.inspect(vim.fn.bufname('%'))
end)
local granted_buf = vim.api.nvim_get_current_buf()

-- Waited for as the host's own bytes: nothing this driver knows is in the buffer, and an empty
-- buffer is exactly what the read is here to rule out.
harness.wait("the host's text for the granted path to arrive", harness.deadline_ms, function()
  return harness.text_of(harness.granted_path) == harness.granted_text
end, function()
  return vim.inspect(harness.text_of(harness.granted_path))
end)
harness.log('the granted path holds', vim.inspect(harness.text_of(harness.granted_path)))

-- The guest writes into it, so the host's copy of a file it never opened becomes something this
-- window wrote. The room's text for a path off the host's disk is the file's own bytes, which end
-- in a newline, so this buffer's last line is empty and the file's final newline *is* that line:
-- replacing it is the edit whose range ends past the end of the room's text.
vim.api.nvim_buf_set_lines(granted_buf, -2, -1, true, { harness.markers.granted })
harness.wait('the guest marker to land in the granted document', harness.deadline_ms, function()
  return harness.text_of(harness.granted_path) == harness.granted_text .. harness.markers.granted
end, function()
  return vim.inspect(harness.text_of(harness.granted_path))
end)
harness.record('granted', harness.text_of(harness.granted_path))
harness.write_file(vim.env.SELVAGE_E2E_GRANTED_DONE_FILE, 'go')
harness.log('the granted path reads', vim.inspect(harness.text_of(harness.granted_path)))

-- The marker is a message still on its way to the room, and the host cannot say it has taken it
-- until it arrives: waiting for that answer is what makes the read a fact about the host and not
-- about this window's own replica.
harness.wait_for_file(
  'the host to take the marker into the granted path',
  harness.deadline_ms + 20000,
  vim.env.SELVAGE_E2E_GRANTED_ACK_FILE
)

-- -- the socket is cut and comes back ----------------------------------------------------------
--
-- The blip is a real TCP close on this client's own socket, and the row is where a person would
-- see it: the connection is being re-established, and a session that says nothing while its
-- socket is gone is the silence the row exists to end. The engine retries on its own and a seat
-- is what says the room is back, so the word is sampled on the poll this wait already runs
-- (every 50ms, against a 500ms retry: the window is not a race) and the control file is what says
-- the blip is over.
if harness.control_file ~= nil then
  local saw_reconnecting = false
  harness.wait(
    'the orchestrator to signal the network blip is over',
    harness.reconnect_deadline_ms,
    function()
      if not saw_reconnecting and harness.row():find('Selvage: reconnecting…', 1, true) ~= nil then
        saw_reconnecting = true
        harness.log('the window said the connection was being re-established')
      end
      return harness.read_file(harness.control_file) ~= nil
    end,
    function()
      return 'the window holds ' .. vim.inspect(harness.row())
    end
  )
  if not saw_reconnecting then
    harness.fail('the dropped socket was never said on the window; the reconnect was invisible')
  end
  harness.wait('the window to name the session again after the blip', harness.reconnect_deadline_ms, function()
    return harness.row():find('Selvage: guest — ', 1, true) ~= nil
  end, function()
    return 'the window holds ' .. vim.inspect(harness.row())
  end)
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { harness.markers.guest2 })
  harness.log('made the second guest edit')
  harness.wait('the host edit made after the blip', harness.reconnect_deadline_ms, function()
    return harness.contains(harness.markers.host2)
  end, harness.observe)
  harness.record('phase2', harness.text())
  harness.log('phase 2 converged:', vim.inspect(harness.text()))
  harness.wait_for_file(
    'the host to hold the second guest edit',
    harness.reconnect_deadline_ms,
    vim.env.SELVAGE_E2E_PHASE2_ACK_FILE
  )
end

-- The host waits for this before it leaves: a host that goes takes the room with it, and the
-- phases above are this side's to finish.
harness.write_file(vim.env.SELVAGE_E2E_GUEST_DONE_FILE, 'go')

selvage.leave()
vim.wait(500)
harness.done()
