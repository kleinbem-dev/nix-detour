#!/usr/bin/env bash
# nix-detour: manage a flake's holds and fixes (held-packages.json) and PR
# packages (nixpkgs-prs.json).
set -euo pipefail

here=$(dirname "$(realpath "$0")")
version="@version@"
[[ $version == @*@ ]] && version="0.4.0"
release_check="@releaseCheck@"
[[ $release_check == @*@ ]] && release_check="$here/release-check.sh"
prs_cli="@prs@"
[[ $prs_cli == @*@ ]] && prs_cli="$here/prs.sh"
web_server_bin="@webServer@"
if [[ $web_server_bin == @*@ ]]; then
  web_server=(python3 "$here/../web/server.py")
else
  web_server=("$web_server_bin")
fi

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
  list [PATH]
      Show every hold, where it comes from and how old it is.
  check [PATH] [--flake REF] [--channel REF]
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

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*$ ]] || die "invalid package name '$1'"
}

all_check=false all_list=false all_release=false fix=false
case "${1:-}" in
  hold) shift ;;
  fix) shift; fix=true ;;
  pr) shift; exec "$prs_cli" "$@" ;;
  check) shift; all_check=true ;;
  list) shift; all_list=true ;;
  release | remove) shift; all_release=true ;;
  web)
    shift
    # The server adds and removes detours through this CLI.
    exec "${web_server[@]}" --cli "$(realpath "$0")" "$@"
    ;;
  add) die "add requires domain: nix-detour hold add ... or nix-detour pr add ..." ;;
  -V | --version)
    echo "nix-detour $version"
    exit 0
    ;;
  -h | --help | "")
    cat <<'EOF'
Usage: nix-detour <command> [options]

Commands:
  hold ...            manage package holds (nix-detour hold --help)
  fix ...             manage package fixes with patches/overrides (nix-detour fix --help)
  pr ...              manage packages from open nixpkgs PRs (nix-detour pr --help)
  list [PATH]         list all active holds, fixes, and PR detours
  check [PATH]        check upstream status for both holds and PRs
  release NAME [PATH] release and retire a hold, fix, or PR detour
  web                 launch the interactive web dashboard (nix-detour web --help)
EOF
    [[ -n "${1:-}" ]] || exit 1
    exit 0
    ;;
  *) die "unknown command $1 (see --help)" ;;
esac

file=held-packages.json prs_file=nixpkgs-prs.json lock=flake.lock input=nixpkgs
file_explicit=false lock_explicit=false flake_explicit=false channel_explicit=false
from=previous reason="" link="" release_when="" until_version="" tests=""
flake=. channel=github:NixOS/nixpkgs/nixos-unstable override=""
args=() patches=()
$fix && from=current

need() {
  (($# >= 2)) || die "$1 needs a value"
}

while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; file_explicit=true; shift 2 ;;
    --lock) need "$@"; lock="$2"; lock_explicit=true; shift 2 ;;
    --input) need "$@"; input="$2"; shift 2 ;;
    --from) need "$@"; from="$2"; shift 2 ;;
    --reason) need "$@"; reason="$2"; shift 2 ;;
    --link) need "$@"; link="$2"; shift 2 ;;
    --release-when) need "$@"; release_when="$2"; shift 2 ;;
    --until-version) need "$@"; until_version="$2"; shift 2 ;;
    --tests) need "$@"; tests="$2"; shift 2 ;;
    --patch) need "$@"; patches+=("$2"); shift 2 ;;
    --override) need "$@"; override="$2"; shift 2 ;;
    --flake) need "$@"; flake="$2"; flake_explicit=true; shift 2 ;;
    --channel) need "$@"; channel="$2"; channel_explicit=true; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    --) shift; args+=("$@"); break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done

to_flake() {
  local p="$1"
  if [[ $p != /* && $p != ./* && $p != ../* && $p != *:* ]]; then
    echo "./$p"
  else
    echo "$p"
  fi
}

# Resolves positional directory or JSON file PATH into $file, $prs_file, $lock, $flake.
resolve_target() {
  local target="$1" dir
  $file_explicit && die "cannot combine --file with a positional target"
  if [[ -d $target ]]; then
    file="$target/held-packages.json"
    prs_file="$target/nixpkgs-prs.json"
    $lock_explicit || lock="$target/flake.lock"
    $flake_explicit || flake=$(to_flake "$target")
  elif [[ -f $target ]]; then
    dir=$(dirname "$target")
    if [[ ${target##*/} == *nixpkgs-prs.json* ]]; then
      prs_file="$target"
      file="$dir/held-packages.json"
    else
      file="$target"
      prs_file="$dir/nixpkgs-prs.json"
    fi
    $lock_explicit || lock="$dir/flake.lock"
    $flake_explicit || flake=$(to_flake "$dir")
  else
    die "target path '$target' not found"
  fi
}

if $file_explicit; then
  prs_file="$(dirname "$file")/nixpkgs-prs.json"
fi

if ($all_list || $all_check) && [[ -n ${args[0]:-} ]]; then
  resolve_target "${args[0]}"
elif ! $all_release && [[ ${args[0]:-} == "list" || ${args[0]:-} == "check" ]] && [[ -n ${args[1]:-} ]]; then
  resolve_target "${args[1]}"
fi

holds() {
  if [[ -e $file ]]; then
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file is not a valid JSON object"
    cat "$file"
  else
    echo '{}'
  fi
}

# Writes the holds from stdin with sorted top-level keys; leaves $file intact on error.
write_holds() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
}

