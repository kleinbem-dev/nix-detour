# What `worked.sh verify` compares, from one system's release checks: per hold
# the recorded build and the held one now. Fixes are meant to differ from the
# last working build, so they're left out before their held package is evaluated.
system: checks:
let
  isFix =
    c:
    let
      e = c.nixHolds or { };
    in
    (e.from or null) == "current" || (e.patches or [ ]) != [ ] || e ? override;
  fixes = builtins.filter (n: isFix checks.${n}) (builtins.attrNames checks);
in
builtins.mapAttrs (
  _: c:
  let
    held = builtins.tryEval (c.nixHoldsHeld.outPath or null);
  in
  {
    worked = c.nixHolds.worked.outPaths.${system} or null;
    now = if held.success then held.value else null;
  }
) (builtins.removeAttrs checks fixes)
