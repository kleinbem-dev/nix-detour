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
worked_cli="@worked@"
[[ $worked_cli == @*@ ]] && worked_cli="$here/worked.sh"
generations_sh="@generations@"
[[ $generations_sh == @*@ ]] && generations_sh="$here/generations.sh"
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
           [--until-version VERSION] [--tests a,b] [--no-record]
      Hold NAME. --from previous (the default) takes the nixpkgs your
      flake.lock had before its last change to that input, from the history
      of the default branch (origin/HEAD, else HEAD; first parents only), so
      only a lock that was merged there counts.
      --from generation[:N] [--host HOST] takes the nixpkgs a system
      generation ran (default: the newest one on an older nixpkgs than the
      newest generation), here or on HOST over ssh: for a package that
      builds but broke at runtime. It says whether the hold builds what that
      generation ran.
      A hold on a nixpkgs revision records the build that last worked
      (`worked`: version and store path per system), from the flake's
      releaseChecks on that revision; --no-record skips it.
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
  verify [PATH] [--flake REF]
      Check that each recorded hold still builds what last worked: "differs"
      means your overlays or config changed the held package.
  refresh NAME [--flake REF]
      Record the held package as it builds now, after such a change on purpose.
  history NAME [--host HOST] [--limit N]
      NAME across the default branch's lock history (version, broken or
      which substituter has it) and the system generations here or on HOST:
      where to hold it from.
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
from=previous reason="" link="" release_when="" until_version="" tests="" record=true
host="" limit=""
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
    --no-record) record=false; shift ;;
    --host) need "$@"; host="$2"; shift 2 ;;
    --limit)
      need "$@"
      [[ $2 =~ ^[1-9][0-9]*$ ]] || die "--limit needs a positive number"
      limit="$2"
      shift 2
      ;;
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
elif ! $all_release && [[ ${args[0]:-} == "list" || ${args[0]:-} == "check" || ${args[0]:-} == "verify" ]] && [[ -n ${args[1]:-} ]]; then
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

# Applies a jq filter to the holds file under a lock (like prs.sh) and
# replaces it in one move (mode as a plain write; mktemp's 0600 would hide it
# from other readers); returns 1 if the filter or the write fails.
update_holds() {
  local lockdir="$file.lock" waited=0 new tmp="" status=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    ((++waited <= 200)) || { echo "nix-detour: timed out waiting for $lockdir" >&2; return 1; }
    sleep 0.05
  done
  if new=$(holds | jq "$@" 2>/dev/null | jq --indent 2 'to_entries | sort_by(.key) | from_entries') \
    && [[ -n $new ]] && tmp=$(mktemp "$file.XXXXXX") \
    && chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp" && printf '%s\n' "$new" >"$tmp" && mv "$tmp" "$file"; then
    :
  else
    status=1
    [[ -z $tmp ]] || rm -f "$tmp"
  fi
  rmdir "$lockdir" 2>/dev/null || true
  return "$status"
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
        + (if (.value.patches // []) != [] or .value.override then "+fix" else "" end)
        + (if .value.worked.version then " @\(.value.worked.version)" else "" end)) as $src
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
    echo ""
    echo "=== Last working builds ==="
    "$worked_cli" verify "$flake" "$file" || failed=true
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
    # shellcheck disable=SC2016  # jq program
    update_holds --arg n "$name" 'del(.[$n])' || die "cannot update $file (is it valid JSON?)"
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

# The default branch: origin's HEAD, else origin/main or origin/master. A
# repository without an origin remote has only HEAD to go by.
default_branch() {
  local dir="$1" ref
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    echo HEAD
    return 0
  fi
  for ref in origin/HEAD origin/main origin/master; do
    if git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
      git -C "$dir" rev-parse --abbrev-ref "$ref"
      return 0
    fi
  done
  return 1
}

# The default branch's lock history, newest first: "<commit> <date> <rev>
# <narHash>" per commit. Git runs in the lock's own repository. Returns 1
# outside git, 2 when origin's default branch is unknown.
lock_history() {
  local dir base branch commit date locked
  dir=$(dirname "$lock") base=$(basename "$lock")
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  branch=$(default_branch "$dir") || return 2
  while read -r commit date; do
    locked=$(git -C "$dir" show "$commit:./$base" 2>/dev/null | locked_nixpkgs) || continue
    jq -r --arg c "$commit" --arg d "$date" '"\($c) \($d) \(.rev) \(.narHash)"' <<<"$locked"
  done < <(git -C "$dir" log --first-parent --format='%H %cs' "$branch" -- "$base")
}

# The newest nixpkgs of the default branch's lock history that isn't the
# current one, with its commit: a lock merged there passed the consumer's
# checks, one on a branch may not have.
previous_nixpkgs() {
  local current history status=0 commit rev nar
  history=$(lock_history) || status=$?
  case $status in
    0) ;;
    2) die "cannot tell origin's default branch (no origin/HEAD, origin/main or origin/master): run git remote set-head origin --auto, or pass --from REV" ;;
    *) die "--from previous reads flake.lock's git history; pass --from REV or stable instead" ;;
  esac
  current=$(locked_nixpkgs <"$lock" | jq -r .rev) || die "no input $input in $lock"
  while read -r commit _ rev nar; do
    if [[ -n $rev && $rev != "$current" ]]; then
      jq -n --arg rev "$rev" --arg h "$nar" --arg c "$commit" '{rev: $rev, narHash: $h, commit: $c}'
      return
    fi
  done <<<"$history"
  die "no earlier nixpkgs in the default branch's history of $lock"
}


