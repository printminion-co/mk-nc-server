#!/usr/bin/env bash
# Tests for the ionos-smoke-*.sh scripts (fresh-install smoke test and the tamper script of the gate proof).
# The decision logic is tested through the scripts with fixtures: an app list against a resolved flavor, log
# files against an allow-list, a tiny zip against the tamper modes. The probes run against a mock web server
# (php -S with a router that imitates the few Nextcloud endpoints), and the whole run script runs with a stub
# `php` that serves the mock and answers occ from fixtures. Nothing here needs a Nextcloud tree or the network.
# Usage: ionos-smoke.test.sh [scenario ...]   (default: all scenarios)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$ROOT"; [ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2>/dev/null' EXIT; else echo "keeping $ROOT" >&2; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
# run <name> <command...>: runs a command, output in $ROOT/<name>.log, status in $ROOT/<name>.status
run() {
  local n="$1"; shift
  "$@" > "$ROOT/$n.log" 2>&1
  echo $? > "$ROOT/$n.status"
}
status() { cat "$ROOT/$1.status"; }
said() { grep -q -- "$2" "$ROOT/$1.log"; }          # said <name> <fixed text>
said_re() { grep -Eq -- "$2" "$ROOT/$1.log"; }      # said_re <name> <regexp>

# ---------------------------------------------------------------- fixtures
FIX="$ROOT/fix"; mkdir -p "$FIX"
cat > "$FIX/resolved.yaml" <<'EOF'
flavor: demo
order:
  - bases/common
  - flavors/demo
apps:
  contacts: default
  dav: always
  files: always
  firstrunwizard: removed
  talk: available
app_folders:
  - apps-upstream
themes: []
config_files: {}
env:
  - name: PHONE_REGION
    required: false
    default: DE
  - name: SMTP_PASSWORD
    required: true
EOF
cat > "$FIX/applist-ok.json" <<'EOF'
{"enabled":{"contacts":"8.10.0","dav":"1.0.0","files":"2.4.0"},"disabled":{"talk":"22.0.0"}}
EOF
# the app list with one app changed: jq filter on the good list
applist() { jq -c "$1" "$FIX/applist-ok.json" > "$FIX/applist-$2.json"; }
applist 'del(.enabled.contacts)' missing
applist '.enabled.extra_app = "1.0.0"' extra-enabled
applist '.disabled.extra_app = "1.0.0"' extra-disabled
applist '.disabled.contacts = .enabled.contacts | del(.enabled.contacts)' default-disabled
applist '.enabled.talk = .disabled.talk | del(.disabled.talk)' available-enabled
applist 'del(.disabled.talk)' available-missing
applist '.enabled.firstrunwizard = "3.0.0"' removed-enabled
applist '.disabled.firstrunwizard = "3.0.0"' removed-disabled
applist '.disabled.files = .enabled.files | del(.enabled.files)' always-disabled
echo 'not json' > "$FIX/applist-bad.json"

# a log line of Nextcloud's JSON log
logline() { # logline <level> <message> [app]
  jq -cn --argjson l "$1" --arg m "$2" --arg a "${3:-core}" '{reqId:"r1",level:$l,time:"2026-11-27T10:00:00+00:00",remoteAddr:"",user:"--",app:$a,method:"",url:"--",message:$m,userAgent:"--",version:"33.0.9.1.5"}'
}
cat > "$FIX/allow.txt" <<'EOF'
# why: the first run of the background job reaches for the network
^Could not connect to the lookup server
# why: the demo app warns about a missing optional setting
Optional setting .* is not set$
EOF

