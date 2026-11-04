#!/usr/bin/env bash
# nix-detour: manage a flake's holds and fixes (held-packages.json) and PR
# packages (nixpkgs-prs.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-detour hold <command> [options]
       nix-detour fix <add|list|remove> [options]
           (manage fixes: the current package or holds with a patch or override)

  add NAME --reason TEXT [--link URL] [--from previous|stable|current|REV]
           [--patch URL|FILE]... [--override FILE] [--release-when ATTR]
           [--until-version VERSION] [--tests a,b]
      Hold NAME. --from previous (the default) takes the nixpkgs your
      flake.lock had before its last change to that input, from git history.
      --patch and --override fix the package on top: a patch URL is pinned
      by its hash, a FILE is relative to the holds file's directory, and
      --override FILE holds `{ pkgs, package }: <the fixed package>`.
      Either way it ends once NAME, unfixed, builds from nixos-unstable.
      --until-version VERSION delays release until the upstream package
      version is at least VERSION.
  remove NAME
      Drop the hold of NAME.
  list
      Show every hold, where it comes from and how old it is.
  check [--flake REF] [--channel REF]
      Build what ends each hold (the flake's releaseChecks, with the holds
      its mkHolds reads) from the newest nixpkgs; say which holds can go.

Options for every command:
  --file PATH    the holds file (default: held-packages.json)
  --lock PATH    the flake.lock to read (default: flake.lock)
  --input NAME   the nixpkgs input in that lock (default: nixpkgs)
EOF
}

die() {
  echo "nix-detour: $*" >&2
  exit 1
}

all_check=false
all_list=false
all_release=false
fix=false
case "${1:-}" in
  hold) shift ;;
  fix)
    shift
    fix=true
    ;;
  pr)
    shift
    exec @prs@ "$@"
    ;;
  check)
    shift
    all_check=true
    ;;
  list)
    shift
    all_list=true
    ;;
  release | remove)
    shift
    all_release=true
    ;;
  web)
    shift
    exec @webServer@ "$@"
    ;;
  add) die "add requires domain: nix-detour hold add ... or nix-detour pr add ..." ;;
  -h | --help | "")
    cat <<'EOF'
Usage: nix-detour <command> [options]

Commands:
  hold ...     manage package holds (nix-detour hold --help)
  fix ...      manage package fixes with patches/overrides (nix-detour fix --help)
  pr ...       manage packages from open nixpkgs PRs (nix-detour pr --help)
  list         list all active holds, fixes, and PR detours
  check        check upstream status for both holds and PRs
  release NAME release and retire a hold, fix, or PR detour
  web          launch the interactive web dashboard (nix-detour web --help)
EOF
    [[ -n "${1:-}" ]] || exit 1
    exit 0
    ;;
  *) die "unknown command $1 (see --help)" ;;
esac

file=held-packages.json lock=flake.lock input=nixpkgs
from=previous reason="" link="" release_when="" until_version="" tests="" flake=. channel=github:NixOS/nixpkgs/nixos-unstable
override=""
args=() patches=()
$fix && from=current
# The value of option $1, or an error when it has none.
need() {
  (($# >= 2)) || die "$1 needs a value"
}
while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; shift 2 ;;
    --lock) need "$@"; lock="$2"; shift 2 ;;
    --input) need "$@"; input="$2"; shift 2 ;;
    --from) need "$@"; from="$2"; shift 2 ;;
    --reason) need "$@"; reason="$2"; shift 2 ;;
    --link) need "$@"; link="$2"; shift 2 ;;
    --release-when) need "$@"; release_when="$2"; shift 2 ;;
    --until-version) need "$@"; until_version="$2"; shift 2 ;;
    --tests) need "$@"; tests="$2"; shift 2 ;;
    --patch) need "$@"; patches+=("$2"); shift 2 ;;
    --override) need "$@"; override="$2"; shift 2 ;;
    --flake) need "$@"; flake="$2"; shift 2 ;;
    --channel) need "$@"; channel="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done

