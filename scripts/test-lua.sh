#!/usr/bin/env bash
#
# The Lua side's own checks, in a real headless Neovim.
#
#   scripts/test-lua.sh
#
# Not part of the workflow: it needs a Neovim, and the runner has none. `npm test` covers the
# companion, which is where every rule lives.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

nvim --headless -l test/lua/document.lua
