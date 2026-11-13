#!/usr/bin/env bash
# nix-detour pr: manage the PRs file of a flake (nixpkgs-prs.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-detour pr <command> [options]

  add [NAME] [NUMBER|URL] [--pr NUMBER] [--repo OWNER/REPO] [--attrs a,b]
           [--rev SHA] [--pin] [--no-pin] [--scope c,d] [--path ATTR=PATH]...
           [--module NAME=PATH]... [--python NAME]... [--channel REF] [--auto]
      Add the packages `attrs` of nixpkgs PR NUMBER (or full PR URL).
      When passed as a PR number or URL (or with --auto), repo, latest commit
      SHA, package attributes and modules are auto-detected from GitHub.
      --pin forces pinning, --no-pin skips it.
      --scope names unexported dependencies; --path sets custom package files;
      --module adds a NixOS module; --python adds a python package.
  pin [NAME|--all] [SHA]
      Pin NAME to commit SHA (or its latest head commit from GitHub if SHA
      is omitted). --all updates all entries in the file.
  remove NAME
      Drop NAME.
  list [PATH]
      Show every entry, its PR and where it is pinned.
  eval NAME [--flake REF]
      Evaluate NAME's packages (the flake's nixpkgsPrs) and print their
      derivations.
  merged [--flake REF]
      Say which entries nixpkgs has in the same or a newer version: they
      can go.
  check [NAME...|PATH] [--channel REF] [--upstream OWNER/REPO] [--json]
      Check upstream GitHub PR status (draft, open, merged) and whether
      merged PRs have reached the upstream channel (default: nixos-unstable).

Options for every command:
  --file PATH    the PRs file (default: nixpkgs-prs.json)
EOF
}

