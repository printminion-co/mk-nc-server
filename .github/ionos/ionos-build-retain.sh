#!/usr/bin/env bash
# Keeps the newest KEEP dev pre-releases and deletes the older ones with their tags. Only published
# pre-releases whose tag has the dev form dev-v<base>.<build number> are ever considered; anything else
# is left alone. Needs jq and an authenticated gh.
#
# Environment:
#   GITHUB_REPOSITORY   owner/name of this fork
#   KEEP                how many to keep, default 14
#   DRY_RUN             "true" to only print what would be deleted
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
KEEP=${KEEP:-14}
DRY_RUN=${DRY_RUN:-false}
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "KEEP '$KEEP' must be a whole number of at least 1"

all=$(dev_prereleases "$REPO") || die "could not list the releases of $REPO"
if [ -z "$all" ]; then log "no dev pre-releases: nothing to prune"; exit 0; fi
old=$(tail -n +"$((KEEP + 1))" <<<"$all" | cut -f2)
if [ -z "$old" ]; then log "$(wc -l <<<"$all") dev pre-release(s), at most $KEEP are kept: nothing to prune"; exit 0; fi

while read -r tag; do
  [ -n "$tag" ] || continue
  if [ "$DRY_RUN" = true ]; then
    log "would delete $tag (and its tag)"
  else
    log "deleting $tag (and its tag)"
    gh release delete "$tag" --cleanup-tag --yes
  fi
done <<<"$old"
