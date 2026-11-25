#!/usr/bin/env bash
# Usage: generations.sh NAME [LIMIT]
#
# NAME's store paths in this machine's newest LIMIT (default 30) NixOS or
# nix-darwin system generations, one line per generation, oldest first:
#   <generation> <unix time> <nixpkgs revision or -> <system> <path>...
# Generations of system-profiles/<p> (comin deploys there) are <p>-N, ordered
# with system-N by when they were made.
# Plain POSIX tools and bash 3.2 (macOS): the CLI pipes it into
# `ssh <host> bash -s` too.
# NIX_DETOUR_PROFILES replaces /nix/var/nix/profiles (for tests).
set -u

name="$1"
limit="${2:-30}"
profiles="${NIX_DETOUR_PROFILES:-/nix/var/nix/profiles}"
# The attribute's last component, as it shows in a store path name
# (python3.13-aider-chat-0.86.1): any version and output suffix (-bin, -rc1,
# -unstable-2026-11-01). Broad on purpose: the CLI compares exact paths.
last="${name##*.}"
pattern="-$(printf '%s' "$last" | sed 's/[.+]/\\&/g')-[^/]+\$"

# A link's own mtime (stat without -L) is when the generation was made.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# A function, not a loop inside $( ): macOS's bash 3.2 can't parse a case there.
# no-link: fixed in bash 4.0; macOS keeps 3.2 (GPLv2) as /bin/bash for good.
list_links() {
  for l in "$profiles"/system-*-link "$profiles"/system-profiles/*-link; do
    [ -e "$l" ] || continue
    id=${l##*/}
    id=${id%-link}
    case $l in "$profiles"/system-profiles/*) ;; *) id=${id#system-} ;; esac
    case ${id##*-} in '' | *[!0-9]*) continue ;; esac
    echo "$(mtime "$l") $id $l"
  done
}
links=$(list_links | sort -n | tail -n "$limit")
case "$(uname -m)-$(uname -s)" in
  x86_64-Linux) system=x86_64-linux ;;
  aarch64-Linux) system=aarch64-linux ;;
  arm64-Darwin) system=aarch64-darwin ;;
  x86_64-Darwin) system=x86_64-darwin ;;
  *) system=- ;;
esac
echo "$links" | while read -r t g link; do
  [ -n "$link" ] || continue
  v=$("$link/sw/bin/nixos-version" --json 2>/dev/null || "$link/sw/bin/darwin-version" --json 2>/dev/null)
  rev=$(printf '%s' "$v" | sed -n 's/.*"nixpkgsRevision" *: *"\([0-9a-f]*\)".*/\1/p')
  paths=$(nix-store -qR "$link" 2>/dev/null | grep -E -- "$pattern" | tr '\n' ' ')
  echo "$g $t ${rev:--} $system $paths"
done
