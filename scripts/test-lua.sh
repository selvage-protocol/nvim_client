#!/usr/bin/env bash
#
# The Lua side's own checks, in a real headless Neovim: the buffer arithmetic against a real
# buffer and a real `on_bytes` (`test/lua/document.lua`), the plugin's own wiring against a
# stubbed companion (`test/lua/session.lua`), and what stopping the process does to it
# (`test/lua/leave.lua`, against a real job).
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
nvim --headless -l test/lua/leave.lua
