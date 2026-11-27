#!/usr/bin/env bash
# Decides whether a run builds (see ionos-build.md). Needs git (the checkout, without submodules), jq
# and an authenticated gh. Writes build=true|false, reason, kind, line, server_commit and flavors_commit to
# $GITHUB_OUTPUT. For a release build it also writes tag, base_release, release_nr, snapshot_branch, rehearsal, scope,
# source_branch and source_commit, all read from the ANNOTATED snapshot tag of the branch (read_snapshot_tag in
# ionos-lib.sh): the scope is never an input of the build.
#
# Environment:
#   EVENT_NAME           schedule or workflow_dispatch
#   KIND                 dev (default) or release
#   FLAVORS              the optional flavors input (dev: only checked here, a manual run always builds; release: refused)
#   FORCE                "true" to build although nothing changed (dev only)
#   REF_NAME, REF_TYPE   the ref of the run. Dev: the branch ionos-dev-v<nn>. Release: the branch rc/ncw-v<nn>-<n> or
#                        rehearsal/ncw-v<nn>-<n>; the rehearsal flag is derived from this prefix and from nothing else
#   GITHUB_REPOSITORY    owner/name of this fork
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

EVENT_NAME=${EVENT_NAME:?EVENT_NAME is required}
KIND=${KIND:-dev}
FORCE=${FORCE:-false}
REF_TYPE=${REF_TYPE:-branch}
FLAVORS=${FLAVORS:-}
REF_NAME=${REF_NAME:?REF_NAME is required}
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
OUT=${GITHUB_OUTPUT:-/dev/null}

case "$KIND" in
  dev|release) ;;
  *) die "unknown build kind '$KIND', expected dev or release" ;;
esac

if [ -n "$FLAVORS" ]; then
  IFS=',' read -r -a names <<<"$FLAVORS"
  for n in "${names[@]}"; do
    n=$(echo "$n" | tr -d '[:space:]')
    [ -z "$n" ] || [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "'$n' in the flavors input is not a flavor name"
  done
  log "flavors input: $FLAVORS (a subset run, never a baseline for skipping)"
fi

if [ "$KIND" = release ]; then
  # A release build builds every flavor of a frozen snapshot and is started by the snapshot workflow (or by a
  # person who restarts it): never by a schedule, never as a subset, never forced.
  [ "$EVENT_NAME" = workflow_dispatch ] || die "a release build is started manually (workflow_dispatch), not by '$EVENT_NAME'"
  [ -z "$FLAVORS" ] || die "a release build builds every flavor: the flavors input must be empty"
  [ "$FORCE" != true ] || die "force does not apply to a release build, which always builds"
  [ "$REF_TYPE" = branch ] || die "a release build runs on a snapshot branch, not on a $REF_TYPE"
  [[ $REF_NAME =~ $SNAPSHOT_BRANCH_RE ]] || die "a release build runs only from a snapshot branch rc/ncw-v<nn>-<n> (rehearsal: rehearsal/ncw-v<nn>-<n>), not from '$REF_NAME'"
  LINE=${BASH_REMATCH[2]}
  SERVER_COMMIT=$(git rev-parse HEAD)
  FLAVORS_COMMIT=$(git rev-parse HEAD:IONOS) || die "the checkout has no IONOS submodule entry"
  read_snapshot_tag "$REPO" "$REF_NAME" "$SERVER_COMMIT"
  log "release build of $REF_NAME: tag $SNAP_TAG, base release $SNAP_BASE, release number $SNAP_NR, rehearsal $SNAP_REHEARSAL, scope: $SNAP_SCOPE"
  {
    echo "build=true"; echo "reason=release build of $REF_NAME"; echo "kind=release"; echo "line=$LINE"
    echo "server_commit=$SERVER_COMMIT"; echo "flavors_commit=$FLAVORS_COMMIT"
    echo "tag=$SNAP_TAG"; echo "base_release=$SNAP_BASE"; echo "release_nr=$SNAP_NR"; echo "snapshot_branch=$SNAP_BRANCH"
    echo "rehearsal=$SNAP_REHEARSAL"; echo "scope=$SNAP_SCOPE"; echo "source_branch=$SNAP_SOURCE_BRANCH"; echo "source_commit=$SNAP_SOURCE_COMMIT"
  } >> "$OUT"
  exit 0
fi

LINE=$(line_of_dev_branch "$REF_NAME") || die "the branch '$REF_NAME' is not a dev branch (ionos-dev-v<nn>); run this workflow from the dev branch"

SERVER_COMMIT=$(git rev-parse HEAD)
FLAVORS_COMMIT=$(git rev-parse HEAD:IONOS) || die "the checkout has no IONOS submodule entry"

decide() { # decide <true|false> <reason>
  log "$2"
  { echo "build=$1"; echo "reason=$2"; echo "kind=dev"; echo "line=$LINE"; echo "server_commit=$SERVER_COMMIT"; echo "flavors_commit=$FLAVORS_COMMIT"; } >> "$OUT"
  exit 0
}

if [ "$EVENT_NAME" != schedule ]; then decide true "manual run: always builds"; fi
if [ "$FORCE" = true ]; then decide true "forced: builds although nothing may have changed"; fi

previous=$(dev_prereleases "$REPO") || die "could not list the releases of $REPO"
last_tag=$(head -n1 <<<"$previous" | cut -f2)
[ -n "$last_tag" ] || decide true "no dev pre-release yet: builds"

body=$(gh api "repos/$REPO/releases/tags/$last_tag" --jq .body) || die "could not read the release $last_tag"
last_scope=$(body_value flavors_scope <<<"$body")
last_server=$(body_value server_commit <<<"$body")
last_flavors=$(body_value flavors_commit <<<"$body")
# The flavors commit fixes the set of flavors, so "all flavors" recorded then is "all flavors resolved now".
[ "$last_scope" = all ] || decide true "$last_tag did not cover all flavors (scope '${last_scope:-unknown}'): builds"
if [ "$last_server" = "$SERVER_COMMIT" ] && [ "$last_flavors" = "$FLAVORS_COMMIT" ]; then
  decide false "nothing changed since $last_tag (server $SERVER_COMMIT, flavors $FLAVORS_COMMIT): skipping"
fi
decide true "changed since $last_tag (server ${last_server:-unknown} -> $SERVER_COMMIT, flavors ${last_flavors:-unknown} -> $FLAVORS_COMMIT): builds"
