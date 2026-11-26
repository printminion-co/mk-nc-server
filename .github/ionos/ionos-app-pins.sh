#!/usr/bin/env bash
# Proposes new pins for upstream's separately hosted apps (see ionos-app-pins.md).
# Works through the GitHub API only (no clone) and needs jq and an authenticated gh.
#
# Environment:
#   GH_TOKEN, GITHUB_REPOSITORY   required (owner/name of this fork)
#   BASE_BRANCH      branch to propose into, default ionos-dev-v33
#   LINE             release line, default 33
#   BASE_RELEASE     optional tag like v33.0.10; default is the newest final release of LINE
#   DRY_RUN          "true" to only print what would be created
set -euo pipefail

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
BASE_BRANCH=${BASE_BRANCH:-ionos-dev-v33}
LINE=${LINE:-33}
BASE_RELEASE=${BASE_RELEASE:-}
DRY_RUN=${DRY_RUN:-false}
RELEASES_REPO=nextcloud-releases/server
UPSTREAM_ORG=nextcloud

log() { echo "ionos-app-pins: $*"; }
die() { echo "ionos-app-pins: error: $*" >&2; exit 1; }

# 1. Which release tag
if [ -z "$BASE_RELEASE" ]; then
  BASE_RELEASE=$(gh api "repos/$RELEASES_REPO/releases?per_page=100" |
    jq -r --arg re "^v$LINE\\.[0-9]+\\.[0-9]+\$" \
      '.[] | select(.prerelease == false and .draft == false and (.tag_name | test($re))) | .tag_name' |
    sort -V | tail -n 1)
  [ -n "$BASE_RELEASE" ] || die "no final release of line $LINE found"
fi
TAG=$BASE_RELEASE
[[ $TAG =~ ^v$LINE\.[0-9]+\.[0-9]+$ ]] || die "base release '$TAG' is not a final tag of line $LINE (vN.M.P)"
log "release tag $TAG"

# 2. Upstream's app list; apps that live in the fork's apps/ need no pin
CONFIG=$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$RELEASES_REPO/contents/stable$LINE.json")
BASE_SHA=$(gh api "repos/$REPO/git/ref/heads/$BASE_BRANCH" | jq -r .object.sha)
ROOT_TREE=$(gh api "repos/$REPO/git/commits/$BASE_SHA" | jq -r .tree.sha)
ROOT=$(gh api "repos/$REPO/git/trees/$ROOT_TREE")
tree_sha() { jq -r --arg p "$1" '.tree[] | select(.path == $p) | .sha' <<<"$ROOT"; }
APPS_TREE=$(tree_sha apps)
IN_TREE=$(gh api "repos/$REPO/git/trees/$APPS_TREE" | jq -r '.tree[] | select(.type == "tree") | .path')

