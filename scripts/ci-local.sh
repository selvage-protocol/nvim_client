#!/usr/bin/env bash
#
# Runs the steps of .github/workflows/ci.yml on this machine, without containers (this host
# has no Docker or Podman, so `act` cannot run here).
#
#   scripts/ci-local.sh checks   # the `checks` job: install, typecheck, the companion suite,
#                                # the release workflow's dry_run gating
#   scripts/ci-local.sh lint     # actionlint over the workflow files
#   scripts/ci-local.sh links    # lychee over README.md and docs/: every relative link and every
#                                # URL the reader-facing prose carries
#   scripts/ci-local.sh lua      # headless Lua suite; npm ci, Node >=22.18, Neovim >=0.12
#   scripts/ci-local.sh e2e      # real Neovims; additionally requires SELVAGE_SELVAGED or a server checkout
#   scripts/ci-local.sh contracts WORKSPACE SPEC_REF --revision nvim_client=REF --revision vscode_client=REF
#   scripts/ci-local.sh all      # lint + checks + links + lua + e2e
#
# `native.yml` runs the Lua and two-instance suites against a fresh public server build.
# Locally, set SELVAGE_SELVAGED to an explicit build to avoid the e2e script's sibling lookup.
# Contracts are separate from `all`: the workspace and every compared revision must be explicit.
# See docs/testing.md for prerequisites and examples.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# `/tmp` is a RAM-backed tmpfs on some hosts, and building there has taken a machine down
# before; keep every artefact inside the checkout.
export TMPDIR="$repo_root/.tmp"
mkdir -p "$TMPDIR"

say() { printf '\n=== %s ===\n' "$*"; }

# The runner has no nix and installs the pinned lychee release instead, so on this host the checker
# comes from nixpkgs when it is not already on PATH.
run_lychee() {
  if command -v lychee >/dev/null 2>&1; then
    lychee "$@"
  else
    nix shell nixpkgs#lychee -c lychee "$@"
  fi
}

job_checks() {
  # The system whose flake checks this builds; the flake carries them for both Linux architectures.
  # Read here rather than at the top: this is the mode that needs nix, while `links` takes its
  # lychee from PATH and has to run on a host that has none.
  local system
  system=$(nix eval --raw --impure --expr builtins.currentSystem)
  say "checks: install"
  npm ci --no-audit --no-fund
  say "checks: typecheck"
  npm run typecheck
  say "checks: the companion suite"
  npm test
  # The guard around a workflow's `dry_run` input reads `.github/workflows`, so none of the suites
  # above covers it. The flake check also runs the retry-precondition suite, with Node and the
  # flake's Python supplying the PyYAML that `ci.yml` installs.
  say "checks: the release workflow's dry_run gating"
  nix build ".#checks.${system}.dry-run-gating" --no-link --print-build-logs
}

job_lint() {
  say "lint: actionlint over the workflows"
  nix shell nixpkgs#actionlint -c actionlint
}

# The scope is this repository's reader-facing front matter and not every Markdown file it holds:
# `vendor/` is a copy of another repository's tree, checked where it is written.
job_links() {
  say "links: lychee over README.md and docs/"
  run_lychee --config lychee.toml --no-progress README.md docs
}

job_lua() {
  say "lua: headless Neovim suite"
  bash scripts/test-lua.sh
}

job_contracts() (
  if [ "$#" -lt 2 ]; then
    printf 'usage: %s contracts WORKSPACE SPEC_REF --revision nvim_client=REF --revision vscode_client=REF\n' "$0" >&2
    exit 2
  fi
  workspace=$(cd -- "$1" && pwd)
  specification_ref=$2
  shift 2
  checker=$(mktemp "$TMPDIR/check-workspace.XXXXXX.py")
  trap 'rm -f "$checker"' EXIT
  specification_sha=$(git -C "$workspace/specification" rev-parse --verify "${specification_ref}^{commit}")
  say "contracts: specification=$specification_sha"
  git -C "$workspace/specification" show "$specification_sha:scripts/check-workspace.py" > "$checker"
  python3 "$checker" --workspace "$workspace" --consumer nvim_client \
    --revision "specification=$specification_sha" "$@"
)

job_e2e() {
  say "e2e: two real Neovims against a real selvaged"
  bash scripts/e2e/run-two-instance.sh
}

case "${1:-all}" in
  checks) job_checks ;;
  lint) job_lint ;;
  links) job_links ;;
  lua) job_lua ;;
  e2e) job_e2e ;;
  contracts) shift; job_contracts "$@" ;;
  all) job_lint; job_checks; job_links; job_lua; job_e2e ;;
  *)
    printf 'usage: %s [checks|lint|links|lua|e2e|contracts WORKSPACE SPEC_REF --revision REPO=REF ...|all]\n' "$0" >&2
    exit 2
    ;;
esac