# generations.sh for NAME: this machine's system generations, or HOST's
# (one ssh call, so one key prompt).
generations() {
  if [[ -n $host ]]; then
    ssh "$host" bash -s -- "$1" "${limit:-30}" <"$generations_sh"
  else
    bash "$generations_sh" "$1" "${limit:-30}"
  fi
}

# The substituter that has PATH, if any.
cached_in() {
  local s
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    if nix path-info --store "$s" "$1" >/dev/null 2>&1; then
      echo "${s#*://}"
      return 0
    fi
  done < <(nix config show substituters 2>/dev/null | tr ' ' '\n')
  return 1
}

# NAME on nixpkgs REV [for SYSTEM], as {version, out} (out null: broken) or {missing}: a
# held one as the flake's release checks build it (with your overlays, like
# `worked`), else plain nixpkgs.
package_at() {
  local name="$1" rev="$2" system="${3:-}" info describe
  [[ -n $system && $system != - ]] || system=$(nix eval --raw --impure --expr builtins.currentSystem)
  # outs: every output, as a generation may hold only some (jq-1.8.2, not -bin).
  # shellcheck disable=SC2016  # Nix expression
  describe='let o = builtins.tryEval p.outPath; os = builtins.tryEval (let l = map (n: p.${n}.outPath) (p.outputs or [ "out" ]); in builtins.deepSeq l l); in { version = p.version or null; out = if o.success then o.value else null; outs = if os.success then os.value else [ ]; }'
  if holds | jq -e --arg n "$name" 'has($n)' >/dev/null \
    && info=$(nix eval --json "$flake#releaseChecks.$system" \
      --override-input "$input" "github:NixOS/nixpkgs/$rev" \
      --apply "c: let p = (c.\"$name\" or { }).nixHoldsPackage or null; in if p == null then null else $describe" 2>/dev/null) \
    && [[ $info != null ]]; then
    echo "$info"
  else
    nix eval --json "github:NixOS/nixpkgs/$rev#legacyPackages.$system.$name" --apply "p: $describe" 2>/dev/null \
      || echo '{"version":null,"out":null,"missing":true}'
  fi
}

# The nixpkgs that builds what a system generation ran: the generation's own
# nixpkgs first, then the lock history. A package can come from elsewhere
# (a hold, an overlay, another flake), so the store path decides, not the
# generation's nixpkgs.
generation_nixpkgs() {
  local name="$1" gen_rev="$2" system="$3" paths="$4" rev out tried=0 revs
  declare -A seen=()
  mapfile -t revs < <(echo "$gen_rev"; lock_history 2>/dev/null | awk '{print $3}')
  for rev in "${revs[@]}"; do
    [[ -n $rev && $rev != - && -z ${seen[$rev]:-} ]] || continue
    seen[$rev]=1
    out=$(package_at "$name" "$rev" "$system" | jq -r '.outs // [] | .[]')
    if [[ -n $out ]] && grep -qxF -f <(tr ' ' '\n' <<<"$paths" | grep .) <<<"$out"; then
      echo "$rev"
      return 0
    fi
    tried=$((tried + 1))
    ((tried < ${limit:-15})) || break
  done
  return 1
}

