# Checks

```
npm run typecheck
npm test                    # the companion, against a replica with no server behind it
scripts/ci-local.sh all     # the workflow's commands, plus actionlint and the proof below
scripts/test-lua.sh         # the Lua side, in a real headless Neovim (not in `all`: see below)
scripts/e2e/run-two-instance.sh   # two real Neovims, a real companion each, a real selvaged
scripts/screenshots/capture.sh    # the README's screenshot: two real Neovims, one of them visible

nix flake check             # the same three suites, the built package and the workflow guard
nix develop                 # Node 22 and a Neovim of a named version; no git hooks
```

[`scripts/ci-local.sh checks`](../scripts/ci-local.sh) is what the workflow runs;
`scripts/ci-local.sh all` adds actionlint and the end-to-end proof, which needs a real Neovim and a
built `selvaged` and so cannot run on a runner.
[`scripts/test-lua.sh`](../scripts/test-lua.sh) is not in `all`: it needs a Neovim too, and
`nix flake check` runs the same files in a sandbox. Run it by hand after changing `lua/`. Its last
file is the checkout as the installed plugin, and it starts its Neovim with no plugin of its own, so
a machine whose editor arrives with a `selvage` installed cannot answer for the checkout.

`nix flake check` runs `typecheck`, the companion suite and the fourteen files under `test/lua/`,
each in its own Neovim, with no network and no editor session, and then the `plugin` check, which is
the only one that starts Neovim against the built package rather than a checkout: the plugin that
`packages.<system>.default` is, on the runtime path of the wrapped Neovim that
`packages.<system>.neovim-selvage` is, with the real companion started from it. `dry-run-gating` is
the fourth: it reads `.github/workflows` back and refuses a workflow that declares a `dry_run` input
and leaves a step below its plan step without a condition that excludes a dry run — the defect
`actionlint` cannot see, because it is the condition a step does not carry. `ci.yml` runs the same
two files, with pip's PyYAML. The two-instance proof is not one of them: it needs a `selvaged` from
the sibling `reference_server` checkout, which a sandboxed build cannot see, so `SELVAGE_SELVAGED`
is the seam. `nix run .#e2e` runs that proof with the flake's Node and Neovim and whatever
`SELVAGE_SELVAGED` names, from the checkout in the working directory:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged nix run .#e2e
```

The two-instance proof ([`scripts/e2e/run-two-instance.sh`](../scripts/e2e/run-two-instance.sh), or
`nix run .#e2e`) needs a built `selvaged`, and finds one through `SELVAGE_SELVAGED` when that is set
and otherwise under `../reference_server/target/{debug,release}`, a path relative to this checkout.
From a git worktree under `.worktrees/` that sibling does not exist, so point it at the main
checkout's binary:

```
SELVAGE_SELVAGED=/path/to/reference_server/target/debug/selvaged scripts/e2e/run-two-instance.sh
```