# ---------------------------------------------------------------- scenario: apps
sc_apps() {
  local f
  run a-ok bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved.yaml"
  check "the app list that matches the resolved flavor passes" test "$(status a-ok)" = 0

  run a1 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-missing.json" "$FIX/resolved.yaml"
  check "a missing app fails" test "$(status a1)" != 0
  check "a missing app is named" said_re a1 "'contacts'.*(not in the app list|missing)"

  for f in extra-enabled extra-disabled; do
    run a2 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-$f.json" "$FIX/resolved.yaml"
    check "an extra app fails ($f)" test "$(status a2)" != 0
    check "an extra app is named ($f)" said_re a2 "'extra_app'.*not in the resolved flavor"
  done

  run a3 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-default-disabled.json" "$FIX/resolved.yaml"
  check "a default app that is disabled fails (wrong mode)" test "$(status a3)" != 0
  check "the wrong mode names the app, the mode and the state" said_re a3 "'contacts'.*default.*disabled"

  run a4 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-always-disabled.json" "$FIX/resolved.yaml"
  check "an always app that is disabled fails" test "$(status a4)" != 0
  check "the always app is named" said_re a4 "'files'.*always.*disabled"

  run a5 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-available-enabled.json" "$FIX/resolved.yaml"
  check "an available app that is enabled fails (wrong mode)" test "$(status a5)" != 0
  check "the available app is named" said_re a5 "'talk'.*available.*enabled"
  run a5 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-available-missing.json" "$FIX/resolved.yaml"
  check "an available app that is absent fails" test "$(status a5)" != 0
  check "the absent available app is named" said_re a5 "'talk'"

  for f in removed-enabled removed-disabled; do
    run a6 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-$f.json" "$FIX/resolved.yaml"
    check "a removed app that is present fails ($f)" test "$(status a6)" != 0
    check "the removed app is named ($f)" said_re a6 "'firstrunwizard'.*removed.*present"
  done

  run a7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-bad.json" "$FIX/resolved.yaml"
  check "an app list that is not JSON fails" test "$(status a7)" != 0
  run a7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/nonexistent.yaml"
  check "a missing resolved flavor fails" test "$(status a7)" != 0
  printf 'flavor: demo\napps: {}\n' > "$FIX/empty-resolved.yaml"
  run a7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/empty-resolved.yaml"
  check "a resolved flavor without apps fails (nothing to compare is no pass)" test "$(status a7)" != 0
  run a7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json"
  check "missing arguments fail" test "$(status a7)" != 0

  jq -c '.enabled.zzz = "1" | del(.enabled.contacts)' "$FIX/applist-ok.json" > "$FIX/applist-two.json"
  run a8 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-two.json" "$FIX/resolved.yaml"
  check "every problem is reported, not only the first" bash -c "grep -q \"'contacts'\" '$ROOT/a8.log' && grep -q \"'zzz'\" '$ROOT/a8.log'"
}

# ---------------------------------------------------------------- scenario: logs
sc_logs() {
  local L="$ROOT/logs"; mkdir -p "$L"
  : > "$L/empty.log"
  { logline 2 "Just a warning"; logline 1 "info"; logline 0 "debug"; } > "$L/low.log"
  { logline 2 "warn"; logline 3 "Could not connect to the lookup server at x"; } > "$L/allowed.log"
  { logline 3 "Could not connect to the lookup server at x"; logline 3 "Something broke badly"; } > "$L/other.log"
  logline 4 "Fatal thing" > "$L/fatal.log"
  { logline 1 "Disabled incompatible app: contacts"; } > "$L/incompat-info.log"
  { logline 3 "Could not connect to the lookup server"; logline 2 "Disabled incompatible app: calendar"; } > "$L/incompat-warn.log"
  { logline 2 "ok"; echo 'PHP Warning: something not JSON'; } > "$L/raw.log"
  logline '"3"' "level as a string" > "$L/strlevel.log"
  logline 3 "Optional setting foo is not set" > "$L/allowed2.log"

  run l1 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log" "$FIX/allow.txt"
  check "an empty log passes" test "$(status l1)" = 0
  run l1 bash "$HERE/ionos-smoke-logs.sh" "$L/low.log" "$FIX/allow.txt"
  check "entries below error pass" test "$(status l1)" = 0
  run l1 bash "$HERE/ionos-smoke-logs.sh" "$L/allowed.log" "$FIX/allow.txt"
  check "an error entry on the allow-list passes" test "$(status l1)" = 0
  run l1 bash "$HERE/ionos-smoke-logs.sh" "$L/allowed2.log" "$FIX/allow.txt"
  check "a second allow-list entry (comments and regexp) passes" test "$(status l1)" = 0

  run l2 bash "$HERE/ionos-smoke-logs.sh" "$L/other.log" "$FIX/allow.txt"
  check "an error entry that is not on the allow-list fails" test "$(status l2)" != 0
  check "the failing entry is shown" said l2 "Something broke badly"
  check "the allowed entry is not reported as a failure" bash -c "! grep -q 'lookup server' '$ROOT/l2.log' || ! grep -q '::error::.*lookup server' '$ROOT/l2.log'"
  run l2 bash "$HERE/ionos-smoke-logs.sh" "$L/fatal.log" "$FIX/allow.txt"
  check "a fatal entry (level 4) fails" test "$(status l2)" != 0
  run l2 bash "$HERE/ionos-smoke-logs.sh" "$L/strlevel.log" "$FIX/allow.txt"
  check "a level written as a string is read as a number" test "$(status l2)" != 0

  printf '%s\n' '.*' > "$L/allow-all.txt"
  run l3 bash "$HERE/ionos-smoke-logs.sh" "$L/incompat-info.log" "$FIX/allow.txt"
  check "a Disabled incompatible app line fails although it is only at info level" test "$(status l3)" != 0
  check "the incompatible app is named" said l3 "contacts"
  run l3 bash "$HERE/ionos-smoke-logs.sh" "$L/incompat-warn.log" "$L/allow-all.txt"
  check "a Disabled incompatible app line fails even with an allow-all entry" test "$(status l3)" != 0
  check "the line is reported as an incompatible app" said l3 "Disabled incompatible app"

  run l4 bash "$HERE/ionos-smoke-logs.sh" "$L/raw.log" "$FIX/allow.txt"
  check "a line that is not JSON counts as an error entry" test "$(status l4)" != 0
  check "the raw line is shown" said l4 "PHP Warning"

  run l5 bash "$HERE/ionos-smoke-logs.sh" "$L/missing.log" "$FIX/allow.txt"
  check "a log file that does not exist counts as no entries" test "$(status l5)" = 0
  run l5 bash "$HERE/ionos-smoke-logs.sh" "$L/other.log" "$L/missing-allow.txt"
  check "a missing allow-list file fails" test "$(status l5)" != 0
  printf '# only a comment\n\n' > "$L/allow-empty.txt"
  run l5 bash "$HERE/ionos-smoke-logs.sh" "$L/other.log" "$L/allow-empty.txt"
  check "an allow-list without entries allows nothing" test "$(status l5)" != 0
  run l5 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log" "$L/allow-empty.txt"
  check "an allow-list without entries is fine for a clean log" test "$(status l5)" = 0
  printf '   \n^x\n' > "$L/allow-blank.txt"
  printf '[unclosed\n' > "$L/allow-bad.txt"
  run l6 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log" "$L/allow-bad.txt"
  check "an allow-list entry that is not a valid regexp fails" test "$(status l6)" != 0
  run l6 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log" "$L/allow-blank.txt"
  check "an allow-list entry of only blanks (it would allow everything) fails" test "$(status l6)" != 0
  run l7 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log"
  check "missing arguments fail" test "$(status l7)" != 0

  # the allow-list that ships with the fork must be valid and must not allow everything
  run l8 bash "$HERE/ionos-smoke-logs.sh" "$L/other.log" "$HERE/ionos-smoke-log-allowlist.txt"
  check "the shipped allow-list does not allow an arbitrary error" test "$(status l8)" != 0
  run l8 bash "$HERE/ionos-smoke-logs.sh" "$L/empty.log" "$HERE/ionos-smoke-log-allowlist.txt"
  check "the shipped allow-list is valid" test "$(status l8)" = 0
}

