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

# Upstream's workflow files stay untouched in the fork (deleting them would conflict on every rebase);
# instead every active workflow outside our ionos- prefix is disabled. Workflows that upstream adds later
# are caught by the next call. Used by ionos-sync.sh (daily) and ionos-app-pins.sh (before it opens a
# pull request, so that a pull request can never start an upstream workflow).
# Needs REPO (owner/name) and optionally DRY_RUN=true (print "would: ...", change nothing). A 4xx on one
# workflow is a warning and the others are still handled; any other failure makes the function return 1.
disable_upstream_workflows() {
  local id path list err failed=0
  # only real workflow files: dynamic workflows (for example pages-build-deployment) have a
  # path outside .github/workflows/ and cannot be disabled this way
  list="$(gh_paginate '.workflows[] | select(.state == "active")
             | select(.path | startswith(".github/workflows/"))
             | select(.path | startswith(".github/workflows/ionos-") | not) | [.id, .path] | @tsv' \
             "repos/${REPO}/actions/workflows?per_page=100")" || return 1
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    if [ "${DRY_RUN:-false}" = true ]; then
      log "[dry run] would: disable workflow ${path} (${id})"
    elif err="$(gh api -X PUT "repos/${REPO}/actions/workflows/${id}/disable" 2>&1 >/dev/null)"; then
      log "workflows: disabled ${path}"
    elif [[ "$err" == *"HTTP 4"* ]]; then
      warn "workflow ${path} (${id}) could not be disabled, continuing: ${err}"
    else
      echo "::error::${LOG_PREFIX}: disabling workflow ${path} (${id}) failed: ${err}"; failed=1
    fi
  done <<<"$list"
  return "$failed"
}

# ---- smoke test (ionos-smoke-*.sh)

# The apps of `ncw resolve` output <file> as "<id> <mode>" lines (the `apps:` section, "  id: mode").
resolved_apps() {
  awk '/^[A-Za-z_]+:/ { sec = $1; sub(/:$/, "", sec); next }
       sec == "apps" && /^  [^ ]/ { id = $1; sub(/:$/, "", id); print id, $2 }' "$1"
}

# The declared environment variables of `ncw resolve` output <file> as "<name><TAB><required><TAB><default>" lines
# (the `env:` section, a list of maps; quotes around a value are dropped; `env: []` gives nothing).
resolved_env() {
  awk -v OFS='\t' '
    function flush() { if (name != "") print name, req, def; name = ""; req = "false"; def = "" }
    function val(s) { sub(/^[^:]*: */, "", s); if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) s = substr(s, 2, length(s) - 2); return s }
    /^[A-Za-z_]+:/ { flush(); sec = $1; sub(/:$/, "", sec); next }
    sec != "env" { next }
    /^  - name:/ { flush(); name = val($0); req = "false"; def = ""; next }
    /^    required:/ { req = val($0); next }
    /^    default:/ { def = val($0); next }
    END { flush() }' "$1"
}

# The apps of `ncw resolve` output <file> that the flavor enables after the install (enable_after_install), one id per line.
resolved_enable_after_install() {
  awk '/^[A-Za-z_]+:/ { sec = $1; sub(/:$/, "", sec); next }
       sec == "enable_after_install" && /^  - / { print $2 }' "$1"
}
