#!/usr/bin/env bash
# nix-detour pr: manage the PRs file of a flake (nixpkgs-prs.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-detour pr <command> [options]

  add NAME --pr NUMBER --repo OWNER/REPO --attrs a,b [--rev SHA]
           [--scope c,d] [--path ATTR=PATH]... [--module NAME=PATH]...
      Add the packages `attrs` of nixpkgs PR NUMBER, whose branch is in
      OWNER/REPO. --rev pins it right away. --scope names packages of the
      PR the attributes need but that stay unexported; --path sets custom
      package files (default: pkgs/by-name/...); --module adds a
      NixOS module of the PR (a path in the PR's tree).
  pin NAME SHA
      Pin NAME to commit SHA (all 40 characters) of its repository.
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
modules=() paths=()
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
    --scope) need "$@"; scope="$2"; shift 2 ;;
    --path) need "$@"; paths+=("$2"); shift 2 ;;
    --module) need "$@"; modules+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"
name="${args[1]:-}"

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
    elif [[ -d "$name" ]] && ! { [[ -f "$file" ]] && jq -e --arg n "$name" 'has($n)' "$file" >/dev/null 2>&1; }; then
      file="$name/nixpkgs-prs.json"
      name=""
    elif [[ -f "$name" ]] && ! { [[ -f "$file" ]] && jq -e --arg n "$name" 'has($n)' "$file" >/dev/null 2>&1; }; then
      file="$name"
      name=""
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
    [[ -n $name ]] || die "add needs the name of the entry"
    [[ $pr =~ ^[0-9]+$ ]] || die "add needs --pr (the nixpkgs PR number)"
    [[ $repo == */* ]] || die "add needs --repo OWNER/REPO (where the PR's branch is)"
    [[ -n $attrs ]] || die "add needs --attrs (the packages to take from the PR)"
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
    hash=""
    [[ -z $rev ]] || hash=$(nar_hash "$repo")
    entries | jq --arg n "$name" --argjson pr "$pr" --arg owner "${repo%%/*}" --arg repo "${repo#*/}" \
      --arg rev "$rev" --arg h "$hash" \
      --arg attrs "$attrs" --arg scope "$scope" --argjson modules "$modules_json" --argjson paths "$paths_json" '
      .[$n] = ({pr: $pr, owner: $owner, repo: $repo, rev: $rev, narHash: $h, attrs: ($attrs | split(","))}
        + (if $scope == "" then {} else {scope: ($scope | split(","))} end)
        + (if $paths == {} then {} else {paths: $paths} end)
        + (if $modules == {} then {} else {modules: $modules} end))' | write_entries
    if [[ -n $rev ]]; then
      echo "added $name, pinned to $rev ($hash)"
    else
      echo "added $name; pin it with: nix-detour pr pin $name SHA"
    fi
    ;;
  pin)
    need_entry
    rev="${args[2]:-}"
    hash=$(nar_hash "$(entries | jq -r --arg n "$name" '.[$n] | "\(.owner)/\(.repo)"')")
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
    if [[ -n $name ]]; then
      need_entry
      target_names=("$name")
    else
      if [[ ! -f $file ]]; then
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

    for n in "${target_names[@]}"; do
      pr_num=$(entries | jq -r --arg n "$n" '.[$n].pr // empty')
      if [[ -z $pr_num ]]; then
        continue
      fi

      pr_json=""
      if command -v gh >/dev/null 2>&1; then
        pr_json=$(gh api "repos/$upstream/pulls/$pr_num" --jq '{state: .state, draft: .draft, merged: .merged, merge_commit_sha: .merge_commit_sha, title: .title, html_url: .html_url}' 2>/dev/null || true)
      fi
      if [[ -z $pr_json || $pr_json == "null" ]]; then
        auth_hdr=()
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
          auth_hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
        fi
        pr_json=$(curl -s -f "${auth_hdr[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$upstream/pulls/$pr_num" 2>/dev/null | jq '{state: .state, draft: .draft, merged: .merged, merge_commit_sha: .merge_commit_sha, title: .title, html_url: .html_url}' 2>/dev/null || true)
      fi

      status="unknown"
      details="GitHub API unavailable"
      state="unknown"
      draft="false"
      merged="false"
      in_channel="false"
      title=""
      html_url="https://github.com/$upstream/pull/$pr_num"

      if [[ -n $pr_json && $pr_json != "null" ]]; then
        state=$(jq -r '.state // "unknown"' <<<"$pr_json")
        draft=$(jq -r '.draft // false' <<<"$pr_json")
        merged=$(jq -r '.merged // false' <<<"$pr_json")
        merge_commit=$(jq -r '.merge_commit_sha // empty' <<<"$pr_json")
        title=$(jq -r '.title // ""' <<<"$pr_json")
        html_url=$(jq -r '.html_url // ""' <<<"$pr_json")

        if [[ $merged == "true" ]]; then
          comp_json=""
          if [[ -n $merge_commit ]]; then
            if command -v gh >/dev/null 2>&1; then
              comp_json=$(gh api "repos/$upstream/compare/$channel_branch...$merge_commit" --jq '{status: .status}' 2>/dev/null || true)
            fi
            if [[ -z $comp_json || $comp_json == "null" ]]; then
              auth_hdr=()
              if [[ -n "${GITHUB_TOKEN:-}" ]]; then
                auth_hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
              fi
              comp_json=$(curl -s -f "${auth_hdr[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$upstream/compare/$channel_branch...$merge_commit" 2>/dev/null | jq '{status: .status}' 2>/dev/null || true)
            fi
          fi
          comp_status=$(jq -r '.status // empty' <<<"$comp_json")
          if [[ $comp_status == "behind" || $comp_status == "identical" ]]; then
            status="in-channel"
            in_channel="true"
            details="landed in $channel_branch (ready to release)"
          else
            status="merged"
            details="merged upstream (waiting for $channel_branch)"
          fi
        elif [[ $draft == "true" ]]; then
          status="draft"
          details="draft PR"
        elif [[ $state == "closed" ]]; then
          status="closed"
          details="closed without merge"
        else
          status="open"
          details="open upstream"
        fi
      fi

      if $as_json; then
        json_results=$(jq --arg n "$n" --argjson pr "$pr_num" \
          --arg status "$status" --arg state "$state" --argjson draft "$draft" \
          --argjson merged "$merged" --argjson inChannel "$in_channel" \
          --arg details "$details" --arg title "$title" --arg url "$html_url" \
          '.[$n] = {pr: $pr, status: $status, state: $state, draft: $draft, merged: $merged, inChannel: $inChannel, details: $details, title: $title, url: $url}' \
          <<<"$json_results")
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
