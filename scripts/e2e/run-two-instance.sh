#!/usr/bin/env bash
#
# Runs `test/e2e/run.ts`: two real headless Neovim processes, each loading the real plugin and
# starting its own real companion, one hosting and one joining over a real `selvaged`, proving
# the room's link admits the guest, that the documents converge in both directions, that a guest
# reads a granted path the host's own window never opened, and — unless `SELVAGE_E2E_RECONNECT=0`
# — that a guest whose socket is cut reconnects and re-converges.
#
# This is not part of `npm test` or CI: it needs a `nvim` on PATH and a real `selvaged`, which
# it builds from the sibling `reference_server` checkout if there is not one already.
#
#   scripts/e2e/run-two-instance.sh
#   SELVAGE_E2E_RECONNECT=0 scripts/e2e/run-two-instance.sh   # without the blip
#   SELVAGE_SELVAGED=/path/to/selvaged scripts/e2e/run-two-instance.sh
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

exec node test/e2e/run.ts
