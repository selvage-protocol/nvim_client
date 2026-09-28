# With Nix

`nix run github:selvage-protocol/nvim_client#nvim` gives a Neovim with the plugin on its runtime
path and Node on `PATH`; `nix run .#nvim` does the same from a checkout. Nothing here runs `npm ci`:
the companion's dependencies are built from `package-lock.json`, and the plugin declares the Node it
needs.

In Home Manager, add the flake as an input and take the plugin straight from it:

```nix
# flake.nix
inputs.nvim-client.url = "github:selvage-protocol/nvim_client";
```

```nix
programs.neovim.plugins = [
  inputs.nvim-client.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

`overlays.default` gives the same plugin the name `pkgs.vimPlugins.selvage`. An overlay belongs
wherever the package set is built, which on NixOS is `nixpkgs.overlays`:

```nix
nixpkgs.overlays = [ inputs.nvim-client.overlays.default ];

programs.neovim.plugins = [ pkgs.vimPlugins.selvage ];
```

A Neovim you wrap yourself takes it in `configure.packages`:

```nix
environment.systemPackages = [
  (pkgs.neovim.override {
    configure.packages.selvage.start = [
      inputs.nvim-client.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
  })
];
```

A wrapper built with runtime-dependency wrapping puts the plugin's `nodejs_22` on the wrapped
Neovim's `PATH`, which is why none of this asks for a Node of your own. One built without it leaves
the companion nowhere to find Node, which says so (`node is not on PATH`); add `pkgs.nodejs_22`
alongside the plugin, the way that wrapper takes packages.
