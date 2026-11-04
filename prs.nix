# Packages and NixOS modules from open nixpkgs PRs, each pinned at one commit and
# built from the PR's own files against your nixpkgs, so you run exactly the PR.
# Works without flakes: `import ./prs.nix { inherit lib; prs = ...; }`.
{
  lib,
  # The PRs file (a path) or the same as an attrset.
  prs,
  # The source tree of an entry. Tests pass a local tree.
  fetch ? (
    entry:
    # fetchTarball, not builtins.fetchTree, which needs the flakes feature.
    builtins.fetchTarball {
      url = "https://github.com/${entry.owner}/${entry.repo}/archive/${entry.rev}.tar.gz";
      sha256 = entry.narHash;
    }
  ),
}:
let
  entries = if builtins.isAttrs prs then prs else lib.importJSON prs;

  packagePath =
    entry: src: name:
    if entry ? paths && entry.paths ? ${name} then
      "${src}/${entry.paths.${name}}"
    else
      "${src}/pkgs/by-name/${lib.substring 0 2 name}/${name}/package.nix";

  allAttrs = lib.concatMap (entry: entry.attrs) (lib.attrValues entries);
  allModules = lib.concatMap (entry: lib.attrNames (entry.modules or { })) (lib.attrValues entries);

  # One entry's attributes, from pkgs. Each entry gets its own scope, so
  # packages of the same PR find each other before falling back to nixpkgs.
  # `scope` names packages of the PR that its attributes need but that aren't
  # exported (a dependency with its own PR, say).
  packagesOf =
    pkgs: entry:
    let
      src = fetch entry;
      scope = lib.makeScope pkgs.newScope (
        self:
        lib.genAttrs (entry.attrs ++ entry.scope or [ ]) (
          name: self.callPackage (packagePath entry src name) { }
        )
      );
    in
    lib.getAttrs entry.attrs scope;

  packages = pkgs: lib.concatMapAttrs (_: packagesOf pkgs) entries;
in
assert lib.assertMsg (lib.allUnique allAttrs) "nix-detour prs: an attribute is in two entries";
assert lib.assertMsg (lib.allUnique allModules) "nix-detour prs: a module name is in two entries";
{
  inherit entries packages;

  # Every entry's packages, built against the package set the overlay is
  # applied to.
  overlay = final: _prev: packages final;

  # Without meta.doc: the manual build rejects chapters missing from nixpkgs'
  # redirects.json. Wrappers keep the function's argument names, since the module
  # system passes only named arguments. The modules need the overlay too.
  nixosModules =
    let
      withoutDoc = module: module // { meta = removeAttrs (module.meta or { }) [ "doc" ]; };
    in
    lib.concatMapAttrs (
      _: entry:
      lib.mapAttrs (
        _: path:
        let
          module = import "${fetch entry}/${path}";
        in
        if lib.isFunction module then
          lib.setFunctionArgs (args: withoutDoc (module args)) (lib.functionArgs module)
        else
          withoutDoc module
      ) (entry.modules or { })
    ) entries;

  # Per entry, from a package set *without* the overlay: its packages, and
  # whether that nixpkgs already has all of them in the same or a newer
  # version (`merged`), so the entry can go. Each carries its entry as
  # `nixPrs`, so the tools read the entries the flake actually uses.
  checks =
    pkgs:
    lib.mapAttrs (
      _: entry:
      let
        ours = packagesOf pkgs entry;
        inNixpkgs =
          attr:
          pkgs ? ${attr}
          && builtins.compareVersions (pkgs.${attr}.version or "") (ours.${attr}.version or "") >= 0;
      in
      {
        packages = ours;
        merged = lib.all inNixpkgs entry.attrs;
        nixPrs = entry;
      }
    ) entries;
}
