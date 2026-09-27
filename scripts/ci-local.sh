#!/usr/bin/env bash
#
# Runs the steps of .github/workflows/ci.yml on this machine, without containers (this host
# has no Docker or Podman, so `act` cannot run here).
#
#   scripts/ci-local.sh checks   # the `checks` job: install, typecheck, the companion suite,
#                                # the release workflow's dry_run gating
#   scripts/ci-local.sh lint     # actionlint over the workflow files
#   scripts/ci-local.sh e2e      # the end-to-end proof: real Neovims against a real `selvaged`
#   scripts/ci-local.sh all      # lint + checks + e2e
#
# Keep the first two in step with the workflow — they run the same commands, so that a red job is
# found here rather than on a runner. `e2e` is this half of the gate that CI cannot be: it needs a
# real Neovim and a built `selvaged` from the sibling `reference_server` checkout, so
# `scripts/e2e/run-two-instance.sh` is run here and nowhere else. It takes a few seconds, a real
# `nvim` per instance and an ephemeral loopback port, and it is the proof that exercises the wire
# end to end — which is why `all` runs it rather than leaving it to whoever remembers.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# `/tmp` is a RAM-backed tmpfs on some hosts, and building there has taken a machine down
# before; keep every artefact inside the checkout.
export TMPDIR="$repo_root/.tmp"
mkdir -p "$TMPDIR"

# The system whose flake checks this builds; the flake carries them for both Linux architectures.
system=$(nix eval --raw --impure --expr builtins.currentSystem)

say() { printf '\n=== %s ===\n' "$*"; }

job_checks() {
  say "checks: install"
  npm ci --no-audit --no-fund
  say "checks: typecheck"
  npm run typecheck
  say "checks: the companion suite"
  npm test
  # The guard around a workflow's `dry_run` input reads `.github/workflows`, so none of the suites
  # above covers it. The flake check runs the same two files `ci.yml` runs, with the flake's Python
  # supplying the PyYAML that job installs.
  say "checks: the release workflow's dry_run gating"
  nix build ".#checks.${system}.dry-run-gating" --no-link --print-build-logs
}

job_lint() {
  say "lint: actionlint over the workflows"
  nix shell nixpkgs#actionlint -c actionlint
}

job_e2e() {
  say "e2e: two real Neovims against a real selvaged"
  bash scripts/e2e/run-two-instance.sh
}

case "${1:-all}" in
  checks) job_checks ;;
  lint) job_lint ;;
  e2e) job_e2e ;;
  all) job_lint && job_checks && job_e2e ;;
  *)
    printf 'usage: %s [checks|lint|e2e|all]\n' "$0" >&2
    exit 2
    ;;
esac
