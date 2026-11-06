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
in
{
  inherit packages;

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
