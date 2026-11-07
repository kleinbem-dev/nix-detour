#!/usr/bin/env bash
# Usage: scripts/commit-signed.sh BRANCH HEADLINE PATH...
#
# Commits PATH... onto the existing BRANCH via GraphQL createCommitOnBranch, so
# GitHub signs it with no key in CI. Fails if BRANCH moved since EXPECTED_HEAD
# (the commit the files were computed on; default: BRANCH's head now).
# Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

branch="$1" headline="$2"
shift 2
repo="${GITHUB_REPOSITORY:?}"
head="${EXPECTED_HEAD:-$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha)}"

additions='[]'
for path in "$@"; do
  additions=$(jq --arg p "$path" --rawfile c <(base64 <"$path" | tr -d '\n') '. + [{path: $p, contents: $c}]' <<<"$additions")
done

jq -n \
  --arg repo "$repo" --arg branch "$branch" --arg sha "$head" --arg headline "$headline" \
  --slurpfile additions <(printf '%s' "$additions") \
  --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      message: {headline: $headline},
      expectedHeadOid: $sha,
      fileChanges: {additions: $additions[0]}
  }}}' | gh api graphql --input - --jq .data.createCommitOnBranch.commit.oid
