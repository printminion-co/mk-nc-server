# shellcheck shell=bash
# Helpers shared by ionos-sync.sh and ionos-app-pins.sh. Source it, do not run it.
# Needs bash, jq and (for gh_paginate) an authenticated gh.

LOG_PREFIX="${LOG_PREFIX:-ionos}"

log()  { echo "${LOG_PREFIX}: $*"; }
warn() { echo "::warning::${LOG_PREFIX}: $*"; }
die()  { echo "::error::${LOG_PREFIX}: $*" >&2; exit 1; }

# The dev branch of a release line: ionos-dev-v<line>.
dev_branch_for_line() { echo "ionos-dev-v$1"; }

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
