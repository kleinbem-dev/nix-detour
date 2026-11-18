#!/usr/bin/env bash
# Usage: scripts/worked.sh record FLAKE NAME package|held [NIX_ARGS...]
#        scripts/worked.sh verify FLAKE
#
# A hold's `worked` is the build that last worked: the package without its
# hold, on the nixpkgs the hold comes from. It reads releaseChecks from mkHolds.
#
# record prints `{ version, outPaths: { <system>: <path> } }` for NAME on every
# system of FLAKE's releaseChecks (`package`: without the hold, the last
# working build when NIX_ARGS override nixpkgs to that revision; `held`: with
# it, to accept the current held build). Prints nothing if no system has it.
#
# verify compares each recorded hold with its held package now, per system:
#   same NAME SYSTEM
#   differs NAME SYSTEM RECORDED NOW   (overlays or config change the build)
#   unrecorded NAME SYSTEM             (no `worked` for this system)
#   unchecked SYSTEM REASON
set -uo pipefail

die() {
  echo "worked.sh: $*" >&2
  exit 1
}

systems() {
  nix eval --json "$1#releaseChecks" --apply builtins.attrNames 2>/dev/null | jq -r '.[]'
}

case "${1:-}" in
  record)
    (($# >= 4)) || die "record needs FLAKE NAME package|held"
    flake="$2" name="$3" which="$4"
    shift 4
    case $which in
      package) attr=nixHoldsPackage ;;
      held) attr=nixHoldsHeld ;;
      *) die "record takes package or held, not $which" ;;
    esac
    result='{}'
    while read -r system; do
      [[ -n $system ]] || continue
      # shellcheck disable=SC2016  # Nix expression
      got=$(nix eval "$@" --json "$flake#releaseChecks.$system" --apply "checks:
        let p = (checks.\"$name\" or { }).$attr or null; in
        if p == null then null else { out = p.outPath; version = p.version or null; }" 2>/dev/null) || continue
      [[ $got != null ]] || continue
      result=$(jq --arg s "$system" --argjson g "$got" \
        '.outPaths[$s] = $g.out | if $g.version != null then .version = $g.version else . end' <<<"$result")
    done < <(systems "$flake")
    if [[ $result != '{}' ]]; then
      jq -c '{version, outPaths} | with_entries(select(.value != null))' <<<"$result"
    fi
    ;;
  verify)
    (($# >= 2)) || die "verify needs FLAKE"
    flake="$2"
    found=false
    err=$(mktemp) || exit 1
    trap 'rm -f "$err"' EXIT
    while read -r system; do
      [[ -n $system ]] || continue
      found=true
      # Plain holds only: a fix is meant to differ from the last working build.
      # shellcheck disable=SC2016  # Nix expression
      if ! got=$(nix eval --json "$flake#releaseChecks.$system" --apply "checks:
        builtins.mapAttrs (_: c:
          let
            e = c.nixHolds or { };
            held = builtins.tryEval (c.nixHoldsHeld.outPath or null);
          in {
            plain = builtins.isAttrs (e.from or null) && (e.patches or [ ]) == [ ] && !(e ? override);
            worked = e.worked.outPaths.\"$system\" or null;
            now = if held.success then held.value else null;
          }) checks" 2>"$err"); then
        echo "unchecked $system $(tail -1 "$err")"
        continue
      fi
      jq -r --arg s "$system" 'to_entries[] | select(.value.plain) | .key as $n | .value
        | if .worked == null then "unrecorded \($n) \($s)"
          elif .now == null then "unchecked \($s) \($n) does not evaluate held"
          elif .worked == .now then "same \($n) \($s)"
          else "differs \($n) \($s) \(.worked) \(.now)" end' <<<"$got"
    done < <(systems "$flake")
    $found || die "cannot evaluate $flake#releaseChecks"
    ;;
  *) die "usage: worked.sh record FLAKE NAME package|held [NIX_ARGS...] | verify FLAKE" ;;
esac
