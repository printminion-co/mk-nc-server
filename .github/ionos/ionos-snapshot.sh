#!/usr/bin/env bash
# Cuts a snapshot and starts its release build (see ionos-snapshot.md). Run by ionos-snapshot.yml; every input
# comes from the environment. Needs gh, jq and base64. It never clones the repository (about 7.6 GB of history):
# it reads and writes refs through the API.
#
# What it does, in this order, and nothing else:
#   1. validates every input with a regular expression (the scope is only ever TEXT: it is stored in the tag
#      annotation and never put into a shell command or a URL);
#   2. reads the tip of the source branch and the base release from its version.php;
#   3. refuses when the release number is used: the branch rc/ncw-v<nn>-<n> exists, or ANY tag
#      ncw-v<nn>.<x>.<y>-<n> of the line exists (rehearsal: the rehearsal/... names, checked among themselves);
#   4. creates the branch at the tip (no new commit, so signatures stay as they are) and the ANNOTATED tag
#      ncw-v<base>-<n>; it never updates or deletes a ref, whatever fails;
#   5. starts the release build explicitly, because pushes made with a token do not start the workflow run
#      that matters here: gh workflow run ionos-build.yml --ref <branch> -f kind=release.
# The release build reads release number, snapshot branch and scope from the tag annotation, so nothing but the
# kind is passed to it.
#
# Environment:
#   GITHUB_REPOSITORY  owner/name of the fork                                  (required)
#   GH_TOKEN           the token for gh: IONOS_SYNC_TOKEN, else the default token (required)
#   HAS_SYNC_TOKEN     "true" when GH_TOKEN is IONOS_SYNC_TOKEN; anything else makes the script warn
#   RELEASE_NR         positive integer, restarts at 1 for each line         (required)
#   SOURCE_BRANCH      ionos-dev-v<nn>                                         (required)
#   SCOPE              the scope text, one line, at most 500 characters      (required)
#   REHEARSAL          true or false (default false): rehearsal/ and rehearsal- names
#   DRY_RUN            true or false (default false): check everything, create and start nothing
#   RETRIES            attempts to start the release build, default 3
#   RETRY_SLEEP        seconds between those attempts, default 5
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-snapshot
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
RELEASE_NR=${RELEASE_NR-}
SOURCE_BRANCH=${SOURCE_BRANCH-}
SCOPE=${SCOPE-}
REHEARSAL=${REHEARSAL:-false}
DRY_RUN=${DRY_RUN:-false}
HAS_SYNC_TOKEN=${HAS_SYNC_TOKEN:-false}
RETRIES=${RETRIES:-3}
RETRY_SLEEP=${RETRY_SLEEP:-5}
OUT=${GITHUB_OUTPUT:-/dev/null}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

# ---- 1. inputs. Every one is checked before anything is read from or written to GitHub.
[[ $RELEASE_NR =~ ^[1-9][0-9]{0,8}$ ]] || die "release_nr must be a positive integer without leading zeros (at most 9 digits)"
[[ $SOURCE_BRANCH =~ ^ionos-dev-v([0-9]{1,3})$ ]] || die "source_branch must be a dev branch ionos-dev-v<nn>"
LINE=${BASH_REMATCH[1]}
valid_scope "$SCOPE" || die "scope is required: one line of text without control characters or leading and trailing blanks, at most $SCOPE_MAX characters"
case "$REHEARSAL" in true|false) ;; *) die "rehearsal must be true or false" ;; esac
case "$DRY_RUN" in true|false) ;; *) die "dry_run must be true or false" ;; esac
[[ $RETRIES =~ ^[1-9][0-9]?$ && $RETRY_SLEEP =~ ^[0-9]+$ ]] || die "RETRIES and RETRY_SLEEP must be whole numbers"

if [ "$HAS_SYNC_TOKEN" != true ]; then
  warn "IONOS_SYNC_TOKEN is not set, using the default GITHUB_TOKEN. GitHub may refuse to create a ref that carries workflow files with it; the branch is the dev branch's own commit, so it often works, but only a token with the workflow scope is supported (ADR 0007, see ionos-snapshot.md)."
fi
[ "$REHEARSAL" = false ] || log "REHEARSAL: the names rehearsal/ and rehearsal- are used, the real ones stay untouched"

# ---- 2. the source
SRC=$(gh api "repos/$REPO/git/ref/heads/$SOURCE_BRANCH" --jq .object.sha) || die "could not read the branch $SOURCE_BRANCH of $REPO"
[[ $SRC =~ ^[0-9a-f]{40}$ ]] || die "the tip of $SOURCE_BRANCH is '$SRC', not a commit sha"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# the version.php of THAT commit (not of the branch, which may move while this runs)
gh api -X GET "repos/$REPO/contents/version.php" -f "ref=$SRC" --jq .content | base64 -d > "$tmp/version.php" \
  || die "could not read version.php of $SOURCE_BRANCH at $SRC"
BASE=$(base_release_of "$tmp")
[[ $BASE =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]] || die "no base release (\$OC_VersionString) found in version.php of $SOURCE_BRANCH at $SRC"
[ "${BASH_REMATCH[1]}" = "$LINE" ] || die "$SOURCE_BRANCH is line $LINE but its version.php says $BASE: refusing to cut a snapshot from it"

