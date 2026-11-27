# shellcheck shell=bash
# The parts of the smoke tests that the fresh-install run (ionos-smoke-run.sh) and the upgrade run
# (ionos-smoke-upgrade.sh) share, so that both apply exactly the same probes, app-state comparison and log check.
# Source it after ionos-lib.sh, do not run it.
#
# The caller sets HERE, PHP, ADMIN_USER, ADMIN_PASS, ALLOWLIST and SERVER_EXTRA (an array), defines `bad <message>`
# (reports a failure of the flavor being tested and remembers it), and calls `trap stop_server EXIT`.

NAME_RE='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'

SERVER_PID=""
stop_server() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }
}

# What Nextcloud 33 needs (admin manual, system requirements). The database driver depends on the database.
SMOKE_BASE_EXTENSIONS=(ctype curl dom fileinfo filter gd hash iconv libxml mbstring openssl posix session simplexml xmlreader xmlwriter zip zlib)
# smoke_check_php <database>: dies and names the missing extensions (database: sqlite or mariadb)
smoke_check_php() {
  local have missing=() e
  have=$("$PHP" -m | tr '[:upper:]' '[:lower:]')
  for e in "${SMOKE_BASE_EXTENSIONS[@]}" "$([ "$1" = mariadb ] && echo pdo_mysql || echo pdo_sqlite)"; do
    grep -qx "$e" <<<"$have" || missing+=("$e")
  done
  [ ${#missing[@]} -eq 0 ] || die "PHP lacks extensions Nextcloud needs: ${missing[*]}"
  log "php: $("$PHP" -r 'echo PHP_VERSION;')"
}

# smoke_flavor_of_archive <zip>: sets FLAVOR from the archive name ncw-<flavor>-v<version>.zip; 1 (with an error) otherwise
smoke_flavor_of_archive() {
  local base; base=$(basename "$1")
  [[ $base =~ ^ncw-(.+)-v[0-9][0-9A-Za-z.]*\.zip$ ]] || { echo "::error::${LOG_PREFIX}: $base is not named ncw-<flavor>-v<version>.zip"; return 1; }
  FLAVOR=${BASH_REMATCH[1]}
  [[ $FLAVOR =~ $NAME_RE ]] || { echo "::error::${LOG_PREFIX}: '$FLAVOR' in $base is not a flavor name"; return 1; }
}

# smoke_export_env <resolved.yaml>: the variables the flavor declares: a test value for the required ones, the
# declared default for the others
smoke_export_env() {
  local name required def
  while IFS=$'\t' read -r name required def; do
    [ -n "$name" ] || continue
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { bad "the flavor declares the variable '$name', which is no variable name"; continue; }
    if [ "$required" = true ]; then
      export "$name=smoke-test-value-$(tr '[:upper:]_' '[:lower:]-' <<<"$name")"
    elif [ -n "$def" ]; then
      export "$name=$def"
    fi
  done < <(resolved_env "$1")
}

smoke_free_port() {
  local p=${SMOKE_PORT:-18080}
  while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do p=$((p + 1)); done
  echo "$p"
}

# smoke_checks <tree> <log dir> <resolved.yaml> [<app list before the upgrade>]: serve the tree with `php -S` and run
# the probes, the brand check and the theme probes (ionos-smoke-brand.sh), cron.php, files:scan --all and the comparison of the app states with the RESOLVED flavor (after an
# upgrade: with the states before it, see ionos-smoke-apps.sh). Every failure goes through `bad`.
smoke_checks() {
  local tree=$1 dir=$2 resolved=$3 before=${4:-} port url up=false rc apps_args
  port=$(smoke_free_port); url="http://localhost:$port"
  ( cd "$tree" && PHP_CLI_SERVER_WORKERS=4 exec "$PHP" -d memory_limit=512M -S "127.0.0.1:$port" -t "$tree" "${SERVER_EXTRA[@]}" ) \
    > "$dir/php-server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 120); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    if curl -s -o /dev/null --max-time 5 "$url/status.php"; then up=true; break; fi
    sleep 0.5
  done
  if [ "$up" != true ]; then
    bad "the web server did not come up on $url"; tail -n 20 "$dir/php-server.log" >&2 || true
  else
    log "$FLAVOR: probes against $url"
    if ! SMOKE_ADMIN_USER=$ADMIN_USER SMOKE_ADMIN_PASS=$ADMIN_PASS bash "$HERE/ionos-smoke-probes.sh" "$url" "$dir/probes" > "$dir/probes.log" 2>&1; then
      cat "$dir/probes.log" >&2; bad "probes failed, see probes.log"
    else cat "$dir/probes.log"; fi
  fi

  if [ "$up" = true ]; then
    log "$FLAVOR: brand check and theme probes"
    if ! PHP="$PHP" SMOKE_ADMIN_USER=$ADMIN_USER SMOKE_ADMIN_PASS=$ADMIN_PASS bash "$HERE/ionos-smoke-brand.sh" "$url" "$tree" "$resolved" "$dir/brand" > "$dir/brand.log" 2>&1; then
      cat "$dir/brand.log" >&2; bad "the brand check or the theme probes failed, see brand.log"
    else cat "$dir/brand.log"; fi
  fi

  log "$FLAVOR: cron.php"
  rc=0; ( cd "$tree" && timeout 900 "$PHP" cron.php ) > "$dir/cron.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -n 20 "$dir/cron.log" >&2; bad "cron.php failed (exit $rc)"; }

  log "$FLAVOR: occ files:scan --all"
  rc=0; ( cd "$tree" && timeout 900 "$PHP" occ files:scan --all ) > "$dir/scan.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -n 20 "$dir/scan.log" >&2; bad "occ files:scan --all failed (exit $rc)"; }

  log "$FLAVOR: app states"
  apps_args=("$dir/app-list.json" "$resolved")
  [ -z "$before" ] || apps_args+=("$before")
  rc=0; ( cd "$tree" && timeout 300 "$PHP" occ app:list --output=json_pretty ) > "$dir/app-list.json" 2> "$dir/app-list.err" || rc=$?
  if [ "$rc" -ne 0 ]; then cat "$dir/app-list.err" >&2; bad "occ app:list failed (exit $rc)"
  elif ! bash "$HERE/ionos-smoke-apps.sh" "${apps_args[@]}" > "$dir/apps.log" 2>&1; then
    cat "$dir/apps.log" >&2; bad "the app states do not match the resolved flavor"
  else cat "$dir/apps.log"; fi
}

# smoke_log_check <nextcloud.log> <log dir> [<expected incompatible apps file>]: the log check, after everything else has run
smoke_log_check() {
  log "$FLAVOR: nextcloud.log"
  if ! bash "$HERE/ionos-smoke-logs.sh" "$1" "$ALLOWLIST" ${3:+"$3"} > "$2/logs.log" 2>&1; then
    cat "$2/logs.log" >&2; bad "the log check failed"
  else cat "$2/logs.log"; fi
}

# The modes of smoke_break (ionos-smoke-break.sh) and the smoke test each one is meant to make fail.
SMOKE_BREAK_FRESH_MODES="missing-app extra-app wrong-mode skip-enable brand"
SMOKE_BREAK_UPGRADE_MODES="removed-in-shipped no-buildnumber"
# smoke_break_for <job: fresh|upgrade> <mode>: the mode when it is meant for this job, none otherwise (a mode never
# touches the archives of a job it is not meant for, so that exactly the job that names it must fail)
smoke_break_for() {
  local m
  case "$1" in fresh) m=$SMOKE_BREAK_FRESH_MODES ;; upgrade) m=$SMOKE_BREAK_UPGRADE_MODES ;; *) echo none; return 1 ;; esac
  case " $m " in *" $2 "*) echo "$2" ;; *) echo none ;; esac
}
