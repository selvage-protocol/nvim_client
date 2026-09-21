{
  description = "Selvage's Neovim client: the plugin, the dev shell, the server-free checks, and the two demo runners";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The client as a package, as a function of a package set: `overlays.default` builds it out
      # of the consumer's own nixpkgs rather than mixing two, and everything below is built from
      # the one record so that the plugin the checks load is the plugin `packages` hands out.
      mkSelvage =
        pkgs:
        let
          node = pkgs.nodejs_22;

          # The companion is Node, and its imports (`yjs`, `ws`, `y-protocols`, `lib0`) resolve
          # from a `node_modules` beside it — built from the lock file rather than taken from a
          # checkout's, because that directory is ignored by git and so never reaches the store
          # copy a flake sees.
          nodeModules = pkgs.importNpmLock.buildNodeModules {
            npmRoot = self;
            nodejs = node;
          };

          # The checkout as the plugin sees it: the tracked files, plus that dependency tree
          # linked in beside them. `lua/selvage/companion.lua` derives the plugin's root from its
          # own path and runs `node <root>/companion/main.ts`, so both have to be in one place.
          pluginSrc = pkgs.runCommand "selvage-nvim-src" { } ''
            cp -r ${self} $out
            chmod -R u+w $out
            ln -s ${nodeModules}/node_modules $out/node_modules
          '';

          plugin = pkgs.vimUtils.buildVimPlugin {
            name = "selvage";
            src = pluginSrc;

            # The companion is a Node process running the TypeScript sources in place (type
            # stripping, Node 22.18 and newer), so Node has to be reachable from the Neovim that
            # loads the plugin. Whichever way the plugin reaches a nixpkgs Neovim wrapper —
            # home-manager's `programs.neovim.plugins`, or `pkgs.neovim.override` with
            # `configure.packages.…` — the wrapper reads this and puts Node on its own PATH; a
            # plugin manager that does not is why the README still asks for Node separately.
            runtimeDeps = [ node ];

            meta = {
              description = "Selvage for Neovim: share a link and edit the same file with someone else";
              homepage = "https://github.com/selvage-protocol/nvim_client";
              license = with pkgs.lib.licenses; [
                mit
                asl20
              ];
              platforms = pkgs.lib.platforms.all;
            };
          };
        in
        {
          inherit node nodeModules plugin;

          # A Neovim with the plugin on its runtime path for real, and Node on PATH because the
          # plugin says it is a runtime dependency — not because this host happens to have one.
          #
          # `pkgs.neovim.override` goes through nixpkgs' `legacyWrapper`, which replaces any
          # `plugins` argument with the list it builds from `configure.packages`; the plugin's own
          # `runtimeDeps` is what it does read, and what puts Node on the wrapper's PATH.
          # (`wrapNeovimUnstable`, which home-manager's `programs.neovim.plugins` goes through,
          # takes `plugins` directly — either way a plugin that declares its runtime dependency
          # gets it.)
          neovim = pkgs.neovim.override {
            configure = {
              packages.selvage.start = [ plugin ];
            };
          };
        };

      forAllSelvage = f: forAllSystems (pkgs: f pkgs (mkSelvage pkgs));
    in
    {
      # `nix build` gives the plugin itself; `nix run .#nvim` gives an editor with it and Node.
      packages = forAllSelvage (pkgs: selvage: {
        default = selvage.plugin;
        neovim-selvage = selvage.neovim;
      });

      # For a configuration that already has a package set: `nixpkgs.overlays = [
      # inputs.nvim_client.overlays.default ];` makes `pkgs.vimPlugins.selvage` the plugin, and
      # `programs.neovim.plugins = [ pkgs.vimPlugins.selvage ];` is then the whole install.
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // {
          selvage = (mkSelvage final).plugin;
        };
      };

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

      checks = forAllSelvage (
        pkgs: selvage:
        let
          # Each file in its own Neovim, as `scripts/test-lua.sh` runs them. They write scratch
          # under `.tmp/`, which is why the copy below is writable rather than the store path
          # itself.
          luaFiles = [
            "test/lua/document.lua"
            "test/lua/session.lua"
            "test/lua/grant.lua"
            "test/lua/granted.lua"
            "test/lua/mirror.lua"
            "test/lua/join.lua"
            "test/lua/joinorder.lua"
            "test/lua/pickers.lua"
            "test/lua/commands.lua"
            "test/lua/warnings.lua"
            "test/lua/vocabulary.lua"
            "test/lua/leave.lua"
            "test/lua/follow.lua"
          ];

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
                ln -s ${selvage.nodeModules}/node_modules work/node_modules
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

          # The built package, in a real Neovim. The working directory is a scratch one on
          # purpose: `test/lua/*.lua` find the plugin through the directory they are run from,
          # so the file run here — the one that asserts the plugin it loaded is the package the
          # flake built — has nothing to find unless the package put the plugin on the runtime
          # path by itself. The Neovim is the wrapper `packages.<system>.neovim-selvage` is.
          plugin =
            pkgs.runCommand "nvim-client-plugin"
              {
                nativeBuildInputs = [ selvage.neovim ];
                SELVAGE_PLUGIN_ROOT = selvage.plugin;
              }
              ''
                mkdir scratch
                cd scratch
                export HOME=$TMPDIR
                log=$TMPDIR/plugin.log
                status=0
                nvim --headless -l ${self}/test/lua/installed.lua > $log 2>&1 || status=1
                # The script asserts this too; this is the derivation's own reading of it, so
                # that a check whose assertion was quietly dropped still fails here.
                grep -q "^plugin root: ${selvage.plugin}$" $log || status=1
                cat $log >&2
                if [ "$status" -eq 0 ]; then
                  echo "nvim-client-plugin: passed" > $out
                else
                  echo "nvim-client-plugin: FAILED" > $out
                  exit 1
                fi
              '';
        in
        {
          typecheck = mkSuite "nvim-client-typecheck" [ selvage.node ] [ "npm run typecheck" ];

          # The companion suite. The two-instance proof is not here: it needs a `selvaged` from
          # the sibling `reference_server` checkout, which a sandboxed build cannot see.
          companion = mkSuite "nvim-client-companion-suite" [ selvage.node ] [ "npm test" ];

          lua = mkSuite "nvim-client-lua-suite" [ pkgs.neovim ] (map (f: "nvim --headless -l ${f}") luaFiles);

          inherit plugin;
        }
      );

      apps = forAllSelvage (
        pkgs: selvage:
        let
          # One command for the two-instance proof: the flake supplies Node and the Neovim, and
          # `SELVAGE_SELVAGED` supplies the server. It runs the checkout in the working
          # directory rather than a store copy, because the proof writes its scratch under
          # `.tmp/` and has to be able to.
          e2e = pkgs.writeShellApplication {
            name = "selvage-nvim-e2e";
            runtimeInputs = [
              selvage.node
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
            program = "${selvage.neovim}/bin/nvim";
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
