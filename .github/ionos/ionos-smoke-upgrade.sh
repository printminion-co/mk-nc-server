#!/usr/bin/env bash
# Upgrade smoke test of every archive in $WORK/out (07-validation.md, "Upgrade from": the vanilla official archive of
# the base release). For each flavor it follows the deployment contract of 05-deployment.md, "Upgrading to a new
# artifact", step by step, and then applies the checks of the fresh-install smoke test (ionos-smoke-lib.sh):
#
#   0. unpack the vanilla official archive (downloaded and verified by ionos-smoke-vanilla.sh) into a fresh folder and
#      install it from the command line (`occ maintenance:install`), data directory OUTSIDE the code tree, on SQLite or
#      on MariaDB; remember `occ app:list` and the version
#   1. disable the apps listed in removed-apps.json of the flavor archive on the OLD version (`occ app:disable`, idempotent:
#      an app that the old version does not have is skipped)
#   2. swap in the flavor archive: the old code tree is replaced by the unpacked archive; the only thing carried over
#      is config/config.php (instanceid, passwordsalt, secret, installed, version: the state Nextcloud writes itself,
#      which the deployment persists). The data folder and the database are outside the tree and stay
#   3. `occ upgrade`; the version must change to the old one plus the build number of the archive (a new build
#      number always looks like a core version change)
#   4. `bash ncw-configure.sh` (app configuration import and enable_after_install)
#   5. the same checks as after a fresh install: probes, cron.php, files:scan, the app states against the RESOLVED
#      flavor (with the states before the upgrade, see ionos-smoke-apps.sh) and the log check with the same allow-list
#
# The archives are untrusted data: each is unpacked into a new empty folder, paths are passed as arguments, and the only
# code run from a tree is `php occ`, `php cron.php` and the web server serving it. Logs stay under
# $SMOKE_LOGS/<flavor>/ whatever the result; timings.txt there says how long each phase took.
#
# Environment:
#   WORK, FLAVORS_DIR, NCW, SMOKE_TMP, SMOKE_LOGS, SMOKE_ALLOWLIST, SMOKE_PORT, SMOKE_KEEP, PHP, SMOKE_ADMIN_USER,
#   SMOKE_ADMIN_PASS, SMOKE_SERVER_ARGS   as for ionos-smoke-run.sh (SMOKE_LOGS defaults to $WORK/upgrade-logs-<db>)
#   VANILLA_ZIP     the verified vanilla archive nextcloud-<base>.zip (required)
#   SMOKE_DB        sqlite (default) or mariadb
#   MariaDB:        SMOKE_DB_HOST (default 127.0.0.1), SMOKE_DB_PORT (default 3306), SMOKE_DB_USER, SMOKE_DB_PASS and
#                   SMOKE_DB_ROOT_PASS (required). Per flavor a fresh database ncw_<flavor> is created with the root account
#                   and the user gets all rights on it; READ-COMMITTED and binlog ROW are set globally first (what Nextcloud
#                   asks of its database; the service container cannot take server arguments)
#   SMOKE_BREAK     a break meant for this test (removed-in-shipped, no-buildnumber): the run must fail
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-upgrade-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"
# shellcheck source=ionos-smoke-lib.sh
. "$HERE/ionos-smoke-lib.sh"

WORK=${WORK:?WORK is required}
VANILLA_ZIP=${VANILLA_ZIP:?VANILLA_ZIP is required}
PHP=${PHP:-php}
DB=${SMOKE_DB:-sqlite}
case "$DB" in sqlite|mariadb) ;; *) die "SMOKE_DB must be sqlite or mariadb, not '$DB'" ;; esac
TMP_ROOT=${SMOKE_TMP:-${RUNNER_TEMP:-/tmp}/ionos-upgrade-smoke}
LOGS=${SMOKE_LOGS:-$WORK/upgrade-logs-$DB}
ALLOWLIST=${SMOKE_ALLOWLIST:-$HERE/ionos-smoke-log-allowlist.txt}
BREAK=$(smoke_break_for upgrade "${SMOKE_BREAK:-none}")
ADMIN_USER=${SMOKE_ADMIN_USER:-admin}
ADMIN_PASS=${SMOKE_ADMIN_PASS:-Smoke-Test-Admin-Pw-1}
if [ -z "${FLAVORS_DIR:-}" ]; then FLAVORS_DIR="$(build_root)/IONOS"; fi
if [ -n "${NCW:-}" ]; then read -r -a NCW_CMD <<<"$NCW"; else NCW_CMD=(node "$(build_root)/IONOS/tools/src/cli.ts"); fi
read -r -a SERVER_EXTRA <<<"${SMOKE_SERVER_ARGS:-}"
if [ "$DB" = mariadb ]; then
  DB_HOST=${SMOKE_DB_HOST:-127.0.0.1}; DB_PORT=${SMOKE_DB_PORT:-3306}
  DB_USER=${SMOKE_DB_USER:?SMOKE_DB_USER is required for mariadb}
  DB_PASS=${SMOKE_DB_PASS:?SMOKE_DB_PASS is required for mariadb}
  DB_ROOT_PASS=${SMOKE_DB_ROOT_PASS:?SMOKE_DB_ROOT_PASS is required for mariadb}
  [[ $DB_USER =~ ^[A-Za-z0-9_]+$ ]] || die "SMOKE_DB_USER must be letters, digits and underscores"
  [[ $DB_PORT =~ ^[0-9]+$ ]] || die "SMOKE_DB_PORT is not a port"