holds() {
  if [[ -e $file ]]; then
    jq . "$file" || die "$file is not valid JSON"
  else
    echo '{}'
  fi
}

# Writes the holds from stdin, top-level keys sorted, entries as they are.
# Empty input (a failed jq before it) leaves the file as it is.
write_holds() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
}

if $all_check; then
  ran=false
  failed=false
  if [[ -f $file ]]; then
    echo "=== Holds ==="
    @releaseCheck@ "$flake" "$channel" || failed=true
    ran=true
  fi
  if [[ -f nixpkgs-prs.json ]]; then
    if $ran; then echo ""; fi
    echo "=== PRs ==="
    @prs@ check --channel "$channel" || failed=true
    ran=true
  fi
  if ! $ran; then
    echo "nix-detour: neither $file nor nixpkgs-prs.json found"
    exit 1
  fi
  $failed && exit 1
  exit 0
fi

if $all_list; then
  has_output=false
  if [[ -f $file ]] && (($(jq 'keys | length' "$file" 2>/dev/null || echo 0) > 0)); then
    echo "=== Holds & Fixes ==="
    today=$(date -u +%s)
    holds | jq -r 'to_entries[] | [.key, ((.value.from | if type == "string" then . else .rev[0:12] end)
        + (if (.value.patches // []) != [] or .value.override then "+fix" else "" end)),
      (.value.since // ""), (.value.releaseWhen // "")] | join("\u001f")' |
      while IFS=$'\x1f' read -r n s si rw; do
        age=""
        [[ -z $si ]] || age="$si ($(((today - $(date -u -d "$si" +%s)) / 86400)) days)"
        printf '%-24s %-14s %s%s\n' "$n" "$s" "${age:-no date}" "${rw:+  until $rw builds}" || true
      done
    has_output=true
  fi
  if [[ -f nixpkgs-prs.json ]] && (($(jq 'keys | length' nixpkgs-prs.json 2>/dev/null || echo 0) > 0)); then
    $has_output && echo ""
    echo "=== PRs ==="
    @prs@ list
    has_output=true
  fi
  if ! $has_output; then
    echo "no holds or PRs found"
  fi
  exit 0
fi

if $all_release; then
  name="${args[0]:-}"
  [[ -n $name ]] || die "release needs package name"
  found=false
  if [[ -f $file ]] && jq -e --arg n "$name" 'has($n)' "$file" >/dev/null 2>&1; then
    holds | jq --arg n "$name" 'del(.[$n])' | write_holds
    echo "released hold $name"
    found=true
  fi
  if [[ -f nixpkgs-prs.json ]] && jq -e --arg n "$name" 'has($n)' nixpkgs-prs.json >/dev/null 2>&1; then
    @prs@ remove "$name"
    found=true
  fi
  if ! $found; then
    die "no hold or PR entry '$name' found"
  fi
  exit 0
fi

((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"

# Prints {rev, narHash} of $input in the lock JSON on stdin.
locked_nixpkgs() {
  jq -e --arg i "$input" '
    .nodes[.nodes.root.inputs[$i]
      | if type == "string" then . else error("input \($i) follows another input") end
    ].locked | {rev, narHash}' 2>/dev/null
}

# The nixpkgs before the last change of $input: the newest committed
# flake.lock whose rev differs from the current one.
previous_nixpkgs() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    die "--from previous reads flake.lock's git history; pass --from REV or stable instead"
  fi
  local current commit locked
  current=$(locked_nixpkgs <"$lock" | jq -r .rev) || die "no input $input in $lock"
  while read -r commit; do
    locked=$(git show "$commit:./$lock" 2>/dev/null | locked_nixpkgs) || continue
    if [[ $(jq -r .rev <<<"$locked") != "$current" ]]; then
      echo "$locked"
      return
    fi
  done < <(git log --format=%H -- "$lock")
  die "no earlier nixpkgs in the history of $lock"
}

case "$command" in
  add)
    name="${args[1]:-}"
    [[ -n $name ]] || die "add needs the name of the package"
    [[ -n $reason ]] || die "add needs --reason (why it is held)"
    if $fix && ((${#patches[@]} == 0)) && [[ -z $override ]]; then
      die "fix add needs --patch or --override"
    fi
    # The fix: URLs pinned by their hash, files checked next to the holds file.
    dir=$(dirname "$file")
    patches_json='[]'
    for p in "${patches[@]}"; do
      if [[ $p == http://* || $p == https://* ]]; then
        h=$(nix store prefetch-file --json "$p" | jq -r .hash) || die "cannot fetch $p"
        patches_json=$(jq --arg u "$p" --arg h "$h" '. + [{url: $u, hash: $h}]' <<<"$patches_json")
      else
        [[ -f $dir/$p ]] || die "$p is not a file next to $file"
        patches_json=$(jq --arg p "$p" '. + [$p]' <<<"$patches_json")
      fi
    done
    [[ -z $override || -f $dir/$override ]] || die "$override is not a file next to $file"
    case "$from" in
      stable) source='"stable"' ;;
      current) source='"current"' ;;
      previous) source=$(previous_nixpkgs) ;;
      *)
        hash=$(nix flake prefetch --json "github:NixOS/nixpkgs/$from" | jq -r .hash) \
          || die "cannot fetch nixpkgs $from"
        source=$(jq -n --arg rev "$from" --arg h "$hash" '{rev: $rev, narHash: $h}')
        ;;
    esac
    holds | jq --arg n "$name" --argjson from "$source" --arg since "$(date -u +%F)" \
      --arg reason "$reason" --arg link "$link" --arg rw "$release_when" --arg uv "$until_version" --arg tests "$tests" \
      --argjson patches "$patches_json" --arg override "$override" '
      .[$n] = ({from: $from, since: $since}
        + (if $patches == [] then {} else {patches: $patches} end)
        + (if $override == "" then {} else {override: $override} end)
        + (if $rw == "" then {} else {releaseWhen: $rw} end)
        + (if $uv == "" then {} else {untilVersion: $uv} end)
        + {reason: $reason}
        + (if $link == "" then {} else {link: $link} end)
        + (if $tests == "" then {} else {tests: ($tests | split(","))} end))' | write_holds
    if [[ $patches_json != '[]' || -n $override ]]; then
      echo "fixing $name on $(jq -r --arg n "$name" '.[$n].from | if type == "string" then . else .rev end' "$file")"
    else
      echo "holding $name from $(jq -r --arg n "$name" '.[$n].from | if type == "string" then . else .rev end' "$file")"
    fi
    ;;
  remove)
    name="${args[1]:-}"
    holds | jq -e --arg n "$name" 'has($n)' >/dev/null || die "$name is not held"
    holds | jq --arg n "$name" 'del(.[$n])' | write_holds
    echo "released $name"
    ;;
  list)
    today=$(date -u +%s)
    filter='to_entries[]'
    $fix && filter='to_entries[] | select((.value.patches // []) != [] or .value.override != null or .value.from == "current")'
    holds | jq -r "$filter"' | [.key, ((.value.from | if type == "string" then . else .rev[0:12] end)
        + (if (.value.patches // []) != [] or .value.override then "+fix" else "" end)),
      (.value.since // ""), (.value.releaseWhen // "")] | join("\u001f")' |
      # \x1f, not a tab: read merges runs of whitespace, so an empty field
      # would shift the ones after it.
      while IFS=$'\x1f' read -r name src since rw; do
        age=""
        [[ -z $since ]] || age="$since ($(((today - $(date -u -d "$since" +%s)) / 86400)) days)"
        printf '%-24s %-14s %s%s\n' "$name" "$src" "${age:-no date}" "${rw:+  until $rw builds}"
      done
    ;;
  check)
    @releaseCheck@ "$flake" "$channel"
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
