# Testing and public CI

The public workflows separate three kinds of evidence:

- `ci.yml`: companion type checks and tests, release-workflow guards, and documentation links.
- `native.yml`: the complete `scripts/test-lua.sh` suite and
  `scripts/e2e/run-two-instance.sh`, including the two-editor reconnect and follow proofs.
  Pull requests check a fixed public `reference_server` commit; weekly and manual runs
  resolve current server `main` to catch upstream behavioral drift. Every run logs the
  full source revisions and builds `selvaged` from scratch with `cargo build --locked`.
  Node 26.13.0, Neovim v0.12.6 (verified archive digest), and
  Rust 1.99.1 are pinned. The job has a 45-minute timeout, shorter build/test step timeouts,
  and uploads build/test logs for seven days on failure. These are real native tests, not
  substitutes inferred from the companion suite.
- `contracts.yml`: the public specification's `scripts/check-workspace.py`, comparing this
  candidate's committed `HEAD` with the current public VS Code `main`, resolved once and
  logged as a full SHA. It checks engine
  and bridge copies, CRDT dependency versions, and shared workflow guards when present. The
  job logs every resolved input SHA and uses read-only repository permissions with checkout
  credentials not persisted.

The executable checker is pinned to a reviewed public specification commit. Separate
canonical specification and VS Code checkouts follow `main`, so new guard or source changes
cannot be hidden by the executable pin. The job logs the checker SHA separately from its data.
When refreshing vendored sources, use the exact resolved canonical commit reported by the
job. Do not freeze the canonical source ref or hand-edit copies to make a comparison pass.

## Native tests locally

Install Node >=22.18 and Neovim >=0.12 on `PATH`, then run `npm ci` in this checkout.
The Lua suite starts the real companion in its installed-plugin test; it is not Lua-only.
The two-instance suite additionally needs a real `selvaged` and an available loopback port.
For an explicit server build:

```sh
cargo build --locked --manifest-path /path/to/reference_server/Cargo.toml -p selvaged
bash scripts/test-lua.sh
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged \
  bash scripts/e2e/run-two-instance.sh
```

Without `SELVAGE_SELVAGED`, the e2e script looks for a sibling `reference_server` build and
uses its Nix development shell to build one if missing. Use the explicit variable in other
workspace layouts.

`nix develop . --max-jobs 2 -c ./scripts/ci-local.sh all` runs lint, companion checks,
links, the Lua suite, and native e2e. It needs the same explicit server prerequisite.
`lua` and `e2e` also work as individual `ci-local.sh` modes. The existing owner flake and lock
remain the source of the local Nix tooling; CI's native job does not rewrite them.

## Copy contracts locally

Use a workspace containing Git repositories named `nvim_client`, `vscode_client`, and
`specification`. The consumer can be a symlink to this worktree when arranging such a workspace.
Supply a commit ref for every repository used, including the checker itself:

```sh
bash scripts/ci-local.sh contracts /path/to/workspace CHECKER_SHA \
  --revision specification=SPECIFICATION_SHA \
  --revision nvim_client=HEAD --revision vscode_client=VSCODE_SHA
```

The wrapper extracts checker code from `CHECKER_SHA` with `git show`, not from an
uncommitted script. That commit must be available in the specification's local Git object
store; explicitly fetch it first in a shallow clone if needed. The separate
`--revision specification=SPECIFICATION_SHA` chooses canonical guard data. Omitting a
required data revision fails instead of substituting the checker commit. The equivalent
public interface, with checker code in its own checkout, is:

```sh
python3 /path/to/contract_checker/scripts/check-workspace.py \
  --workspace /path/to/workspace --consumer nvim_client \
  --revision nvim_client=HEAD --revision vscode_client=VSCODE_SHA \
  --revision specification=SPECIFICATION_SHA
```

For the direct form, use checker code checked out at `CHECKER_SHA`, independently of the
canonical `SPECIFICATION_SHA` under the workspace. Neither form needs
an MCP checkout, private coordination files, or an implicit sibling source checkout. Missing
repositories or refs fail rather than falling back to working-tree content. `HEAD` means the
committed tree, so commit candidate changes before relying on the comparison. Contracts are
not included in `all`, because their cross-repository inputs must be supplied explicitly.
