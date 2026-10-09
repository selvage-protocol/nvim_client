-- The joining half of the README's screenshot, run by `test/screenshots/capture.ts` as a real but
-- headless Neovim on the room's own invite. It joins, waits for the room's first document to land
-- in its window, selects the line the screenshot is about, and holds both the selection and the
-- process until the capture is done — a selection is published from the mode this window is in, so
-- leaving Visual would take it off the host's screen.
--
-- The selection is found in the text rather than written here as a line and column: what the
-- screenshot shows is the project's own code, and a project that moves takes the selection with it.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'guest'
harness.result_file = assert(vim.env.SELVAGE_E2E_RESULT_FILE)
harness.deadline_ms = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '30000')
harness.seed_path = assert(vim.env.SELVAGE_E2E_SEED_PATH)
harness.outcome = { role = 'guest' }

-- The name the room is told, so that the host draws `Gr` in her gutter rather than a peer id.
vim.g.selvage_display_name = 'Grace'

local selvage = harness.load_plugin()

--- The first row and byte column holding `text`, as the buffer reads.
local function find_text(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, true)) do
    local start = line:find(text, 1, true)
    if start ~= nil then
      return row, start - 1
    end
  end
  harness.fail(('the open file holds no %s'):format(vim.inspect(text)))
end

local invite = harness.wait_for_file(
  'the host to hand on its invite',
  harness.deadline_ms,
  assert(vim.env.SELVAGE_E2E_INVITE_FILE)
)
selvage.join(invite)
harness.log('joining', invite)

harness.wait("the room's text to arrive", harness.deadline_ms, function()
  local text = harness.text()
  return text ~= nil and text ~= ''
end, harness.observe)
harness.log('the room holds', vim.inspect(harness.text()))

harness.wait('the mirror to be materialised', harness.deadline_ms, function()
  return selvage.session().mirror ~= nil
end, function()
  return vim.inspect(selvage.session())
end)

-- The room's first document lands in this window by itself when the join names it, which is the
-- same landing a person sees. What this waits for is that landing — the buffer the window is on
-- being the room's own copy of the file — rather than opening it again: a second `:edit` of the
-- same path is refused as a change to a modified buffer, and presence is published for the buffer
-- a person is looking at, so the window has to be on the room's copy for the host to draw her.
local mirrored = harness.buffer_name(harness.seed_path)
harness.wait('the landed document to be this window', harness.deadline_ms, function()
  return vim.fn.bufname('%') == mirrored
end, function()
  return vim.fn.bufname('%')
end)
harness.wait('the landed document to hold the room text', harness.deadline_ms, function()
  local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), '\n')
  return lines == harness.text()
end, function()
  return vim.inspect(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), '\n'))
end)

-- Grace selects the line the screenshot is about, left to right, and stays in Visual mode: the
-- host's fill covers `[anchor, head)` and her block sits on the last selected character.
local selected = assert(vim.env.SELVAGE_SHOT_GUEST_SELECTS)
local row, col = find_text(selected)
vim.api.nvim_win_set_cursor(0, { row, col })
vim.cmd('normal! v')
vim.api.nvim_win_set_cursor(0, { row, col + #selected - 1 })
harness.log(('selecting %s at %d,%d'):format(vim.inspect(selected), row, col))

harness.write_file(assert(vim.env.SELVAGE_SHOT_READY_FILE), 'selected')
harness.record('staged', harness.text(), { invite = invite, selection = selected })

harness.wait_for_file(
  'the capture to be done',
  tonumber(vim.env.SELVAGE_SHOT_HOLD_MS or '600000'),
  assert(vim.env.SELVAGE_SHOT_DONE_FILE)
)
harness.log('the capture is done')
harness.done()
