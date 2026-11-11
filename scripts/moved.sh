#!/usr/bin/env bash
# Usage: scripts/moved.sh
#
# Sets the step output moved=true when SKIP_UNMOVED isn't "true", or when
# FLAKE's flake.lock has another revision of INPUT than BASE's flake.lock;
# else moved=false. Environment: SKIP_UNMOVED, FLAKE, INPUT, BASE,
# GITHUB_OUTPUT.
set -euo pipefail

out() {
  echo "moved=$1" >>"$GITHUB_OUTPUT"
  echo "$2"
}
[[ ${SKIP_UNMOVED:-false} == true ]] || { out true "Checking every run (skip-unmoved is off)."; exit 0; }
rev() {
  jq -er --arg i "$INPUT" '.nodes[.nodes.root.inputs[$i]].locked.rev'
}
git fetch -q --depth 1 origin "$BASE" || { echo "cannot fetch $BASE from origin" >&2; exit 1; }
# ./ makes the path relative to this directory, like FLAKE.
before=$(git show "FETCH_HEAD:./${FLAKE%/}/flake.lock" | rev) || { echo "no input $INPUT in $BASE's flake.lock" >&2; exit 1; }
after=$(rev <"${FLAKE%/}/flake.lock") || { echo "no input $INPUT in ${FLAKE%/}/flake.lock" >&2; exit 1; }
if [[ $before == "$after" ]]; then
  out false "$INPUT stays at ${after:0:12}: nothing to check."
else
  out true "$INPUT moves ${before:0:12} -> ${after:0:12}."
fi
