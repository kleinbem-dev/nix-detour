# What the update action checks after a lock update. Only top-level attributes
# can be held, so a package is watched when the attribute of its name is the same
# package; a broken one (outPath throws) matches an attribute that throws too.
{ lib }:
let
  try = builtins.tryEval;

  # The watched packages among `packages`, as { name = pkgs.name; }.
  #   pkgs: the package set the configuration uses (with its holds)
  #   packages: a list of packages (environment.systemPackages, home.packages, ...)
  packages =
    { pkgs, packages }:
    let
      nameOf =
        p:
        let
          name = try (p.pname or (lib.getName p));
        in
        if name.success && builtins.isString name.value then name.value else null;
      same =
        p: name:
        let
          ours = try p.outPath;
          theirs = try pkgs.${name}.outPath;
        in
        if ours.success && theirs.success then
          ours.value == theirs.value
        else
          !ours.success && !theirs.success;
      watched = lib.filter (name: name != null && pkgs ? ${name}) (map nameOf packages);
    in
    lib.genAttrs (lib.filter (name: lib.any (p: nameOf p == name && same p name) packages) (
      lib.unique watched
    )) (name: pkgs.${name});
  # Held packages a target still has unheld, as { name = [ drv ... ]; }: a
  # derivation in its closure with the held package's name (held, or as
  # nixpkgs has it) that isn't the held one. It comes from a package set the
  # overlay doesn't reach, such as another flake's `packages` output.
  #   pkgs: the target's package set (with its holds)
  #   names: the held attribute names
  #   closure: the target's derivations (store paths ending in .drv)
  #   plain: nixpkgs without overlays, for an unheld version's name
  unreached =
    {
      pkgs,
      names,
      closure,
      plain ? import pkgs.path {
        inherit (pkgs.stdenv.hostPlatform) system;
        config.allowAliases = false;
      },
    }:
    let
      nameOf = drv: lib.removeSuffix ".drv" (lib.removePrefix "${builtins.storeDir}/" drv);
      # Without the hash; a name never has a slash, so a bare one passes too.
      bare = drv: lib.concatStringsSep "-" (lib.drop 1 (lib.splitString "-" (nameOf drv)));
      tryName = p: try (builtins.seq p.name p.name);
      check =
        name:
        let
          held = try pkgs.${name}.drvPath;
          heldName = tryName pkgs.${name};
          plainName = if plain ? ${name} then tryName plain.${name} else { success = false; };
          wanted = map (r: r.value) (
            lib.filter (r: r.success) [
              heldName
              plainName
            ]
          );
        in
        if !held.success || wanted == [ ] then
          [ ]
        else
          lib.filter (drv: drv != held.value && lib.elem (bare drv) wanted) closure;
    in
    lib.filterAttrs (_: drvs: drvs != [ ]) (
      lib.genAttrs (lib.filter (name: pkgs ? ${name}) names) check
    );
in
{
  inherit packages unreached;

  # A NixOS configuration as a target (nixDetourTargets): when its toplevel
  # fails to evaluate, the package to hold is found from the error's trace,
  # among the attributes of its package set. Catches packages reached any way
  # (services, config files), not only installed ones.
  target = system: {
    target = system.config.system.build.toplevel;
    inherit (system) pkgs;
  };

  # The system packages of a NixOS configuration (lib.nixosSystem's result),
  # plus the home.packages of its home-manager users, if any.
  nixos =
    system:
    let
      inherit (system) config pkgs;
      home =
        if config ? home-manager then
          lib.concatMap (user: user.home.packages or [ ]) (lib.attrValues (config.home-manager.users or { }))
        else
          [ ];
    in
    packages {
      inherit pkgs;
      packages = config.environment.systemPackages ++ home;
    };
}
