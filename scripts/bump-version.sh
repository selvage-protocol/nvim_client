#!/usr/bin/env bash
#
# Set this repository's release version in every file that carries it. The release coordinator
# calls this; the caller commits, tags and pushes.
#
#   scripts/bump-version.sh 0.5.2
#
# Two files carry it, and a release that moves one and not the other is a red run:
#
#   package.json       the companion's manifest (`selvage-nvim-companion`, private), which
#                      `release.yml` asserts the dispatch input and the tag name against. The
#                      plugin has no version string of its own: `lua/` and `plugin/` carry none,
#                      the README names no release, and the client identity the companion sends
#                      in `session.hello` is `selvage-nvim`, which carries no version.
#   package-lock.json  the root `version` and the same key under `packages.""`, which npm copies
#                      from the manifest
#
# `test/bump-version.test.ts` holds that file set, so a third home cannot appear without that
# test failing. `release.yml` carries no version of its own either: its `version` input is
# required with no default, so nothing in this repository has to be hand-bumped besides these
# two files.
#
# The version is `X.Y.Z`: three plain decimal components and nothing else, the rule
# `specification/scripts/check-release-version.sh` applies to a dispatch input. A `case` glob is
# not that rule — `[0-9]*.[0-9]*.[0-9]*` admits `1.2.3-rc1`, `1x2.3.4` and `1.2.3/../x` — so the
# character check and the shape check are separate.
#
# Nothing is written until every spot has been found, so a refusal leaves the tree as it was, and
# a version the tree already carries is a no-op rather than a rewrite.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <X.Y.Z>\n' "${0##*/}" >&2
  exit 2
fi

new=$1

case "$new" in
  '' | *[!0-9.]*)
    printf 'refusing: %q is not a release version\n' "$new" >&2
    exit 1
    ;;
esac

if ! [[ $new =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'refusing: %s is not a release version\n' "$new" >&2
  exit 1
fi

# The manifest is the version's one home; the lockfile is held to it, so a manifest this cannot
# read stops the run rather than moving the lockfile to a version nothing else agrees with.
current=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' package.json)
if [ -z "$current" ] || [ "$(printf '%s\n' "$current" | wc -l)" -ne 1 ]; then
  printf 'refusing: cannot read one version from package.json\n' >&2
  exit 1
fi

if [ "$current" = "$new" ]; then
  printf 'already at %s (package.json); nothing changed\n' "$new"
  exit 0
fi

# Every spot as an exact line, so matching is by fixed string and a dependency's own version in
# the lockfile cannot be mistaken for the package's.
manifest_line=$(printf '  "version": "%s",' "$current")
lock_package_line=$(printf '      "version": "%s",' "$current")

look_for() {
  local file=$1 line=$2 hits
  hits=$(grep -F -x -c -- "$line" "$file" || true)
  if [ "$hits" != 1 ]; then
    printf 'refusing: %s carries that line %s time(s), want one; nothing written\n' "$file" "$hits" >&2
    exit 1
  fi
}

look_for package.json "$manifest_line"
look_for package-lock.json "$manifest_line"
look_for package-lock.json "$lock_package_line"

# `\.` in the pattern, so the dots of a version cannot match any character. The replacement
# carries the version alone, so nothing in it needs escaping.
current_pattern=${current//./\\.}

sed -i "s|^  \"version\": \"$current_pattern\",$|  \"version\": \"$new\",|" package.json
sed -i "s|^  \"version\": \"$current_pattern\",$|  \"version\": \"$new\",|" package-lock.json
sed -i "s|^      \"version\": \"$current_pattern\",$|      \"version\": \"$new\",|" package-lock.json

printf 'set %s -> %s in:\n' "$current" "$new"
printf '  %s\n' package.json package-lock.json
