#!/usr/bin/env bash
#
# Bump this repository's release version in every file that carries it. The release coordinator
# calls this; the caller commits, tags and pushes.
#
#   scripts/bump-version.sh <major|minor|patch> [--dry-run]
#
# Two files carry it, and a release that moves one and not the other is a red run:
#
#   package.json       the companion's manifest (`selvage-nvim-companion`, private), which
#                      `release.yml` asserts the tag name against. The plugin has no version
#                      string of its own: `lua/`, `plugin/`, the README and `docs/` carry none,
#                      and the identity the companion sends in `session.hello` is
#                      `selvage-nvim`, which carries no version.
#   package-lock.json  the root `version` and the same key under `packages.""`, which npm copies
#                      from the manifest
#
# `test/bump-version.test.ts` holds that file set, so a third home cannot appear without that test
# failing. `release.yml` carries no version of its own either: its `version` input is required with
# no default, so nothing in this repository has to be hand-bumped besides these two files.
#
# The word is applied to the version `package.json` carries: `patch` moves the last component
# (0.5.1 -> 0.5.2), `minor` the middle one and zeros the last (0.5.1 -> 0.6.0), and `major` the
# first and zeros the rest (0.5.1 -> 1.0.0). The resulting version is printed as the last line of
# stdout and shares that line with nothing else, so the caller can name the tag and the Release
# from it. `--dry-run` prints the same version and writes nothing. Anything that is not one of the
# three words — the `X.Y.Z` form included, which this script no longer takes — is refused with the
# tree unchanged.
#
# Every spot is found by the shape of the key that carries it rather than by the version it holds,
# and each is written only when it does not already carry the version asked for. So a tree where
# the manifest was bumped by hand and the lockfile was not is repaired rather than reported as
# done, and every file written — or, under `--dry-run`, that would be — is named.
#
# Every spot is located before the first is written, so a file whose shape has moved refuses with
# the tree as it was rather than leaving a half-bumped one behind.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

usage() {
  printf 'usage: %s <major|minor|patch> [--dry-run]\n' "${0##*/}" >&2
  exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi

word=$1
dry_run=false
if [ "$#" -eq 2 ]; then
  if [ "$2" != '--dry-run' ]; then
    usage
  fi
  dry_run=true
fi

case "$word" in
  major | minor | patch) ;;
  *)
    printf 'refusing: %q is not a bump; name major, minor or patch\n' "$word" >&2
    exit 1
    ;;
esac

# The manifest's own version, which the word is applied to. It is `X.Y.Z`: three plain decimal
# components and nothing else. A tree that carries anything else is refused rather than bumped
# from it.
current=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' package.json)
if [ -z "$current" ] || [ "$(printf '%s\n' "$current" | wc -l)" -ne 1 ]; then
  printf 'refusing: cannot read one version from package.json\n' >&2
  exit 1
fi
if ! [[ $current =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'refusing: package.json carries %q, not X.Y.Z\n' "$current" >&2
  exit 1
fi

major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

# The shell's arithmetic is signed 64-bit, so a component of 19 digits or more can wrap when it is
# incremented — `9223372036854775807 + 1` is negative — and the version printed and written would
# not be the one the word names. Only the component the word moves can overflow; the ones below it
# are reset rather than incremented.
too_large() {
  printf 'refusing: %s carries a component too large to bump\n' "$current" >&2
  exit 1
}
case "$word" in
  major)
    [ "${#major}" -le 18 ] || too_large
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    [ "${#minor}" -le 18 ] || too_large
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    [ "${#patch}" -le 18 ] || too_large
    patch=$((patch + 1))
    ;;
esac
new="$major.$minor.$patch"

# locate <file> <ere>: the one line the pattern names, refusing when it names none or more than
# one.
locate() {
  local file=$1 pattern=$2 hits
  hits=$(grep -c -E -- "$pattern" "$file" || true)
  if [ "$hits" != 1 ]; then
    printf 'refusing: %s has %s line(s) matching %s, want one; nothing written\n' "$file" "$hits" "$pattern" >&2
    exit 1
  fi
  grep -n -E -- "$pattern" "$file" | cut -d: -f1
}

# Only the top level of either file carries a `version` at two spaces, so these two cannot reach a
# dependency's own entry, which is nested.
manifest_line=$(locate package.json '^  "version": "[^"]*",$')
lock_root_line=$(locate package-lock.json '^  "version": "[^"]*",$')

# The lockfile's second copy of the manifest version sits in the root package entry,
# `packages.""`, which is laid out exactly like a dependency's entry: found by walking `packages`
# to the empty key, not by an indentation a dependency also has.
lock_package_line=$(awk '
  /^  "packages": \{$/ { packages = 1; next }
  packages && /^    "": \{$/ { root = 1; next }
  root && /^      "version": "[^"]*",$/ { print NR; exit }
  root && /^    \},$/ { exit }
' package-lock.json)
if [ -z "$lock_package_line" ]; then
  printf 'refusing: package-lock.json carries no version in packages.""; nothing written\n' >&2
  exit 1
fi

# What each spot becomes. The whole line is replaced, addressed by its number, so no dependency's
# version line in the lockfile can be reached even in principle.
files=(package.json package-lock.json package-lock.json)
lines=("$manifest_line" "$lock_root_line" "$lock_package_line")
targets=(
  "$(printf '  "version": "%s",' "$new")"
  "$(printf '  "version": "%s",' "$new")"
  "$(printf '      "version": "%s",' "$new")"
)

changed=()
for i in "${!files[@]}"; do
  file=${files[$i]}
  if [ "$(sed -n "${lines[$i]}p" "$file")" = "${targets[$i]}" ]; then
    continue
  fi
  if [ "$dry_run" = false ]; then
    sed -i "${lines[$i]}s|.*|${targets[$i]}|" "$file"
  fi
  if [[ ! " ${changed[*]-} " == *" $file "* ]]; then
    changed+=("$file")
  fi
done

if [ "$dry_run" = true ]; then
  printf 'would set %s -> %s in:\n' "$current" "$new"
else
  printf 'set %s -> %s in:\n' "$current" "$new"
fi
printf '  %s\n' "${changed[@]}"
printf '%s\n' "$new"