fi
trap stop_server EXIT

[ -f "$VANILLA_ZIP" ] || die "no vanilla archive at $VANILLA_ZIP"
smoke_check_php "$DB"

shopt -s nullglob
zips=("$WORK"/out/*.zip)
[ ${#zips[@]} -gt 0 ] || die "no archive in $WORK/out: nothing to smoke test"
mkdir -p "$LOGS" "$TMP_ROOT"
failed_flavors=()
tested=0

# sql <statement>: runs a statement as the MariaDB root user (the credentials go through the environment, not the command line)
sql() {
  # shellcheck disable=SC2016 # the PHP code is single quoted on purpose
  SMOKE_SQL=$1 SMOKE_DB_HOST=$DB_HOST SMOKE_DB_PORT=$DB_PORT SMOKE_DB_ROOT_PASS=$DB_ROOT_PASS "$PHP" -r '
    $pdo = new PDO("mysql:host=" . getenv("SMOKE_DB_HOST") . ";port=" . getenv("SMOKE_DB_PORT"), "root", getenv("SMOKE_DB_ROOT_PASS"),
      [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec(getenv("SMOKE_SQL"));'
}

# phase <log file> <name> <command...>: runs the command in the current folder with its output in <log file>, records
# the seconds it took in timings.txt of the flavor, returns the command's status
phase() {
  local out=$1 name=$2 start=$SECONDS rc=0
  shift 2
  "$@" > "$out" 2>&1 || rc=$?
  echo "$name $((SECONDS - start)) s (exit $rc)" >> "$TIMINGS"
  log "$FLAVOR: $name took $((SECONDS - start)) s"
  return "$rc"
}

# upgrade_one <archive>: 0 when the archive passed, 1 when it did not
upgrade_one() {
  local zip=$1 base flavor dir work live new retired rc dbname build before_version after_version removed id
  base=$(basename "$zip")
  smoke_flavor_of_archive "$zip" || return 1
  flavor=$FLAVOR
  dir="$LOGS/$flavor"; work="$TMP_ROOT/$flavor"
  live="$work/live"; new="$work/new"; retired="$work/retired"
  mkdir -p "$dir"
  TIMINGS="$dir/timings.txt"; : > "$TIMINGS"
  SMOKE_OK=true
  bad() { echo "::error::${LOG_PREFIX}: $flavor: $*"; SMOKE_OK=false; }
  echo "::group::upgrade smoke test ($DB): $flavor ($base)"
  finish() { # finish <status>: the folder is deleted, the verdict logged
    stop_server
    [ "${SMOKE_KEEP:-false}" = true ] || rm -rf "$work"
    echo "::endgroup::"
    if [ "$SMOKE_OK" = true ]; then log "$flavor: PASSED"; return 0; fi
    log "$flavor: FAILED"; return 1
  }

  if ! "${NCW_CMD[@]}" resolve --flavors "$FLAVORS_DIR" --flavor "$flavor" > "$dir/resolved.yaml" 2> "$dir/resolve.err"; then
    cat "$dir/resolve.err" >&2; bad "could not resolve the flavor"; finish; return
  fi
  [ ! -e "$work" ] || { bad "$work exists already (the trees are unpacked into fresh folders)"; echo "::endgroup::"; return 1; }
  mkdir -p "$work/vanilla" "$new" "$work/data"

  # the flavor archive, into its own fresh folder; it is not touched again until the swap
  if ! unzip -q "$zip" -d "$new" > "$dir/unzip-flavor.log" 2>&1; then
    cat "$dir/unzip-flavor.log" >&2; bad "could not unpack $base"; finish; return
  fi
  [ "$(jq -r '.flavor // ""' "$new/version.json" 2>/dev/null || true)" = "$flavor" ] \
    || { bad "version.json names another flavor than '$flavor' (the archive name)"; finish; return; }
  build=$(jq -r '.build_number // ""' "$new/version.json" 2>/dev/null || true)
  [[ $build =~ ^[1-9][0-9]*$ ]] || { bad "version.json has no build number: the upgrade could not be told from no upgrade"; finish; return; }
  [ -f "$new/ncw-configure.sh" ] || { bad "the archive has no ncw-configure.sh"; finish; return; }
  [ -f "$new/removed-apps.json" ] || { bad "the archive has no removed-apps.json (the deployment needs the list, even when it is empty)"; finish; return; }
  removed=$(jq -r 'if type == "array" and all(.[]; type == "string") then .[] else error("not a list of app ids") end' "$new/removed-apps.json" 2>/dev/null) \
    || { bad "removed-apps.json is not a JSON list of app ids"; finish; return; }
  [ ! -e "$new/config/config.php" ] || { bad "the archive has a config/config.php of its own: the deployment persists that file, an archive must not ship one"; finish; return; }

  smoke_export_env "$dir/resolved.yaml"

  # 0. the vanilla base release, installed
  if ! phase "$dir/unzip-vanilla.log" "unzip vanilla" unzip -q "$VANILLA_ZIP" -d "$work/vanilla"; then
    cat "$dir/unzip-vanilla.log" >&2; bad "could not unpack the vanilla archive"; finish; return
  fi
  [ -f "$work/vanilla/nextcloud/occ" ] || { bad "the vanilla archive has no nextcloud/occ"; finish; return; }
  mv "$work/vanilla/nextcloud" "$live"
  local install_args=(maintenance:install --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS" --data-dir "$work/data" --no-interaction)
  if [ "$DB" = mariadb ]; then
    dbname="ncw_${flavor//-/_}"
    if ! { sql "SET GLOBAL transaction_isolation = 'READ-COMMITTED'" && sql "SET GLOBAL binlog_format = 'ROW'" \
        && sql "DROP DATABASE IF EXISTS \`$dbname\`" && sql "CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci" \
        && sql "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO '$DB_USER'@'%'"; } > "$dir/database.log" 2>&1; then
      cat "$dir/database.log" >&2; bad "could not prepare the MariaDB database $dbname"; finish; return
    fi
    install_args+=(--database mysql --database-host "$DB_HOST:$DB_PORT" --database-name "$dbname" --database-user "$DB_USER" --database-pass "$DB_PASS")
  else
    install_args+=(--database sqlite)
  fi
  log "$flavor: installing the vanilla release on $DB"
  rc=0
  ( cd "$live" && phase "$dir/install.log" "install vanilla" timeout 1800 "$PHP" occ "${install_args[@]}" ) || rc=$?
  tail -n 12 "$dir/install.log"
  [ "$rc" -eq 0 ] || { bad "occ maintenance:install of the vanilla release failed (exit $rc), see install.log"; finish; return; }
  ( cd "$live" && timeout 300 "$PHP" occ app:list --output=json_pretty ) > "$dir/app-list-before.json" 2> "$dir/app-list-before.err" \
    || { cat "$dir/app-list-before.err" >&2; bad "occ app:list on the vanilla release failed"; finish; return; }
  before_version=$( cd "$live" && timeout 300 "$PHP" occ status --output=json 2>/dev/null | jq -r '.version // ""' ) || before_version=""
  [ -n "$before_version" ] || { bad "could not read the version of the vanilla release (occ status)"; finish; return; }
  log "$flavor: vanilla release $before_version installed; $(jq -r '.enabled | length' "$dir/app-list-before.json") apps enabled"

  # 1. the apps the flavor removes are disabled on the OLD version (idempotent: an app the old version has not is skipped)
  : > "$dir/disable.log"; : > "$dir/disable-refused.txt"
  for id in $removed; do
    [[ $id =~ ^[a-z0-9_]+$ ]] || { bad "removed-apps.json lists '$id', which is no app id"; continue; }
    if jq -e --arg id "$id" '.enabled | has($id)' "$dir/app-list-before.json" >/dev/null; then
      rc=0; ( cd "$live" && timeout 300 "$PHP" occ app:disable "$id" ) > "$dir/disable-one.log" 2>&1 || rc=$?
      cat "$dir/disable-one.log" >> "$dir/disable.log"
      if [ "$rc" -eq 0 ]; then :
      elif grep -qx "$id can't be disabled\." "$dir/disable-one.log"; then
        # An always-enabled core app of the old version (workflowengine on 33) cannot be disabled by occ. The deployment
        # step does not apply to it: `occ upgrade` takes an app that is in none of the three shipped lists out
        # (05-deployment.md, step 1 is hygiene on line 33), and logs "Disabled incompatible app: <id>" for it, which the log
        # check accepts for exactly these apps. The app states after the upgrade show whether it went.
        echo "$id: always enabled on the old version, occ refuses to disable it; left to occ upgrade" >> "$dir/disable.log"
        echo "$id" >> "$dir/disable-refused.txt"
        warn "$flavor: $id is always enabled on the old version and cannot be disabled; occ upgrade must take it out"
      else
        tail -n 5 "$dir/disable-one.log" >&2; bad "occ app:disable $id failed on the old version (exit $rc), see disable.log"
      fi
    else
      echo "$id: not enabled on the old version, skipped" >> "$dir/disable.log"
    fi
  done
  cat "$dir/disable.log"
  rm -f "$dir/disable-one.log"
  [ "$SMOKE_OK" = true ] || { finish; return; }

  # 2. swap in the flavor archive: the code tree is replaced, only config/config.php is carried over
  [ -f "$live/config/config.php" ] || { bad "the installed vanilla release has no config/config.php"; finish; return; }
  mv "$live" "$retired"
  mv "$new" "$live"
  cp "$retired/config/config.php" "$live/config/config.php"
  rm -rf "$retired"
  log "$flavor: swapped in $base (config/config.php kept, data folder and database untouched)"

  # 3. occ upgrade
  rc=0
  ( cd "$live" && phase "$dir/upgrade.log" "occ upgrade" timeout 1800 "$PHP" occ upgrade ) || rc=$?
  tail -n 25 "$dir/upgrade.log"
  if [ "$rc" -ne 0 ]; then
    bad "occ upgrade failed (exit $rc), see upgrade.log"
  else
    after_version=$( cd "$live" && timeout 300 "$PHP" occ status --output=json 2>/dev/null | jq -r '.version // ""' ) || after_version=""
    if [ "$after_version" != "$before_version.$build" ]; then
      bad "after the upgrade the version is '${after_version:-unknown}', expected '$before_version.$build' (the old version plus the build number $build of the archive): the upgrade did not take"
    else
      log "$flavor: upgraded $before_version -> $after_version"
      # 4. the deployment's next step after every upgrade
      log "$flavor: bash ncw-configure.sh"
      rc=0
      ( cd "$live" && phase "$dir/configure.log" "ncw-configure.sh" env PHP="$PHP" bash ncw-configure.sh ) || rc=$?
      if [ "$rc" -ne 0 ]; then cat "$dir/configure.log" >&2; bad "ncw-configure.sh failed, see configure.log"; else cat "$dir/configure.log"; fi
      # 5. the checks that a fresh install gets too
      smoke_checks "$live" "$dir" "$dir/resolved.yaml" "$dir/app-list-before.json"
    fi
  fi
  stop_server
  if [ -f "$work/data/nextcloud.log" ]; then cp "$work/data/nextcloud.log" "$dir/nextcloud.log"; fi
  smoke_log_check "$dir/nextcloud.log" "$dir" "$dir/disable-refused.txt"
  finish
}

for z in "${zips[@]}"; do
  tested=$((tested + 1))
  upgrade_one "$z" || failed_flavors+=("$(basename "$z")")
done

if [ "$BREAK" != none ] && [ -n "$BREAK" ]; then
  if [ ${#failed_flavors[@]} -eq 0 ]; then
    die "the upgrade smoke test did not catch the break '$BREAK': the gate proves nothing"
  fi
  log "the break '$BREAK' was caught by the upgrade smoke test, as it must be: failing the run on purpose"
fi
if [ ${#failed_flavors[@]} -gt 0 ]; then
  die "upgrade smoke test ($DB) failed for: ${failed_flavors[*]}"
fi
log "upgrade smoke test ($DB) passed for $tested archive(s)"
