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

  pythonPath =
    entry: src: name:
    let
      key = "python3Packages.${name}";
    in
    if entry ? paths && entry.paths ? ${key} then
      "${src}/${entry.paths.${key}}"
    else
      "${src}/pkgs/development/python-modules/${name}/default.nix";

  allAttrs = lib.concatMap (entry: entry.attrs) (lib.attrValues entries);
  allPython = lib.concatMap (entry: entry.pythonPackages or [ ]) (lib.attrValues entries);
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

  # An entry's Python packages, from a Python package set. Arguments that the
  # entry's own packages provide (a library the bindings load, say) come from
  # them, the rest from the Python set.
  pythonPackagesOf =
    python: ours: entry:
    let
      src = fetch entry;
    in
    lib.genAttrs (entry.pythonPackages or [ ]) (
      name:
      let
        path = pythonPath entry src name;
      in
      python.callPackage path (lib.intersectAttrs (lib.functionArgs (import path)) ours)
    );

  # The derivations of a set of packages, a scope's as `<scope>.<name>`, so the
  # tools can evaluate and build each one.
  derivations =
    set:
    lib.concatMapAttrs (
      name: value:
      if lib.isDerivation value then
        { ${name} = value; }
      else
        lib.mapAttrs' (sub: lib.nameValuePair "${name}.${sub}") (
          lib.filterAttrs (_: lib.isDerivation) value
        )
    ) set;
in
assert lib.assertMsg (lib.allUnique allAttrs) "nix-detour prs: an attribute is in two entries";
assert lib.assertMsg (lib.allUnique allModules) "nix-detour prs: a module name is in two entries";
assert lib.assertMsg (lib.allUnique allPython) "nix-detour prs: a Python package is in two entries";
{
  inherit entries packages;

  # Every entry's packages, built against the package set the overlay is
  # applied to.
  # Python packages go into every Python package set, and find the entries'
  # other packages in the overlaid set.
  overlay =
    final: prev:
    packages final
    // lib.optionalAttrs (allPython != [ ]) {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (
          pyfinal: _:
          lib.concatMapAttrs (
            _: entry: pythonPackagesOf pyfinal (lib.getAttrs entry.attrs final) entry
          ) entries
        )
      ];
    };

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
        # The entry's Python packages in a Python set that has all of them, as
        # the overlay's does, so they find each other.
        pythonSet =
          let
            python = pkgs.python3.override {
              self = python;
              packageOverrides = pyfinal: _: pythonPackagesOf pyfinal ours entry;
            };
          in
          python.pkgs;
        python = lib.mapAttrs' (name: lib.nameValuePair "python3Packages.${name}") (
          lib.getAttrs (entry.pythonPackages or [ ]) pythonSet
        );
        all = derivations ours // python;
        # Whether nixpkgs has the package at this attribute path, in the same or
        # a newer version.
        inNixpkgs =
          path:
          let
            theirs = lib.attrByPath (lib.splitString "." path) null pkgs;
          in
          theirs != null && builtins.compareVersions (theirs.version or "") (all.${path}.version or "") >= 0;
      in
      {
        packages = all;
        merged = lib.all inNixpkgs (lib.attrNames all);
        nixPrs = entry;
      }
    ) entries;
}
