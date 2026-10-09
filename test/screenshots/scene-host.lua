-- The hosting half of the README's screenshot, run by `test/screenshots/capture.ts` in a real,
-- visible Neovim (`kitty -- nvim -c luafile <this>`) on a real `selvaged`. It opens the project's
-- own file, hosts the session, hands the invite on through a file, and holds the window while the
-- display is captured.
--
-- What this side waits for before it says it is ready is what the drawing itself reads: the guest's
-- row in `require('selvage').peers()`, with the two cells the gutter shows for her, and her caret's
-- and her selection's marks in the presence namespace. Those are the block, the fill and the sign
-- the picture is of, so a screenshot taken after them says the drawing is there rather than that the
-- guest merely connected.

local harness = dofile(vim.env.SELVAGE_E2E_PLUGIN_ROOT .. '/test/e2e/harness.lua')
harness.role = 'host'
harness.result_file = assert(vim.env.SELVAGE_E2E_RESULT_FILE)
harness.deadline_ms = tonumber(vim.env.SELVAGE_E2E_DEADLINE_MS or '30000')
harness.seed_path = assert(vim.env.SELVAGE_E2E_SEED_PATH)
harness.outcome = { role = 'host' }

-- A visible Neovim prints to its own screen, which is what the picture is of and not something a
-- failed run can be read from: what the harness logs goes to a file instead, beside the guest's.
io.stdout = assert(io.open(assert(vim.env.SELVAGE_SHOT_LOG), 'a'))

-- The name the room is told, so that no question has to be answered by nobody.
vim.g.selvage_display_name = 'Ada'

local selvage = harness.load_plugin()

-- A line-number column, because that is what a reader's own Neovim has, and the project opens
-- under its folder so no path of the machine taking the picture is in the window.
--
-- Truecolor, because the colours this client draws with — a peer's caret, their selection, the
-- faces on the session bar — are hex values the bridge derived, and a stock Neovim leaves
-- `'termguicolors'` off, where a highlight carrying only those values draws as nothing at all.
vim.opt.number = true
vim.opt.termguicolors = true
vim.cmd('edit ' .. vim.fn.fnameescape(harness.seed_path))
harness.log('opened', harness.seed_path)

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

-- Ada's own caret, where it sits in the screenshot, found in the text rather than written here as
-- a line number so that the project moving takes the caret with it. The guest selects elsewhere in
-- the same function, so both ends of the room are in one frame.
local at_row, at_col = find_text(assert(vim.env.SELVAGE_SHOT_HOST_AT))
vim.api.nvim_win_set_cursor(0, { at_row, at_col })
-- Centred rather than at the top of the file: the guest's selection is a few lines below this
-- window's own caret, and a view that starts at line one leaves the room's own drawing off screen.
vim.cmd('normal! zz')

selvage.host(vim.env.SELVAGE_E2E_SERVER_URL)
harness.wait('the room to be minted', harness.deadline_ms, function()
  return selvage.session().invite ~= nil
end, function()
  return vim.inspect(selvage.session())
end)
local invite = selvage.session().invite
harness.write_file(assert(vim.env.SELVAGE_E2E_INVITE_FILE), invite)
harness.log('hosting; the invite is in', vim.env.SELVAGE_E2E_INVITE_FILE)

--- The marks the drawing left in this window's buffer, read back through the very namespace it
--- wrote them into: the caret's sign and block and, when the room's report carries a range, the
--- selection's fill. This is what the picture shows, so it is what the picture waits for.
local function presence_marks()
  local namespace = vim.api.nvim_get_namespaces()['selvage.presence']
  if namespace == nil then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
end

--- The guest's row as the drawing reads it: in this document, with the two cells her name is cut
--- to, and with both marks on screen — the caret's and the selection's.
local function guest_drawn()
  local drawn = nil
  for _, peer in ipairs(selvage.peers()) do
    if peer.label == 'Grace' and peer.path == harness.seed_path and peer.sign == 'Gr' then
      drawn = peer
    end
  end
  if drawn == nil then
    return false
  end
  local caret, fill = 0, 0
  for _, mark in ipairs(presence_marks()) do
    local details = mark[4] or {}
    if details.sign_text ~= nil then
      caret = caret + 1
    else
      fill = fill + 1
    end
  end
  return caret == 1 and fill == 1 and { peer = drawn, caret = caret, fill = fill }
end

harness.wait('the guest to be drawn in this file', harness.deadline_ms, guest_drawn, function()
  return ('%s with %s'):format(vim.inspect(selvage.peers()), vim.inspect(presence_marks()))
end)

-- The message line is the last thing this window said to itself; a screenshot of a session is not
-- the place for it.
vim.api.nvim_echo({}, false, {})
vim.cmd('redraw!')
harness.record('staged', harness.text(), {
  invite = invite,
  role = selvage.session().role,
  peers = selvage.peers(),
  marks = presence_marks(),
})
harness.write_file(assert(vim.env.SELVAGE_SHOT_STAGED_FILE), 'staged')
harness.log('staged; holding for the capture')

harness.wait_for_file(
  'the capture to be done',
  tonumber(vim.env.SELVAGE_SHOT_HOLD_MS or '600000'),
  assert(vim.env.SELVAGE_SHOT_DONE_FILE)
)
harness.log('the capture is done')
harness.done()
