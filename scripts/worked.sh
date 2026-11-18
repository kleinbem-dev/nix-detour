#!/usr/bin/env bash
# Usage: scripts/worked.sh record FLAKE NAME package|held [NIX_ARGS...]
#        scripts/worked.sh verify FLAKE [HOLDS]
#
# A hold's `worked` is the build that last worked: the package without its
# hold, on the nixpkgs the hold comes from. It reads releaseChecks from mkHolds.
# NIX_DETOUR_ARGS (as for update.sh) go to every evaluation.
#
# record prints `{ version, outPaths: { <system>: <path> }, failed: [<system>] }`
# for NAME on every system of FLAKE's releaseChecks (`package`: without the
# hold, the last working build when NIX_ARGS pin that nixpkgs; `held`: with it,
# to accept the current held build). `failed` lists systems whose evaluation
# failed, as opposed to ones without NAME. Prints nothing if no system has it.
#
# verify compares each recorded hold (not fixes) with its held package now:
#   same NAME SYSTEM
#   differs NAME SYSTEM RECORDED NOW   (overlays or config change the build)
#   unrecorded NAME SYSTEM             (no `worked` for this system)
#   unchecked SYSTEM REASON
# With HOLDS, a recorded hold missing from the release checks is unchecked
# too. Exits 1 if anything couldn't be checked.
set -uo pipefail

die() {
  echo "worked.sh: $*" >&2
  exit 1
}

read -ra nix_args <<<"${NIX_DETOUR_ARGS:-}"
systems() {
  nix eval "${nix_args[@]}" "${@:2}" --json "$1#releaseChecks" --apply builtins.attrNames 2>/dev/null | jq -r '.[]'
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
    result='{"failed": []}'
    while read -r system; do
      [[ -n $system ]] || continue
      # shellcheck disable=SC2016  # Nix expression
      if ! got=$(nix eval "${nix_args[@]}" "$@" --json "$flake#releaseChecks.$system" --apply "checks:
        let p = (checks.\"$name\" or { }).$attr or null; in
        if p == null then null else { out = p.outPath; version = p.version or null; }" 2>/dev/null); then
        result=$(jq --arg s "$system" '.failed += [$s]' <<<"$result")
        continue
      fi
      [[ $got != null ]] || continue
      result=$(jq --arg s "$system" --argjson g "$got" \
        '.outPaths[$s] = $g.out | if $g.version != null then .version = $g.version else . end' <<<"$result")
    done < <(systems "$flake" "$@")
    if jq -e '.outPaths' <<<"$result" >/dev/null; then
      jq -c '{version, outPaths, failed} | with_entries(select(.value != null and .value != []))' <<<"$result"
    fi
    ;;
  verify)
    (($# >= 2)) || die "verify needs FLAKE"
    flake="$2" holds="${3:-}"
    found=false incomplete=false
    err=$(mktemp) || exit 1
    trap 'rm -f "$err"' EXIT
    while read -r system; do
      [[ -n $system ]] || continue
      found=true
      # Fixes are meant to differ from the last working build: left out
      # before their held package is evaluated.
      # shellcheck disable=SC2016  # Nix expression
      if ! got=$(nix eval "${nix_args[@]}" --json "$flake#releaseChecks.$system" --apply "checks:
        builtins.mapAttrs (_: c:
          let held = builtins.tryEval (c.nixHoldsHeld.outPath or null); in {
            worked = c.nixHolds.worked.outPaths.\"$system\" or null;
            now = if held.success then held.value else null;
          }) (builtins.filterAttrs (_: c:
            let e = c.nixHolds or { }; in
            (e.from or null) != \"current\" && (e.patches or [ ]) == [ ] && !(e ? override)) checks)" 2>"$err"); then
        echo "unchecked $system $(tail -1 "$err")"
        incomplete=true
        continue
      fi
      jq -r --arg s "$system" 'to_entries[] | .key as $n | .value
        | if .worked == null then "unrecorded \($n) \($s)"
          elif .now == null then "unchecked \($s) \($n) does not evaluate held"
          elif .worked == .now then "same \($n) \($s)"
          else "differs \($n) \($s) \(.worked) \(.now)" end' <<<"$got"
      jq -e 'any(.[]; .worked != null and .now == null)' <<<"$got" >/dev/null && incomplete=true
      if [[ -n $holds && -f $holds ]]; then
        missing=$(jq -r --arg s "$system" --argjson got "$got" \
          'to_entries[] | .key as $k | select(.value.worked.outPaths[$s] != null and ($got | has($k) | not)) | $k' "$holds")
        for name in $missing; do
          echo "unchecked $system $name is recorded in $holds but not in the release checks (does the flake read this file?)"
          incomplete=true
        done
      fi
    done < <(systems "$flake")
    $found || { echo "unchecked all cannot evaluate $flake#releaseChecks"; exit 1; }
    $incomplete && exit 1
    exit 0
    ;;
  *) die "usage: worked.sh record FLAKE NAME package|held [NIX_ARGS...] | verify FLAKE [HOLDS]" ;;
esac
