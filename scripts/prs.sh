#!/usr/bin/env bash
# nix-detour pr: manage the PRs file of a flake (nixpkgs-prs.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-detour pr <command> [options]

  add [NAME] [NUMBER|URL] [--pr NUMBER] [--repo OWNER/REPO] [--attrs a,b]
           [--rev SHA] [--pin] [--no-pin] [--scope c,d] [--path ATTR=PATH]...
           [--module NAME=PATH]... [--python NAME]... [--auto]
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
  check [NAME|PATH] [--channel REF] [--upstream OWNER/REPO] [--json]
      Check upstream GitHub PR status (draft, open, merged) and whether
      merged PRs have reached the upstream channel (default: nixos-unstable).

Options for every command:
  --file PATH    the PRs file (default: nixpkgs-prs.json)
EOF
}

die() {
  echo "nix-detour pr: $*" >&2
  exit 1
}

file=nixpkgs-prs.json file_explicit=false flake=. pr="" repo="" attrs="" rev="" scope=""
channel=nixos-unstable upstream=NixOS/nixpkgs as_json=false
all_entries=false no_pin=false pin_explicit=false auto_flag=false
modules=() paths=() python_pkgs=()
args=()
need() {
  (($# >= 2)) || die "$1 needs a value"
}
while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; file_explicit=true; shift 2 ;;
    --flake) need "$@"; flake="$2"; shift 2 ;;
    --channel) need "$@"; channel="$2"; shift 2 ;;
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
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"
name="${args[1]:-}"

gh_api() {
  local endpoint="$1"
  local res=""
  if command -v gh >/dev/null 2>&1; then
    res=$(gh api "$endpoint" 2>/dev/null || true)
  fi
  if [[ -z "$res" || "$res" == "null" ]]; then
    local auth_hdr=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      auth_hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    res=$(curl -s -f "${auth_hdr[@]}" -H "Accept: application/vnd.github+json" -H "User-Agent: nix-detour" "https://api.github.com/$endpoint" 2>/dev/null || true)
  fi
  printf '%s' "$res"
}

gh_api_files() {
  local endpoint="$1"
  local res=""
  if command -v gh >/dev/null 2>&1; then
    res=$(gh api "$endpoint" 2>/dev/null || true)
  fi
  if [[ -z "$res" || "$res" == "null" ]]; then
    local page=1 all="[]"
    while :; do
      local p_res
      local delim="?"
      [[ "$endpoint" == *\?* ]] && delim="&"
      p_res=$(gh_api "${endpoint}${delim}page=$page&per_page=100")
      [[ -n "$p_res" && "$p_res" != "null" && "$p_res" != "[]" ]] || break
      all=$(jq -s 'add' <<<"$all $p_res" 2>/dev/null || true)
      ((page++))
      ((page > 5)) && break
    done
    res="$all"
  fi
  printf '%s' "$res"
}

parse_pr_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    upstream="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    pr="${BASH_REMATCH[3]}"
    return 0
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    pr="$ref"
    return 0
  fi
  return 1
}

if [[ -n "$pr" ]]; then
  parse_pr_ref "$pr" || true
fi

pr_positional=false
if [[ "$command" == "add" ]]; then
  if [[ -n "$name" && -z "$pr" ]]; then
    if parse_pr_ref "$name"; then
      name=""
      pr_positional=true
    elif [[ -n "${args[2]:-}" ]] && parse_pr_ref "${args[2]}"; then
      pr_positional=true
    fi
  elif [[ -n "${args[2]:-}" && -z "$pr" ]] && parse_pr_ref "${args[2]}"; then
    pr_positional=true
  fi
fi

if $file_explicit && [[ "$command" == "list" ]] && [[ -n "$name" ]]; then
  die "cannot combine --file with a positional target"
