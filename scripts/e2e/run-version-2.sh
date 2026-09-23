#!/usr/bin/env bash
#
# Runs `test/e2e/run-version-2.ts`: the `selvage/2` proof, two real headless Neovims against one
# real `selvaged` on its defaults, which seat both versions, each with its own real companion. The
# host pins `vim.g.selvage_wire_version = '2'` and mints a version-2 room, hands the guest its page
# link with `§5.1`'s fragment on it, and the two exchange an edit in both directions — which is the
# whole of what a version-2 session is: the room's state is the host's, the content is sealed, and
# the server relays bytes.
#
# This is not part of `npm test` or CI: it needs a `nvim` on PATH and a real `selvaged`, which it
# builds from the sibling `reference_server` checkout if there is not one already.
#
#   scripts/e2e/run-version-2.sh
#   SELVAGE_SELVAGED=/path/to/selvaged scripts/e2e/run-version-2.sh
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

export TMPDIR="$repo_root/.tmp"
mkdir -p "$TMPDIR"

reference_server="${SELVAGE_REFERENCE_SERVER:-../reference_server}"

if [[ -z "${SELVAGE_SELVAGED:-}" && ! -x "$reference_server/target/debug/selvaged" && ! -x "$reference_server/target/release/selvaged" ]]; then
  echo "no selvaged binary; building one from $reference_server" >&2
  nix develop "$reference_server" -c sh -c "cd '$reference_server' && cargo build -p selvaged"
fi

exec node test/e2e/run-version-2.ts
