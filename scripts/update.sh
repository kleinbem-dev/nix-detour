#!/usr/bin/env bash
# Usage: scripts/update.sh FLAKE [--no-build | --build-fetches] [--only a,b]
#
# After a lock update, finds the failing packages FLAKE uses, so they can be held:
# nixDetourWatch packages are evaluated one by one and built if no substituter has
# them (with --build-fetches only their fixed-output derivations, where a stale
# hash shows); for each failing nixDetourTargets target, the innermost derivation
# in the trace that fails on its own in pkgs (one per target and run).
#
# Prints "broken <name> <reason>", "unavailable <name> <reason>" (a download
# failed: says nothing about the update), "unattributed <target> <reason>" and
# "ok <system> <count>". NIX_DETOUR_ARGS and NIX_DETOUR_OVERRIDE go to every flake
# eval and build; NIX_DETOUR_SYSTEMS (default: this one) are evaluated, only this
# one built.
set -uo pipefail

flake="$1"
shift
build=true only=""
while (($#)); do
  case "$1" in
    --no-build) build=false; shift ;;
    --build-fetches) build=fetches; shift ;;
    --only) only="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

read -ra extra <<<"${NIX_DETOUR_ARGS:-} ${NIX_DETOUR_OVERRIDE:-}"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
native=$(nix eval --raw --impure --expr builtins.currentSystem)
read -ra systems <<<"${NIX_DETOUR_SYSTEMS:-}"
((${#systems[@]})) || systems=("$native")
# shellcheck disable=SC2016  # a Nix expression
filter='ws: let only = builtins.filter (n: builtins.isString n && n != "") (builtins.split "," "'"$only"'"); in
  if only == [ ] then ws else builtins.intersectAttrs (builtins.listToAttrs (map (n: { name = n; value = null; }) only)) ws'

# The innermost error in nix's stderr on stdin, the cause (the outer ones are
# often a bare "error:"), with a "- broken: ..." list after it.
innermost() {
  awk '
    /^[[:space:]]*error:[[:space:]]*[^[:space:]]/ { sub(/^[[:space:]]*error:[[:space:]]*/, ""); last = $0; inlist = 1; next }
    inlist && /^[[:space:]]*- / { sub(/^[[:space:]]*/, " "); last = last $0; next }
    { inlist = 0 }
    END { print last }' | sed -E 's| in /nix/store/[^ ]+||' | cut -c1-300
}

# The first network error in nix's log $1: a download that failed, not a
# broken package. Only errors count (nix warns on every retry), and a 404 is
# not one of them: that source is gone.
network_error() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -m1 -oE \
    "error: unable to download '[^']+': (HTTP error (429|5[0-9][0-9])|Could not|Couldn't|Timeout|Failed to connect|SSL|Recv failure|Empty reply)[^;]*|curl: \((6|7|28|35|52|56)\)[^;]*|curl: \(22\) The requested URL returned error: (429|5[0-9][0-9])" |
    cut -c1-200
}

# Builds only the fixed-output derivations among $tobuild (fetches, vendored
# dependencies) and reports each watched package in "${mine[@]}" that needs
# one that fails. Nothing else of the package is built.
build_fetches() {
  local shown fods fod name drv why closure
  # A failed inspection is reported: no fetches found would read as "ok".
  shown=$(nix derivation show --stdin <<<"$tobuild" 2>"$tmp/err") || {
    echo "unattributed $watchOut.$system fetches not checked: $(innermost <"$tmp/err")"
    return 0
  }
  mapfile -t fods < <(jq -r '(.derivations // .) | to_entries[] | select(.value.outputs.out.hash != null) | .key | sub(".*/"; "")' <<<"$shown")
  ((${#fods[@]})) || return 0
  fods=("${fods[@]/#//nix/store/}")
  nix build "${extra[@]}" --fallback --no-link --keep-going "${fods[@]/%/^*}" 2>&1 | tee "$tmp/fetch.log" >&2
  : >"$tmp/failed"
  : >"$tmp/unavailable"
  for fod in "${fods[@]}"; do
    # shellcheck disable=SC2046  # one output path
    nix-store --check-validity $(nix-store -q --outputs "$fod") 2>/dev/null && continue
    name=${fod#/nix/store/*-}
    name=${name%.drv}
    # Once more on its own: a download that failed once is not a broken fetch.
    nix build "${extra[@]}" --fallback --no-link "$fod^*" >"$tmp/one.log" 2>&1 && continue
    cat "$tmp/one.log" >&2
    # nix's own error has the hash a fix needs.
    why=$(awk 'index($0, "hash mismatch in fixed-output derivation") { hit = 1 }
      hit && /got:/ { print $NF; exit }' "$tmp/one.log")
    if [[ -n $why ]]; then
      printf '%s\t%s\n' "$fod" "hash mismatch in $name (got $why)" >>"$tmp/failed"
    elif why=$(network_error "$tmp/one.log") && [[ -n $why ]]; then
      printf '%s\t%s\n' "$fod" "$name: $why" >>"$tmp/unavailable"
    else
      printf '%s\t%s\n' "$fod" "its fetch $name fails" >>"$tmp/failed"
    fi
  done
  [[ -s $tmp/failed || -s $tmp/unavailable ]] || return 0
  while read -r name drv; do
    closure=$(nix-store -qR "$drv")
    # A broken fetch wins over a failed download in the same package.
    while IFS=$'\t' read -r fod why; do
      if grep -qxF "$fod" <<<"$closure"; then
        broken+=("$name")
        echo "broken $name $why"
        continue 2
      fi
    done <"$tmp/failed"
    while IFS=$'\t' read -r fod why; do
      if grep -qxF "$fod" <<<"$closure"; then
        echo "unavailable $name $why"
        continue 2
      fi
    done <"$tmp/unavailable"
  done < <(jq -r --arg m "${mine[*]}" '($m | split(" ")) as $set
    | to_entries[] | select(.value != null and (.value.drv | IN($set[]))) | "\(.key) \(.value.drv)"' <<<"$results")
}

# Why evaluating watched package NAME fails.
reason() {
  nix eval "${extra[@]}" --raw "$watch.\"$1\".drvPath" 2>&1 >/dev/null | innermost
}

# Whether the flake has output $1 for this system (an output that fails to
# evaluate counts as there).
has_output() {
  local err
  err=$(nix eval "${extra[@]}" --raw "$flake#$1.$system" --apply 'x: "yes"' 2>&1 >/dev/null) && return 0
  ! grep -q 'does not provide attribute' <<<"$err"
}

# Checks one system; $system is the one.
check() {
  local system="$1" results broken watch targets target err chain name why list watchOut targetsOut
  results='{}' broken=()
  # The old nix-holds output names still work, with a warning.
  watchOut=nixDetourWatch targetsOut=nixDetourTargets
  if ! has_output nixDetourWatch && has_output nixHoldsWatch; then
    echo "nixHoldsWatch is now nixDetourWatch; rename the output" >&2
    watchOut=nixHoldsWatch
  fi
  if ! has_output nixDetourTargets && has_output nixHoldsTargets; then
    echo "nixHoldsTargets is now nixDetourTargets; rename the output" >&2
    targetsOut=nixHoldsTargets
  fi
  watch="$flake#$watchOut.$system"
  if has_output "$watchOut"; then
    # name -> { drv, out } or null when it doesn't evaluate. tryEval catches
    # throws (broken, unfree, insecure, removed aliases); other errors fail the
    # whole evaluation, and then each name is evaluated on its own.
    results=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.mapAttrs (_: p:
      let r = builtins.tryEval (builtins.seq p.drvPath p.outPath); in
      if r.success then { drv = p.drvPath; out = r.value; } else null) (($filter) ws)" 2>/dev/null)
    if [[ -z $results ]]; then
      # A watch list that can't even be listed (say, a host's package list
      # names a removed attribute) is reported; the targets still run.
      names=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.attrNames (($filter) ws)" 2>"$tmp/err") || {
        echo "unattributed $watchOut.$system $(innermost <"$tmp/err")"
        names='[]'
      }
      results='{}'
      mapfile -t list < <(jq -r '.[]' <<<"$names")
    for name in "${list[@]}"; do
        one=$(nix eval "${extra[@]}" --json "$watch.\"$name\"" --apply 'p: { drv = p.drvPath; out = p.outPath; }' 2>/dev/null || echo null)
        results=$(jq --arg n "$name" --argjson v "$one" '.[$n] = $v' <<<"$results")
      done
    fi

    broken=()
    while read -r name; do
      [[ -n $name ]] || continue
      broken+=("$name")
      echo "broken $name $(reason "$name")"
    done < <(jq -r 'to_entries[] | select(.value == null) | .key' <<<"$results")

    if [[ $build != false && $system == "$native" ]]; then
      mapfile -t drvs < <(jq -r '.[] | select(. != null) | .drv' <<<"$results")
      if ((${#drvs[@]})); then
        # What no substituter has: the watched derivations themselves among what
        # a build would build (their dependencies get built along the way).
        tobuild=$(nix build "${extra[@]}" --dry-run "${drvs[@]/%/^*}" 2>&1 | sed -n '/will be built:/,/will be fetched/p' | grep -oE '/nix/store/[^ ]+\.drv' | sort -u)
        mapfile -t mine < <(jq -r --arg b "$tobuild" '($b | split("\n")) as $set
          | to_entries[] | select(.value != null and (.value.drv | IN($set[]))) | .value.drv' <<<"$results")
        if ((${#mine[@]})) && [[ $build == fetches ]]; then
          build_fetches
        elif ((${#mine[@]})); then
          nix build "${extra[@]}" --fallback --no-link --keep-going "${mine[@]/%/^*}" >&2 || true
          while read -r name drv out; do
            nix path-info "$out" >/dev/null 2>&1 && continue
            # Once more on its own: a download that failed once is not a broken package.
            nix build "${extra[@]}" --fallback --no-link "$drv^*" >"$tmp/one.log" 2>&1 && continue
            cat "$tmp/one.log" >&2
            if why=$(network_error "$tmp/one.log") && [[ -n $why ]]; then
              echo "unavailable $name $why"
            else
              broken+=("$name")
              echo "broken $name fails to build"
            fi
          done < <(jq -r --arg m "${mine[*]}" '($m | split(" ")) as $set
            | to_entries[] | select(.value != null and (.value.drv | IN($set[]))) | "\(.key) \(.value.drv) \(.value.out)"' <<<"$results")
        fi
      fi
    fi
  fi

  if [[ -z $only ]] && has_output "$targetsOut"; then
    targets=$(nix eval "${extra[@]}" --json "$flake#$targetsOut.$system" --apply builtins.attrNames 2>"$tmp/err") || {
      echo "unattributed $targetsOut.$system $(innermost <"$tmp/err")"
      targets='[]'
    }
    mapfile -t list < <(jq -r '.[]' <<<"$targets")
    for target in "${list[@]}"; do
      err=$(nix eval "${extra[@]}" --show-trace --raw "$flake#$targetsOut.$system.\"$target\".target.drvPath" 2>&1 >/dev/null) && continue
      # The derivations in the trace, innermost first.
      chain=$(grep -oE "while evaluating derivation '[^']+'" <<<"$err" | cut -d"'" -f2 | tac | jq -Rsc 'split("\n") | map(select(. != ""))')
      # shellcheck disable=SC2016  # a Nix expression
      name=$(nix eval "${extra[@]}" --raw "$flake#$targetsOut.$system.\"$target\".pkgs" --apply "pkgs: let
          names = map (d: (builtins.parseDrvName d).name) (builtins.fromJSON ''$chain'');
          held = builtins.filter (n: pkgs ? \${n} && !(builtins.tryEval pkgs.\${n}.drvPath).success) names;
        in if held == [ ] then \"\" else builtins.head held" 2>/dev/null)
      why=$(innermost <<<"$err")
      if [[ -n $name ]]; then
        echo "broken $name $why (in $target)"
      else
        echo "unattributed $target $why"
      fi
    done
  fi

  echo "ok $system $(($(jq 'length' <<<"$results") - ${#broken[@]}))"
}

for system in "${systems[@]}"; do
  check "$system"
done
