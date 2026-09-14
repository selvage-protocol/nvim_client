#!/usr/bin/env bash
#
# The sync engine and the bridge in `vendor/` are vendored, not authored here: the canonical
# copies live in the VS Code client (`selvage-protocol/vscode_client`, its `src/engine` and
# `src/bridge`). `DESIGN.md` §6 splits a client into a sync engine and an editor adapter, and
# this repository is an editor adapter — the engine it drives is the one that already speaks
# the wire, so it is copied rather than written a second time in a second language.
#
#   scripts/sync-engine.sh [path-to-vscode_client-checkout]
#
# The default source is the sibling checkout `../vscode_client`. The script copies and then
# reports the difference, so a run either brings `vendor/` into agreement or says what it
# could not.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-"$here/../vscode_client"}"

for part in engine bridge; do
  if [[ ! -d "$source_dir/src/$part" ]]; then
    printf 'no src/%s in %s: pass the path to a vscode_client checkout\n' "$part" "$source_dir" >&2
    exit 1
  fi
done

for part in engine bridge; do
  mkdir -p "$here/vendor/$part"
  cp -a "$source_dir/src/$part/." "$here/vendor/$part/"

  # A module the source has retired must go too, or the copy drifts by addition.
  while IFS= read -r file; do
    [[ -e "$source_dir/src/${file#vendor/}" ]] || rm -- "$here/$file"
  done < <(cd "$here" && find "vendor/$part" -type f)
done
find "$here/vendor" -mindepth 1 -type d -empty -delete

status=0
for part in engine bridge; do
  if ! diff -r "$source_dir/src/$part" "$here/vendor/$part"; then
    printf 'vendor/%s differs from %s/src/%s\n' "$part" "$source_dir" "$part" >&2
    status=1
  fi
done
if [[ $status -eq 0 ]]; then
  printf 'vendor/ is the same as %s/src\n' "$source_dir"
fi
exit "$status"
