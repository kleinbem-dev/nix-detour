#!/usr/bin/env bash
# Usage: scripts/release-check.sh FLAKE CHANNEL
#
# Builds FLAKE's releaseChecks.<system>.* with its nixpkgs set to CHANNEL. Prints
# "release <name>" for each that builds, else "held <name> [<days since>]".
set -euo pipefail

flake="$1" channel="$2"
system=$(nix eval --raw --impure --expr builtins.currentSystem)
today=$(date -u +%s)
holds=$(nix eval --json "$flake#releaseChecks.$system" --override-input nixpkgs "$channel" \
  --apply 'builtins.mapAttrs (_: check: { since = check.nixHolds.since or null; })' 2>/dev/null || true)

if [[ -z $holds || $holds == null ]]; then
  names_json=$(nix eval --json "$flake#releaseChecks.$system" --override-input nixpkgs "$channel" \
    --apply 'builtins.attrNames' 2>/dev/null) || {
    echo "cannot evaluate $flake#releaseChecks.$system" >&2
    exit 1
  }
  mapfile -t names < <(jq -r '.[]' <<<"$names_json")
  holds='{}'
  for name in "${names[@]}"; do
    since=$(nix eval --json "$flake#releaseChecks.$system.\"$name\".nixHolds.since" \
      --override-input nixpkgs "$channel" 2>/dev/null || echo "null")
    holds=$(jq --arg n "$name" --argjson s "$since" '.[$n] = {since: $s}' <<<"$holds")
  done
else
  mapfile -t names < <(jq -r 'keys[]' <<<"$holds")
fi
for name in "${names[@]}"; do
  since=$(jq -r --arg n "$name" '.[$n].since // empty' <<<"$holds")
  days=""
  # A malformed date leaves the age out instead of stopping the check.
  if [[ -n $since ]] && start=$(date -u -d "$since" +%s 2>/dev/null); then
    days=$(((today - start) / 86400))
  fi
  if nix build --no-link "$flake#releaseChecks.$system.\"$name\"" --override-input nixpkgs "$channel" >&2; then
    echo "release $name"
  else
    echo "held $name${days:+ $days}"
  fi
done
