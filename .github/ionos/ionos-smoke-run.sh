#!/usr/bin/env bash
# Fresh-install smoke test of every archive in $WORK/out (07-validation.md): unpack into a fresh folder, install from
# the command line on SQLite, import the app configuration, serve the tree with `php -S`, run the probes, `cron.php`
# and `files:scan`, compare the app states with the RESOLVED flavor (`ncw resolve`, no per-flavor code) and check
# nextcloud.log against the allow-list. Every flavor is tested and every failure reported; the run fails when one
# flavor failed. The logs are kept under $SMOKE_LOGS/<flavor>/ whatever the result.
#
# The archive is treated as untrusted data: it is unpacked into a new empty folder, paths are passed as arguments,
# and the only code that runs from the unpacked tree is `php occ`, `php cron.php` and the web server serving it.
#
# How apps get enabled: `occ maintenance:install` installs and enables every app that core/shipped.json lists in
# alwaysEnabled or defaultEnabled, wherever it lives (also an added app that is not in shippedApps). Apps the
# installer cannot enable are `available` and listed in the flavor's enable_after_install; the archive's own
# ncw-configure.sh (run right after the install, as the deployment does) enables them. The smoke test runs no
# `occ app:enable` itself: an app that is not enabled afterwards is exactly what the comparison must show.
#
# Environment:
#   WORK            the run's work folder: out/ holds the archives (ncw-<flavor>-v<...>.zip)
#   FLAVORS_DIR     the flavors folder (the pinned IONOS submodule); default <checkout>/IONOS
#   NCW             the flavors tool command, default "node <checkout>/IONOS/tools/src/cli.ts"
#   SMOKE_TMP       where trees are unpacked (default $RUNNER_TEMP/ionos-smoke or /tmp/ionos-smoke); must not hold a tree yet
#   SMOKE_LOGS      where the logs go (default $WORK/smoke-logs)
#   SMOKE_ALLOWLIST the log allow-list (default ionos-smoke-log-allowlist.txt next to this script)
#   SMOKE_BREAK     the break the workflow applied to the archives (none or empty: no break). With a break the run
#                   must fail: when it does not, that is reported as a failure of the gate
#   SMOKE_PORT      first port to try for the web server (default 18080)
#   SMOKE_KEEP      "true" keeps the unpacked trees (local debugging)
#   PHP             the php binary (default php)
#   SMOKE_ADMIN_USER, SMOKE_ADMIN_PASS   the test admin
#   SMOKE_SERVER_ARGS  extra arguments for `php -S` (for the tests: a router)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"
# shellcheck source=ionos-smoke-lib.sh
. "$HERE/ionos-smoke-lib.sh"

WORK=${WORK:?WORK is required}
PHP=${PHP:-php}
TMP_ROOT=${SMOKE_TMP:-${RUNNER_TEMP:-/tmp}/ionos-smoke}
LOGS=${SMOKE_LOGS:-$WORK/smoke-logs}
ALLOWLIST=${SMOKE_ALLOWLIST:-$HERE/ionos-smoke-log-allowlist.txt}
# a break that is meant for the upgrade smoke test (ionos-smoke-upgrade.sh) leaves these archives alone
BREAK=$(smoke_break_for fresh "${SMOKE_BREAK:-none}")
ADMIN_USER=${SMOKE_ADMIN_USER:-admin}
ADMIN_PASS=${SMOKE_ADMIN_PASS:-Smoke-Test-Admin-Pw-1}
if [ -z "${FLAVORS_DIR:-}" ]; then FLAVORS_DIR="$(build_root)/IONOS"; fi
if [ -n "${NCW:-}" ]; then read -r -a NCW_CMD <<<"$NCW"; else NCW_CMD=(node "$(build_root)/IONOS/tools/src/cli.ts"); fi
read -r -a SERVER_EXTRA <<<"${SMOKE_SERVER_ARGS:-}"
trap stop_server EXIT

# ---- PHP extensions: say what is missing before anything is installed
smoke_check_php sqlite

