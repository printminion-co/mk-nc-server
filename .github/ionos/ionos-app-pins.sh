#!/usr/bin/env bash
# Proposes new pins for upstream's separately hosted apps (see ionos-app-pins.md).
# Works through the GitHub API only (no clone) and needs jq and an authenticated gh.
#
# Environment:
#   GH_TOKEN, GITHUB_REPOSITORY   required (owner/name of this fork)
#   READ_TOKEN       token for reading public upstream data (nextcloud/*, nextcloud-releases/*), default
#                    GH_TOKEN. The workflow passes the default GITHUB_TOKEN: the nextcloud organization
#                    rejects fine-grained personal access tokens with a lifetime over 366 days, which the
#                    sync token may have. Only operations on the fork use GH_TOKEN.
#   HAS_SYNC_TOKEN   "true" when GH_TOKEN is the repository secret IONOS_SYNC_TOKEN. Pull requests
#                    opened with the default GITHUB_TOKEN do not trigger workflows (no commit lint)
#   LINE             release line, default 33
#   BASE_BRANCH      branch to propose into, default ionos-dev-v$LINE
#   BASE_RELEASE     optional tag like v33.0.10 that overrides the release of BASE_BRANCH
#   DRY_RUN          "true" to only print what would be created
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-app-pins
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
LINE=${LINE:-33}
BASE_BRANCH=${BASE_BRANCH:-$(dev_branch_for_line "$LINE")}
BASE_RELEASE=${BASE_RELEASE:-}
DRY_RUN=${DRY_RUN:-false}
HAS_SYNC_TOKEN=${HAS_SYNC_TOKEN:-false}
RELEASES_REPO=nextcloud-releases/server
UPSTREAM_SERVER=nextcloud/server
UPSTREAM_ORG=nextcloud
READ_TOKEN=${READ_TOKEN:-${GH_TOKEN:-}}
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

# upstream_api <gh api arguments>: the one way to read public upstream data (nextcloud/*, nextcloud-releases/*),
# with the read token. gh's error text goes to $ERRFILE (see api_error), not to the log.
upstream_api() { GH_TOKEN="$READ_TOKEN" gh api "$@" 2>"$ERRFILE"; }
# fork_api <gh api arguments>: a read of this fork with the sync token, same error handling.
fork_api() { gh api "$@" 2>"$ERRFILE"; }
# gh's last error message, on one line
api_error() { tr '\n' ' ' <"$ERRFILE" | sed 's/ *$//'; }

[[ $LINE =~ ^[0-9]+$ ]] || die "LINE '$LINE' is not a number"
[[ $BASE_BRANCH =~ ^[A-Za-z0-9._/-]+$ && $BASE_BRANCH != *..* ]] || die "BASE_BRANCH '$BASE_BRANCH' contains characters that are not allowed in a branch name here"
[ "$HAS_SYNC_TOKEN" = true ] || warn "IONOS_SYNC_TOKEN is not set, using the default GITHUB_TOKEN: a pull request opened with it does not trigger workflows, so the commit-lint check will not run on it. Store a fine-grained token as the repository secret IONOS_SYNC_TOKEN (see ionos-app-pins.md)."

# The pins (lines "app sha") in the apps-upstream/ folder of a root tree of this fork.
pins_in_root_tree() {
  local root au
  root=$(gh api "repos/$REPO/git/trees/$1")
  au=$(jq -r '.tree[] | select(.path == "apps-upstream") | .sha' <<<"$root")
  [ -n "$au" ] || return 0
  gh api "repos/$REPO/git/trees/$au" | jq -r '.tree[] | select(.mode == "160000") | .path + " " + .sha'
}

