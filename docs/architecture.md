# Shape

The protocol's design splits a client into a sync engine (the CRDT, awareness, the wire) and an
editor adapter (buffers, paths, decorations). This repository is the adapter:

| Part | Where | What it does |
|---|---|---|
| Sync engine + bridge | `vendor/engine`, `vendor/bridge` | Vendored from `vscode_client`. Pure TypeScript, no editor import. |
| Companion | `companion/` | A Node process holding the engine and the bridge, with a Neovim `EditorHost`. Speaks newline-delimited JSON over stdio. |
| Plugin | `lua/selvage/`, `plugin/` | Commands, `nvim_buf_attach`, `nvim_buf_set_text`, and the conversion between byte positions and UTF-16 code units. |

One Neovim instance runs one companion process, started on the first `:SelvageHost` or
`:SelvageJoin` and stopped on `:SelvageLeave`.
