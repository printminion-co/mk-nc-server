# shellcheck shell=bash
# Helpers shared by the ionos-*.sh scripts. Source it, do not run it.
# Needs bash, jq and (for gh_paginate) an authenticated gh.

LOG_PREFIX="${LOG_PREFIX:-ionos}"

log()  { echo "${LOG_PREFIX}: $*"; }
warn() { echo "::warning::${LOG_PREFIX}: $*"; }
die()  { echo "::error::${LOG_PREFIX}: $*" >&2; exit 1; }

# The dev branch of a release line: ionos-dev-v<line>.
dev_branch_for_line() { echo "ionos-dev-v$1"; }

# The line of a dev branch name (ionos-dev-v33 -> 33); fails for any other name.
line_of_dev_branch() {
  [[ $1 =~ ^ionos-dev-v([0-9]+)$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# The one definition of "a final release tag of line <line>": v<line>.x.y, no beta/rc suffix.
final_tag_re() { echo "^v${1}\\.[0-9]+\\.[0-9]+\$"; }

# Final tags of line <line> read from stdin (one per line), newest first.
final_tags_newest_first() {
  local re; re="$(final_tag_re "$1")"
  { grep -E "$re" || true; } | sort -rV
}

# The newest final tag of line <line> among the tags on stdin; empty when there is none.
newest_final_tag() { final_tags_newest_first "$1" | head -n1; }

# gh_paginate <jq filter> <gh api arguments...>: every page of a GitHub list endpoint, with the
# filter applied to each page (pages arrive as separate JSON documents). Pass query parameters
# with -f/--field together with -X GET, never by concatenating them into the URL.
gh_paginate() {
  local filter="$1"; shift
  gh api --paginate "$@" | jq -r "$filter"
}

# ---- dev builds (ionos-build-*.sh)

# The one definition of a dev pre-release tag: dev-v<base release>.<build number>, for example dev-v33.0.9.42.
DEV_TAG_JQ_RE='^dev-v[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$'

# The dev pre-releases of repository <owner/name>, newest first, as "<build number><TAB><tag>". Only
# published (not draft) pre-releases whose tag matches the dev tag form count; the build number is the
# last element of the tag. A failing listing fails the caller.
dev_prereleases() {
  local list
  list=$(gh_paginate '.[] | select(.prerelease and (.draft | not) and (.tag_name | test("'"$DEV_TAG_JQ_RE"'")))
    | [(.tag_name | capture("\\.(?<n>[0-9]+)$").n), .tag_name] | @tsv' \
    -X GET "repos/$1/releases" -f per_page=100) || return 1
  [ -z "$list" ] || sort -t$'\t' -k1,1nr <<<"$list"
}

# The value of a machine-readable "<key>: <value>" line in a release body read from stdin.
body_value() { sed -n "s/^$1: //p" | head -n1; }

# The root of the checkout the scripts work on: $ROOT, or the top level of the current git work tree.
build_root() { echo "${ROOT:-$(git rev-parse --show-toplevel)}"; }

# The base release (the $OC_VersionString) of the server tree <dir>, for example 33.0.9.
base_release_of() {
  sed -n "s/^.*\\\$OC_VersionString *= *'\\([0-9][0-9.]*\\)'.*\$/\\1/p" "$1/version.php" | head -n1
}

# True when <path> (relative to the checkout) is a submodule of the commit checked out in <root>.
is_gitlink() { git -C "$1" ls-tree HEAD -- "$2" | grep -q '^160000 '; }