# ---------------------------------------------------------------- scenario: break (the tamper script)
mkzip() { # mkzip <zip>: a small archive shaped like a flavor archive
  local d="$ROOT/zipsrc"; rm -rf "$d"; mkdir -p "$d/core" "$d/apps/files/appinfo" "$d/apps-upstream/weather_status/appinfo" "$d/apps-upstream/contacts/appinfo" "$d/config"
  jq -nc '{alwaysEnabled:["files"],defaultEnabled:["contacts","weather_status"],shippedApps:["files"]}' > "$d/core/shipped.json"
  for a in apps/files apps-upstream/weather_status apps-upstream/contacts; do echo '<info/>' > "$d/$a/appinfo/info.xml"; echo x > "$d/$a/x.php"; done
  echo '<?php' > "$d/version.php"
  rm -f "$1"; ( cd "$d" && zip -qr "$1" . )
}
sc_break() {
  local z="$ROOT/b.zip" list
  mkzip "$z"; cp "$z" "$ROOT/orig.zip"
  run b0 bash "$HERE/ionos-smoke-break.sh" none "$z"
  check "mode none succeeds" test "$(status b0)" = 0
  check "mode none leaves the archive as it is" cmp "$z" "$ROOT/orig.zip"

  run b1 bash "$HERE/ionos-smoke-break.sh" missing-app "$z"
  check "missing-app succeeds" test "$(status b1)" = 0
  list=$(unzip -Z1 "$z")
  check "missing-app removes the folder of an app that is enabled at install (the last default app)" bash -c "! grep -q '^apps-upstream/weather_status/' <<<'$list'"
  check "missing-app keeps the other apps" bash -c "grep -q '^apps-upstream/contacts/appinfo/info.xml' <<<'$list' && grep -q '^apps/files/' <<<'$list'"
  check "missing-app names the app it removed" said b1 weather_status
  check "missing-app leaves shipped.json alone (the app is still listed)" bash -c "unzip -p '$z' core/shipped.json | jq -e '.defaultEnabled | index(\"weather_status\")' >/dev/null"

  mkzip "$z"
  run b2 bash "$HERE/ionos-smoke-break.sh" extra-app "$z"
  check "extra-app succeeds" test "$(status b2)" = 0
  check "extra-app adds an app folder with an info.xml" bash -c "unzip -Z1 '$z' | grep -qx 'apps/ionos_smoke_extra/appinfo/info.xml'"
  check "extra-app's info.xml names the app id and is well-formed" bash -c "unzip -p '$z' apps/ionos_smoke_extra/appinfo/info.xml | grep -q '<id>ionos_smoke_extra</id>' && unzip -p '$z' apps/ionos_smoke_extra/appinfo/info.xml | xmllint --noout - 2>/dev/null || ! command -v xmllint"
  check "extra-app does not list the app in shipped.json" bash -c "! unzip -p '$z' core/shipped.json | grep -q ionos_smoke_extra"
  check "extra-app keeps the existing apps" bash -c "unzip -Z1 '$z' | grep -q '^apps-upstream/weather_status/appinfo/info.xml'"

  mkzip "$z"
  run b3 bash "$HERE/ionos-smoke-break.sh" wrong-mode "$z"
  check "wrong-mode succeeds" test "$(status b3)" = 0
  check "wrong-mode takes the app out of defaultEnabled" bash -c "unzip -p '$z' core/shipped.json | jq -e '(.defaultEnabled | index(\"weather_status\") | not) and (.defaultEnabled | index(\"contacts\"))' >/dev/null"
  check "wrong-mode keeps the other lists" bash -c "unzip -p '$z' core/shipped.json | jq -e '.alwaysEnabled == [\"files\"] and .shippedApps == [\"files\"]' >/dev/null"
  check "wrong-mode keeps the app folder" bash -c "unzip -Z1 '$z' | grep -q '^apps-upstream/weather_status/appinfo/info.xml'"
  check "wrong-mode names the app" said b3 weather_status

  mkzip "$z"; cp "$z" "$ROOT/before.zip"
  run b4 bash "$HERE/ionos-smoke-break.sh" bogus "$z"
  check "an unknown mode fails" test "$(status b4)" != 0
  check "an unknown mode leaves the archive alone" cmp "$z" "$ROOT/before.zip"
  run b4 bash "$HERE/ionos-smoke-break.sh" missing-app "$ROOT/nothing.zip"
  check "a missing archive fails" test "$(status b4)" != 0
  run b4 bash "$HERE/ionos-smoke-break.sh" missing-app
  check "missing arguments fail" test "$(status b4)" != 0
  # an archive whose shipped.json lists no default app (nothing to break)
  local d="$ROOT/zipnone"; rm -rf "$d"; mkdir -p "$d/core" "$d/apps/files/appinfo"; echo '{"defaultEnabled":[]}' > "$d/core/shipped.json"; echo '<info/>' > "$d/apps/files/appinfo/info.xml"
  ( cd "$d" && zip -qr "$ROOT/none.zip" . )
  run b5 bash "$HERE/ionos-smoke-break.sh" wrong-mode "$ROOT/none.zip"
  check "wrong-mode fails clearly when no default app exists" test "$(status b5)" != 0
  run b5 bash "$HERE/ionos-smoke-break.sh" missing-app "$ROOT/none.zip"
  check "missing-app fails clearly when no default app exists" test "$(status b5)" != 0
  # a default app that has no folder is not picked
  mkzip "$z"; zip -qd "$z" 'apps-upstream/weather_status/*'
  run b6 bash "$HERE/ionos-smoke-break.sh" missing-app "$z"
  check "an app without a folder in the archive is not picked (the next one is)" bash -c "test '$(status b6)' = 0 && ! unzip -Z1 '$z' | grep -q '^apps-upstream/contacts/'"
  # several archives (one per flavor) are all tampered with
  mkzip "$z"; mkzip "$ROOT/b2.zip"
  run b8 bash "$HERE/ionos-smoke-break.sh" wrong-mode "$z" "$ROOT/b2.zip"
  check "every archive given is tampered with" bash -c "unzip -p '$z' core/shipped.json | jq -e '.defaultEnabled | index(\"weather_status\") | not' >/dev/null && unzip -p '$ROOT/b2.zip' core/shipped.json | jq -e '.defaultEnabled | index(\"weather_status\") | not' >/dev/null"
  run b8 bash "$HERE/ionos-smoke-break.sh" wrong-mode "$z" "$ROOT/nothing.zip"
  check "a missing archive among several fails before anything is changed" test "$(status b8)" != 0
  # an app id with odd characters in shipped.json must not reach zip's patterns
  mkzip "$z"; jq -c '.defaultEnabled += ["a*b"]' <(unzip -p "$z" core/shipped.json) > "$ROOT/odd.json"
  ( cd "$ROOT" && mkdir -p oddroot/core && cp odd.json oddroot/core/shipped.json && cd oddroot && zip -q "$z" core/shipped.json )
  run b7 bash "$HERE/ionos-smoke-break.sh" missing-app "$z"
  check "an odd app id in shipped.json is ignored, not used as a pattern" bash -c "test '$(status b7)' = 0 && unzip -Z1 '$z' | grep -q '^apps/files/'"
}