There is no `busted` or plugin-test framework here: almost every rule worth testing (what enters
the replica, which change an editor is asked to apply, when a document is written) lives in the
companion, and is tested there against a fake editor. `test/bridge.test.ts` takes the vendored
bridge directly (this adapter's `NvimEditorHost` in front of it, a fake replica behind) because a
guest document the room has not sent the text for is a case the companion's own deferral never
lets the bridge see. `test/grant.test.ts` is the host's side of the room's listing on a real
directory tree: which files a listing carries and in what order, which of them the folder's own
ignore files leave out, and how far a path a peer named may reach, including the symbolic links
that make a guess about a path interesting. A bound of §13.3's is crossed there over a tree handed
to the same seam instead, because reaching one on a real disk takes a hundred thousand files. What is left on the Lua side is translation, the wiring around one
session, and one rule of the editor's own: the conversion between Neovim's byte positions and the
protocol's UTF-16 code units. The first two get `test/lua/document.lua` and
`test/lua/session.lua`, which run in a real headless Neovim. The first is against a real buffer
and a real `on_bytes` rather than a mock; the second is against a stubbed companion, and checks
the wiring around a session: which buffers it shares, that it lets them go when the session ends,
and that a caret is published and a peer's caret and selection are drawn at the peer's position.
`test/lua/commands.lua` is the commands' own policy, through the real command definitions: what
`:SelvageHost`, `:SelvageJoin` and `:SelvageOpen` ask for, refuse and never do.
`test/lua/granted.lua` is the room's grant on the front-end's side: what the room offers, the
completion and the chooser over it, and opening a path nobody has opened without counting it as
held. `test/lua/mirror.lua` is the mirror, against a stub companion that answers holds the way the
room does: where the directory is and how long it lives, what a listing materialises and what it
refuses to, what a listing that loses a path removes, keeps and leaves open, which buffer a room
path is opened in, how content reaches the file, what a save does and what a write the room knows
nothing about does, and `:SelvageFetch` over one path, a directory and the whole listing.
`test/lua/vocabulary.lua` pins the words rather than the behaviour, as the other client's
`test/vocabulary.test.ts` does: the phrase each command is described by, and every sentence the
front-end notifies, with the level it notifies it at. Both clients say the same sentence at a
moment and keep only the presentation around it to themselves, so a reworded sentence fails this
suite here rather than drifting away from the other editor's. `test/lua/leave.lua` starts a real
job, one that ignores its stdin, to check what `:SelvageLeave` does to a companion that does not
go on its own, and reads the framing of what the companion writes off the same object: a line
arriving in pieces, and one past the bound being shed to the newline that ends it.
`test/lua/health.lua` is the two floors this plugin states: the comparison itself against
the suite's own versions, the refusal sentence, and the bound on the spawn that reads Node's —
with that spawn stubbed, so nothing here depends on the Node or the Neovim the suite runs on —
plus the promise that an editor or a Node below either floor starts no job at all, and that the
README and the npm manifest state the floors the code holds.

`scripts/e2e/run-two-instance.sh` is the proof end to end: two real headless Neovim processes, each
loading the real plugin and starting its own real companion, one minting a room on a real `selvaged`
and the other joining the link it hands on. It proves what a session is: the page link carries
`§5.1`'s fragment, the guest reads the room and its own role out of the state the host signed, an
edit made in either window ends up in both, the host's working copy on disk holds the guest's own
edit, and the companion's trace of that run holds the invite with its fragment redacted out. It also
opens a granted path the host's own window never opened, so the text can only be the host's working
copy read on the guest's hold, and — unless `SELVAGE_E2E_RECONNECT=0` — cuts the guest's socket and
checks that both windows re-converge once it has re-established. It is not part of `npm test` or CI,
because it needs a `nvim` and a built `selvaged`.

`scripts/screenshots/capture.sh` is the README's screenshot, a manual step run when the plugin's
look changes and never part of the gate. It is the proof's own shape with a window in it: two real
Neovim instances in one room on a real `selvaged`, the host as a visible editor in a terminal on an
Xvfb display at 1280×800 and the guest headless behind it, staged through the driver scripts under
`test/screenshots/`, which reuse `test/e2e/harness.lua` and wait on what the drawing reads — the
guest's own row in `require('selvage').peers()`, and her caret's and her selection's marks in the
presence namespace — before the display is captured. The capture happens once three readings of the
display in a row are byte-for-byte the same, so the picture is of a frame that had stopped moving,
and a display that is blank fails there rather than being saved as a picture of nothing. A failure
saves the screen as a PNG: what a visible editor has to say about one is on its screen rather than
in its log. The image is recompressed losslessly with optipng and has to come out under 1 MB. Each
editor's `HOME` is its own sandbox under `.tmp/screenshots/` and the project opens under its folder,
so no path of the machine taking the picture is in the window.

What that window is showing is a stock Neovim — `--clean`, with no configuration of the machine at
all — with a line-number column and `'termguicolors'` on. The second is not decoration: a peer's
colour is a hex value the bridge derived, and Neovim's own default leaves `'termguicolors'` off, so
a highlight carrying only such a value draws as nothing.
