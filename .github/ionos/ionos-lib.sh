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

# ---- snapshots and release builds (ionos-snapshot*.sh, ionos-build-*.sh)

# The one definition of the names. <rehearsal> is true or false: a rehearsal uses its own prefixes, so the real
# names are never used by one (rc/* and ncw-v* are protected from deletion, rehearsal refs are not).
#   branch  rc/ncw-v<line>-<n>          rehearsal/ncw-v<line>-<n>
#   tag     ncw-v<base>-<n>             rehearsal-v<base>-<n>        (annotated)
snapshot_branch_name() { # snapshot_branch_name <rehearsal> <line> <release number>
  if [ "$1" = true ]; then echo "rehearsal/ncw-v$2-$3"; else echo "rc/ncw-v$2-$3"; fi
}
snapshot_tag_name() { # snapshot_tag_name <rehearsal> <base release> <release number>
  if [ "$1" = true ]; then echo "rehearsal-v$2-$3"; else echo "ncw-v$2-$3"; fi
}
# The tag prefix without the base release, for matching-refs: ncw-v33. or rehearsal-v33.
snapshot_tag_search_prefix() { if [ "$1" = true ]; then echo "rehearsal-v$2."; else echo "ncw-v$2."; fi; }
# A snapshot branch: rc/ncw-v<line>-<n> or rehearsal/ncw-v<line>-<n>.
SNAPSHOT_BRANCH_RE='^(rc|rehearsal)/ncw-v([0-9]+)-([1-9][0-9]*)$'
# The scope text: one line, no control characters, no leading or trailing blank, at most 500 characters.
SCOPE_MAX=500
valid_scope() {
  local s="$1"
  [ -n "$s" ] && [ "${#s}" -le "$SCOPE_MAX" ] || return 1
  [[ $s != *[[:cntrl:]]* ]] || return 1
  [[ $s =~ ^[^[:space:]] && $s =~ [^[:space:]]$ ]]
}

# The annotation of a snapshot tag. Single line values, the scope last, so no value can inject another key.
snapshot_tag_message() { # <rehearsal> <line> <base> <nr> <source branch> <source commit> <scope>
  local tag branch; tag=$(snapshot_tag_name "$1" "$3" "$4"); branch=$(snapshot_branch_name "$1" "$2" "$4")
  printf '%s\n\n' "$tag: snapshot of $5 for the release build"
  printf 'release_nr: %s\nline: %s\nbase_release: %s\nsource_branch: %s\nsource_commit: %s\nsnapshot_branch: %s\nrehearsal: %s\nscope: %s\n' \
    "$4" "$2" "$3" "$5" "$6" "$branch" "$1" "$7"
}
# The value of "<key>: <value>" in an annotation read from stdin (the first such line).
tag_message_value() { sed -n "s/^$1: //p" | head -n1; }

# read_snapshot_tag <owner/name> <branch of the run> <commit built>: the facts of the snapshot a release build
# builds, read from the ANNOTATED tag of that snapshot. Dies unless the branch is a snapshot branch, exactly one
# tag of that release number and line exists, it is annotated, points at the built commit, and its annotation agrees
# with the branch name. Sets SNAP_TAG SNAP_BASE SNAP_NR SNAP_LINE SNAP_REHEARSAL SNAP_BRANCH SNAP_SCOPE
# SNAP_SOURCE_BRANCH SNAP_SOURCE_COMMIT (read by the callers). Needs gh and jq.
# shellcheck disable=SC2034
read_snapshot_tag() {
  local repo="$1" ref="$2" commit="$3" prefix line nr re found nfound tagref objtype objsha tagjson msg v
  [[ $ref =~ $SNAPSHOT_BRANCH_RE ]] || die "'$ref' is not a snapshot branch (rc/ncw-v<nn>-<n>)"
  prefix=${BASH_REMATCH[1]}; line=${BASH_REMATCH[2]}; nr=${BASH_REMATCH[3]}
  SNAP_REHEARSAL=false; [ "$prefix" = rehearsal ] && SNAP_REHEARSAL=true
  re="^refs/tags/$([ "$SNAP_REHEARSAL" = true ] && echo rehearsal || echo ncw)-v${line}\\.[0-9]+\\.[0-9]+-${nr}\$"
  found=$(gh api --paginate "repos/$repo/git/matching-refs/tags/$(snapshot_tag_search_prefix "$SNAP_REHEARSAL" "$line")" \
    | jq -r --arg re "$re" '.[] | select(.ref | test($re)) | [.ref, .object.type, .object.sha] | @tsv') \
    || die "could not list the tags of $repo"
  nfound=$(grep -c . <<<"$found" || true)
  [ "$nfound" -ge 1 ] || die "no snapshot tag for $ref: the snapshot workflow creates the branch and its annotated tag; a branch made any other way is not built as a release"
  [ "$nfound" -eq 1 ] || die "more than one snapshot tag matches $ref: $(cut -f1 <<<"$found" | paste -sd' ')"
  IFS=$'\t' read -r tagref objtype objsha <<<"$found"
  SNAP_TAG=${tagref#refs/tags/}
  [ "$objtype" = tag ] || die "the tag $SNAP_TAG is a lightweight tag (it points at a $objtype): the scope lives in the annotation of an annotated tag"
  tagjson=$(gh api "repos/$repo/git/tags/$objsha") || die "could not read the annotated tag $SNAP_TAG"
  [ "$(jq -r '.object.type' <<<"$tagjson")" = commit ] || die "the tag $SNAP_TAG does not point at a commit"
  v=$(jq -r '.object.sha' <<<"$tagjson")
  [ "$v" = "$commit" ] || die "the tag $SNAP_TAG points at $v but this run builds $commit: the branch $ref and its tag disagree"
  msg=$(jq -r '.message' <<<"$tagjson")
  SNAP_BRANCH=$(tag_message_value snapshot_branch <<<"$msg"); SNAP_NR=$(tag_message_value release_nr <<<"$msg")
  SNAP_LINE=$(tag_message_value line <<<"$msg"); SNAP_BASE=$(tag_message_value base_release <<<"$msg")
  SNAP_SCOPE=$(tag_message_value scope <<<"$msg"); SNAP_SOURCE_BRANCH=$(tag_message_value source_branch <<<"$msg")
  SNAP_SOURCE_COMMIT=$(tag_message_value source_commit <<<"$msg")
  [ "$SNAP_BRANCH" = "$ref" ] || die "the annotation of $SNAP_TAG names the snapshot branch '$SNAP_BRANCH', not $ref"
  { [ "$SNAP_NR" = "$nr" ] && [ "$SNAP_LINE" = "$line" ]; } || die "the annotation of $SNAP_TAG disagrees with $ref about the release number or line"
  [ "$(tag_message_value rehearsal <<<"$msg")" = "$SNAP_REHEARSAL" ] || die "the annotation of $SNAP_TAG disagrees with $ref about rehearsal"
  [ "$SNAP_TAG" = "$(snapshot_tag_name "$SNAP_REHEARSAL" "$SNAP_BASE" "$nr")" ] || die "the annotation of $SNAP_TAG names the base release '$SNAP_BASE', which does not fit the tag name"
  valid_scope "$SNAP_SCOPE" || die "the annotation of $SNAP_TAG has no usable scope"
}