shopt -s nullglob
zips=("$WORK"/out/*.zip)
[ ${#zips[@]} -gt 0 ] || die "no archive in $WORK/out: nothing to smoke test"

mkdir -p "$LOGS" "$TMP_ROOT"
failed_flavors=()
tested=0

# smoke_one <archive>: returns 0 when the archive passed, 1 when it did not
smoke_one() {
  local zip=$1 base flavor dir tree ok=true rc
  base=$(basename "$zip")
  smoke_flavor_of_archive "$zip" || return 1
  flavor=$FLAVOR
  dir="$LOGS/$flavor"; tree="$TMP_ROOT/$flavor"
  mkdir -p "$dir"
  echo "::group::smoke test: $flavor ($base)"
  bad() { echo "::error::${LOG_PREFIX}: $flavor: $*"; ok=false; }

  # the expected states come from the resolved flavor
  if ! "${NCW_CMD[@]}" resolve --flavors "$FLAVORS_DIR" --flavor "$flavor" > "$dir/resolved.yaml" 2> "$dir/resolve.err"; then
    cat "$dir/resolve.err" >&2
    bad "could not resolve the flavor"; echo "::endgroup::"; return 1
  fi

  # a fresh, empty folder; the archive is untrusted data
  [ ! -e "$tree" ] || { bad "$tree exists already (the trees are unpacked into fresh folders)"; echo "::endgroup::"; return 1; }
  mkdir "$tree"
  if ! unzip -q "$zip" -d "$tree" > "$dir/unzip.log" 2>&1; then
    cat "$dir/unzip.log" >&2; bad "could not unpack $base"; rm -rf "$tree"; echo "::endgroup::"; return 1
  fi
  local tree_flavor
  tree_flavor=$(jq -r '.flavor // ""' "$tree/version.json" 2>/dev/null || true)
  if [ "$tree_flavor" != "$flavor" ]; then
    bad "version.json names the flavor '$tree_flavor', the archive name says '$flavor'"; rm -rf "$tree"; echo "::endgroup::"; return 1
  fi

  [ -f "$tree/ncw-configure.sh" ] || { bad "the archive has no ncw-configure.sh"; rm -rf "$tree"; echo "::endgroup::"; return 1; }

  # the variables the flavor declares
  smoke_export_env "$dir/resolved.yaml"

  # install from the command line on SQLite
  log "$flavor: occ maintenance:install"
  rc=0
  ( cd "$tree" && timeout 900 "$PHP" occ maintenance:install --database sqlite --admin-user "$ADMIN_USER" \
      --admin-pass "$ADMIN_PASS" --no-interaction ) > "$dir/install.log" 2>&1 || rc=$?
  tail -n 25 "$dir/install.log"
  if [ "$rc" -ne 0 ]; then
    bad "occ maintenance:install failed (exit $rc), see install.log"
  else
    # the deployment's next step: the archive's own ncw-configure.sh (app config, special settings, enable_after_install)
    log "$flavor: bash ncw-configure.sh"
    if ! ( cd "$tree" && PHP="$PHP" bash ncw-configure.sh ) > "$dir/configure.log" 2>&1; then
      cat "$dir/configure.log" >&2; bad "ncw-configure.sh failed, see configure.log"
    else cat "$dir/configure.log"; fi

    # serve the tree, probes, cron.php, files:scan, app states: the part the upgrade smoke test shares
    smoke_checks "$tree" "$dir" "$dir/resolved.yaml"
  fi
  stop_server

  # the log: after everything above has run
  if [ -f "$tree/data/nextcloud.log" ]; then cp "$tree/data/nextcloud.log" "$dir/nextcloud.log"; fi
  smoke_log_check "$dir/nextcloud.log" "$dir"

  [ "${SMOKE_KEEP:-false}" = true ] || rm -rf "$tree"
  echo "::endgroup::"
  if [ "$ok" = true ]; then log "$flavor: PASSED"; return 0; fi
  log "$flavor: FAILED"
  return 1
}

for z in "${zips[@]}"; do
  tested=$((tested + 1))
  smoke_one "$z" || failed_flavors+=("$(basename "$z")")
done

if [ "$BREAK" != none ] && [ -n "$BREAK" ]; then
  if [ ${#failed_flavors[@]} -eq 0 ]; then
    die "the smoke test did not catch the break '$BREAK': the gate proves nothing"
  fi
  log "the break '$BREAK' was caught by the smoke test, as it must be: failing the run on purpose"
fi
if [ ${#failed_flavors[@]} -gt 0 ]; then
  die "smoke test failed for: ${failed_flavors[*]}"
fi
log "smoke test passed for $tested archive(s)"
