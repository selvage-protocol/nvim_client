#!/usr/bin/env bash
#
# The Lua side's own checks, in a real headless Neovim: the buffer arithmetic against a real
# buffer and a real `on_bytes` (`test/lua/document.lua`), the plugin's own wiring against a
# stubbed companion (`test/lua/session.lua`), the folder a session shares and what moves it
# (`test/lua/grant.lua`), the room's grant listing and `:SelvageOpen` over it
# (`test/lua/granted.lua`), the guest's mirror of that listing (`test/lua/mirror.lua`), what the
# commands themselves decide (`test/lua/commands.lua`), the words the two clients share
# (`test/lua/vocabulary.lua`), what starting it suppresses (`test/lua/warnings.lua`), and what
# stopping the process does to it (`test/lua/leave.lua`,
# against a real job).
#
#   scripts/test-lua.sh
#
# Not part of the workflow: it needs a Neovim, and the runner has none. `npm test` covers the
# companion, which is where every rule lives.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

nvim --headless -l test/lua/document.lua
nvim --headless -l test/lua/session.lua
nvim --headless -l test/lua/grant.lua
nvim --headless -l test/lua/granted.lua
nvim --headless -l test/lua/mirror.lua
nvim --headless -l test/lua/commands.lua
nvim --headless -l test/lua/vocabulary.lua
nvim --headless -l test/lua/warnings.lua
nvim --headless -l test/lua/leave.lua
