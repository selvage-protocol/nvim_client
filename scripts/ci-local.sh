#!/usr/bin/env bash
#
# Runs the steps of .github/workflows/ci.yml on this machine, without containers (this host
# has no Docker or Podman, so `act` cannot run here).
#
#   scripts/ci-local.sh checks   # the `checks` job: install, typecheck, the companion suite
#   scripts/ci-local.sh lint     # actionlint over the workflow files
#   scripts/ci-local.sh all      # lint + checks
#
# Keep this in step with the workflow — it runs the same commands, so that a red job is found
# here rather than on a runner. The two-instance proof is not part of it; it needs a real
# Neovim and a built `selvaged`, and runs from `scripts/e2e/run-two-instance.sh`.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# `/tmp` is a RAM-backed tmpfs on some hosts, and building there has taken a machine down
# before; keep every artefact inside the checkout.
export TMPDIR="$repo_root/.tmp"
mkdir -p "$TMPDIR"

say() { printf '\n=== %s ===\n' "$*"; }

job_checks() {
  say "checks: install"
  npm ci --no-audit --no-fund
  say "checks: typecheck"
  npm run typecheck
  say "checks: the companion suite"
  npm test
}

job_lint() {
  say "lint: actionlint over the workflows"
  nix shell nixpkgs#actionlint -c actionlint
}

case "${1:-all}" in
  checks) job_checks ;;
  lint) job_lint ;;
  all) job_lint && job_checks ;;
  *)
    printf 'usage: %s [checks|lint|all]\n' "$0" >&2
    exit 2
    ;;
esac