# The base release of the dev branch, the way ionos-sync.sh finds it: the newest final tag of the
# line (from upstream's server repository) that is an ancestor of the dev branch tip. Done through
# the API: the tag's commit is compared with the tip, status ahead or identical means ancestor.
base_release_of_dev_branch() {
  local tips name type sha status t obj cmp
  local -A TYPE SHA
  tips=$(upstream_api --paginate -X GET "repos/$UPSTREAM_SERVER/git/matching-refs/tags/v$LINE." -f per_page=100) ||
    die "cannot list the tags of $UPSTREAM_SERVER: $(api_error)"
  tips=$(jq -r '.[] | [(.ref | ltrimstr("refs/tags/")), .object.type, .object.sha] | @tsv' <<<"$tips") ||
    die "cannot read the tag list of $UPSTREAM_SERVER"
  while IFS=$'\t' read -r name type sha; do
    [ -n "$name" ] || continue
    TYPE[$name]=$type; SHA[$name]=$sha
  done <<<"$tips"
  while read -r t; do
    [ -n "$t" ] || continue
    sha=${SHA[$t]}
    if [ "${TYPE[$t]}" = tag ]; then   # annotated tag: dereference to the commit
      obj=$(upstream_api "repos/$UPSTREAM_SERVER/git/tags/$sha") || die "cannot read the tag object of $t in $UPSTREAM_SERVER: $(api_error)"
      sha=$(jq -r 'select(.object.type == "commit") | .object.sha' <<<"$obj")
    fi
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "tag $t of $UPSTREAM_SERVER does not point at a commit"
    cmp=$(fork_api -X GET "repos/$REPO/compare/$sha...$BASE_SHA" -f per_page=1) ||
      die "cannot compare $t with $BASE_BRANCH: $(api_error)"
    status=$(jq -r .status <<<"$cmp") || die "cannot compare $t with $BASE_BRANCH: unexpected answer"
    case "$status" in
      ahead | identical) echo "$t"; return 0 ;;
    esac
  done < <(printf '%s\n' "${!TYPE[@]}" | final_tags_newest_first "$LINE")
  die "no final release tag of line $LINE is an ancestor of $BASE_BRANCH"
}

# 1. The tip of the dev branch, and which release tag to pin for
TIP=$(gh api -X GET "repos/$REPO/commits" -f sha="$BASE_BRANCH" -f per_page=1) || die "cannot read branch $BASE_BRANCH of $REPO"
BASE_SHA=$(jq -r '.[0].sha // empty' <<<"$TIP")
ROOT_TREE=$(jq -r '.[0].commit.tree.sha // empty' <<<"$TIP")
[[ $BASE_SHA =~ ^[0-9a-f]{40}$ && -n $ROOT_TREE ]] || die "branch $BASE_BRANCH of $REPO has no commits"
if [ -z "$BASE_RELEASE" ]; then
  BASE_RELEASE=$(base_release_of_dev_branch)
fi
TAG=$BASE_RELEASE
[[ $TAG =~ $(final_tag_re "$LINE") ]] || die "base release '$TAG' is not a final tag of line $LINE (vN.M.P)"
log "release tag $TAG (base of $BASE_BRANCH)"

# 2. Upstream's app list; apps that live in the fork's apps/ need no pin
CONFIG=$(upstream_api -H 'Accept: application/vnd.github.raw+json' "repos/$RELEASES_REPO/contents/stable$LINE.json") ||
  die "cannot read the app list stable$LINE.json of $RELEASES_REPO: $(api_error)"
ROOT=$(gh api "repos/$REPO/git/trees/$ROOT_TREE")
APPS_TREE=$(jq -r '.tree[] | select(.path == "apps") | .sha' <<<"$ROOT")
IN_TREE=$(gh api "repos/$REPO/git/trees/$APPS_TREE" | jq -r '.tree[] | select(.type == "tree") | .path')

