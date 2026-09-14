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
  return vim.fn.bufname('%') == 'selvage://' .. harness.seed_path
end, function()
  return vim.inspect(selvage.session())
end)

local bufnr = vim.api.nvim_get_current_buf()
harness.log('the buffer exists and holds', vim.inspect(harness.text()))
if harness.text() ~= '\n' then
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

bufnr = vim.fn.bufnr('selvage://' .. harness.seed_path)
if bufnr == -1 then
  harness.fail('the room document did not open as a buffer')
end

harness.write_file(harness.joined_file, 'joined')

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
  local bufnr = vim.fn.bufnr('selvage://' .. harness.seed_path)
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

-- The caret is *at* the host's position: a block on the host's own line, not a row of its own
-- above it. The host selected the marker it wrote, so the caret's byte column is that marker's
-- length — the end of the line, where there is no cell to fill and the block is the one drawn
-- after the text. The mark is the host's because the bridge withholds a cursor for the local
-- peer and because its sign is the host's own name; a caret published as soon as the buffer was
-- shared, before the host moved, would carry the same sign but sit at the column the insert left
-- behind, which is why the wait is for the marker's column and not for any caret at all.
local function host_caret()
  local label = vim.env.SELVAGE_E2E_HOST_DISPLAY_NAME or vim.env.USER or 'neovim'
  for _, mark in ipairs(presence_marks()) do
    if mark[2] == 0 and mark[3] == #harness.markers.host then
      local text = mark[4].virt_text
      local sign = mark[4].sign_text
      local block = text ~= nil and text[1] ~= nil and mark[4].virt_text_pos ~= nil and #text[1][1] == 1
      local mine = sign ~= nil and label:sub(1, #sign) == sign
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
-- start to the host caret's column.
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
