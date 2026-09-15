{
  description = "Selvage's Neovim client: the dev shell, the server-free checks, and the two demo runners";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      withPackages =
        f:
        forAllSystems (
          pkgs:
          let
            node = pkgs.nodejs_22;

            # Built from the lock file, not taken from a checkout's `node_modules`: that
            # directory is ignored by git and so never reaches the store copy a flake sees.
            nodeModules = pkgs.importNpmLock.buildNodeModules {
              npmRoot = self;
              nodejs = node;
            };
          in
          f {
            inherit pkgs node nodeModules;
          }
        );
    in
    {
      # Node and a Neovim of a named version, and deliberately no git hooks: the hook set that
      # installs itself into whatever repository the shell is started in belongs to
      # `reference_server`, and this one wants none of it.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs_22
            pkgs.neovim
          ];
        };
      });

      checks = withPackages (
        { pkgs, node, nodeModules }:
        let
          # The suites run in a writable copy of the source with the store's tree linked in:
          # flake sources are read-only, and the Lua checks write scratch files under `.tmp/`.
          #
          # The suite's own output goes to stderr, and `$out` gets one stable line: the log
          # carries per-test timings, and a derivation whose output differs from build to build
          # is one `nix build --rebuild` rightly calls non-deterministic.
          mkSuite =
            name: inputs: steps:
            pkgs.runCommand name
              {
                nativeBuildInputs = inputs;
              }
              ''
                cp -r ${self} work
                chmod -R u+w work
                ln -s ${nodeModules}/node_modules work/node_modules
                cd work
                export HOME=$TMPDIR
                log=$TMPDIR/suite.log
                if (${pkgs.lib.concatStringsSep " && " steps}) > $log 2>&1; then
                  cat $log >&2
                  echo "${name}: passed" > $out
                else
                  cat $log >&2
                  echo "${name}: FAILED" > $out
                  exit 1
                fi
              '';
        in
        {
          typecheck = mkSuite "nvim-client-typecheck" [ node ] [ "npm run typecheck" ];

          # The companion suite. The two-instance proof is not here: it needs a `selvaged` from
          # the sibling `reference_server` checkout, which a sandboxed build cannot see.
          companion = mkSuite "nvim-client-companion-suite" [ node ] [ "npm test" ];

          # Each file in its own Neovim, as `scripts/test-lua.sh` runs them. They write scratch
          # under `.tmp/`, which is why the copy above is writable rather than the store path
          # itself.
          lua = mkSuite "nvim-client-lua-suite" [ pkgs.neovim ] [
            "nvim --headless -l test/lua/document.lua"
            "nvim --headless -l test/lua/session.lua"
            "nvim --headless -l test/lua/commands.lua"
            "nvim --headless -l test/lua/leave.lua"
          ];
        }
      );

      apps = withPackages (
        { pkgs, node, nodeModules }:
        let
          # The checkout as the plugin sees it: the tracked files plus the dependency tree the
          # companion's imports resolve against. `lua/selvage/companion.lua` derives the plugin's
          # root from its own path, so everything it reaches for has to be beside it.
          pluginSrc = pkgs.runCommand "selvage-nvim-plugin-src" { } ''
            cp -r ${self} $out
            chmod -R u+w $out
            ln -s ${nodeModules}/node_modules $out/node_modules
          '';

          plugin = pkgs.vimUtils.buildVimPlugin {
            name = "selvage";
            src = pluginSrc;
          };

          # A Neovim with the plugin on its runtime path for real, and Node on its PATH so the
          # companion it starts can be found.
          wrapped = pkgs.neovim.override {
            extraMakeWrapperArgs = "--prefix PATH : ${pkgs.lib.makeBinPath [ node ]}";

            configure = {
              packages.selvage.start = [ plugin ];
            };
          };

          # One command for the two-instance proof: the flake supplies Node and the Neovim, and
          # `SELVAGE_SELVAGED` supplies the server. It runs the checkout in the working
          # directory rather than a store copy, because the proof writes its scratch under
          # `.tmp/` and has to be able to.
          e2e = pkgs.writeShellApplication {
            name = "selvage-nvim-e2e";
            runtimeInputs = [
              node
              pkgs.neovim
            ];
            text = ''
              if [ ! -f test/e2e/run.ts ]; then
                echo "selvage-nvim-e2e: run it from the nvim_client checkout (and run npm ci first)" >&2
                exit 2
              fi
              exec node test/e2e/run.ts
            '';
          };
        in
        {
          nvim = {
            type = "app";
            program = "${wrapped}/bin/nvim";
            meta.description = "Neovim with the Selvage plugin on the runtime path and Node on PATH";
          };

          e2e = {
            type = "app";
            program = "${e2e}/bin/selvage-nvim-e2e";
            meta.description = "Two real Neovims and two real companions against a selvaged named by SELVAGE_SELVAGED";
          };
        }
      );
    };
}
