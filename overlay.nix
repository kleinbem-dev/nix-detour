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

  base =
    name: entry:
    if entry.from == "current" then prev.${name} else packageSets.${key entry.from}.${name};
in
lib.mapAttrs (name: entry: fixed entry (base name entry)) (
  lib.filterAttrs (name: _: prev ? ${name}) holds
)