elif ! $file_explicit && [[ -n "$name" ]]; then
  if [[ "$command" == "list" ]]; then
    if [[ -d "$name" ]]; then
      file="$name/nixpkgs-prs.json"
      name=""
    elif [[ -f "$name" ]]; then
      file="$name"
      name=""
    else
      die "target path '$name' not found"
    fi
  elif [[ "$command" == "check" ]]; then
    if [[ "$name" == */* || "$name" == *.json ]]; then
      if [[ -d "$name" ]]; then
        file="$name/nixpkgs-prs.json"
        name=""
      elif [[ -f "$name" ]]; then
        file="$name"
        name=""
      fi
    elif [[ -d "$name" ]]; then
      if [[ -f "$file" ]]; then
        has_entry=$(jq -r --arg n "$name" 'if has($n) then "yes" else "no" end' "$file" 2>/dev/null) || die "$file is not valid JSON"
        if [[ "$has_entry" != "yes" ]]; then
          file="$name/nixpkgs-prs.json"
          name=""
        fi
      else
        file="$name/nixpkgs-prs.json"
        name=""
      fi
    elif [[ -f "$name" ]]; then
      if [[ -f "$file" ]]; then
        has_entry=$(jq -r --arg n "$name" 'if has($n) then "yes" else "no" end' "$file" 2>/dev/null) || die "$file is not valid JSON"
        if [[ "$has_entry" != "yes" ]]; then
          file="$name"
          name=""
        fi
      else
        file="$name"
        name=""
      fi
    fi
  fi
fi

entries() {
  if [[ -e $file ]]; then
    jq . "$file" || die "$file is not valid JSON"
  else
    echo '{}'
  fi
}

# Writes the entries from stdin, top-level keys sorted, entries as they are.
# Empty input (a failed jq before it) leaves the file as it is.
write_entries() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
}

need_entry() {
  [[ -n $name ]] || die "$command needs the name of the entry"
  entries | jq -e --arg n "$name" 'has($n)' >/dev/null || die "$file has no entry $name"
}

# The narHash of commit $rev of OWNER/REPO $1.
nar_hash() {
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the commit must be a full 40-character SHA"
  nix flake prefetch --json "github:$1/$rev" | jq -er .hash || die "cannot fetch github:$1/$rev"
}

system() {
  nix eval --raw --impure --expr builtins.currentSystem
}

case "$command" in
  add)
    [[ -n "$pr" && "$pr" =~ ^[0-9]+$ ]] || die "add needs a PR number or GitHub pull request URL (or --pr NUMBER)"

    auto_detect=false
    if $pr_positional || $auto_flag; then
      auto_detect=true
    fi

    pr_title=""
    if $auto_detect; then
      pr_json=$(gh_api "repos/$upstream/pulls/$pr")
      if [[ -n "$pr_json" && "$pr_json" != "null" ]]; then
        pr_title=$(jq -r '.title // ""' <<<"$pr_json")
        if [[ -z "$repo" ]]; then
          repo=$(jq -r '.head.repo.full_name // empty' <<<"$pr_json")
          if [[ -z "$repo" ]]; then
            head_user=$(jq -r '.head.user.login // empty' <<<"$pr_json")
            [[ -n "$head_user" ]] && repo="$head_user/nixpkgs"
          fi
        fi
        if ! $no_pin && [[ -z "$rev" ]]; then
          head_sha=$(jq -r '.head.sha // empty' <<<"$pr_json")
          if [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
            rev="$head_sha"
          fi
        fi
      fi

      if [[ -z "$attrs" || ((${#modules[@]} == 0)) || ((${#python_pkgs[@]} == 0)) ]]; then
        files_json=$(gh_api_files "repos/$upstream/pulls/$pr/files")
        if [[ -n "$files_json" && "$files_json" != "null" && "$files_json" != "[]" ]]; then
          if [[ -z "$attrs" ]]; then
            inferred_attrs=$(jq -r '
              [ .[] | .filename | capture("^pkgs/by-name/[^/]+/(?<attr>[^/]+)/") | .attr ]
              | unique | join(",")' <<<"$files_json" 2>/dev/null || true)
            if [[ -n "$inferred_attrs" ]]; then
              attrs="$inferred_attrs"
            fi
          fi
          if ((${#python_pkgs[@]} == 0)); then
            while IFS= read -r py_name; do
              [[ -z "$py_name" ]] && continue
              python_pkgs+=("$py_name")
            done < <(jq -r '
              [ .[] | .filename | capture("^pkgs/development/python-modules/(?<py>[^/]+)/") | .py ]
              | unique[]' <<<"$files_json" 2>/dev/null || true)
          fi
          if ((${#modules[@]} == 0)); then
            while IFS= read -r mod_path; do
              [[ -z "$mod_path" ]] && continue
              mod_name=$(basename "$mod_path" .nix)
              modules+=("$mod_name=$mod_path")
            done < <(jq -r '
              [ .[] | .filename | select(startswith("nixos/modules/")) | select(endswith(".nix")) | select(. != "nixos/modules/module-list.nix") ]
              | unique[]' <<<"$files_json" 2>/dev/null || true)
          fi
        fi
      fi

      if [[ -z "$attrs" && ((${#python_pkgs[@]} == 0)) && -n "$pr_title" ]]; then
        title_cand=$(sed -E 's/^[[:space:]]*(\[[^]]+\][[:space:]]*)?([^:, ]+):.*/\2/' <<<"$pr_title")
        if [[ -n "$title_cand" && "$title_cand" != */* ]]; then
          attrs="$title_cand"
        fi
      fi
    fi

    if $pin_explicit && ! $no_pin && [[ -z "$rev" ]]; then
      pr_json=$(gh_api "repos/$upstream/pulls/$pr")
      head_sha=$(jq -r '.head.sha // empty' <<<"$pr_json")
      [[ -n "$head_sha" && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || die "--pin requested but cannot determine latest commit from GitHub"
      rev="$head_sha"
    fi

    [[ -n "$name" || $auto_detect ]] || die "add needs the name of the entry"
    [[ -n "$repo" && "$repo" == */* ]] || die "add needs --repo OWNER/REPO (where the PR's branch is)"
    [[ -n "$attrs" || ${#python_pkgs[@]} -gt 0 ]] || die "add needs --attrs (the packages to take from the PR)"

    if [[ -z "$name" ]]; then
      if [[ -n "$attrs" ]]; then
        first_attr="${attrs%%,*}"
        if [[ -n "$pr_title" ]]; then
          title_cand=$(sed -E 's/^[[:space:]]*(\[[^]]+\][[:space:]]*)?([^:, ]+):.*/\2/' <<<"$pr_title")
          found=false
          IFS=',' read -ra attr_list <<<"$attrs"
          for a in "${attr_list[@]}"; do
            if [[ "$a" == "$title_cand" ]]; then
              name="$a"
              found=true
              break
            fi
          done
          $found || name="$first_attr"
        else
          name="$first_attr"
        fi
      elif ((${#python_pkgs[@]} >= 1)); then
        name="${python_pkgs[0]}"
      elif ((${#modules[@]} >= 1)); then
        name="${modules[0]%%=*}"
      fi
    fi
    [[ -n "$name" ]] || name="pr-$pr"

    if entries | jq -e --arg n "$name" 'has($n)' >/dev/null; then
      die "$file already has an entry $name (remove it first)"
    fi

    modules_json='{}'
    for module in "${modules[@]}"; do
      [[ $module == ?*=?* ]] || die "--module needs NAME=PATH"
      modules_json=$(jq --arg n "${module%%=*}" --arg p "${module#*=}" '.[$n] = $p' <<<"$modules_json")
    done
    paths_json='{}'
    IFS=',' read -ra allowed <<<"$attrs${scope:+,$scope}"
    for path in "${paths[@]}"; do
      [[ $path == ?*=?* ]] || die "--path needs NAME=PATH"
      pname="${path%%=*}"
      found=false
      for a in "${allowed[@]}"; do
        if [[ $a == "$pname" ]]; then found=true; break; fi
      done
      $found || die "--path $pname is not in --attrs or --scope"
      paths_json=$(jq --arg n "$pname" --arg p "${path#*=}" '.[$n] = $p' <<<"$paths_json")
    done
    python_json='[]'
    for py in "${python_pkgs[@]}"; do
      python_json=$(jq --arg p "$py" '. + [$p]' <<<"$python_json")
    done

    hash=""
    [[ -z "$rev" ]] || hash=$(nar_hash "$repo")

    entries | jq --arg n "$name" --argjson pr "$pr" --arg owner "${repo%%/*}" --arg repo "${repo#*/}" \
      --arg rev "$rev" --arg h "$hash" --arg upstream "$upstream" \
      --arg attrs "$attrs" --arg scope "$scope" --argjson modules "$modules_json" --argjson paths "$paths_json" \
      --argjson python "$python_json" '
      .[$n] = ({pr: $pr, owner: $owner, repo: $repo, rev: $rev, narHash: $h, attrs: (if $attrs == "" then [] else ($attrs | split(",")) end)}
        + (if $upstream != "NixOS/nixpkgs" then {upstream: $upstream} else {} end)
        + (if $scope == "" then {} else {scope: ($scope | split(","))} end)
        + (if $paths == {} then {} else {paths: $paths} end)
        + (if $modules == {} then {} else {modules: $modules} end)
        + (if $python == [] then {} else {pythonPackages: $python} end))' | write_entries
    if [[ -n "$rev" ]]; then
      echo "added $name, pinned to $rev ($hash)"
    else
      echo "added $name; pin it with: nix-detour pr pin $name SHA"
    fi
    ;;
  pin)
    if [[ "$name" == "--all" || "$name" == "-a" ]] || $all_entries; then
      mapfile -t keys < <(entries | jq -r 'keys[]' 2>/dev/null)
      for k in "${keys[@]}"; do
        pr_num=$(entries | jq -r --arg n "$k" '.[$n].pr')
        cur_rev=$(entries | jq -r --arg n "$k" '.[$n].rev // ""')
        cur_owner=$(entries | jq -r --arg n "$k" '.[$n].owner')
        cur_repo=$(entries | jq -r --arg n "$k" '.[$n].repo')
        entry_upstream=$(entries | jq -r --arg n "$k" '.[$n].upstream // empty')
        target_upstream="${entry_upstream:-$upstream}"
        pr_info=$(gh_api "repos/$target_upstream/pulls/$pr_num")
        latest_sha=$(jq -r '.head.sha // empty' <<<"$pr_info")
        if [[ -z "$latest_sha" || ! "$latest_sha" =~ ^[0-9a-f]{40}$ ]]; then
          echo "$k (#$pr_num): could not fetch latest commit from GitHub, skipping" >&2
          continue
        fi
        if [[ "$latest_sha" == "$cur_rev" ]]; then
          echo "$k is already up to date at ${cur_rev:0:12}"
        else
          rev="$latest_sha"
          hash=$(nar_hash "$cur_owner/$cur_repo")
          entries | jq --arg n "$k" --arg rev "$latest_sha" --arg h "$hash" \
            '.[$n].rev = $rev | .[$n].narHash = $h' | write_entries
          echo "$k updated to ${latest_sha:0:12} ($hash)"
        fi
      done
      exit 0
    fi

    need_entry
    rev="${args[2]:-}"
    owner_repo="$(entries | jq -r --arg n "$name" '.[$n] | "\(.owner)/\(.repo)"')"
    if [[ -z "$rev" ]]; then
      pr_num=$(entries | jq -r --arg n "$name" '.[$n].pr')
      cur_rev=$(entries | jq -r --arg n "$name" '.[$n].rev // ""')
      entry_upstream=$(entries | jq -r --arg n "$name" '.[$n].upstream // empty')
      target_upstream="${entry_upstream:-$upstream}"
      pr_info=$(gh_api "repos/$target_upstream/pulls/$pr_num")
      latest_sha=$(jq -r '.head.sha // empty' <<<"$pr_info")
      [[ -n "$latest_sha" && "$latest_sha" =~ ^[0-9a-f]{40}$ ]] || die "cannot determine latest commit for $name from GitHub: please specify a SHA"
      if [[ "$latest_sha" == "$cur_rev" ]]; then
        cur_hash=$(entries | jq -r --arg n "$name" '.[$n].narHash // ""')
        echo "$name is already up to date at ${cur_rev:0:12} ($cur_hash)"
        exit 0
      fi
      rev="$latest_sha"
    fi
    hash=$(nar_hash "$owner_repo")
    entries | jq --arg n "$name" --arg rev "$rev" --arg h "$hash" \
      '.[$n].rev = $rev | .[$n].narHash = $h' | write_entries
    echo "$name pinned to $rev ($hash)"
    ;;
  remove)
    need_entry
    entries | jq --arg n "$name" 'del(.[$n])' | write_entries
    echo "removed $name"
    ;;
  list)
    entries | jq -r 'to_entries[] | [.key, "#\(.value.pr)",
      (if .value.rev == "" then "not pinned" else .value.rev[0:12] end),
      (.value.attrs | join(","))] | join("\u001f")' |
      while IFS=$'\x1f' read -r n p r a; do
        printf '%-24s %-8s %-12s %s\n' "$n" "$p" "$r" "$a"
      done
    ;;
  eval)
    need_entry
    nix eval --json "$flake#nixpkgsPrs.$(system).\"$name\".packages" \
      --apply 'builtins.mapAttrs (_: p: p.drvPath)' | jq -r 'to_entries[] | "\(.key) \(.value)"'
    ;;
  merged)
    merged=$(nix eval --json "$flake#nixpkgsPrs.$(system)" --apply 'builtins.mapAttrs (_: c: c.merged)') \
      || die "cannot evaluate $flake#nixpkgsPrs"
    jq -r 'to_entries[] | "\(if .value then "merged" else "open" end) \(.key)"' <<<"$merged"
    ;;
  check)
    channel_branch="$channel"
    if [[ $channel_branch == github:*/*/* ]]; then
      channel_branch="${channel_branch#github:*/*/}"
    fi
    target_names=()
    if [[ -n "$name" ]]; then
      need_entry
      target_names=("$name")
    else
      if [[ ! -f "$file" ]]; then
        $as_json && echo "{}" || echo "no $file found"
        exit 0
      fi
      raw_keys=$(entries | jq -r 'keys[]') || exit 1
      mapfile -t target_names <<<"$raw_keys"
    fi

    if ((${#target_names[@]} == 0)); then
      $as_json && echo "{}" || echo "no entries in $file"
      exit 0
    fi

    is_tty=false
    if [[ -t 1 ]] && ! $as_json; then
      is_tty=true
    fi

    json_results='{}'
    if ! $as_json; then
      printf '%-20s %-8s %-16s %s\n' "NAME" "PR" "STATUS" "DETAILS"
    fi

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    for n in "${target_names[@]}"; do
      (
        pr_num=$(entries | jq -r --arg n "$n" '.[$n].pr // empty')
        if [[ -z $pr_num ]]; then
          exit 0
        fi
        entry_upstream=$(entries | jq -r --arg n "$n" '.[$n].upstream // empty')
        target_upstream="${entry_upstream:-$upstream}"

        pr_json=$(gh_api "repos/$target_upstream/pulls/$pr_num")
        status="unknown"
        details="GitHub API unavailable"
        state="unknown"
        draft="false"
        merged="false"
        in_channel="false"
        title=""
        html_url="https://github.com/$target_upstream/pull/$pr_num"

        if [[ -n "$pr_json" && "$pr_json" != "null" ]]; then
          state=$(jq -r '.state // "unknown"' <<<"$pr_json")
          draft=$(jq -r '.draft // false' <<<"$pr_json")
          merged=$(jq -r '.merged // false' <<<"$pr_json")
          merge_commit=$(jq -r '.merge_commit_sha // empty' <<<"$pr_json")
          title=$(jq -r '.title // ""' <<<"$pr_json")
          html_url=$(jq -r '.html_url // ""' <<<"$pr_json")

          if [[ "$merged" == "true" ]]; then
            comp_json=""
            if [[ -n "$merge_commit" ]]; then
              comp_json=$(gh_api "repos/$target_upstream/compare/$channel_branch...$merge_commit")
            fi
            comp_status=$(jq -r '.status // empty' <<<"$comp_json")
            if [[ "$comp_status" == "behind" || "$comp_status" == "identical" ]]; then
              status="in-channel"
              in_channel="true"
              details="landed in $channel_branch (ready to release)"
            else
              status="merged"
              details="merged upstream (waiting for $channel_branch)"
            fi
          elif [[ "$draft" == "true" ]]; then
            status="draft"
            details="draft PR"
          elif [[ "$state" == "closed" ]]; then
            status="closed"
            details="closed without merge"
          else
            status="open"
            details="open upstream"
          fi
        fi

        hash_key=$(printf '%s' "$n" | sha256sum | cut -d' ' -f1)
        jq -n \
          --arg n "$n" --argjson pr "$pr_num" \
          --arg status "$status" --arg state "$state" --argjson draft "$draft" \
          --argjson merged "$merged" --argjson inChannel "$in_channel" \
          --arg details "$details" --arg title "$title" --arg url "$html_url" \
          '{($n): {pr: $pr, status: $status, state: $state, draft: $draft, merged: $merged, inChannel: $inChannel, details: $details, title: $title, url: $url}}' \
          > "$tmpdir/$hash_key.json"
      ) &
    done
    wait

    for n in "${target_names[@]}"; do
      hash_key=$(printf '%s' "$n" | sha256sum | cut -d' ' -f1)
      if [[ ! -f "$tmpdir/$hash_key.json" ]]; then
        die "check failed for entry '$n'"
      fi
      entry_res=$(cat "$tmpdir/$hash_key.json")
      pr_num=$(jq -r --arg n "$n" '.[$n].pr' <<<"$entry_res")
      status=$(jq -r --arg n "$n" '.[$n].status' <<<"$entry_res")
      details=$(jq -r --arg n "$n" '.[$n].details' <<<"$entry_res")

      if $as_json; then
        json_results=$(jq -s '.[0] * .[1]' <<<"$json_results $entry_res")
      else
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
      echo "$json_results" | jq .
    fi
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
