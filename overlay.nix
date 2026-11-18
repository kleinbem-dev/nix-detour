# Each held package comes from the nixpkgs its entry names (`from`: "stable" is
# nixpkgs-stable, "current" your own nixpkgs, or a rev + narHash), plus its fix:
# `patches` (relative to the holds file, or { url, hash }) and/or `override`, a
# file holding `{ pkgs, package }: <the fixed package>`. Packages your set lacks
# are skipped.
{
  holds,
  nixpkgs-stable,
  extraOverlays ? [ ],
  config ? null,
  # Where relative fix files are; null when the holds came as an attrset.
  root ? null,
}:
final: prev:
let
  inherit (prev) lib;

  # Only these settings: a whole evaluated config doesn't type-check in another nixpkgs.
  carriedConfig = [
    "allowAliases"
    "allowBroken"
    "allowInsecurePredicate"
    "allowNonSource"
    "allowNonSourcePredicate"
    "allowUnfree"
    "allowUnfreePackages"
    "allowUnfreePredicate"
    "allowUnsupportedSystem"
    "allowlistedLicenses"
    "blocklistedLicenses"
    "cudaCapabilities"
    "cudaForwardCompat"
    "cudaSupport"
    "permittedInsecurePackages"
    "rocmSupport"
  ];

  key = from: if from == "stable" then "stable" else from.rev;
  # fetchTarball, not builtins.fetchTree, which needs the flakes feature.
  source =
    from:
    if from == "stable" then
      nixpkgs-stable
    else
      builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${from.rev}.tar.gz";
        sha256 = from.narHash;
      };

  # One package set per source, shared by the entries that use it.
  packageSets = lib.listToAttrs (
    map
      (from: {
        name = key from;
        value = import (source from) {
          inherit (prev.stdenv.hostPlatform) system;
          config =
            if config != null then
              config
            else
              lib.getAttrs (lib.filter (n: prev.config ? ${n}) carriedConfig) prev.config;
          overlays = extraOverlays;
        };
      })
      (lib.unique (lib.filter (from: from != "current") (map (entry: entry.from) (lib.attrValues holds))))
  );

  file =
    p:
    if builtins.isPath p then
      p
    else if root != null then
      root + "/${p}"
    else
      throw "nix-detour: ${p} is relative, but the holds came without a file to resolve it against";
  patch = p: if builtins.isAttrs p then prev.fetchurl { inherit (p) url hash; } else file p;

  fixed =
    entry: package:
    let
      patched =
        if entry.patches or [ ] == [ ] then
          package
        else
          package.overrideAttrs (old: {
            # An earlier overlay may have set patches to null.
            patches = lib.optionals (old.patches or null != null) old.patches ++ map patch entry.patches;
          });
    in
    if entry ? override then
      import (file entry.override) {
        pkgs = final;
        package = patched;
      }
    else
      patched;

  # `home-assistant-custom-components.auth_oidc` is a package inside a set.
  path = name: lib.splitString "." name;
  base =
    name: entry:
    lib.getAttrFromPath (path name) (
      if entry.from == "current" then prev else packageSets.${key entry.from}
    );

  held = name: fixed holds.${name} (base name holds.${name});
in
# Names come from the top level only (`prev ? top`): looking inside a set to
# decide the overlay's names would recurse. A package inside a set replaces
# only its own attribute, if the set has it; the rest of the set stays.
# Shallow names go first, so a hold inside a held set lands on that set.
lib.mapAttrs
  (
    top: names:
    if names == [ top ] then
      held top
    else
      lib.foldl'
        (
          set: name:
          lib.updateManyAttrsByPath [
            {
              path = lib.tail (path name);
              update = _: held name;
            }
          ] set
        )
        prev.${top}
        (
          lib.sort (a: b: lib.length (path a) < lib.length (path b)) (
            lib.filter (name: lib.hasAttrByPath (path name) prev) names
          )
        )
  )
  (
    lib.groupBy (name: lib.head (path name)) (
      lib.filter (name: prev ? ${lib.head (path name)}) (lib.attrNames holds)
    )
  )
