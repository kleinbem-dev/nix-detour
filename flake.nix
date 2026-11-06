{
  description = "Single packages take a detour from your nixpkgs (held back while broken, or ahead from an open nixpkgs PR) until nixpkgs catches up";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Consumers make this follow their own nixpkgs-stable.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-stable,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # holds: held-packages.json (a path) or an attrset; nixpkgs-stable: for `from = "stable"`.
      # extraOverlays: your own overlays, so your own packages can be held too.
      # config: nixpkgs config for the held sets; default: carried over from yours.
      lib.mkHolds =
        {
          holds,
          nixpkgs-stable ? inputs.nixpkgs-stable,
          extraOverlays ? [ ],
          config ? null,
        }:
        let
          entries = if builtins.isAttrs holds then holds else lib.importJSON holds;
          heldIn = pkgs: builtins.filter (name: pkgs ? ${name}) (builtins.attrNames entries);
        in
        {
          overlay = import ./overlay.nix {
            inherit nixpkgs-stable extraOverlays config;
            holds = entries;
            root = if builtins.isAttrs holds then null else dirOf holds;
          };

          # NixOS tests of the held packages (`tests`, default nixosTests.<name>):
          # the module is from the current nixpkgs and the package from its hold,
          # so a mismatch only shows at runtime. Run them with your own overlays.
          nixosTests =
            pkgs:
            let
              testsOf = name: entries.${name}.tests or (lib.optional (pkgs.nixosTests ? ${name}) name);
            in
            lib.genAttrs (lib.unique (lib.concatMap testsOf (heldIn pkgs))) (test: pkgs.nixosTests.${test});

          # Per hold, its `releaseWhen` (default: the package) from a set without
          # the holds; the hold can go once this builds on the newest nixpkgs.
          # `nixHolds` carries the entry, so the tools read the holds in use.
          releaseChecks =
            pkgs:
            lib.genAttrs (heldIn pkgs) (
              name:
              let
                entry = entries.${name};
                path = lib.splitString "." (entry.releaseWhen or name);
                pkg = lib.attrByPath path null pkgs;
                versionSatisfied =
                  if entry ? untilVersion && pkg != null && pkg ? version then
                    builtins.compareVersions pkg.version entry.untilVersion >= 0
                  else
                    true;
              in
              (if pkg != null && versionSatisfied then pkg else { })
              // {
                nixHolds = entry;
              }
            );
        };

      # Packages from open nixpkgs PRs of one consumer (see prs.nix).
      #   prs: its nixpkgs-prs.json (a path) or the same as an attrset
      lib.mkPrs = { prs }: import ./prs.nix { inherit lib prs; };

      # What the update action checks (see watch.nix): lib.watch.nixos
      # nixosSystem, or lib.watch.packages { pkgs, packages }.
      lib.watch = import ./watch.nix { inherit lib; };

      # The CLI: add, remove, list and check holds, and the same for PR
      # packages (`nix-detour pr`). Nix itself comes from the user's PATH.
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.nix-detour;
        web = pkgs.buildNpmPackage {
          pname = "nix-detour-web";
          version = "0.1.0";
          src = ./web;
          # Hashes come from package-lock.json, so Dependabot bumps need no hash update.
          npmDeps = pkgs.importNpmLock { npmRoot = ./web; };
          npmConfigHook = pkgs.importNpmLock.npmConfigHook;
          # svelte-check: CI builds this, so type errors fail it.
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            npm run check
            runHook postCheck
          '';
          installPhase = ''
            runHook preInstall
            cp -r dist $out
            runHook postInstall
          '';
        };

        web-server = pkgs.writeShellApplication {
          name = "nix-detour-web-server";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./web/server.py} --static-dir "${
              self.packages.${pkgs.stdenv.hostPlatform.system}.web
            }" "$@"
          '';
        };

        nix-detour =
          let
            releaseCheck = pkgs.writeShellApplication {
              name = "nix-detour-release-check";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
              text = builtins.readFile ./scripts/release-check.sh;
            };
            prs = pkgs.writeShellApplication {
              name = "nix-detour-pr";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.curl
                pkgs.jq
              ];
              text = builtins.readFile ./scripts/prs.sh;
            };
            webServer = self.packages.${pkgs.stdenv.hostPlatform.system}.web-server;
          in
          pkgs.writeShellApplication {
            name = "nix-detour";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
              pkgs.jq
            ];
            text =
              builtins.replaceStrings
                [ "@releaseCheck@" "@prs@" "@webServer@" ]
                [ (lib.getExe releaseCheck) (lib.getExe prs) (lib.getExe webServer) ]
                (builtins.readFile ./scripts/nix-detour.sh);
          };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.nix-detour;
          meta.description = "The nix-detour CLI";
        };
        web = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.web-server;
          meta.description = "Run the nix-detour web dashboard";
        };
      });

      # Tests of mkHolds, mkPrs and the CLI.
      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs nixpkgs nixpkgs-stable;
          inherit (self.lib) mkHolds;
          mkPrs = args: import ./prs.nix ({ inherit lib; } // args);
          inherit (self.lib) watch;
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) nix-detour;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