DESIRED=""
while IFS=$'\t' read -r id repo; do
  [ -n "$id$repo" ] || continue
  # untrusted text from upstream: validate before any use
  [[ $id =~ ^[a-z0-9_]+$ ]] || die "invalid app id $(printf '%q' "$id") in upstream's app list"
  if grep -qxF -e "$id" <<<"$IN_TREE"; then continue; fi
  case "$repo" in
    "$UPSTREAM_ORG"/*) ;;
    *) log "skipping $id: repository is not under $UPSTREAM_ORG/"; continue ;;
  esac
  [[ $repo =~ ^nextcloud/[A-Za-z0-9._-]+$ && $repo != */. && $repo != */.. ]] ||
    die "invalid repository $(printf '%q' "$repo") for app $id in upstream's app list"
  if ! ref=$(upstream_api "repos/$repo/git/ref/tags/$TAG"); then
    if grep -q 'HTTP 404' "$ERRFILE"; then
      die "tag $TAG not found in $repo (app $id): upstream does not tag every listed app for this release"
    fi
    die "cannot read tag $TAG of $repo (app $id): $(api_error)"
  fi
  sha=$(jq -r 'select(.object.type == "commit") | .object.sha' <<<"$ref")
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "tag $TAG of $repo (app $id) does not point at a commit"
  DESIRED+="$id $sha $repo"$'\n'
done < <(jq -r '.[] | [.id, .repo] | @tsv' <<<"$CONFIG")
DESIRED=${DESIRED%$'\n'}

# 3. Current pins on the dev branch
CURRENT=$(pins_in_root_tree "$ROOT_TREE")

