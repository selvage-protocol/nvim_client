-- Whether this editor has anyone to ask.
--
-- A question is a `vim.ui.input` box or a `vim.fn.confirm` dialog, and a Neovim with no UI — a
-- headless run, an `--embed` session a test drives — has nobody to answer one. A question that has
-- nowhere to go is said as a notification instead, so this is what tells the two apart: the input
-- function is the one that stood when the plugin loaded, and a test that stubs `vim.ui.input`
-- afterwards is not mistaken for a person who can answer.
local api = vim.api


local M = {}

--- The `vim.ui.input` the plugin was loaded with. A replaced one — a GUI prompt, another
--- plugin — is a prompt mechanism of its own, so it counts as somewhere to ask even where no
--- UI is attached; the built-in reads the terminal, which a headless process does not have.
local builtin_input = vim.ui.input

--- Whether there is anyone to answer a prompt.
local function can_prompt()
  return #api.nvim_list_uis() > 0 or vim.ui.input ~= builtin_input
end


M.can_prompt = can_prompt

return M