# ---------------------------------------------------------------- scenario: appconfig
sc_appconfig() {
  local t="$ROOT/ac"; rm -rf "$t"; mkdir -p "$t"
  cat > "$ROOT/occ-stub" <<'STUB'
#!/usr/bin/env bash
# stub for `php occ`: records the arguments, and for config:import also the file it was given
echo "occ $*" >> "$OCC_LOG"
if [ "$1" = config:import ]; then cp "$2" "$OCC_LOG.import"; fi
[ "${OCC_FAIL:-}" != "$1" ] || { echo "occ: $1 failed" >&2; exit 1; }
STUB
  chmod +x "$ROOT/occ-stub"
  cat > "$t/app-config.json" <<'EOF'
{"apps":{"theming":{"name":"Demo","url":"${BASE_URL}/x"}}}
EOF
  cat > "$t/app-config-special.json" <<'EOF'
[
  {"app":"mail","key":"smtp_pass","value":"${SMTP_PASSWORD}","sensitive":true},
  {"app":"demo","key":"count","value":"3","type":"integer","lazy":true}
]
EOF
  : > "$ROOT/occ.log"
  run c1 env OCC="$ROOT/occ-stub" OCC_LOG="$ROOT/occ.log" BASE_URL=https://demo.example SMTP_PASSWORD=s3cret bash "$HERE/ionos-smoke-appconfig.sh" "$t" "$t-tmp"
  check "the app config step succeeds" test "$(status c1)" = 0
  check "app-config.json is imported" grep -q '^occ config:import ' "$ROOT/occ.log"
  check "the placeholders of app-config.json are filled from the environment" grep -q 'https://demo.example/x' "$ROOT/occ.log.import"
  check "the imported file has no placeholder left" bash -c "! grep -q '\${' '$ROOT/occ.log.import'"
  check "a sensitive special setting is set with --sensitive and the filled value" grep -q '^occ config:app:set mail smtp_pass --value=s3cret --sensitive' "$ROOT/occ.log"
  check "a lazy typed special setting is set with --lazy and --type" grep -q '^occ config:app:set demo count --value=3 --type=integer --lazy' "$ROOT/occ.log"
  check "the secret does not appear in the step's output" bash -c "! grep -q s3cret '$ROOT/c1.log'"

  : > "$ROOT/occ.log"
  run c2 env OCC="$ROOT/occ-stub" OCC_LOG="$ROOT/occ.log" SMTP_PASSWORD=s3cret bash "$HERE/ionos-smoke-appconfig.sh" "$t" "$t-tmp"
  check "a placeholder without a value fails (never imports a literal placeholder)" test "$(status c2)" != 0
  check "the missing variable is named" said c2 BASE_URL
  check "nothing is imported when a variable is missing" bash -c "! grep -q config:import '$ROOT/occ.log'"

  : > "$ROOT/occ.log"
  run c3 env OCC="$ROOT/occ-stub" OCC_LOG="$ROOT/occ.log" OCC_FAIL=config:import BASE_URL=u SMTP_PASSWORD=p bash "$HERE/ionos-smoke-appconfig.sh" "$t" "$t-tmp"
  check "a failing import fails the step" test "$(status c3)" != 0

  local e="$ROOT/ac2"; mkdir -p "$e"; echo '{"apps":{}}' > "$e/app-config.json"; echo '[]' > "$e/app-config-special.json"
  : > "$ROOT/occ.log"
  run c4 env OCC="$ROOT/occ-stub" OCC_LOG="$ROOT/occ.log" bash "$HERE/ionos-smoke-appconfig.sh" "$e" "$e-tmp"
  check "an empty app config is imported without error" bash -c "test '$(status c4)' = 0 && grep -q config:import '$ROOT/occ.log' && ! grep -q config:app:set '$ROOT/occ.log'"
  run c5 env OCC="$ROOT/occ-stub" OCC_LOG="$ROOT/occ.log" bash "$HERE/ionos-smoke-appconfig.sh" "$ROOT/nodir" "$ROOT/nodir-tmp"
  check "a tree without app-config.json fails" test "$(status c5)" != 0
}

