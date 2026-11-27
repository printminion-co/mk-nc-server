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

WORK=${WORK:?WORK is required}
PHP=${PHP:-php}
TMP_ROOT=${SMOKE_TMP:-${RUNNER_TEMP:-/tmp}/ionos-smoke}
LOGS=${SMOKE_LOGS:-$WORK/smoke-logs}
ALLOWLIST=${SMOKE_ALLOWLIST:-$HERE/ionos-smoke-log-allowlist.txt}
BREAK=${SMOKE_BREAK:-none}
ADMIN_USER=${SMOKE_ADMIN_USER:-admin}
ADMIN_PASS=${SMOKE_ADMIN_PASS:-Smoke-Test-Admin-Pw-1}
if [ -z "${FLAVORS_DIR:-}" ]; then FLAVORS_DIR="$(build_root)/IONOS"; fi
if [ -n "${NCW:-}" ]; then read -r -a NCW_CMD <<<"$NCW"; else NCW_CMD=(node "$(build_root)/IONOS/tools/src/cli.ts"); fi
read -r -a SERVER_EXTRA <<<"${SMOKE_SERVER_ARGS:-}"
NAME_RE='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
# what Nextcloud 33 needs (admin manual, system requirements); sqlite is the database of the smoke test
REQUIRED_EXTENSIONS=(ctype curl dom fileinfo filter gd hash iconv libxml mbstring openssl pdo_sqlite posix session simplexml xmlreader xmlwriter zip zlib)

SERVER_PID=""
stop_server() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }
}
trap stop_server EXIT

# ---- PHP extensions: say what is missing before anything is installed
have=$("$PHP" -m | tr '[:upper:]' '[:lower:]')
missing=()
for e in "${REQUIRED_EXTENSIONS[@]}"; do grep -qx "$e" <<<"$have" || missing+=("$e"); done
[ ${#missing[@]} -eq 0 ] || die "PHP lacks extensions Nextcloud needs: ${missing[*]}"
log "php: $("$PHP" -r 'echo PHP_VERSION;')"

shopt -s nullglob
zips=("$WORK"/out/*.zip)
[ ${#zips[@]} -gt 0 ] || die "no archive in $WORK/out: nothing to smoke test"

mkdir -p "$LOGS" "$TMP_ROOT"
failed_flavors=()
tested=0

free_port() {
  local p=${SMOKE_PORT:-18080}
  while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do p=$((p + 1)); done
  echo "$p"
}

# smoke_one <archive>: returns 0 when the archive passed, 1 when it did not
smoke_one() {
  local zip=$1 base flavor dir tree ok=true name required def rc port url
  base=$(basename "$zip")
  [[ $base =~ ^ncw-(.+)-v[0-9][0-9A-Za-z.]*\.zip$ ]] || { echo "::error::${LOG_PREFIX}: $base is not named ncw-<flavor>-v<version>.zip"; return 1; }
  flavor=${BASH_REMATCH[1]}
  [[ $flavor =~ $NAME_RE ]] || { echo "::error::${LOG_PREFIX}: '$flavor' in $base is not a flavor name"; return 1; }
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

  # the variables the flavor declares: a test value for the required ones, the declared default for the others
  while IFS=$'\t' read -r name required def; do
    [ -n "$name" ] || continue
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { bad "the flavor declares the variable '$name', which is no variable name"; continue; }
    if [ "$required" = true ]; then
      export "$name=smoke-test-value-$(tr '[:upper:]_' '[:lower:]-' <<<"$name")"
    elif [ -n "$def" ]; then
      export "$name=$def"
    fi
  done < <(resolved_env "$dir/resolved.yaml")

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

    # serve the tree: php -S, no router (index.php/remote.php paths)
    port=$(free_port); url="http://localhost:$port"
    ( cd "$tree" && PHP_CLI_SERVER_WORKERS=4 exec "$PHP" -d memory_limit=512M -S "127.0.0.1:$port" -t "$tree" "${SERVER_EXTRA[@]}" ) \
      > "$dir/php-server.log" 2>&1 &
    SERVER_PID=$!
    local up=false
    for _ in $(seq 120); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      if curl -s -o /dev/null --max-time 5 "$url/status.php"; then up=true; break; fi
      sleep 0.5
    done
    if [ "$up" != true ]; then
      bad "the web server did not come up on $url"; tail -n 20 "$dir/php-server.log" >&2 || true
    else
      log "$flavor: probes against $url"
      if ! SMOKE_ADMIN_USER=$ADMIN_USER SMOKE_ADMIN_PASS=$ADMIN_PASS bash "$HERE/ionos-smoke-probes.sh" "$url" "$dir/probes" > "$dir/probes.log" 2>&1; then
        cat "$dir/probes.log" >&2; bad "probes failed, see probes.log"
      else cat "$dir/probes.log"; fi
    fi

    log "$flavor: cron.php"
    rc=0; ( cd "$tree" && timeout 900 "$PHP" cron.php ) > "$dir/cron.log" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || { tail -n 20 "$dir/cron.log" >&2; bad "cron.php failed (exit $rc)"; }

    log "$flavor: occ files:scan --all"
    rc=0; ( cd "$tree" && timeout 900 "$PHP" occ files:scan --all ) > "$dir/scan.log" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || { tail -n 20 "$dir/scan.log" >&2; bad "occ files:scan --all failed (exit $rc)"; }

    log "$flavor: app states"
    rc=0; ( cd "$tree" && timeout 300 "$PHP" occ app:list --output=json_pretty ) > "$dir/app-list.json" 2> "$dir/app-list.err" || rc=$?
    if [ "$rc" -ne 0 ]; then cat "$dir/app-list.err" >&2; bad "occ app:list failed (exit $rc)"
    elif ! bash "$HERE/ionos-smoke-apps.sh" "$dir/app-list.json" "$dir/resolved.yaml" > "$dir/apps.log" 2>&1; then
      cat "$dir/apps.log" >&2; bad "the app states do not match the resolved flavor"
    else cat "$dir/apps.log"; fi
  fi
  stop_server

  # the log: after everything above has run
  if [ -f "$tree/data/nextcloud.log" ]; then cp "$tree/data/nextcloud.log" "$dir/nextcloud.log"; fi
  log "$flavor: nextcloud.log"
  if ! bash "$HERE/ionos-smoke-logs.sh" "$dir/nextcloud.log" "$ALLOWLIST" > "$dir/logs.log" 2>&1; then
    cat "$dir/logs.log" >&2; bad "the log check failed"
  else cat "$dir/logs.log"; fi

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