# Formats holds from stdin; jq handles date parsing so BSD/macOS date works and
# malformed `since` values never abort listing.
# shellcheck disable=SC2016  # jq program
print_holds() {
  local only_fixes="${1:-false}"
  jq -r --argjson today "$(date -u +%s)" --argjson fix "$only_fixes" '
    to_entries[]
    | select(($fix | not) or (.value.patches // []) != [] or .value.override != null or .value.from == "current")
    | .key as $name
    | ((.value.from | if type == "string" then . else .rev[0:12] end)
        + (if (.value.patches // []) != [] or .value.override then "+fix" else "" end)) as $src
    | (.value.since // "") as $since
    | (if $since == "" then "no date"
       else (try ($since | strptime("%Y-%m-%d") | mktime) catch null) as $ts
         | if $ts != null then "\($since) (\((($today - $ts) / 86400) | floor) days)"
           else $since end
       end) as $age
    | (.value.releaseWhen // "") as $rw
    | [$name, $src, $age, (if $rw == "" then "" else "  until \($rw) builds" end)]
    | join("\u001f")' |
    while IFS=$'\x1f' read -r n s age rw; do
      printf '%-24s %-14s %s%s\n' "$n" "$s" "$age" "$rw"
    done
}

if $all_check; then
  ran=false failed=false
  if [[ -f $file ]]; then
    echo "=== Holds ==="
    "$release_check" "$flake" "$channel" || failed=true
    ran=true
  fi
  if [[ -f $prs_file ]]; then
    $ran && echo ""
    echo "=== PRs ==="
    pr_check_args=(check --file "$prs_file")
    $channel_explicit && pr_check_args+=(--channel "$channel")
    "$prs_cli" "${pr_check_args[@]}" || failed=true
    ran=true
  fi
  $ran || die "neither $file nor $prs_file found"
  $failed && exit 1
  exit 0
fi

if $all_list; then
  has_output=false
  if [[ -f $file ]]; then
    holds_data=$(holds)
    if (($(jq 'length' <<<"$holds_data") > 0)); then
      echo "=== Holds & Fixes ==="
      print_holds false <<<"$holds_data"
      has_output=true
    fi
  fi
  if [[ -f $prs_file ]]; then
    jq -e 'type == "object"' "$prs_file" >/dev/null 2>&1 || die "$prs_file is not a valid JSON object"
    if (($(jq 'length' "$prs_file") > 0)); then
      $has_output && echo ""
      echo "=== PRs ==="
      "$prs_cli" list --file "$prs_file"
      has_output=true
    fi
  fi
  $has_output || echo "no holds or PRs found"
  exit 0
fi

if $all_release; then
  name="${args[0]:-}"
  [[ -n ${args[1]:-} ]] && resolve_target "${args[1]}"
  [[ -n $name ]] || die "release needs package name"
  valid_name "$name"
  holds_data='{}'
  [[ -f $file ]] && holds_data=$(holds)
  if [[ -f $prs_file ]]; then
    jq -e 'type == "object"' "$prs_file" >/dev/null 2>&1 || die "$prs_file is not a valid JSON object"
  fi
  found=false
  if [[ -f $file ]] && jq -e --arg n "$name" 'has($n)' <<<"$holds_data" >/dev/null; then
    jq --arg n "$name" 'del(.[$n])' <<<"$holds_data" | write_holds
    echo "released hold $name"
    found=true
  fi
  if [[ -f $prs_file ]] && jq -e --arg n "$name" 'has($n)' "$prs_file" >/dev/null; then
    "$prs_cli" remove --file "$prs_file" -- "$name"
    found=true
  fi
  $found || die "no hold or PR entry '$name' found"
  exit 0
fi

((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"

# Resolves $input (including nested `a/b` paths and `follows` arrays) to {rev, narHash}.
# shellcheck disable=SC2016  # jq program
locked_nixpkgs() {
  jq -e --arg i "$input" '
    . as $lock
    | def nodeof($segs): reduce $segs[] as $s ($lock.root // "root";
        if . == null then null else ($lock.nodes[.].inputs[$s] // null)
        | if type == "array" then nodeof(.) else . end end);
    $lock.nodes[nodeof($i | split("/"))].locked
    | select(. != null and .rev != null and .narHash != null)
    | {rev, narHash}' 2>/dev/null
}

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
    valid_name "$name"
    [[ -n $reason ]] || die "add needs --reason (why it is held)"
    if $fix && ((${#patches[@]} == 0)) && [[ -z $override ]]; then
      die "fix add needs --patch or --override"
    fi
    dir=$(dirname "$file")
    patches_json='[]'
    for p in "${patches[@]}"; do
      if [[ $p == http://* || $p == https://* ]]; then
        h=$(nix store prefetch-file --json "$p" | jq -er .hash) || die "cannot fetch $p"
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
        hash=$(nix flake prefetch --json "github:NixOS/nixpkgs/$from" | jq -er .hash) \
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
    src_label=$(jq -r --arg n "$name" '.[$n].from | if type == "string" then . else .rev end' "$file")
    if [[ $patches_json != '[]' || -n $override ]]; then
      echo "fixing $name on $src_label"
    else
      echo "holding $name from $src_label"
    fi
    ;;
  remove)
    name="${args[1]:-}"
    [[ -n $name ]] || die "remove needs the name of the package"
    valid_name "$name"
    holds_data=$(holds)
    jq -e --arg n "$name" 'has($n)' <<<"$holds_data" >/dev/null || die "$name is not held"
    jq --arg n "$name" 'del(.[$n])' <<<"$holds_data" | write_holds
    echo "released $name"
    ;;
  list)
    holds | print_holds "$fix"
    ;;
  check)
    "$release_check" "$flake" "$channel"
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