# ---------------------------------------------------------------- the mock Nextcloud (for probes and the run script)
write_mock() {
  mkdir -p "$ROOT/mock/docroot" "$ROOT/mock/files"
  cat > "$ROOT/mock/router.php" <<'PHP'
<?php
// Imitates the endpoints the probes use. MOCK_FAIL=<probe> breaks one of them. State is in MOCK_DIR.
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];
$fail = getenv('MOCK_FAIL') ?: '';
$dir = getenv('MOCK_DIR');
$pass = getenv('MOCK_PASS');
$basic = ($_SERVER['PHP_AUTH_USER'] ?? '') === 'admin' && ($_SERVER['PHP_AUTH_PW'] ?? '') === $pass;
$session = ($_COOKIE['mocksession'] ?? '') === 'ok';
$page = fn(string $t) => print("<html><head data-requesttoken=\"tok123\"></head><body>$t " . str_repeat('x', 400) . "</body></html>");
if ($uri === '/status.php') {
    header('Content-Type: application/json');
    echo json_encode(['installed' => $fail !== 'status', 'maintenance' => false, 'needsDbUpgrade' => false, 'version' => '33.0.9.1.5']);
} elseif ($uri === '/index.php/login') {
    if ($method === 'POST') {
        $okLogin = ($_SERVER['HTTP_ORIGIN'] ?? '') !== '' && ($_POST['requesttoken'] ?? '') === 'tok123'
            && ($_POST['user'] ?? '') === 'admin' && ($_POST['password'] ?? '') === $pass && $fail !== 'session';
        if ($okLogin) { setcookie('mocksession', 'ok'); header('Location: /index.php/apps/dashboard/', true, 303); }
        else { header('Location: /index.php/login?user=admin&direct=1', true, 303); }
    } elseif ($fail === 'login') { http_response_code(500); echo 'boom'; }
    else { $page('login'); }
} elseif (str_starts_with($uri, '/ocs/v2.php/cloud/capabilities')) {
    header('Content-Type: application/json');
    if (!$basic || ($_SERVER['HTTP_OCS_APIREQUEST'] ?? '') !== 'true') { http_response_code(401); echo '{}'; return; }
    echo $fail === 'ocs' ? '{"ocs":{"meta":{"statuscode":997}}}' : '{"ocs":{"meta":{"status":"ok","statuscode":200},"data":{"capabilities":{"core":{"pollinterval":60}}}}}';
} elseif (str_starts_with($uri, '/remote.php/dav/files/admin')) {
    if (!$basic) { http_response_code(401); return; }
    $name = basename($uri);
    $file = "$dir/files/" . $name;
    if ($method === 'PROPFIND') {
        if ($fail === 'propfind') { http_response_code(500); return; }
        http_response_code(207); header('Content-Type: application/xml'); echo '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response/></d:multistatus>';
    } elseif ($method === 'PUT') {
        if ($fail === 'put') { http_response_code(500); return; }
        @mkdir("$dir/files", 0777, true); file_put_contents($file, file_get_contents('php://input')); http_response_code(201);
    } elseif ($method === 'GET') {
        if ($fail === 'get') { http_response_code(404); return; }
        echo $fail === 'content' ? 'something else' : file_get_contents($file);
    } elseif ($method === 'DELETE') { @unlink($file); http_response_code(204); }
} elseif ($uri === '/index.php/apps/files/' || $uri === '/index.php/settings/admin' || $uri === '/index.php/settings/admin/overview') {
    if (!$session) { http_response_code(401); echo 'login required'; return; }
    $key = ['/index.php/apps/files/' => 'files', '/index.php/settings/admin' => 'settings', '/index.php/settings/admin/overview' => 'overview'][$uri];
    if ($fail === $key) { http_response_code(500); echo 'Internal Server Error'; return; }
    $page($key);
} else { http_response_code(404); echo 'not found'; }
PHP
}
mock_start() { # mock_start [VAR=value ...]: starts the mock on a free port; sets MOCK_URL
  mock_stop
  local port
  for port in $(seq 28100 28200); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break; done
  rm -rf "$ROOT/mock/state"; mkdir -p "$ROOT/mock/state"
  env MOCK_DIR="$ROOT/mock/state" MOCK_PASS=Smoke-Pass "$@" php -S "127.0.0.1:$port" -t "$ROOT/mock/docroot" "$ROOT/mock/router.php" > "$ROOT/mock/server.log" 2>&1 &
  MOCK_PID=$!
  MOCK_URL="http://localhost:$port"
  local _; for _ in $(seq 50); do curl -s -o /dev/null "$MOCK_URL/status.php" && return 0; sleep 0.1; done
  echo "mock server did not start" >&2; return 1
}
mock_stop() { [ -z "${MOCK_PID:-}" ] || { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""; }; }

