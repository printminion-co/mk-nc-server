#!/usr/bin/env bash
# Decides whether a run builds (see ionos-build.md). Needs git (the checkout, without submodules), jq
# and an authenticated gh. Writes build=true|false, reason, line, server_commit and flavors_commit to
# $GITHUB_OUTPUT.
#
# Environment:
#   EVENT_NAME           schedule or workflow_dispatch
#   KIND                 dev (default) or release; release is rejected here
#   FLAVORS              the optional flavors input (only checked here; a manual run always builds)
#   FORCE                "true" to build although nothing changed
#   REF_NAME             the branch of the run, must be ionos-dev-v<nn>
#   GITHUB_REPOSITORY    owner/name of this fork
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

EVENT_NAME=${EVENT_NAME:?EVENT_NAME is required}
KIND=${KIND:-dev}
FORCE=${FORCE:-false}
FLAVORS=${FLAVORS:-}
REF_NAME=${REF_NAME:?REF_NAME is required}
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
OUT=${GITHUB_OUTPUT:-/dev/null}

case "$KIND" in
  dev) ;;
  release) die "release builds arrive with the snapshot ticket; only kind dev can be built now" ;;
  *) die "unknown build kind '$KIND', expected dev" ;;
esac

if [ -n "$FLAVORS" ]; then
  IFS=',' read -r -a names <<<"$FLAVORS"
  for n in "${names[@]}"; do
    n=$(echo "$n" | tr -d '[:space:]')
    [ -z "$n" ] || [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "'$n' in the flavors input is not a flavor name"
  done
  log "flavors input: $FLAVORS (a subset run, never a baseline for skipping)"
fi

LINE=$(line_of_dev_branch "$REF_NAME") || die "the branch '$REF_NAME' is not a dev branch (ionos-dev-v<nn>); run this workflow from the dev branch"

SERVER_COMMIT=$(git rev-parse HEAD)
FLAVORS_COMMIT=$(git rev-parse HEAD:IONOS) || die "the checkout has no IONOS submodule entry"

decide() { # decide <true|false> <reason>
  log "$2"
  { echo "build=$1"; echo "reason=$2"; echo "line=$LINE"; echo "server_commit=$SERVER_COMMIT"; echo "flavors_commit=$FLAVORS_COMMIT"; } >> "$OUT"
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