# 4. The difference, as tree entries
ENTRIES=$(jq -n --arg d "$DESIRED" --arg c "$CURRENT" '
  def pins($s): [$s | split("\n")[] | select(length > 0) | split(" ") | {key: .[0], value: .[1]}] | from_entries;
  pins($d) as $want | pins($c) as $have |
  [ ($want | to_entries[] | select($have[.key] != .value)
      | {path: ("apps-upstream/" + .key), mode: "160000", type: "commit", sha: .value}),
    ($have | to_entries[] | select($want[.key] == null)
      | {path: ("apps-upstream/" + .key), mode: "160000", type: "commit", sha: null}) ]')

# .gitmodules changes only when the set of apps changes (append new sections, drop removed ones)
ids_of() { cut -d' ' -f1 <<<"$1" | grep -E '^[a-z0-9_]+$' | sort || true; }
GITMODULES=""
ADDED=$(comm -13 <(ids_of "$CURRENT") <(ids_of "$DESIRED"))
REMOVED=$(comm -23 <(ids_of "$CURRENT") <(ids_of "$DESIRED"))
if [ -n "$ADDED$REMOVED" ]; then
  DROP=""
  while read -r id; do
    [ -n "$id" ] && DROP+="[submodule \"apps-upstream/$id\"]"$'\n'
  done <<<"$REMOVED"
  RAW=$(gh api -X GET -H 'Accept: application/vnd.github.raw+json' "repos/$REPO/contents/.gitmodules" -f ref="$BASE_SHA")
  skip=0
  while IFS= read -r line; do
    if [[ $line == '['* ]]; then
      skip=0
      if grep -qxF -e "$line" <<<"$DROP"; then skip=1; fi
    fi
    if [ "$skip" -eq 0 ]; then GITMODULES+="$line"$'\n'; fi
  done <<<"$RAW"
  while read -r id _ repo; do
    [ -n "$id" ] || continue
    if grep -qxF -e "$id" <<<"$ADDED"; then
      GITMODULES+=$'\n'"[submodule \"apps-upstream/$id\"]"$'\n'$'\t'"path = apps-upstream/$id"$'\n'$'\t'"url = https://github.com/$repo.git"
    fi
  done <<<"$DESIRED"
  GITMODULES+=$'\n'
fi

BRANCH="app-pins/$TAG"
TITLE="IONOS(apps): pin upstream's bundled apps for $TAG"
if [ "$(jq length <<<"$ENTRIES")" -eq 0 ]; then
  log "pins on $BASE_BRANCH already match upstream's apps for $TAG; nothing to do"
  exit 0
fi
log "changes: $(jq -c '[.[] | .path]' <<<"$ENTRIES")"

# 5. Idempotency: an open pull request is never touched; an existing branch with the same pins
#    is left alone; an existing branch with other pins is refreshed.
OWNER=${REPO%%/*}
OPEN=$(gh api -X GET "repos/$REPO/pulls" -f state=open -f head="$OWNER:$BRANCH" -f base="$BASE_BRANCH" | jq -r '.[0].number // empty')
if [ -n "$OPEN" ]; then
  log "pull request #$OPEN for $BRANCH is already open; leaving it alone"
  exit 0
fi
REFRESH=false
BRANCH_SHA=""
if out=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" 2>&1); then
  BRANCH_SHA=$(jq -r .object.sha <<<"$out")
  BRANCH_TREE=$(gh api "repos/$REPO/git/commits/$BRANCH_SHA" | jq -r .tree.sha)
  if [ "$(pins_in_root_tree "$BRANCH_TREE" | sort)" = "$(sort <<<"$DESIRED" | cut -d' ' -f1,2)" ]; then
    log "branch $BRANCH already exists with these pins; nothing to do"
    exit 0
  fi
  REFRESH=true
  log "branch $BRANCH already exists with other pins; it will be updated"
elif [[ $out != *"HTTP 404"* ]]; then
  die "cannot look up branch $BRANCH: $out"
fi

if [ "$DRY_RUN" = true ]; then
  if [ "$REFRESH" = true ]; then
    log "dry run: would update $BRANCH with the changes above, then open a pull request titled: $TITLE"
  else
    log "dry run: would open $BRANCH with the changes above and the title: $TITLE"
  fi
  exit 0
fi

# 6. Create the commit, then create or update the branch, then open the pull request
if [ -n "$GITMODULES" ]; then
  BLOB=$(jq -n --arg c "$GITMODULES" '{content: $c, encoding: "utf-8"}' |
    gh api --method POST "repos/$REPO/git/blobs" --input - | jq -r .sha)
  ENTRIES=$(jq --arg b "$BLOB" '. + [{path: ".gitmodules", mode: "100644", type: "blob", sha: $b}]' <<<"$ENTRIES")
fi
TREE=$(jq -n --arg base "$ROOT_TREE" --argjson e "$ENTRIES" '{base_tree: $base, tree: $e}' |
  gh api --method POST "repos/$REPO/git/trees" --input - | jq -r .sha)
COMMIT=$(jq -n --arg m "$TITLE" --arg t "$TREE" --arg p "$BASE_SHA" '{message: $m, tree: $t, parents: [$p]}' |
  gh api --method POST "repos/$REPO/git/commits" --input - | jq -r .sha)
if [ "$REFRESH" = true ]; then
  # The API has no compare-and-swap: re-read the branch right before moving it and give up when
  # somebody pushed to it since we looked (a best-effort lease).
  NOW=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" | jq -r .object.sha)
  [ "$NOW" = "$BRANCH_SHA" ] || die "branch $BRANCH moved while the helper ran; not overwriting it"
  jq -n --arg s "$COMMIT" '{sha: $s, force: true}' |
    gh api --method PATCH "repos/$REPO/git/refs/heads/$BRANCH" --input - >/dev/null
  log "updated $BRANCH to $COMMIT"
else
  jq -n --arg r "refs/heads/$BRANCH" --arg s "$COMMIT" '{ref: $r, sha: $s}' |
    gh api --method POST "repos/$REPO/git/refs" --input - >/dev/null
fi
URL=$(jq -n --arg t "$TITLE" --arg h "$BRANCH" --arg b "$BASE_BRANCH" \
  '{title: $t, head: $h, base: $b, body: "Proposed by the scheduled ionos-app-pins helper."}' |
  gh api --method POST "repos/$REPO/pulls" --input - | jq -r .html_url)
log "opened $URL"