# ---------------------------------------------------------------- scenario: probes
sc_probes() {
  write_mock
  mock_start
  run p0 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass bash "$HERE/ionos-smoke-probes.sh" "$MOCK_URL" "$ROOT/probe-out"
  check "every probe passes against a healthy server" test "$(status p0)" = 0
  local name
  for name in status "login page" capabilities "dav list" upload download "files page" "admin settings" "admin overview"; do
    check "probe reported: $name" grep -qi -- "ok .*$name" "$ROOT/p0.log"
  done
  check "the probe outputs are kept" test -s "$ROOT/probe-out/capabilities.json" -a -s "$ROOT/probe-out/files-page.html"
  check "the uploaded file was cleaned up" bash -c "test -z \"\$(ls '$ROOT/mock/state/files' 2>/dev/null)\""

  local f
  for f in status login ocs propfind put get content session files settings overview; do
    mock_start MOCK_FAIL="$f"
    run p1 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass bash "$HERE/ionos-smoke-probes.sh" "$MOCK_URL" "$ROOT/probe-out-$f"
    check "a failing endpoint fails the probes ($f)" test "$(status p1)" != 0
    check "the failing probe is named ($f)" said_re p1 "FAIL"
  done
  mock_start MOCK_FAIL=ocs
  run p2 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass bash "$HERE/ionos-smoke-probes.sh" "$MOCK_URL" "$ROOT/probe-out-x"
  check "all probes run even after one failed (the others are reported ok)" bash -c "grep -qi 'ok .*dav list' '$ROOT/p2.log' && grep -qi 'FAIL.*capabilities' '$ROOT/p2.log'"
  mock_start MOCK_FAIL=content
  run p3 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass bash "$HERE/ionos-smoke-probes.sh" "$MOCK_URL" "$ROOT/probe-out-y"
  check "a download that differs from the upload is named" said_re p3 "FAIL.*download.*differ"
  run p4 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=wrong bash "$HERE/ionos-smoke-probes.sh" "$MOCK_URL" "$ROOT/probe-out-z"
  check "a wrong admin password fails" test "$(status p4)" != 0
  run p5 bash "$HERE/ionos-smoke-probes.sh"
  check "missing arguments fail" test "$(status p5)" != 0
  mock_stop
  run p6 env SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass bash "$HERE/ionos-smoke-probes.sh" "http://localhost:1" "$ROOT/probe-out-w"
  check "no server at all fails" test "$(status p6)" != 0
}