BRANCH=$(snapshot_branch_name "$REHEARSAL" "$LINE" "$RELEASE_NR")
TAG=$(snapshot_tag_name "$REHEARSAL" "$BASE" "$RELEASE_NR")
log "source: $SOURCE_BRANCH at $SRC (base release $BASE, line $LINE)"

# ---- 3. a used release number. The branch is looked up with a prefix match, so it is compared exactly; the tags
# of ANY base release of the line count (the number restarts per line, not per base release).
used=()
refs=$(gh api --paginate "repos/$REPO/git/matching-refs/heads/$BRANCH" | jq -r --arg r "refs/heads/$BRANCH" '.[] | select(.ref == $r) | .ref') \
  || die "could not list the branches of $REPO"
[ -z "$refs" ] || used+=("branch ${refs#refs/heads/}")
tag_re="^refs/tags/$([ "$REHEARSAL" = true ] && echo rehearsal || echo ncw)-v${LINE}\\.[0-9]+\\.[0-9]+-${RELEASE_NR}\$"
refs=$(gh api --paginate "repos/$REPO/git/matching-refs/tags/$(snapshot_tag_search_prefix "$REHEARSAL" "$LINE")" | jq -r --arg re "$tag_re" '.[] | select(.ref | test($re)) | .ref') \
  || die "could not list the tags of $REPO"
while read -r r; do [ -z "$r" ] || used+=("tag ${r#refs/tags/}"); done <<<"$refs"
if [ ${#used[@]} -gt 0 ]; then
  hint="Choose the next release number; refs are never updated or deleted."
  [ "$REHEARSAL" != true ] || hint="Choose another number, or delete the rehearsal refs and release by hand first (ionos-snapshot.md)."
  die "release number $RELEASE_NR of line $LINE is already used by: ${used[*]}. $hint"
fi

MESSAGE=$(snapshot_tag_message "$REHEARSAL" "$LINE" "$BASE" "$RELEASE_NR" "$SOURCE_BRANCH" "$SRC" "$SCOPE")

if [ "$DRY_RUN" = true ]; then
  log "[dry run] would: create the branch $BRANCH at $SRC and the annotated tag $TAG, then start: gh workflow run ionos-build.yml --ref $BRANCH -f kind=release"
  log "[dry run] the tag annotation would be:"
  sed 's/^/    /' <<<"$MESSAGE"
  exit 0
fi

# ---- 4. create. The annotated tag object first (it is only an object, no ref points at it yet), then the branch,
# then the tag ref. Nothing is ever deleted: if a step fails, what exists stays and the message says what.
TAG_OBJECT=$(gh api -X POST "repos/$REPO/git/tags" -f "tag=$TAG" -f "message=$MESSAGE" -f "object=$SRC" -f type=commit --jq .sha) \
  || die "could not create the annotated tag object for $TAG; nothing was created"
[[ $TAG_OBJECT =~ ^[0-9a-f]{40}$ ]] || die "the tag object for $TAG came back as '$TAG_OBJECT'; nothing was created"
gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$BRANCH" -f "sha=$SRC" >/dev/null \
  || die "could not create the branch $BRANCH; nothing was created"
log "created the branch $BRANCH at $SRC"
if ! gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/tags/$TAG" -f "sha=$TAG_OBJECT" >/dev/null; then
  die "the branch $BRANCH exists but the tag $TAG could not be created. Nothing was deleted, and no release build was started (it needs the tag). The release number $RELEASE_NR is spent: choose a new release number. If the half-made snapshot must go, an admin removes the branch by hand (disable the ruleset ncw-snapshot-branches for the moment, see ionos-snapshot.md)."
fi
log "created the annotated tag $TAG"
{ echo "branch=$BRANCH"; echo "tag=$TAG"; echo "source_commit=$SRC"; echo "base_release=$BASE"; } >> "$OUT"

# ---- 5. start the release build. A failure here leaves the snapshot as it is.
RUNS_URL="https://github.com/$REPO/actions/workflows/ionos-build.yml"
{
  echo "### Snapshot $TAG"
  echo
  echo "- branch: \`$BRANCH\` at \`$SRC\` (from \`$SOURCE_BRANCH\`)"
  echo "- annotated tag: \`$TAG\`"
  echo "- release build: [runs of ionos-build.yml]($RUNS_URL)"
} >> "$SUMMARY"

attempt=1
while :; do
  if gh workflow run ionos-build.yml -R "$REPO" --ref "$BRANCH" -f kind=release; then
    log "started the release build of $BRANCH (attempt $attempt)"
    exit 0
  fi
  [ "$attempt" -lt "$RETRIES" ] || break
  warn "starting the release build failed (attempt $attempt of $RETRIES), trying again in ${RETRY_SLEEP}s"
  sleep "$RETRY_SLEEP"
  attempt=$((attempt + 1))
done
die "the snapshot $BRANCH and its tag $TAG exist and stay, but the release build could NOT be started. Start it yourself: gh workflow run ionos-build.yml --ref $BRANCH -f kind=release (or Actions > IONOS build > Run workflow, branch $BRANCH, kind release). Do not run this workflow again for release number $RELEASE_NR: it would be refused."