die() { echo "nix-detour pr: $*" >&2; exit 1; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*$ ]] || die "invalid entry name '$1'"; }
valid_repo() { [[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $1 != *..* ]] || die "invalid repository '$1' (expected OWNER/REPO)"; }
need() { (($# >= 2)) || die "$1 needs a value"; }

to_flake() {
  if [[ $1 != /* && $1 != ./* && $1 != ../* && $1 != *:* ]]; then echo "./$1"; else echo "$1"; fi
}

file=nixpkgs-prs.json file_explicit=false flake=. pr="" repo="" attrs="" rev="" scope=""
channel=nixos-unstable channel_explicit=false upstream=NixOS/nixpkgs as_json=false
all_entries=false no_pin=false pin_explicit=false auto_flag=false
modules=() paths=() python_pkgs=() args=()

while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; file_explicit=true; shift 2 ;;
    --flake) need "$@"; flake="$2"; shift 2 ;;
    --channel | --until-channel) need "$@"; channel="$2"; channel_explicit=true; shift 2 ;;
    --upstream) need "$@"; upstream="$2"; shift 2 ;;
    --json) as_json=true; shift ;;
    --pr) need "$@"; pr="$2"; shift 2 ;;
    --repo) need "$@"; repo="$2"; shift 2 ;;
    --attrs) need "$@"; attrs="$2"; shift 2 ;;
    --rev) need "$@"; rev="$2"; shift 2 ;;
    --pin) pin_explicit=true; shift ;;
    --no-pin) no_pin=true; shift ;;
    --auto) auto_flag=true; shift ;;
    --scope) need "$@"; scope="$2"; shift 2 ;;
    --path) need "$@"; paths+=("$2"); shift 2 ;;
    --module) need "$@"; modules+=("$2"); shift 2 ;;
    --python) need "$@"; python_pkgs+=("$2"); shift 2 ;;
    --all | -a) all_entries=true; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; args+=("$@"); break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"
name="${args[1]:-}"

valid_repo "$upstream"
has_gh=false
command -v gh >/dev/null 2>&1 && has_gh=true

gh_api() {
  local endpoint="$1" res=""
  $has_gh && res=$(gh api "$endpoint" 2>/dev/null || true)
  if [[ -z $res || $res == "null" ]]; then
    local auth_hdr=()
    [[ -n ${GITHUB_TOKEN:-} ]] && auth_hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    res=$(curl -sf "${auth_hdr[@]}" -H "Accept: application/vnd.github+json" -H "User-Agent: nix-detour" "https://api.github.com/$endpoint" 2>/dev/null || true)
  fi
  printf '%s' "$res"
}

gh_api_files() {
  local endpoint="$1" res=""
  $has_gh && res=$(gh api "$endpoint" 2>/dev/null || true)
  if [[ -z $res || $res == "null" ]]; then
    local page=1 all="[]" delim="?" p_res
    [[ $endpoint == *\?* ]] && delim="&"
    while ((page <= 5)); do
      p_res=$(gh_api "${endpoint}${delim}page=$page&per_page=100")
      [[ -n $p_res && $p_res != "null" && $p_res != "[]" ]] || break
      all=$(jq -s 'add' <<<"$all $p_res" 2>/dev/null || echo "$all")
      ((page++))
    done
    res="$all"
  fi
  printf '%s' "$res"
}

parse_pr_ref() {
  if [[ $1 =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    upstream="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    pr="${BASH_REMATCH[3]}"
    valid_repo "$upstream"
    return 0
  elif [[ $1 =~ ^[0-9]+$ ]]; then
    pr="$1"
    return 0
  fi
  return 1
}

# Extracts `<pkg>` from Nixpkgs-style PR titles (`[Backport] pkg: init at 1.0`).
extract_title_pkg() {
  jq -rn --arg t "$1" '$t | capture("^\\s*(?:\\[[^\\]]+\\]\\s*)?(?<pkg>[^:,\\s]+):") | .pkg // empty' 2>/dev/null || true
}

[[ -n $pr ]] && { parse_pr_ref "$pr" || true; }

pr_positional=false
if [[ $command == "add" ]]; then
  if [[ -n $name && -z $pr ]] && parse_pr_ref "$name"; then
    name=""
    pr_positional=true
  elif [[ -n ${args[2]:-} && -z $pr ]] && parse_pr_ref "${args[2]}"; then
    pr_positional=true
  fi
fi

resolve_pr_file() {
  if [[ -d $1 ]]; then file="$1/nixpkgs-prs.json"; else file="$1"; fi
  name=""
}

if $file_explicit && [[ $command == "list" && -n $name ]]; then
  die "cannot combine --file with a positional target"
elif ! $file_explicit && [[ -n $name && ${#args[@]} -eq 2 ]]; then
  if [[ $command == "list" ]]; then
    [[ -d $name || -f $name ]] || die "target path '$name' not found"
    resolve_pr_file "$name"
  elif [[ $command == "check" && (-d $name || -f $name) ]]; then
    if [[ $name == */* || $name == *.json || ! -f $file ]]; then
      resolve_pr_file "$name"
    else
      has_entry=$(jq -r --arg n "$name" 'has($n)' "$file" 2>/dev/null) || die "$file is not valid JSON"
      [[ $has_entry == "true" ]] || resolve_pr_file "$name"
    fi
  fi
fi

entries() {
  if [[ -e $file ]]; then
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file is not a valid JSON object"
    cat "$file"
  else
    echo '{}'
  fi
}

write_entries() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
}

need_entry() {
  local target_name="${1:-$name}"
  [[ -n $target_name ]] || die "$command needs the name of the entry"
  entries | jq -e --arg n "$target_name" 'has($n)' >/dev/null || die "$file has no entry $target_name"
}

nar_hash() {
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the commit must be a full 40-character SHA"
  nix flake prefetch --json "github:$1/$rev" | jq -er .hash || die "cannot fetch github:$1/$rev"
}

system() { nix eval --raw --impure --expr builtins.currentSystem; }

strip_channel() {
  local ch="$1"
  [[ $ch == github:*/*/* ]] && ch="${ch#github:*/*/}"
  printf '%s' "$ch"
}

case "$command" in
  add)
    [[ -n $pr && $pr =~ ^[0-9]+$ ]] || die "add needs a PR number or GitHub pull request URL (or --pr NUMBER)"
    auto_detect=false
    ($pr_positional || $auto_flag) && auto_detect=true

    pr_title=""
    if $auto_detect; then
      pr_json=$(gh_api "repos/$upstream/pulls/$pr")
      if [[ -n $pr_json && $pr_json != "null" ]]; then
        pr_title=$(jq -r '.title // ""' <<<"$pr_json")
        if [[ -z $repo ]]; then
          repo=$(jq -r '.head.repo.full_name // empty' <<<"$pr_json")
          if [[ -z $repo ]]; then
            head_user=$(jq -r '.head.user.login // empty' <<<"$pr_json")
            [[ -n $head_user ]] && repo="$head_user/nixpkgs"
          fi
        fi
        if ! $no_pin && [[ -z $rev ]]; then
          head_sha=$(jq -r '.head.sha // empty' <<<"$pr_json")
          [[ $head_sha =~ ^[0-9a-f]{40}$ ]] && rev="$head_sha"
        fi
      fi

      if [[ -z $attrs || ${#modules[@]} -eq 0 || ${#python_pkgs[@]} -eq 0 ]]; then
        files_json=$(gh_api_files "repos/$upstream/pulls/$pr/files")
        if [[ -n $files_json && $files_json != "null" && $files_json != "[]" ]]; then
          if [[ -z $attrs ]]; then
            inferred_attrs=$(jq -r '[.[] | .filename | capture("^pkgs/by-name/[^/]+/(?<attr>[^/]+)/") | .attr] | unique | join(",")' <<<"$files_json" 2>/dev/null || true)
            [[ -n $inferred_attrs ]] && attrs="$inferred_attrs"
          fi
          if ((${#python_pkgs[@]} == 0)); then
            while IFS= read -r py_name; do
              [[ -n $py_name ]] && python_pkgs+=("$py_name")
            done < <(jq -r '[.[] | .filename | capture("^pkgs/development/python-modules/(?<py>[^/]+)/") | .py] | unique[]' <<<"$files_json" 2>/dev/null || true)
          fi
          if ((${#modules[@]} == 0)); then
            while IFS= read -r mod_path; do
              [[ -n $mod_path ]] && modules+=("$(basename "$mod_path" .nix)=$mod_path")
            done < <(jq -r '[.[] | .filename | select(startswith("nixos/modules/") and endswith(".nix") and . != "nixos/modules/module-list.nix")] | unique[]' <<<"$files_json" 2>/dev/null || true)
          fi
        fi
      fi

      if [[ -z $attrs && ${#python_pkgs[@]} -eq 0 && -n $pr_title ]]; then
        title_cand=$(extract_title_pkg "$pr_title")
        if [[ -n $title_cand && $title_cand != */* ]]; then
          if [[ $title_cand == python3Packages.* ]]; then
            python_pkgs+=("${title_cand#python3Packages.}")
          else
            attrs="$title_cand"
          fi
        fi
      fi
    fi

    if $pin_explicit && ! $no_pin && [[ -z $rev ]]; then
      head_sha=$(gh_api "repos/$upstream/pulls/$pr" | jq -r '.head.sha // empty')
      [[ $head_sha =~ ^[0-9a-f]{40}$ ]] || die "--pin requested but cannot determine latest commit from GitHub"
      rev="$head_sha"
    fi

    [[ -n $name ]] || $auto_detect || die "add needs the name of the entry"
    [[ -n $repo ]] || die "add needs --repo OWNER/REPO (where the PR's branch is)"
    valid_repo "$repo"
    [[ -n $attrs || ${#python_pkgs[@]} -gt 0 ]] || die "add needs --attrs (the packages to take from the PR)"

    if [[ -z $name ]]; then
      if [[ -n $attrs ]]; then
        title_cand=$(extract_title_pkg "$pr_title")
        name="${attrs%%,*}"
        IFS=',' read -ra attr_list <<<"$attrs"
        for a in "${attr_list[@]}"; do [[ $a == "$title_cand" ]] && { name="$a"; break; }; done
      elif ((${#python_pkgs[@]} >= 1)); then
        name="${python_pkgs[0]}"
      elif ((${#modules[@]} >= 1)); then
        name="${modules[0]%%=*}"
      fi
      [[ -n $name ]] || name="pr-$pr"
    fi
    valid_name "$name"

    entries_data=$(entries)
    jq -e --arg n "$name" 'has($n)' <<<"$entries_data" >/dev/null && die "$file already has an entry $name (remove it first)"

    modules_json='{}'
    for module in "${modules[@]}"; do
      [[ $module == ?*=?* ]] || die "--module needs NAME=PATH"
      modules_json=$(jq --arg n "${module%%=*}" --arg p "${module#*=}" '.[$n] = $p' <<<"$modules_json")
    done

    paths_json='{}'
    IFS=',' read -ra allowed <<<"$attrs${scope:+,$scope}"
    for py in "${python_pkgs[@]}"; do allowed+=("python3Packages.$py"); done
    for path in "${paths[@]}"; do
      [[ $path == ?*=?* ]] || die "--path needs NAME=PATH"
      pname="${path%%=*}" found=false
      for a in "${allowed[@]}"; do [[ $a == "$pname" ]] && { found=true; break; }; done
      $found || die "--path $pname is not in --attrs, --scope, or python3Packages.<--python>"
      paths_json=$(jq --arg n "$pname" --arg p "${path#*=}" '.[$n] = $p' <<<"$paths_json")
    done

    python_json='[]'
    if ((${#python_pkgs[@]} > 0)); then
      python_json=$(printf '%s\n' "${python_pkgs[@]}" | jq -R . | jq -s .)
    fi

    until_ch=""
    $channel_explicit && until_ch=$(strip_channel "$channel")
    hash=""
    [[ -z $rev ]] || hash=$(nar_hash "$repo")

    jq --arg n "$name" --argjson pr "$pr" --arg owner "${repo%%/*}" --arg repo "${repo#*/}" \
      --arg rev "$rev" --arg h "$hash" --arg upstream "$upstream" --arg untilCh "$until_ch" \
      --arg attrs "$attrs" --arg scope "$scope" --argjson modules "$modules_json" --argjson paths "$paths_json" \
      --argjson python "$python_json" '
      .[$n] = ({pr: $pr, owner: $owner, repo: $repo, rev: $rev, narHash: $h, attrs: (if $attrs == "" then [] else ($attrs | split(",")) end)}
        + (if $upstream != "NixOS/nixpkgs" then {upstream: $upstream} else {} end)
        + (if $untilCh != "" then {untilChannel: $untilCh} else {} end)
        + (if $scope == "" then {} else {scope: ($scope | split(","))} end)
        + (if $paths == {} then {} else {paths: $paths} end)
        + (if $modules == {} then {} else {modules: $modules} end)
        + (if $python == [] then {} else {pythonPackages: $python} end))' <<<"$entries_data" | write_entries
    if [[ -n $rev ]]; then
      echo "added $name, pinned to $rev ($hash)"
    else
      echo "added $name; pin it with: nix-detour pr pin $name SHA"
    fi
    ;;
  pin)
    entries_data=$(entries)
    if [[ $name == "--all" || $name == "-a" ]] || $all_entries; then
      mapfile -t keys < <(jq -r 'keys[]' <<<"$entries_data")
      for k in "${keys[@]}"; do
        [[ -n $k ]] || continue
        IFS=$'\x1f' read -r pr_num cur_rev owner_repo entry_upstream < <(
          jq -r --arg n "$k" '.[$n] | [(.pr | tostring), (.rev // ""), "\(.owner)/\(.repo)", (.upstream // "")] | join("\u001f")' <<<"$entries_data"
        )
        latest_sha=$(gh_api "repos/${entry_upstream:-$upstream}/pulls/$pr_num" | jq -r '.head.sha // empty')
        if [[ ! $latest_sha =~ ^[0-9a-f]{40}$ ]]; then
          echo "$k (#$pr_num): could not fetch latest commit from GitHub, skipping" >&2
          continue
        fi
        if [[ $latest_sha == "$cur_rev" ]]; then
          echo "$k is already up to date at ${cur_rev:0:12}"
        else
          rev="$latest_sha"
          hash=$(nar_hash "$owner_repo")
          entries_data=$(jq --arg n "$k" --arg rev "$rev" --arg h "$hash" '.[$n].rev = $rev | .[$n].narHash = $h' <<<"$entries_data")
          printf '%s' "$entries_data" | write_entries
          echo "$k updated to ${rev:0:12} ($hash)"
        fi
      done
      exit 0
    fi

    need_entry
    rev="${args[2]:-}"
    IFS=$'\x1f' read -r pr_num cur_rev cur_hash owner_repo entry_upstream < <(
      jq -r --arg n "$name" '.[$n] | [(.pr | tostring), (.rev // ""), (.narHash // ""), "\(.owner)/\(.repo)", (.upstream // "")] | join("\u001f")' <<<"$entries_data"
    )
    if [[ -z $rev ]]; then
      latest_sha=$(gh_api "repos/${entry_upstream:-$upstream}/pulls/$pr_num" | jq -r '.head.sha // empty')
      [[ $latest_sha =~ ^[0-9a-f]{40}$ ]] || die "cannot determine latest commit for $name from GitHub: please specify a SHA"
      if [[ $latest_sha == "$cur_rev" ]]; then
        echo "$name is already up to date at ${cur_rev:0:12} ($cur_hash)"
        exit 0
      fi
      rev="$latest_sha"
    fi
    hash=$(nar_hash "$owner_repo")
    jq --arg n "$name" --arg rev "$rev" --arg h "$hash" '.[$n].rev = $rev | .[$n].narHash = $h' <<<"$entries_data" | write_entries
    echo "$name pinned to $rev ($hash)"
    ;;
  remove)
    need_entry
    valid_name "$name"
    entries | jq --arg n "$name" 'del(.[$n])' | write_entries
    echo "removed $name"
    ;;
  list)
    entries | jq -r 'to_entries[] | [.key, "#\(.value.pr)",
      (if (.value.rev // "") == "" then "not pinned" else .value.rev[0:12] end),
      (((.value.attrs // []) + ((.value.pythonPackages // []) | map("python3Packages." + .))) | join(","))]
      | join("\u001f")' |
      while IFS=$'\x1f' read -r n p r a; do printf '%-24s %-8s %-12s %s\n' "$n" "$p" "$r" "$a"; done
    ;;
  eval)
    need_entry
    flake_ref=$(to_flake "$flake")
    nix eval --json "$flake_ref#nixpkgsPrs.$(system).\"$name\".packages" \
      --apply 'builtins.mapAttrs (_: p: p.drvPath)' | jq -r 'to_entries[] | "\(.key) \(.value)"'
    ;;
  merged)
    flake_ref=$(to_flake "$flake")
    merged=$(nix eval --json "$flake_ref#nixpkgsPrs.$(system)" --apply 'builtins.mapAttrs (_: c: c.merged)') \
      || die "cannot evaluate $flake_ref#nixpkgsPrs"
    jq -r 'to_entries[] | "\(if .value then "merged" else "open" end) \(.key)"' <<<"$merged"
    ;;
  check)
    default_branch=$(strip_channel "$channel")
    target_names=()
    if [[ -n $name ]]; then
      entries_data=$(entries)
      for target_name in "${args[@]:1}"; do
        jq -e --arg n "$target_name" 'has($n)' <<<"$entries_data" >/dev/null || die "$file has no entry $target_name"
        target_names+=("$target_name")
      done
    else
      [[ -f $file ]] || { $as_json && echo "{}" || echo "no $file found"; exit 0; }
      entries_data=$(entries)
      mapfile -t target_names < <(jq -r 'keys[]' <<<"$entries_data")
    fi

    if ((${#target_names[@]} == 0)); then
      $as_json && echo "{}" || echo "no entries in $file"
      exit 0
    fi

    is_tty=false
    [[ -t 1 ]] && ! $as_json && is_tty=true
    $as_json || printf '%-20s %-8s %-16s %s\n' "NAME" "PR" "STATUS" "DETAILS"

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    # Cap concurrent GitHub API queries to avoid secondary rate limits.
    running=0
    for idx in "${!target_names[@]}"; do
      n="${target_names[$idx]}"
      (
        IFS=$'\x1f' read -r pr_num entry_upstream entry_channel < <(
          jq -r --arg n "$n" '.[$n] | [(.pr // "" | tostring), (.upstream // ""), (.untilChannel // "")] | join("\u001f")' <<<"$entries_data"
        )
        [[ -n $pr_num ]] || exit 0
        target_upstream="${entry_upstream:-$upstream}"
        channel_branch="$default_branch"
        ! $channel_explicit && [[ -n $entry_channel ]] && channel_branch=$(strip_channel "$entry_channel")

        pr_json=$(gh_api "repos/$target_upstream/pulls/$pr_num")
        status="unknown" details="GitHub API unavailable" state="unknown"
        draft="false" merged="false" in_channel="false" title=""
        html_url="https://github.com/$target_upstream/pull/$pr_num"

        if [[ -n $pr_json && $pr_json != "null" ]]; then
          IFS=$'\x1f' read -r state draft merged merge_commit title parsed_url < <(
            jq -r '[(.state // "unknown"), (.draft // false | tostring), (.merged // false | tostring), (.merge_commit_sha // ""), (.title // ""), (.html_url // "")] | join("\u001f")' <<<"$pr_json"
          )
          [[ -n $parsed_url ]] && html_url="$parsed_url"

          if [[ $merged == "true" ]]; then
            comp_status=""
            [[ -n $merge_commit ]] && comp_status=$(gh_api "repos/$target_upstream/compare/$channel_branch...$merge_commit" | jq -r '.status // empty')
            if [[ $comp_status == "behind" || $comp_status == "identical" ]]; then
              status="in-channel" in_channel="true" details="landed in $channel_branch (ready to release)"
            else
              status="merged" details="merged upstream (waiting for $channel_branch)"
            fi
          elif [[ $draft == "true" ]]; then
            status="draft" details="draft PR"
          elif [[ $state == "closed" ]]; then
            status="closed" details="closed without merge"
          else
            status="open" details="open upstream"
          fi
        fi

        jq -n --arg n "$n" --argjson pr "$pr_num" --arg status "$status" --arg state "$state" \
          --argjson draft "$draft" --argjson merged "$merged" --argjson inChannel "$in_channel" \
          --arg details "$details" --arg title "$title" --arg url "$html_url" --arg ch "$channel_branch" \
          '{($n): {pr: $pr, status: $status, state: $state, draft: $draft, merged: $merged, inChannel: $inChannel, details: $details, title: $title, url: $url, channel: $ch}}' \
          >"$tmpdir/$idx.json"
      ) &
      ((++running))
      if ((running >= 6)); then
        if ((BASH_VERSINFO[0] >= 5)); then wait -n || true; ((--running)); else wait; running=0; fi
      fi
    done
    wait

    files_out=()
    for idx in "${!target_names[@]}"; do
      n="${target_names[$idx]}"
      [[ -f "$tmpdir/$idx.json" ]] || die "check failed for entry '$n'"
      files_out+=("$tmpdir/$idx.json")
      if ! $as_json; then
        IFS=$'\x1f' read -r pr_num status details < <(
          jq -r --arg n "$n" '.[$n] | [(.pr | tostring), .status, .details] | join("\u001f")' "$tmpdir/$idx.json"
        )
        status_display="$status"
        if $is_tty; then
          case "$status" in
            in-channel) status_display=$'\e[1;32min-channel\e[0m' ;;
            merged) status_display=$'\e[1;35mmerged\e[0m' ;;
            open) status_display=$'\e[1;34mopen\e[0m' ;;
            draft) status_display=$'\e[1;33mdraft\e[0m' ;;
            closed) status_display=$'\e[1;31mclosed\e[0m' ;;
          esac
        fi
        printf '%-20s %-8s %-16s %s\n' "$n" "#$pr_num" "$status_display" "$details"
      fi
    done
    if $as_json; then
      jq -s 'add // {}' "${files_out[@]}"
    fi
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