# ---------------------------------------------------------------- scenario: run (the whole script with stubs)
# The stub `php` answers the occ commands from fixtures and serves the mock for `-S`; the stub ncw prints a resolved flavor.
setup_run() { # setup_run <name>: a world with an archive, a flavors folder, stubs
  local w="$ROOT/$1"; rm -rf "$w"; mkdir -p "$w/work/out" "$w/bin" "$w/flavors" "$w/src/core" "$w/src/apps/files/appinfo" "$w/src/data"
  write_mock
  jq -nc '{flavor:"demo"}' > "$w/src/version.json"
  echo '{"apps":{}}' > "$w/src/app-config.json"; echo '[]' > "$w/src/app-config-special.json"
  echo '<?php' > "$w/src/occ"
  ( cd "$w/src" && zip -qr "$w/work/out/ncw-demo-v33.0.9.7.zip" . )
  cp "$FIX/applist-ok.json" "$w/applist.json"
  cp "$FIX/resolved.yaml" "$w/resolved.yaml"
  : > "$w/occ.log"
  cat > "$w/bin/ncw" <<'STUB'
#!/usr/bin/env bash
# stub of the flavors tool: ncw resolve --flavors <dir> --flavor <name>
[ "$1" = resolve ] || exit 2
cat "$STUB_RESOLVED"
STUB
  cat > "$w/bin/php" <<'STUB'
#!/usr/bin/env bash
# stub php: -m lists modules, occ/cron.php answer from fixtures, -S serves the mock with the real php
echo "php $*" >> "$STUB_DIR/php.log"
case "$1" in
  -r) echo 8.3.0; exit 0 ;;
  -m) printf '%s\n' ctype curl dom fileinfo gd mbstring openssl posix session SimpleXML xmlreader xmlwriter zip zlib pdo_sqlite libxml filter hash iconv intl; exit 0 ;;
  -d) exec "$REAL_PHP" "$@" ;;