# Adds `worked` (worked.sh record WHICH NIX_ARGS) to NAME's entry, BASIS saying
# what it was evaluated on. Fails with a warning when the flake can't tell, or
# when the entry changed meanwhile (removed, or another source).
record_worked() {
  local name="$1" which="$2" basis="$3" worked from failed
  shift 3
  if ! command -v nix >/dev/null 2>&1; then
    echo "nix-detour: no nix, so the last working build of $name is not recorded" >&2
    return 1
  fi
  from=$(holds | jq -c --arg n "$name" '.[$n].from')
  worked=$("$worked_cli" record "$flake" "$name" "$which" "$@") || worked=""
  if [[ -z $worked ]]; then
    echo "nix-detour: the last working build of $name is not recorded: $flake has no release check for it (does its mkHolds read $file? In a git flake, git add a new file first)" >&2
    return 1
  fi
  failed=$(jq -r '.failed // [] | join(", ")' <<<"$worked")
  if [[ -n $failed ]]; then
    if [[ $which == held ]]; then
      echo "nix-detour: $name is not refreshed: evaluation failed on $failed" >&2
      return 1
    fi
    echo "nix-detour: the last working build of $name is not recorded on $failed: evaluation failed" >&2
  fi
  # shellcheck disable=SC2016  # jq program
  update_holds --arg n "$name" --argjson from "$from" --argjson w "$(jq -c 'del(.failed)' <<<"$worked")" \
    'if has($n) and .[$n].from == $from then .[$n].worked = $w else error("changed") end' || {
    echo "nix-detour: $name changed in $file meanwhile (or it can't be written): its last working build is not recorded" >&2
    return 1
  }
  echo "recorded $name $(jq -r '.version // "(no version)"' <<<"$worked") on $(jq -r '.outPaths | keys | join(", ")' <<<"$worked") ($basis)"
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
      previous)
        source=$(previous_nixpkgs)
        previous_commit=$(jq -r .commit <<<"$source")
        source=$(jq -c 'del(.commit)' <<<"$source")
        ;;
      generation | generation:*)
        lines=$(generations "$name") || die "cannot read the system generations${host:+ of $host}"
        [[ -n $lines ]] || die "no system generations${host:+ on $host}"
        if [[ $from == generation:* ]]; then
          gen=$(awk -v n="${from#generation:}" '$1 == n' <<<"$lines")
          [[ -n $gen ]] || die "no generation ${from#generation:}${host:+ on $host} among the newest ${limit:-30} (see --limit)"
        else
          newest=$(tail -1 <<<"$lines" | awk '{print $3}')
          gen=$(awk -v r="$newest" '$3 != r && $3 != "-"' <<<"$lines" | tail -1)
          [[ -n $gen ]] || die "every generation${host:+ on $host} has nixpkgs ${newest:0:12}: pass --from generation:N"
        fi
        read -r gen_number _ gen_rev gen_system gen_paths <<<"$gen"
        [[ -n ${gen_paths// /} ]] || die "generation $gen_number${host:+ on $host} has no store path of $name"
        echo "generation $gen_number${host:+ on $host} has $gen_paths" >&2
        rev=$(generation_nixpkgs "$name" "$gen_rev" "$gen_system" "$gen_paths") \
          || die "no nixpkgs in the generation or the lock history (${limit:-15} tried) builds what it ran: an overlay or another flake changes it; pick one with nix-detour hold history $name and pass --from REV"
        hash=$(nix flake prefetch --json "github:NixOS/nixpkgs/$rev" | jq -er .hash) \
          || die "cannot fetch nixpkgs $rev"
        source=$(jq -n --arg rev "$rev" --arg h "$hash" '{rev: $rev, narHash: $h}')
        ;;
      *)
        hash=$(nix flake prefetch --json "github:NixOS/nixpkgs/$from" | jq -er .hash) \
          || die "cannot fetch nixpkgs $from"
        source=$(jq -n --arg rev "$from" --arg h "$hash" '{rev: $rev, narHash: $h}')
        ;;
    esac
    # shellcheck disable=SC2016  # jq program
    update_holds --arg n "$name" --argjson from "$source" --arg since "$(date -u +%F)" \
      --arg reason "$reason" --arg link "$link" --arg rw "$release_when" --arg uv "$until_version" --arg tests "$tests" \
      --argjson patches "$patches_json" --arg override "$override" '
      .[$n] = ({from: $from, since: $since}
        + (if $patches == [] then {} else {patches: $patches} end)
        + (if $override == "" then {} else {override: $override} end)
        + (if $rw == "" then {} else {releaseWhen: $rw} end)
        + (if $uv == "" then {} else {untilVersion: $uv} end)
        + {reason: $reason}
        + (if $link == "" then {} else {link: $link} end)
        + (if $tests == "" then {} else {tests: ($tests | split(","))} end))' || die "cannot update $file (is it valid JSON?)"
    src_label=$(jq -r --arg n "$name" '.[$n].from | if type == "string" then . else .rev end' "$file")
    if [[ $patches_json != '[]' || -n $override ]]; then
      echo "fixing $name on $src_label"
    else
      echo "holding $name from $src_label"
      if $record && jq -e 'type == "object"' <<<"$source" >/dev/null; then
        rev=$(jq -r .rev <<<"$source")
        lock_dir=$(dirname "$lock")
        if [[ -n ${previous_commit:-} && -d $flake && $(realpath "$flake") == "$(realpath "$lock_dir")" ]]; then
          # The flake with all its inputs as at that commit, not only nixpkgs:
          # an overlay input may have moved in the same update.
          ref_lock=$(mktemp)
          trap 'rm -f "$ref_lock"' EXIT
          git -C "$lock_dir" show "$previous_commit:./$(basename "$lock")" >"$ref_lock"
          record_worked "$name" package "with the inputs of ${previous_commit:0:12}" \
            --reference-lock-file "$ref_lock" --no-write-lock-file || true
        else
          record_worked "$name" package "nixpkgs ${rev:0:12}, other inputs as they are now" \
            --override-input "$input" "github:NixOS/nixpkgs/$rev" || true
        fi
      fi
      if [[ -n ${gen_number:-} ]]; then
        # The host's own overlays or config can make what it ran differ from
        # what the holds flake builds; verify can't see that, so say it here.
        # Every output of the held build on the generation's system.
        outs=$(nix eval --json "$flake#releaseChecks.$gen_system" --apply "c: let p = (c.\"$name\" or { }).nixHoldsHeld or null; in
          if p == null then [ ] else map (n: p.\${n}.outPath) (p.outputs or [ \"out\" ])" 2>/dev/null | jq -r '.[]') || outs=
        [[ -n $outs ]] || outs=$(jq -r --arg n "$name" --arg s "$gen_system" '.[$n].worked.outPaths[$s] // empty' "$file")
        # Candidates are broad (any path named like NAME): report what the hold builds.
        read -ra gen_path_list <<<"$gen_paths"
        same=()
        for path in "${gen_path_list[@]}"; do
          ! grep -qxF -- "$path" <<<"$outs" || same+=("$path")
        done
        if [[ -z $outs ]]; then
          echo "generation $gen_number${host:+ on $host} ran ${gen_path_list[*]}"
        elif ((${#same[@]})); then
          echo "generation $gen_number${host:+ on $host} ran ${same[*]}: the hold builds the same"
        else
          echo "generation $gen_number${host:+ on $host} ran ${gen_path_list[*]}, the hold builds $(paste -sd' ' <<<"$outs"): that host's overlays or config change it"
        fi
      fi
    fi
    ;;
  refresh)
    name="${args[1]:-}"
    [[ -n $name ]] || die "refresh needs the name of the package"
    valid_name "$name"
    holds | jq -e --arg n "$name" 'has($n)' >/dev/null || die "$name is not held"
    record_worked "$name" held "the held build as it is now" || exit 1
    ;;
  verify)
    "$worked_cli" verify "$flake" "$file"
    ;;
  history)
    name="${args[1]:-}"
    [[ -n $name ]] || die "history needs the name of the package"
    valid_name "$name"
    command -v nix >/dev/null 2>&1 || die "history needs nix"
    held_rev=$(holds | jq -r --arg n "$name" '.[$n].from.rev? // empty')
    in_holds=$(holds | jq --arg n "$name" 'has($n)')
    mark() { [[ -n $held_rev && $1 == "$held_rev" ]] && echo "  <- held" || true; }
    gen_lines=$(generations "$name" 2>/dev/null) || gen_lines=
    [[ -z $host || -n $gen_lines ]] || die "cannot read the system generations of $host"
    # Another host's lock rows are for its system: that is the build it would run.
    system=$(awk 'NR == 1 && $4 != "-" { print $4 }' <<<"$gen_lines")
    [[ -n $host && -n $system ]] || system=$(nix eval --raw --impure --expr builtins.currentSystem)
    if $in_holds; then
      echo "$name in the nixpkgs of $lock ($system, newest first; as $flake's release checks build it):"
    else
      echo "$name in the nixpkgs of $lock ($system, newest first; plain nixpkgs, without your overlays):"
    fi
    revs=()
    if current=$(locked_nixpkgs <"$lock"); then revs+=("current $(jq -r .rev <<<"$current")"); fi
    if history=$(lock_history); then
      while read -r _ date rev _; do
        [[ -z $rev ]] || revs+=("$date $rev")
      done <<<"$history"
    fi
    declare -A seen=()
    shown=0
    for entry in "${revs[@]}"; do
      read -r date rev <<<"$entry"
      [[ -z ${seen[$rev]:-} ]] || continue
      seen[$rev]=1
      info=$(package_at "$name" "$rev" "$system")
      version=$(jq -r '.version // "-"' <<<"$info")
      out=$(jq -r '.out // empty' <<<"$info")
      if jq -e .missing <<<"$info" >/dev/null 2>&1; then
        state="not in this nixpkgs"
      elif [[ -z $out ]]; then
        state="broken"
      elif where=$(cached_in "$out"); then
        state="built ($where)"
      else
        state="in no substituter"
      fi
      printf '  %-10s %-12s %-16s %s%s\n' "$date" "${rev:0:12}" "$version" "$state" "$(mark "$rev")"
      shown=$((shown + 1))
      ((shown < ${limit:-8})) || break
    done
    ((shown)) || echo "  (no nixpkgs $input in $lock)"
    if [[ -n $gen_lines ]]; then
      echo
      echo "$name in the system generations${host:+ of $host} (newest first):"
      last="${name##*.}"
      sort -k2,2nr <<<"$gen_lines" | while read -r gen t rev _ paths; do
        day=$(jq -nr --argjson t "$t" '$t | strftime("%F")')
        read -ra path_list <<<"$paths"
        # Only version-like names: foo-bar-9 is another package, not foo.
        versions=$(for p in "${path_list[@]}"; do
          v="${p##*-"$last"-}"
          case $v in [0-9]* | unstable-*) echo "$v" ;; esac
        done \
          | sed -E 's/-(bin|dev|lib|out|man|doc|devdoc|info|debug|static|python|data)$//' | sort -u | paste -sd' ')
        printf '  %-9s %-10s %-12s %s%s\n' "$gen" "$day" "${rev:0:12}" "${versions:-(not in this generation)}" "$(mark "$rev")"
      done
    fi
    ;;
  remove)
    name="${args[1]:-}"
    [[ -n $name ]] || die "remove needs the name of the package"
    valid_name "$name"
    holds_data=$(holds)
    jq -e --arg n "$name" 'has($n)' <<<"$holds_data" >/dev/null || die "$name is not held"
    # shellcheck disable=SC2016  # jq program
    update_holds --arg n "$name" 'del(.[$n])' || die "cannot update $file (is it valid JSON?)"
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
