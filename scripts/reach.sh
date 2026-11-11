#!/usr/bin/env bash
# Usage: scripts/reach.sh FLAKE HOLDS
#
# For each nixDetourTargets target that evaluates, the holds in HOLDS that it
# still has unheld (watch.nix's unreached): a derivation with the held
# package's name that isn't the held one, from a package set the holds
# overlay doesn't reach. Such a hold can't fix that target.
#
# Prints "unreached <name> <target> <drv>". NIX_DETOUR_ARGS,
# NIX_DETOUR_OVERRIDE and NIX_DETOUR_SYSTEMS as for update.sh.
set -uo pipefail

flake="$1"
holds="$2"
here=$(dirname "$(realpath "$0")")
read -ra extra <<<"${NIX_DETOUR_ARGS:-} ${NIX_DETOUR_OVERRIDE:-}"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
names=$(jq -c 'keys' "$holds") || exit 1
[[ $names != "[]" ]] || exit 0
read -ra systems <<<"${NIX_DETOUR_SYSTEMS:-}"
((${#systems[@]})) || systems=("$(nix eval --raw --impure --expr builtins.currentSystem)")

for system in "${systems[@]}"; do
  out="$flake#nixDetourTargets.$system"
  targets=$(nix eval "${extra[@]}" --json "$out" --apply builtins.attrNames 2>/dev/null) || continue
  mapfile -t list < <(jq -r '.[]' <<<"$targets")
  for target in "${list[@]}"; do
    # A target that fails to evaluate is update.sh's to report.
    drv=$(nix eval "${extra[@]}" --raw "$out.\"$target\".target.drvPath" 2>/dev/null) || continue
    nix-store -qR "$drv" | grep '\.drv$' | jq -Rsc 'split("\n") | map(select(. != ""))' >"$tmp/closure.json"
    nix eval "${extra[@]}" --impure --json "$out.\"$target\".pkgs" --apply "pkgs:
      (import $here/../watch.nix { inherit (pkgs) lib; }).unreached {
        inherit pkgs;
        names = builtins.fromJSON ''$names'';
        closure = builtins.fromJSON (builtins.readFile $tmp/closure.json);
      }" 2>"$tmp/err" | jq -r --arg t "$target" 'to_entries[] | .key as $n | .value[] | "unreached \($n) \($t) \(.)"' \
      || echo "reach: $target not checked: $(tail -1 "$tmp/err")" >&2
  done
done