esac
case "$(basename "$1")" in
  occ)
    shift
    case "$1" in
      maintenance:install)
        [ "${STUB_FAIL:-}" = install ] && { echo "install failed: boom" >&2; exit 1; }
        mkdir -p data; : > data/nextcloud.log
        [ -z "${STUB_LOG_LINE:-}" ] || echo "$STUB_LOG_LINE" >> data/nextcloud.log
        env | grep -E '^(SMTP_PASSWORD|PHONE_REGION)=' > "$STUB_DIR/env.seen" || true ;;
      app:list) cat "$STUB_DIR/applist.json" ;;
      files:scan) [ "${STUB_FAIL:-}" = scan ] && exit 1; echo scanned ;;
      config:import|config:app:set) echo "occ $*" >> "$STUB_DIR/occ.log" ;;
      *) echo "stub occ: $*" ;;
    esac ;;
  cron.php) [ "${STUB_FAIL:-}" = cron ] && exit 1; echo cron ;;
  *) echo "stub php: unexpected $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$w/bin/ncw" "$w/bin/php"
}
run_smoke() { # run_smoke <world> [VAR=value ...]
  local w="$ROOT/$1"; shift
  local port
  for port in $(seq 28300 28400); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break; done
  rm -rf "$w/tmp" "$w/logs"
  run "$(basename "$w")-run" env PATH="$w/bin:$PATH" REAL_PHP="$(command -v php)" STUB_DIR="$w" STUB_RESOLVED="$w/resolved.yaml" \
    NCW="$w/bin/ncw" WORK="$w/work" FLAVORS_DIR="$w/flavors" SMOKE_TMP="$w/tmp" SMOKE_LOGS="$w/logs" SMOKE_PORT="$port" \
    MOCK_DIR="$w/mock" MOCK_PASS=Smoke-Test-Admin-Pw-1 MOCK_ROUTER="$ROOT/mock/router.php" SMOKE_ALLOWLIST="$FIX/allow.txt" \
    SMOKE_SERVER_ARGS="$ROOT/mock/router.php" "$@" bash "$HERE/ionos-smoke-run.sh"
}
sc_run() {
  local w r
  setup_run r1; w="$ROOT/r1"
  run_smoke r1
  r=r1-run
  check "a healthy archive passes the whole smoke test" test "$(status $r)" = 0
  check "the install ran with SQLite" grep -q 'maintenance:install --database sqlite' "$w/php.log"
  check "the required env var got a test value" grep -q '^SMTP_PASSWORD=smoke-test-value-smtp-password$' "$w/env.seen"
  check "cron.php and files:scan ran" bash -c "grep -q 'cron.php' '$w/php.log' && grep -q 'files:scan --all' '$w/php.log'"
  check "app-config.json was imported after the install" grep -q '^occ config:import' "$w/occ.log"
  check "the logs are kept" test -f "$w/logs/demo/install.log" -a -f "$w/logs/demo/app-list.json" -a -f "$w/logs/demo/nextcloud.log"
  check "the unpacked tree is removed afterwards" test ! -e "$w/tmp/demo"
  check "the run says which flavor it tested" said $r demo

  setup_run r2; w="$ROOT/r2"
  cp "$FIX/applist-missing.json" "$w/applist.json"; run_smoke r2
  check "a missing app fails the run" test "$(status r2-run)" != 0
  check "the failing app is named" said_re r2-run "'contacts'"
  check "a failed run still keeps the logs" test -f "$w/logs/demo/app-list.json"

  setup_run r3; w="$ROOT/r3"
  run_smoke r3 STUB_FAIL=install
  check "a failing install fails the run" test "$(status r3-run)" != 0
  check "the install output is kept" grep -q 'install failed' "$w/logs/demo/install.log"

  setup_run r4; w="$ROOT/r4"
  run_smoke r4 STUB_LOG_LINE="$(logline 3 "Real trouble here")"
  check "an error log entry fails the run" test "$(status r4-run)" != 0
  check "the entry is shown" said r4-run "Real trouble here"
  setup_run r5; run_smoke r5 STUB_LOG_LINE="$(logline 1 "Disabled incompatible app: contacts")"
  check "a Disabled incompatible app line fails the run" test "$(status r5-run)" != 0
  setup_run r6; run_smoke r6 STUB_LOG_LINE="$(logline 3 "Could not connect to the lookup server")"
  check "an allow-listed error entry passes the run" test "$(status r6-run)" = 0

  setup_run r7; run_smoke r7 STUB_FAIL=cron
  check "a failing cron run fails the run" test "$(status r7-run)" != 0
  setup_run r8; run_smoke r8 STUB_FAIL=scan
  check "a failing file scan fails the run" test "$(status r8-run)" != 0
  setup_run r9; run_smoke r9 MOCK_FAIL=propfind
  check "a failing probe fails the run" test "$(status r9-run)" != 0

  # the declared env: required gets a test value, an optional one its declared default
  setup_run r10; w="$ROOT/r10"; run_smoke r10
  check "an optional variable gets its declared default" grep -q '^PHONE_REGION=DE$' "$w/env.seen"

  # the gate proof: with a break the run must fail; a pass is itself a failure
  setup_run r11; run_smoke r11 SMOKE_BREAK=wrong-mode
  check "a break that the smoke test does not catch fails the run (the gate proves nothing)" test "$(status r11-run)" != 0
  check "that failure says the gate did not catch the break" said_re r11-run "did not catch"
  setup_run r12; cp "$FIX/applist-missing.json" "$ROOT/r12/applist.json"; run_smoke r12 SMOKE_BREAK=missing-app
  check "a break that the smoke test catches still fails the run" test "$(status r12-run)" != 0
  setup_run r13; run_smoke r13 SMOKE_BREAK=none
  check "break none behaves like no break" test "$(status r13-run)" = 0

  # inputs
  setup_run r14; rm -f "$ROOT/r14/work/out/"*.zip
  run_smoke r14
  check "no archive fails the run (nothing tested is no pass)" test "$(status r14-run)" != 0
  setup_run r15; mv "$ROOT/r15/work/out/ncw-demo-v33.0.9.7.zip" "$ROOT/r15/work/out/ncw-bad..name-v1.zip"
  run_smoke r15
  check "an archive name that is no flavor name fails the run" test "$(status r15-run)" != 0
  setup_run r16; w="$ROOT/r16"; rm -rf "$w/src"/*; rm -f "$w/work/out/"*.zip
  mkdir -p "$w/src/data" "$w/src/apps"; echo '{"flavor":"other"}' > "$w/src/version.json"; echo '<?php' > "$w/src/occ"
  ( cd "$w/src" && zip -qr "$w/work/out/ncw-demo-v33.0.9.7.zip" . )
  run_smoke r16
  check "version.json that names another flavor fails the run" test "$(status r16-run)" != 0
}

ALL="apps logs break appconfig probes run"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
mock_stop
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
