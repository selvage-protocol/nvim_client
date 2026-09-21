#!/usr/bin/env bash
#
# The Lua side's own checks, in a real headless Neovim: the buffer arithmetic against a real
# buffer and a real `on_bytes` (`test/lua/document.lua`), the plugin's own wiring against a
# stubbed companion (`test/lua/session.lua`), the folder a session shares and what moves it
# (`test/lua/grant.lua`), the room's grant listing and `:SelvageOpen` over it
# (`test/lua/granted.lua`), the guest's mirror of that listing (`test/lua/mirror.lua`), the one
# summary a guest's join says whatever order the room speaks in (`test/lua/join.lua` for the
# listing-first order, `test/lua/joinorder.lua` for documents first), what the
# commands themselves decide (`test/lua/commands.lua`), the words the two clients share
# (`test/lua/vocabulary.lua`), what starting it suppresses (`test/lua/warnings.lua`), and what
# stopping the process does to it (`test/lua/leave.lua`,
# against a real job), and going to a participant and following one (`test/lua/follow.lua`),
# and the pickers asking through `vim.ui.select` with no external picker required
# (`test/lua/pickers.lua`), and the plugin as the package it is installed as — the real
# companion process started from it, with nothing stubbed (`test/lua/installed.lua`).
#
#   scripts/test-lua.sh
#
# Not part of the workflow: it needs a Neovim, and the runner has none. `npm test` covers the
# companion, which is where every rule lives. The last file also needs `npm ci` to have run, the
# same as running the plugin itself does.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

nvim --headless -l test/lua/document.lua
nvim --headless -l test/lua/session.lua
nvim --headless -l test/lua/grant.lua
nvim --headless -l test/lua/granted.lua
nvim --headless -l test/lua/mirror.lua
nvim --headless -l test/lua/join.lua
nvim --headless -l test/lua/joinorder.lua
nvim --headless -l test/lua/pickers.lua
nvim --headless -l test/lua/commands.lua
nvim --headless -l test/lua/vocabulary.lua
nvim --headless -l test/lua/warnings.lua
nvim --headless -l test/lua/leave.lua
nvim --headless -l test/lua/follow.lua
# The checkout as the installed plugin, which is what `SELVAGE_PLUGIN_ROOT` names: the file
# asserts that it is what Neovim loaded before it starts the companion for real.
SELVAGE_PLUGIN_ROOT="$repo_root" nvim --headless -l test/lua/installed.lua
