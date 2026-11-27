#!/usr/bin/env bash
# The gate in front of `publish`: decides from the results of the jobs before it whether anything may be published.
# It exists because a job-level `if:` with a status function cannot say "skipped is fine for this job, but not for
# that one" in a way that can be tested; here the rule is plain code with its own tests.
#
# Rules:
#   - the plan job must have succeeded
#   - when the plan says nothing is built (BUILD=false: a scheduled run with no change) every later job is skipped and
#     the gate passes (publish then needs `build`, which was skipped, so it does not run either)
#   - otherwise build, the fresh-install smoke and the SQLite upgrade smoke must have SUCCEEDED
#   - the MariaDB upgrade smoke must have succeeded for a release build; for a dev build it is not run (result
#     `skipped`), and that is fine. A failure or a cancel blocks in every case, and so does a skipped MariaDB job in a
#     release build (that would mean the release was published without the test on the production database engine)
#   - any other result value (or none) blocks
# Environment: BUILD (plan output: true/false), KIND (dev/release), and the results PLAN_RESULT, BUILD_RESULT,
# SMOKE_RESULT, UPGRADE_SQLITE_RESULT, UPGRADE_MARIADB_RESULT (each one of success, failure, cancelled, skipped).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-gate
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

BUILD=${BUILD:-}
KIND=${KIND:-}
PLAN_RESULT=${PLAN_RESULT:-}
BUILD_RESULT=${BUILD_RESULT:-}
SMOKE_RESULT=${SMOKE_RESULT:-}
UPGRADE_SQLITE_RESULT=${UPGRADE_SQLITE_RESULT:-}
UPGRADE_MARIADB_RESULT=${UPGRADE_MARIADB_RESULT:-}

[ "$PLAN_RESULT" = success ] || die "the plan job is '${PLAN_RESULT:-unknown}', not success: nothing is published"
if [ "$BUILD" = false ]; then
  for r in "$BUILD_RESULT" "$SMOKE_RESULT" "$UPGRADE_SQLITE_RESULT" "$UPGRADE_MARIADB_RESULT"; do
    [ "$r" = skipped ] || die "the plan says nothing is built, but a later job is '${r:-unknown}', not skipped"
  done
  log "nothing is built: nothing to publish"
  exit 0
fi
[ "$BUILD" = true ] || die "the plan output build is '${BUILD:-unknown}', not true or false"
case "$KIND" in dev|release) ;; *) die "the build kind is '${KIND:-unknown}', not dev or release" ;; esac

must_succeed() { # must_succeed <name> <result>
  [ "$2" = success ] || die "$1 is '${2:-unknown}', not success: nothing is published"
}
must_succeed "the build job" "$BUILD_RESULT"
must_succeed "the fresh-install smoke test" "$SMOKE_RESULT"
must_succeed "the SQLite upgrade smoke test" "$UPGRADE_SQLITE_RESULT"
if [ "$KIND" = release ]; then
  must_succeed "the MariaDB upgrade smoke test (required for a release build)" "$UPGRADE_MARIADB_RESULT"
else
  case "$UPGRADE_MARIADB_RESULT" in
    success) ;;
    skipped) log "the MariaDB upgrade smoke test does not run for a dev build" ;;
    *) die "the MariaDB upgrade smoke test is '${UPGRADE_MARIADB_RESULT:-unknown}': nothing is published" ;;
  esac
fi
log "every required test succeeded: publishing may go ahead"
