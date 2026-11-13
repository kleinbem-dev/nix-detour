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
      lib = {
        # holds: held-packages.json (a path) or an attrset; nixpkgs-stable: for `from = "stable"`.
        # extraOverlays: your own overlays, so your own packages can be held too.
        # config: nixpkgs config for the held sets; default: carried over from yours.
        mkHolds =
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
        mkPrs = { prs }: import ./prs.nix { inherit lib prs; };

        # What the update action checks (see watch.nix): lib.watch.nixos
        # nixosSystem, or lib.watch.packages { pkgs, packages }.
        watch = import ./watch.nix { inherit lib; };
      };

      packages = forAllSystems (
        pkgs:
        let
          nix-detour = pkgs.callPackage ./package.nix { };
        in
        {
          default = nix-detour;
          inherit nix-detour;

          web = pkgs.runCommand "nix-detour-web-${nix-detour.version}" { } ''
            ln -s ${nix-detour}/share/nix-detour/web $out
          '';

          web-server =
            pkgs.runCommand "nix-detour-web-server-${nix-detour.version}"
              {
                meta.mainProgram = "nix-detour-web-server";
              }
              ''
                mkdir -p $out/bin
                ln -s ${nix-detour}/libexec/nix-detour/web-server $out/bin/nix-detour-web-server
              '';
        }
      );

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.nix-detour;
          meta.description = "The nix-detour CLI";
        };
        web = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "nix-detour-web" ''
              exec ${lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.nix-detour} web "$@"
            ''
          );
          meta.description = "Run the nix-detour web dashboard";
        };
      });

      checks = forAllSystems (
        pkgs:
        let
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) nix-detour;
        in
        (import ./tests {
          inherit
            pkgs
            nixpkgs
            nixpkgs-stable
            nix-detour
            ;
          inherit (self.lib) mkHolds watch;
          mkPrs = args: import ./prs.nix ({ inherit lib; } // args);
        })
        // {
          package-smoke = nix-detour.passthru.tests.cli;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