DESIRED=""
while IFS=$'\t' read -r id repo; do
  if grep -qx "$id" <<<"$IN_TREE"; then continue; fi
  case "$repo" in
    "$UPSTREAM_ORG"/*) ;;
    *) log "skipping $id: repository $repo is not under $UPSTREAM_ORG/"; continue ;;
  esac
  sha=$(gh api "repos/$repo/git/ref/tags/$TAG" | jq -r 'select(.object.type == "commit") | .object.sha')
  [[ $id =~ ^[a-z0-9_]+$ && $sha =~ ^[0-9a-f]{40}$ ]] || die "no commit found for $repo at tag $TAG"
  DESIRED+="$id $sha $repo"$'\n'
done < <(jq -r '.[] | [.id, .repo] | @tsv' <<<"$CONFIG")

# 3. Current pins on the base branch
AU_TREE=$(tree_sha apps-upstream)
CURRENT=""
if [ -n "$AU_TREE" ]; then
  CURRENT=$(gh api "repos/$REPO/git/trees/$AU_TREE" |
    jq -r '.tree[] | select(.mode == "160000") | .path + " " + .sha')$'\n'
fi

# 4. The difference, as tree entries
ENTRIES=$(jq -n --arg d "$DESIRED" --arg c "$CURRENT" '
  def pins($s): [$s | split("\n")[] | select(length > 0) | split(" ") | {key: .[0], value: .[1]}] | from_entries;
  pins($d) as $want | pins($c) as $have |
  [ ($want | to_entries[] | select($have[.key] != .value)
      | {path: ("apps-upstream/" + .key), mode: "160000", type: "commit", sha: .value}),
    ($have | to_entries[] | select($want[.key] == null)
      | {path: ("apps-upstream/" + .key), mode: "160000", type: "commit", sha: null}) ]')

# .gitmodules changes only when the set of apps changes (append new sections, drop removed ones)
GITMODULES=""
ADDED=$(comm -13 <(awk '{print $1}' <<<"$CURRENT" | sort) <(awk '{print $1}' <<<"$DESIRED" | sort))
REMOVED=$(comm -23 <(awk '{print $1}' <<<"$CURRENT" | sort) <(awk '{print $1}' <<<"$DESIRED" | sort))
if [ -n "$ADDED$REMOVED" ]; then
  GITMODULES=$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$REPO/contents/.gitmodules?ref=$BASE_SHA")
  GITMODULES=$(awk -v removed="$REMOVED" '
    BEGIN { n = split(removed, r, "\n"); for (i = 1; i <= n; i++) if (r[i] != "") drop["[submodule \"apps-upstream/" r[i] "\"]"] = 1 }
    /^\[/ { skip = ($0 in drop) }
    !skip { print }' <<<"$GITMODULES")
  while read -r id _ repo; do
    if grep -qx "$id" <<<"$ADDED"; then
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

# 5. Idempotency: never a second branch or pull request for the same tag
if gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  log "branch $BRANCH already exists; nothing to do"
  exit 0
fi
OWNER=${REPO%%/*}
OPEN=$(gh api "repos/$REPO/pulls?state=open&head=$OWNER:$BRANCH&base=$BASE_BRANCH" | jq -r '.[0].number // empty')
if [ -n "$OPEN" ]; then
  log "pull request #$OPEN for $BRANCH is already open; nothing to do"
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  log "dry run: would open $BRANCH with the changes above and the title: $TITLE"
  exit 0
fi

# 6. Create branch, commit and pull request
if [ -n "$GITMODULES" ]; then
  BLOB=$(jq -n --arg c "$GITMODULES" '{content: $c, encoding: "utf-8"}' |
    gh api --method POST "repos/$REPO/git/blobs" --input - | jq -r .sha)
  ENTRIES=$(jq --arg b "$BLOB" '. + [{path: ".gitmodules", mode: "100644", type: "blob", sha: $b}]' <<<"$ENTRIES")
fi
TREE=$(jq -n --arg base "$ROOT_TREE" --argjson e "$ENTRIES" '{base_tree: $base, tree: $e}' |
  gh api --method POST "repos/$REPO/git/trees" --input - | jq -r .sha)
COMMIT=$(jq -n --arg m "$TITLE" --arg t "$TREE" --arg p "$BASE_SHA" '{message: $m, tree: $t, parents: [$p]}' |
  gh api --method POST "repos/$REPO/git/commits" --input - | jq -r .sha)
jq -n --arg r "refs/heads/$BRANCH" --arg s "$COMMIT" '{ref: $r, sha: $s}' |
  gh api --method POST "repos/$REPO/git/refs" --input - >/dev/null
URL=$(jq -n --arg t "$TITLE" --arg h "$BRANCH" --arg b "$BASE_BRANCH" \
  '{title: $t, head: $h, base: $b, body: "Proposed by the scheduled ionos-app-pins helper."}' |
  gh api --method POST "repos/$REPO/pulls" --input - | jq -r .html_url)
log "opened $URL"
