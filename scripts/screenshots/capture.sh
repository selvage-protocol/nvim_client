#!/usr/bin/env bash
#
# Takes the README's screenshot into `docs/images/`: two real Neovim instances in one room on a
# real `selvaged`, the host as a visible editor in a terminal on an Xvfb display at 1280×800 and the
# guest headless behind it, staged through the driver scripts under `test/screenshots/`. A manual
# step, run when the plugin's look changes, and never part of the gate:
#
#   scripts/screenshots/capture.sh
#
# The display, the terminal, `import` and `xdotool` are this shell's business rather than the dev
# shell's, so they come from `nix shell`; `node` and `nvim` come from the flake, the same pair
# `scripts/e2e/run-two-instance.sh` runs under. The image is then recompressed losslessly with
# optipng, through `nix shell`, and has to come out under 1 MB. Sandboxes and logs are kept under
# `.tmp/screenshots/` until the next run.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

export TMPDIR="$repo_root/.tmp"
mkdir -p "$TMPDIR"

raw="$TMPDIR/screenshots-raw"
out="docs/images"
rm -rf "$raw"

nix shell nixpkgs#xvfb-run nixpkgs#imagemagick nixpkgs#kitty nixpkgs#xdotool -c bash -c "
  xvfb-run -a --server-args='-screen 0 1280x800x24' nix develop . -c node test/screenshots/capture.ts '$raw'
"

# The images this run took, named before anything is published: an empty list is a capture that
# ran and wrote nothing, which is a failure rather than a run with no pictures to check.
shopt -s nullglob
raws=("$raw"/*.png)
shopt -u nullglob
if (( ${#raws[@]} == 0 )); then
  echo "no PNG was written under $raw; test/screenshots/capture.ts is what writes the image" >&2
  exit 1
fi

nix shell nixpkgs#optipng -c optipng -quiet -o5 -strip all "${raws[@]}"

# Validated first, published after: a picture over the size bound fails the run with `$out`
# untouched, and nothing a run leaves there is a file it took. The directory holds what this run
# took and nothing else, so a renamed or dropped picture does not stay behind beside it.
mkdir -p "$out"
rm -f "$out"/*.png
for raw_image in "${raws[@]}"; do
  image="$out/$(basename "$raw_image")"
  size=$(stat -c %s "$raw_image")
  if (( size >= 1048576 )); then
    echo "$image is $size bytes, over the 1 MB a README image may be" >&2
    exit 1
  fi
  cp "$raw_image" "$image"
  echo "ok: $image, $size bytes"
done
