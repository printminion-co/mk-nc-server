#!/usr/bin/env bash
# Opens ONE issue for the weekly app cache check when its report ($REPORT, written by ionos-cache-check.sh) names
# mismatching apps. If an open issue with the fixed title exists, a comment is added to it instead, so reruns
# do not spam. No report, or a report without a mismatch: nothing happens and gh is not called.
#
# Environment:  REPORT, RUN_URL (link to the run), GH_TOKEN and GITHUB_REPOSITORY (as for gh)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-cache-check
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

REPORT=${REPORT:?REPORT is required}
RUN_URL=${RUN_URL:-}
# The fixed title: the one thing the search for an open issue goes by. Keep the prefix when changing the rest.
TITLE="IONOS app cache check: rebuilt apps differ from the cache"

[ -f "$REPORT" ] || { log "no report: nothing to do"; exit 0; }
line=$(sed -n 's/^mismatch: //p' "$REPORT" | head -n1)
{ [ -n "$line" ] && [ "$line" != none ]; } || { log "no mismatch: no issue"; exit 0; }

body=$(mktemp); trap 'rm -f "$body"' EXIT
{
  cat "$REPORT"
  echo
  [ -z "$RUN_URL" ] || echo "Run: $RUN_URL"
  echo
  echo "The cache holds a build whose checksum a clean rebuild of the same app commit, recipe and toolchain does not reproduce: the build is not bit-reproducible, or the cache is damaged. Delete the cache entries in the Actions cache list to rebuild from clean, see .github/ionos/ionos-build.md (Cache)."
} > "$body"

number=$(gh issue list --state open --limit 200 --json number,title | jq -r --arg t "$TITLE" '[.[] | select(.title == $t)] | .[0].number // empty') \
  || die "cannot list the open issues"
if [ -n "$number" ]; then
  gh issue comment "$number" --body-file "$body" || die "cannot comment on issue #$number"
  log "commented on the open issue #$number"
else
  gh issue create --title "$TITLE" --body-file "$body" || die "cannot create the issue"
  log "opened the issue"
fi
