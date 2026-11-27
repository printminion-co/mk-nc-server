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
# a flavor that enables the available app talk after the install (ncw-configure.sh)
sed 's/^app_folders:/enable_after_install:\n  - talk\napp_folders:/' "$FIX/resolved.yaml" > "$FIX/resolved-enable.yaml"
applist '.enabled.talk = .disabled.talk | del(.disabled.talk)' talk-enabled
applist '.enabled.talk = .disabled.talk | del(.disabled.talk) | del(.enabled.contacts)' talk-enabled-missing

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

  # enable_after_install: the app is mode available, and must be enabled after the script
  run a9 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-talk-enabled.json" "$FIX/resolved-enable.yaml"
  check "an enable_after_install app that is enabled passes" test "$(status a9)" = 0
  run a9 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved-enable.yaml"
  check "an enable_after_install app that is still disabled fails" test "$(status a9)" != 0
  check "the failure names the app and says it must be enabled" said_re a9 "'talk'.*enable_after_install.*must be enabled"
  run a9 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-talk-enabled.json" "$FIX/resolved.yaml"
  check "without enable_after_install an available app that is enabled still fails" test "$(status a9)" != 0
  check "enable_after_install: [] in the resolved flavor means none" bash -c "sed 's/^app_folders:/enable_after_install: []\napp_folders:/' '$FIX/resolved.yaml' > '$FIX/resolved-empty-enable.yaml' && bash '$HERE/ionos-smoke-apps.sh' '$FIX/applist-ok.json' '$FIX/resolved-empty-enable.yaml'"
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

# ---------------------------------------------------------------- scenario: brand (the text check on fixture pages)
sc_brand() {
  local P="$ROOT/bpages" B="$HERE/ionos-smoke-brand.sh" A="$ROOT/ballow.txt" b64
  rm -rf "$P"; mkdir -p "$P"
  cat > "$A" <<'EOF2'
# a test allow-list
* :: IONOS Nextcloud Workspace :: the product name
* :: https://docs\.nextcloud\.com/server/33/go\.php\?to=[a-z-]+ :: documentation link
login :: id="nextcloud" :: element id on the login page only
EOF2
  printf '<html><title>Login - IONOS Nextcloud Workspace</title><a href="https:\\/\\/docs.nextcloud.com\\/server\\/33\\/go.php?to=admin-install">docs</a><div id="nextcloud"></div></html>\n' > "$P/login.html"
  run c1 bash "$B" --scan "$P" "$A"
  check "a page with the product name, a documentation link (JSON-escaped slashes) and an allowed id passes" test "$(status c1)" = 0
  check "the passing page is reported with its allowed occurrences" said_re c1 "ok - brand check, page login \(3 allowed"

  printf '<html><p>Welcome to Nextcloud</p> IONOS Nextcloud Workspace</html>\n' > "$P/files.html"
  run c2 bash "$B" --scan "$P" "$A"
  check "a bare Nextcloud on a page fails the check" test "$(status c2)" != 0
  check "the failure names the page and shows the context" said_re c2 "page files: 1 occurrence.*\n?" 
  check "the context of the occurrence is printed" said c2 "Welcome to Nextcloud"
  check "the other page still passes" said_re c2 "ok - brand check, page login"
  rm -f "$P/files.html"

  local t
  for t in nextcloud NEXTCLOUD NeXtCloud "my-nextcloud.example" "https://nextcloud.com/x" "Nextcloud-Server"; do
    printf '<html>%s</html>\n' "$t" > "$P/other.html"
    run c3 bash "$B" --scan "$P" "$A"
    check "the text '$t' fails the check (any case, in text, URLs and compounds)" test "$(status c3)" != 0
  done
  printf '<html>IONOS Nextcloud Workspace and nextcloud</html>\n' > "$P/other.html"
  run c3 bash "$B" --scan "$P" "$A"
  check "an allowed phrase does not allow a second, bare occurrence on the same page" bash -c "test '$(status c3)' != 0 && grep -q 'page other: 1 occurrence' '$ROOT/c3.log'"
  printf '<html>IONOS  Nextcloud  Workspace</html>\n' > "$P/other.html"
  run c3 bash "$B" --scan "$P" "$A"
  check "the product name must match exactly (other spacing fails)" test "$(status c3)" != 0
  printf '<html>ionos nextcloud workspace</html>\n' > "$P/other.html"
  run c3 bash "$B" --scan "$P" "$A"
  check "the allow-list is case sensitive (the product name in lower case fails)" test "$(status c3)" != 0
  rm -f "$P/other.html"

  # the page glob: an entry for the login page does not allow the id on another page
  printf '<div id="nextcloud"></div>\n' > "$P/files.html"
  run c4 bash "$B" --scan "$P" "$A"
  check "an entry for one page does not allow the text on another page" test "$(status c4)" != 0
  rm -f "$P/files.html"

  # initial states are decoded
  b64=$(printf 'Nextcloud hidden in a state' | base64 -w0)
  printf '<html><input type="hidden" id="initial-state-app-key" value="%s"></html>\n' "$b64" > "$P/settings.html"
  run c5 bash "$B" --scan "$P" "$A"
  check "a Base64 initial-state value is decoded and checked" test "$(status c5)" != 0
  check "the decoded context is shown" said c5 "hidden in a state"
  b64=$(printf 'IONOS Nextcloud Workspace' | base64 -w0)
  printf '<html><input type="hidden" id="initial-state-app-key" value="%s"></html>\n' "$b64" > "$P/settings.html"
  run c5 bash "$B" --scan "$P" "$A"
  check "a decoded initial-state value with only the product name passes" test "$(status c5)" = 0
  rm -f "$P/settings.html"

  # a mail as text
  printf 'Hello\n-- \nNextcloud\n' > "$P/mail-text.txt"
  run c6 bash "$B" --scan "$P" "$A"
  check "a text page (the plain text mail) is checked too" test "$(status c6)" != 0
  rm -f "$P/mail-text.txt"

  # stale entries are a notice, not a failure
  printf '%s\n' '* :: this text is on no page :: a stale entry' >> "$A"
  run c7 bash "$B" --scan "$P" "$A"
  check "an entry that matched nothing is reported as stale and does not fail" bash -c "test '$(status c7)' = 0 && grep -q 'notice.*matched nothing' '$ROOT/c7.log'"

  # allow-list files
  run c8 bash "$B" --scan "$P" "$ROOT/no-such-allowlist.txt"
  check "a missing allow-list fails" test "$(status c8)" != 0
  local bad
  for bad in 'login :: foo' 'login :: foo :: ' ' :: foo :: reason' 'login ::  :: reason' 'login :: [unclosed :: reason' 'login :: x* :: matches the empty string' 'just some text'; do
    printf '%s\n' "$bad" > "$ROOT/ballow-bad.txt"
    run c9 bash "$B" --scan "$P" "$ROOT/ballow-bad.txt"
    check "a bad allow-list entry fails: $bad" test "$(status c9)" != 0
  done
  printf '# only comments\n\n' > "$ROOT/ballow-empty.txt"
  run c10 bash "$B" --scan "$P" "$ROOT/ballow-empty.txt"
  check "an allow-list without entries allows nothing (the product name fails)" test "$(status c10)" != 0
  mkdir -p "$ROOT/bempty"
  run c11 bash "$B" --scan "$ROOT/bempty" "$A"
  check "no pages is no pass" test "$(status c11)" != 0
  run c11 bash "$B" --scan "$ROOT/does-not-exist" "$A"
  check "a missing pages folder fails" test "$(status c11)" != 0
  run c11 bash "$B" --scan
  check "missing arguments fail" test "$(status c11)" != 0
  run c11 bash "$B" http://localhost:1
  check "wrong arguments fail" test "$(status c11)" != 0

  # the allow-list that ships with the fork: valid, and strict
  rm -rf "$P"; mkdir -p "$P"
  printf '<html>IONOS Nextcloud Workspace</html>\n' > "$P/login.html"
  run c12 bash "$B" --scan "$P"
  check "the shipped allow-list is valid and allows the product name" test "$(status c12)" = 0
  local t2
  for t2 in "Nextcloud" "Welcome to Nextcloud" "https://nextcloud.com/install/" "Nextcloud Hub" "Powered by Nextcloud" "Nextcloud GmbH" 'https://github.com/nextcloud' "nextcloud_announcements" "Nextcloud Account"; do
    printf '<html>%s</html>\n' "$t2" > "$P/login.html"
    run c13 bash "$B" --scan "$P"
    check "the shipped allow-list does not allow '$t2' on the login page" test "$(status c13)" != 0
  done
  printf '<html>Nextcloud Hub 26 Winter</a> (33.0.9)</html>\n' > "$P/files.html"; rm -f "$P/login.html"
  run c13 bash "$B" --scan "$P"
  check "the shipped allow-list keeps the Nextcloud Hub label to the admin overview only" test "$(status c13)" != 0
  rm -f "$P/files.html"; printf '<p>x>Nextcloud Hub 26 Winter</a> (33.0.9)</p>\n' > "$P/overview.html"
  run c13 bash "$B" --scan "$P"
  check "the Nextcloud Hub label is allowed on the admin overview" test "$(status c13)" = 0
  check "every entry of the shipped allow-list has a page, a regexp and a reason" bash -c "! grep -vE '^[[:space:]]*(#|\$)' '$HERE/ionos-smoke-brand-allowlist.txt' | grep -vE '^[^ ]+ :: .+ :: .+\$'"
  check "no entry of the shipped allow-list allows the bare word" bash -c "! grep -vE '^[[:space:]]*(#|\$)' '$HERE/ionos-smoke-brand-allowlist.txt' | awk -F ' :: ' '{print \$2}' | grep -xiE '(nextcloud|.\\*nextcloud.\\*|\\(\\?i\\).*)'"
}

# ---------------------------------------------------------------- scenario: brand_run (fetch, theme probes and the mail against the mock)
brand_world() { # brand_world <name> [theme]: a tree, a resolved flavor and a stub php; sets BW
  BW="$ROOT/$1"; rm -rf "$BW"; mkdir -p "$BW/tree" "$BW/bin" "$BW/sysconf"
  write_mock
  cp "$FIX/resolved.yaml" "$BW/resolved.yaml"
  if [ -n "${2:-}" ]; then
    sed "s/^themes: \[\]/themes:\n  - $2\nenforce_theme: $2/" "$FIX/resolved.yaml" > "$BW/resolved.yaml"
    printf '%s\n' "$2" > "$BW/sysconf/enforce_theme"
    printf '%s\n' "$2" > "$BW/sysconf/theme"
    printf '%s\n' 'OC\Ncw\Mail\IonosEMailTemplate' > "$BW/sysconf/mail_template_class"
    jq -nc '{class:"OC\\Ncw\\Mail\\IonosEMailTemplate",html:"<p>IONOS Nextcloud Workspace</p>",text:"mail IONOS Nextcloud Workspace"}' > "$BW/mail.json"
    echo '[{"app":"theming","key":"disable-user-theming","value":"1","type":"boolean"}]' > "$BW/tree/app-config-special.json"
  fi
  cat > "$BW/bin/php" <<'STUB'
#!/usr/bin/env bash
case "$(basename "$1")" in
  occ) shift; [ "$1" = config:system:get ] && { [ ! -f "$STUB_DIR/sysconf/$2" ] || cat "$STUB_DIR/sysconf/$2"; } ;;
  ionos-smoke-mail.php) if [ -f "$STUB_DIR/mail.json" ]; then cat "$STUB_DIR/mail.json"; else echo '{"class":"OC\\Mail\\EMailTemplate","html":"<p>mail</p>","text":"mail"}'; fi ;;
  *) echo "stub php: unexpected $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$BW/bin/php"
}
brand_run() { # brand_run <name> [VAR=value ...]: mock + brand script; the log is <name>.log
  local n=$1; shift
  mock_start "$@"
  run "$n" env PATH="$BW/bin:$PATH" PHP="$BW/bin/php" STUB_DIR="$BW" SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass SMOKE_BRAND_ALLOWLIST="$FIX/brand-allow.txt" \
    bash "$HERE/ionos-smoke-brand.sh" "$MOCK_URL" "$BW/tree" "$BW/resolved.yaml" "$BW/out"
}
sc_brand_run() {
  printf '* :: IONOS Nextcloud Workspace :: the product name\n' > "$FIX/brand-allow.txt"
  brand_world bw1
  brand_run d1
  check "a flavor without theme or mail class: the pages are checked and the run passes" test "$(status d1)" = 0
  check "the pages and the mail are kept" bash -c "ls '$BW/out/pages' | tr '\n' ' ' | grep -q 'admin-theming.html files.html login.html mail-html.html mail-text.txt overview.html personal.html settings.html user-theming.html'"
  check "no theme probe runs for a flavor without enforce_theme" bash -c "! grep -qiE 'enforce_theme|theme stylesheet|data-theme' '$ROOT/d1.log'"
  check "the settings the flavor does not set are not probed (no lock, no mail class)" bash -c "! grep -qiE 'locked|mail uses|user theming is disabled' '$ROOT/d1.log'"

  brand_world bw2 ionos
  brand_run d2 MOCK_THEME=ionos
  check "a flavor with an enforced theme, locks and a mail class: every probe passes" test "$(status d2)" = 0
  local p
  for p in "enforce_theme is ionos" "the login page carries data-theme-ionos" "theme stylesheet of ionos" "only the enforced theme" "user theming is disabled" "admin theming is locked" "system mail uses the template"; do
    check "probe reported: $p" grep -q -- "ok - .*$p" "$ROOT/d2.log"
  done

  local case_
  for case_ in "css:theme stylesheet" "cssbody:theme stylesheet" "notheme:enforced theme on the login page" "personal:page personal" "user-theming:page user-theming" "admin-theming:page admin-theming"; do
    brand_world bw3 ionos
    brand_run d3 MOCK_THEME=ionos MOCK_FAIL="${case_%%:*}"
    check "a failing endpoint fails the run (${case_%%:*})" test "$(status d3)" != 0
    check "the failure is named (${case_%%:*})" said_re d3 "FAIL - ${case_#*:}"
  done
  brand_world bw4 ionos; brand_run d4 MOCK_THEME=ionos MOCK_USER_THEMING=on
  check "user theming that is still enabled fails although the archive disables it" bash -c "test '$(status d4)' != 0 && grep -q 'FAIL - user theming' '$ROOT/d4.log'"
  brand_world bw5 ionos; brand_run d5 MOCK_THEME=ionos MOCK_ADMIN_THEMEABLE=1
  check "an admin theming section that is not locked fails although the system theme is set" bash -c "test '$(status d5)' != 0 && grep -q 'FAIL - admin theming' '$ROOT/d5.log'"
  brand_world bw6 ionos; brand_run d6 MOCK_THEME=ionos MOCK_THEMES='[{"id":"ionos"},{"id":"dark"}]'
  check "another theme in the user theming list fails" bash -c "test '$(status d6)' != 0 && grep -q 'FAIL - theme list' '$ROOT/d6.log'"
  brand_world bw7 ionos; echo other > "$BW/sysconf/enforce_theme"; brand_run d7 MOCK_THEME=ionos
  check "an enforce_theme of the instance that differs from the resolved flavor fails" bash -c "test '$(status d7)' != 0 && grep -q 'FAIL - enforce_theme' '$ROOT/d7.log'"
  brand_world bw8 ionos; jq -nc '{class:"OC\\Mail\\EMailTemplate",html:"<p>x</p>",text:"x"}' > "$BW/mail.json"; brand_run d8 MOCK_THEME=ionos
  check "a sample mail made by the stock template fails although mail_template_class is set" bash -c "test '$(status d8)' != 0 && grep -q 'FAIL - mail template' '$ROOT/d8.log'"
  brand_world bw9 ionos; jq -nc '{class:"OC\\Ncw\\Mail\\IonosEMailTemplate",html:"<p>Powered by Nextcloud</p>",text:"x"}' > "$BW/mail.json"; brand_run d9 MOCK_THEME=ionos
  check "a Nextcloud text in the sample mail fails the brand check" bash -c "test '$(status d9)' != 0 && grep -q 'page mail-html' '$ROOT/d9.log'"
  brand_world bw10 ionos; brand_run d10 MOCK_THEME=ionos MOCK_BRAND=login
  check "a Nextcloud text on the login page fails the run" bash -c "test '$(status d10)' != 0 && grep -q 'page login: 1 occurrence' '$ROOT/d10.log'"
  brand_world bw11 ionos; brand_run d11 MOCK_THEME=ionos MOCK_BRAND=files
  check "a Nextcloud text on the files page fails the run" bash -c "test '$(status d11)' != 0 && grep -q 'page files: 1 occurrence' '$ROOT/d11.log'"
  brand_world bw12 ionos; rm -f "$BW/mail.json"
  cat > "$BW/bin/php" <<'STUB'
#!/usr/bin/env bash
case "$(basename "$1")" in occ) exit 0 ;; *) echo oops >&2; exit 1 ;; esac
STUB
  brand_run d12 MOCK_THEME=ionos
  check "a sample mail that cannot be made fails the run" bash -c "test '$(status d12)' != 0 && grep -q 'FAIL - sample mail' '$ROOT/d12.log'"
  brand_world bw13; brand_run d13 MOCK_FAIL=settings
  check "a page that does not answer fails the run" bash -c "test '$(status d13)' != 0 && grep -q 'FAIL - page settings' '$ROOT/d13.log'"
  mock_stop
  run d14 env PATH="$BW/bin:$PATH" PHP="$BW/bin/php" STUB_DIR="$BW" SMOKE_ADMIN_USER=admin SMOKE_ADMIN_PASS=Smoke-Pass SMOKE_BRAND_ALLOWLIST="$FIX/brand-allow.txt" \
    bash "$HERE/ionos-smoke-brand.sh" "http://localhost:1" "$BW/tree" "$BW/resolved.yaml" "$BW/out-none"
  check "no server at all fails" test "$(status d14)" != 0
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
  # skip-enable: the script keeps its other lines, only the list of apps to enable is emptied
  mkzip "$z"
  cat > "$ROOT/zipsrc/ncw-configure.sh" <<'SCRIPT'
#!/usr/bin/env bash
ENABLE_APPS=('groupfolders' 'x')
app:enable "${ENABLE_APPS[@]}"
SCRIPT
  ( cd "$ROOT/zipsrc" && zip -q "$z" ncw-configure.sh )
  run b9 bash "$HERE/ionos-smoke-break.sh" skip-enable "$z"
  check "skip-enable empties ENABLE_APPS and keeps the rest of the script" bash -c "test '$(status b9)' = 0 && unzip -p '$z' ncw-configure.sh | grep -qx 'ENABLE_APPS=()' && unzip -p '$z' ncw-configure.sh | grep -q 'app:enable' && ! unzip -p '$z' ncw-configure.sh | grep -q groupfolders"
  mkzip "$z"
  run b9 bash "$HERE/ionos-smoke-break.sh" skip-enable "$z"
  check "skip-enable fails when the archive has no script" test "$(status b9)" != 0
  printf '#!/usr/bin/env bash\nENABLE_APPS=()\n' > "$ROOT/zipsrc/ncw-configure.sh"; ( cd "$ROOT/zipsrc" && zip -q "$z" ncw-configure.sh )
  run b9 bash "$HERE/ionos-smoke-break.sh" skip-enable "$z"
  check "skip-enable fails when the script enables no app (nothing to prove)" test "$(status b9)" != 0
  # brand: a visible Nextcloud text in the login template
  mkzip "$z"
  mkdir -p "$ROOT/zipsrc/core/templates"; printf '<?php\nif (true) {\n?>\n<div id="login"></div>\n<?php } ?>\n<p>login</p>\n' > "$ROOT/zipsrc/core/templates/login.php"
  ( cd "$ROOT/zipsrc" && zip -q "$z" core/templates/login.php )
  run b10 bash "$HERE/ionos-smoke-break.sh" brand "$z"
  check "brand appends a visible Nextcloud text to the login template" bash -c "test '$(status b10)' = 0 && unzip -p '$z' core/templates/login.php | grep -q 'Nextcloud (added by ionos-smoke-break.sh)'"
  check "brand keeps the template and appends outside of PHP code" bash -c "unzip -p '$z' core/templates/login.php | head -n 6 | diff -q - '$ROOT/zipsrc/core/templates/login.php' >/dev/null && php -l <(unzip -p '$z' core/templates/login.php) >/dev/null 2>&1 || php -r 'exit(0);'"
  check "brand names the file" said b10 "core/templates/login.php"
  mkzip "$z"
  run b11 bash "$HERE/ionos-smoke-break.sh" brand "$z"
  check "brand fails clearly when the archive has no login template" test "$(status b11)" != 0
  mkdir -p "$ROOT/zipsrc/core/templates"; printf '%s\n' '<div></div>' '<?php' 'echo 1;' > "$ROOT/zipsrc/core/templates/login.php"
  ( cd "$ROOT/zipsrc" && zip -q "$z" core/templates/login.php )
  run b12 bash "$HERE/ionos-smoke-break.sh" brand "$z"
  check "brand fails when the login template ends in PHP mode (the text would be code)" test "$(status b12)" != 0
  check "that failure leaves the template as it was" bash -c "unzip -p '$z' core/templates/login.php | cmp -s - '$ROOT/zipsrc/core/templates/login.php'"
  rm -rf "$ROOT/zipsrc/core/templates"
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

# ---------------------------------------------------------------- scenario: apps after an upgrade
sc_apps_upgrade() {
  local B="$FIX/applist-before.json"
  # the old version: contacts enabled, talk disabled (the flavor makes talk available and contacts default: both only decide fresh installs)
  echo '{"enabled":{"contacts":"8.9.0","dav":"1.0.0","files":"2.4.0","firstrunwizard":"6.0.0"},"disabled":{"talk":"22.0.0"}}' > "$B"
  run u1 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: the states that match the old ones and the modes pass" test "$(status u1)" = 0
  # an available app that the old version had ENABLED stays enabled on an upgrade (only fresh installs obey `available`)
  jq -c '.enabled.talk = .disabled.talk | del(.disabled.talk)' "$FIX/applist-ok.json" > "$FIX/up-talk-enabled.json"
  jq -c '.enabled.talk = .disabled.talk | del(.disabled.talk)' "$B" > "$FIX/before-talk-enabled.json"
  run u2 bash "$HERE/ionos-smoke-apps.sh" "$FIX/up-talk-enabled.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: an available app that was disabled and is enabled now fails" test "$(status u2)" != 0
  check "upgrade: it is named and the old state is said" said_re u2 "'talk'.*was disabled before the upgrade.*enabled now"
  run u2 bash "$HERE/ionos-smoke-apps.sh" "$FIX/up-talk-enabled.json" "$FIX/resolved.yaml" "$FIX/before-talk-enabled.json"
  check "upgrade: an available app that was enabled keeps its state (no failure for being enabled)" test "$(status u2)" = 0
  run u2 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved.yaml"
  check "no old list: the fresh-install rules still apply (the same list passes)" test "$(status u2)" = 0
  # a default app that was disabled before keeps that state
  jq -c '.disabled.contacts = .enabled.contacts | del(.enabled.contacts)' "$B" > "$FIX/before-contacts-disabled.json"
  run u3 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-default-disabled.json" "$FIX/resolved.yaml" "$FIX/before-contacts-disabled.json"
  check "upgrade: a default app that was disabled stays disabled and passes" test "$(status u3)" = 0
  run u3 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-default-disabled.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: a default app that was enabled and is disabled now fails" test "$(status u3)" != 0
  check "upgrade: it is named" said_re u3 "'contacts'.*enabled before the upgrade"
  run u4 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-missing.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: an app of the old version that vanished fails" test "$(status u4)" != 0
  check "upgrade: it says the app is missing" said_re u4 "'contacts'.*missing"
  # always and removed are the modes that change a state on an upgrade
  run u5 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-always-disabled.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: an always app that is disabled fails" test "$(status u5)" != 0
  run u5 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-removed-enabled.json" "$FIX/resolved.yaml" "$B"
  check "upgrade: a removed app that is still present fails" test "$(status u5)" != 0
  check "upgrade: it is named" said_re u5 "'firstrunwizard'.*removed.*present"
  # enable_after_install must be enabled even when the old version had the app disabled
  run u6 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved-enable.yaml" "$B"
  check "upgrade: an enable_after_install app that is disabled fails (the script must enable it)" test "$(status u6)" != 0
  run u6 bash "$HERE/ionos-smoke-apps.sh" "$FIX/up-talk-enabled.json" "$FIX/resolved-enable.yaml" "$B"
  check "upgrade: an enable_after_install app that is enabled passes" test "$(status u6)" = 0
  # an app that is new on the instance is judged like on a fresh install
  jq -c 'del(.enabled.contacts)' "$B" > "$FIX/before-no-contacts.json"
  run u7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-default-disabled.json" "$FIX/resolved.yaml" "$FIX/before-no-contacts.json"
  check "upgrade: a new default app that is disabled fails like on a fresh install" test "$(status u7)" != 0
  run u7 bash "$HERE/ionos-smoke-apps.sh" "$FIX/applist-ok.json" "$FIX/resolved.yaml" "$FIX/nonexistent.json"
  check "upgrade: a missing old app list fails" test "$(status u7)" != 0
}

# ---------------------------------------------------------------- scenario: logs with expected incompatible apps
sc_logs_expected() {
  local L="$ROOT/logs-exp"; mkdir -p "$L"
  # the real wording of Nextcloud 33's updater (info level)
  jq -cn '{level:1,app:"updater",message:"\\OC\\Updater::incompatibleAppDisabled: Disabled incompatible app: workflowengine"}' > "$L/wfe.log"
  jq -cn '{level:1,app:"updater",message:"\\OC\\Updater::incompatibleAppDisabled: Disabled incompatible app: calendar"}' > "$L/cal.log"
  cat "$L/wfe.log" "$L/cal.log" > "$L/both.log"
  printf 'workflowengine\n' > "$L/expected.txt"
  : > "$L/none.txt"
  run x1 bash "$HERE/ionos-smoke-logs.sh" "$L/wfe.log" "$FIX/allow.txt" "$L/expected.txt"
  check "an expected incompatible app (removed from the flavor, refused by app:disable) passes" test "$(status x1)" = 0
  run x2 bash "$HERE/ionos-smoke-logs.sh" "$L/wfe.log" "$FIX/allow.txt"
  check "without the expected file the same line still fails (fresh install: never allowed)" test "$(status x2)" != 0
  run x3 bash "$HERE/ionos-smoke-logs.sh" "$L/cal.log" "$FIX/allow.txt" "$L/expected.txt"
  check "another app disabled as incompatible fails" test "$(status x3)" != 0
  check "the other app is named" said x3 calendar
  run x4 bash "$HERE/ionos-smoke-logs.sh" "$L/both.log" "$FIX/allow.txt" "$L/expected.txt"
  check "one expected and one unexpected: still fails" test "$(status x4)" != 0
  run x5 bash "$HERE/ionos-smoke-logs.sh" "$L/wfe.log" "$FIX/allow.txt" "$L/none.txt"
  check "an empty expected file allows nothing" test "$(status x5)" != 0
  logline 1 "Disabled incompatible app: workflowengine extra" > "$L/other-wording.log"
  run x6 bash "$HERE/ionos-smoke-logs.sh" "$L/other-wording.log" "$FIX/allow.txt" "$L/expected.txt"
  check "another wording of the line fails (only the exact message of the updater is accepted)" test "$(status x6)" != 0
  run x7 bash "$HERE/ionos-smoke-logs.sh" "$L/wfe.log" "$FIX/allow.txt" "$L/missing.txt"
  check "a missing expected file fails" test "$(status x7)" != 0
  printf 'bad id\n' > "$L/bad.txt"
  run x7 bash "$HERE/ionos-smoke-logs.sh" "$L/wfe.log" "$FIX/allow.txt" "$L/bad.txt"
  check "an entry that is no app id fails" test "$(status x7)" != 0
  # the shipped allow-list: the one upgrade message is on it, a lookalike is not
  logline 3 "No application directories are marked as writable." > "$L/nowrite.log"
  logline 3 "No application directories are marked as writable. Really." > "$L/nowrite2.log"
  run x8 bash "$HERE/ionos-smoke-logs.sh" "$L/nowrite.log" "$HERE/ionos-smoke-log-allowlist.txt"
  check "the shipped allow-list accepts the writable-apps-path message of occ upgrade" test "$(status x8)" = 0
  run x8 bash "$HERE/ionos-smoke-logs.sh" "$L/nowrite2.log" "$HERE/ionos-smoke-log-allowlist.txt"
  check "the shipped allow-list entry is not wider than that message" test "$(status x8)" != 0
}

# ---------------------------------------------------------------- scenario: the upgrade break modes
sc_break_upgrade() {
  local z="$ROOT/bu.zip" d="$ROOT/zipu"
  rm -rf "$d"; mkdir -p "$d/core" "$d/apps/files/appinfo"
  jq -nc '{alwaysEnabled:["files"],defaultEnabled:["contacts"],shippedApps:["files","contacts"]}' > "$d/core/shipped.json"
  echo '["firstrunwizard","workflowengine"]' > "$d/removed-apps.json"; echo 12 > "$d/.buildnumber"; echo '<?php' > "$d/version.php"
  rm -f "$z"; ( cd "$d" && zip -qr "$z" . )
  run k1 bash "$HERE/ionos-smoke-break.sh" removed-in-shipped "$z"
  check "removed-in-shipped succeeds" test "$(status k1)" = 0
  check "removed-in-shipped puts the first removed app into all three lists" bash -c "unzip -p '$z' core/shipped.json | jq -e '(.alwaysEnabled|index(\"firstrunwizard\")) and (.defaultEnabled|index(\"firstrunwizard\")) and (.shippedApps|index(\"firstrunwizard\"))' >/dev/null"
  check "removed-in-shipped keeps the other entries and does not touch removed-apps.json" bash -c "unzip -p '$z' core/shipped.json | jq -e '.alwaysEnabled|index(\"files\")' >/dev/null && unzip -p '$z' removed-apps.json | jq -e 'length == 2' >/dev/null"
  check "removed-in-shipped names the app" said k1 firstrunwizard
  rm -f "$z"; ( cd "$d" && zip -qr "$z" . ); echo '[]' > "$ROOT/empty-removed.json"
  ( cd "$ROOT" && mkdir -p ur && cp empty-removed.json ur/removed-apps.json && cd ur && zip -q "$z" removed-apps.json )
  run k2 bash "$HERE/ionos-smoke-break.sh" removed-in-shipped "$z"
  check "removed-in-shipped fails clearly when the flavor removes no app" test "$(status k2)" != 0
  rm -f "$z"; ( cd "$d" && zip -qr "$z" . )
  run k3 bash "$HERE/ionos-smoke-break.sh" no-buildnumber "$z"
  check "no-buildnumber removes .buildnumber and nothing else" bash -c "test '$(status k3)' = 0 && ! unzip -Z1 '$z' | grep -qx '.buildnumber' && unzip -Z1 '$z' | grep -qx 'version.php'"
  run k3 bash "$HERE/ionos-smoke-break.sh" no-buildnumber "$z"
  check "no-buildnumber fails when there is no .buildnumber" test "$(status k3)" != 0
  # which job a mode is for
  rm -f "$z"; ( cd "$d" && zip -qr "$z" . ); cp "$z" "$ROOT/bu-orig.zip"
  run k4 env SMOKE_BREAK_JOB=fresh bash "$HERE/ionos-smoke-break.sh" removed-in-shipped "$z"
  check "an upgrade mode leaves the archives of the fresh-install job alone" bash -c "test '$(status k4)' = 0 && cmp '$z' '$ROOT/bu-orig.zip'"
  run k4 env SMOKE_BREAK_JOB=upgrade bash "$HERE/ionos-smoke-break.sh" removed-in-shipped "$z"
  check "an upgrade mode tampers with the archives of the upgrade job" bash -c "test '$(status k4)' = 0 && ! cmp -s '$z' '$ROOT/bu-orig.zip'"
  rm -f "$z"; ( cd "$d" && zip -qr "$z" . ); cp "$z" "$ROOT/bu-orig.zip"
  run k5 env SMOKE_BREAK_JOB=upgrade bash "$HERE/ionos-smoke-break.sh" wrong-mode "$z"
  check "a fresh-install mode leaves the archives of the upgrade job alone" bash -c "test '$(status k5)' = 0 && cmp '$z' '$ROOT/bu-orig.zip'"
  run k6 bash -c ". '$HERE/ionos-lib.sh'; . '$HERE/ionos-smoke-lib.sh'; echo \"\$(smoke_break_for fresh missing-app) \$(smoke_break_for upgrade missing-app) \$(smoke_break_for upgrade no-buildnumber) \$(smoke_break_for fresh none)\""
  check "smoke_break_for maps every mode to its own smoke test" said k6 "missing-app none no-buildnumber none"
  run k6 bash -c ". '$HERE/ionos-lib.sh'; . '$HERE/ionos-smoke-lib.sh'; echo \"\$(smoke_break_for fresh brand) \$(smoke_break_for upgrade brand)\""
  check "the brand break is for the fresh-install test only" said k6 "brand none"
  run k7 bash "$HERE/ionos-smoke-break.sh" bogus "$z"
  check "an unknown mode still fails" test "$(status k7)" != 0
}

# ---------------------------------------------------------------- scenario: the vanilla download and its checks
sc_vanilla() {
  local v="$ROOT/vanilla" gh="$ROOT/vanilla/gnupg"
  rm -rf "$v"; mkdir -p "$v/srv" "$gh"; chmod 700 "$gh"
  echo 'a stand-in for the official archive' > "$v/srv/payload.txt"
  ( cd "$v/srv" && zip -q nextcloud-33.0.9.zip payload.txt && rm payload.txt )
  # a throw-away key stands in for the Nextcloud release key; a second key stands in for an attacker
  local k
  for k in good evil; do
    GNUPGHOME="$gh/$k" gpg --batch --quiet --passphrase '' --quick-generate-key "$k <$k@example.invalid>" rsa2048 sign never 2>/dev/null || { mkdir -p "$gh/$k"; chmod 700 "$gh/$k"; GNUPGHOME="$gh/$k" gpg --batch --quiet --passphrase '' --quick-generate-key "$k <$k@example.invalid>" rsa2048 sign never 2>/dev/null; }
    GNUPGHOME="$gh/$k" gpg --batch --armor --export > "$v/$k.asc" 2>/dev/null
  done
  local fpr; fpr=$(GNUPGHOME="$gh/good" gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
  local sum; sum=$(sha256sum "$v/srv/nextcloud-33.0.9.zip" | cut -d' ' -f1)
  printf '%s  nextcloud-33.0.9.zip\n%s  nextcloud-33.0.9.metadata\n' "$sum" "$(printf x | sha256sum | cut -d' ' -f1)" > "$v/srv/nextcloud-33.0.9.zip.sha256"
  GNUPGHOME="$gh/good" gpg --batch --armor --detach-sign -o "$v/srv/nextcloud-33.0.9.zip.asc" "$v/srv/nextcloud-33.0.9.zip" 2>/dev/null
  local common=(VANILLA_URL="file://$v/srv" NC_RELEASE_KEY="$v/good.asc" NC_RELEASE_KEY_FPR="$fpr")

  run n1 env "${common[@]}" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out1"
  check "a good archive passes the checksum and the signature" test "$(status n1)" = 0
  check "the last line is the path of the zip" bash -c "tail -n1 '$ROOT/n1.log' | grep -qx '$v/out1/nextcloud-33.0.9.zip' && test -f '$v/out1/nextcloud-33.0.9.zip'"
  check "both checks are reported" bash -c "grep -q 'sha256 ok' '$ROOT/n1.log' && grep -q 'signature ok' '$ROOT/n1.log'"

  run n2 env "${common[@]}" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out1"
  check "an output folder that is not empty is refused" test "$(status n2)" != 0
  run n2 env "${common[@]}" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9
  check "missing arguments fail" test "$(status n2)" != 0
  run n2 env "${common[@]}" bash "$HERE/ionos-smoke-vanilla.sh" '33.0.9/../x' "$v/out2"
  check "a base release that is no version is refused" test "$(status n2)" != 0
  run n2 env "${common[@]}" VANILLA_URL=http://example.invalid/x bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out2"
  check "a plain http URL is refused" test "$(status n2)" != 0

  # corrupt download: the zip changes after the checksum was published
  rm -rf "$v/srv2"; cp -r "$v/srv" "$v/srv2"; echo more >> "$v/srv2/nextcloud-33.0.9.zip"
  run n3 env "${common[@]}" VANILLA_URL="file://$v/srv2" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out3"
  check "a corrupt archive fails the checksum" test "$(status n3)" != 0
  check "the checksum failure says what the checksum can and cannot prove" said_re n3 "SHA-256.*corrupt"
  # tampered AND checksum republished by the same host: only the signature catches it
  sum=$(sha256sum "$v/srv2/nextcloud-33.0.9.zip" | cut -d' ' -f1)
  printf '%s  nextcloud-33.0.9.zip\n' "$sum" > "$v/srv2/nextcloud-33.0.9.zip.sha256"
  run n4 env "${common[@]}" VANILLA_URL="file://$v/srv2" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out4"
  check "a tampered archive with a matching checksum fails the signature" test "$(status n4)" != 0
  check "the signature failure is named" said_re n4 "signature"
  # signed by another key than the pinned one
  rm -rf "$v/srv3"; cp -r "$v/srv" "$v/srv3"; rm "$v/srv3/nextcloud-33.0.9.zip.asc"
  GNUPGHOME="$gh/evil" gpg --batch --armor --detach-sign -o "$v/srv3/nextcloud-33.0.9.zip.asc" "$v/srv3/nextcloud-33.0.9.zip" 2>/dev/null
  run n5 env "${common[@]}" VANILLA_URL="file://$v/srv3" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out5"
  check "a signature by another key fails" test "$(status n5)" != 0
  run n6 env "${common[@]}" NC_RELEASE_KEY="$v/evil.asc" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out6"
  check "a key file whose fingerprint is not the pinned one is refused" test "$(status n6)" != 0
  check "the fingerprint mismatch is named" said_re n6 "fingerprint"
  run n7 env "${common[@]}" VANILLA_URL="file://$v/nothing" bash "$HERE/ionos-smoke-vanilla.sh" 33.0.9 "$v/out7"
  check "a download that fails fails" test "$(status n7)" != 0
  # the key and fingerprint that ship with the fork are consistent
  check "the committed release key has the pinned default fingerprint" bash -c "gpg --show-keys --with-colons '$HERE/ionos-nextcloud-release-key.asc' | awk -F: '\$1==\"fpr\"{print \$10; exit}' | grep -qx 28806A878AE423A28372792ED75899B9A724937A && grep -q 28806A878AE423A28372792ED75899B9A724937A '$HERE/ionos-smoke-vanilla.sh'"
}

# ---------------------------------------------------------------- scenario: upgrade (the whole upgrade script with stubs)
# The stub php imitates the occ commands of an install and an upgrade and checks what the contract demands: the apps are
# disabled while the OLD tree is in place, the swap replaced the tree, config/config.php survived, the data dir is
# outside the tree. Every call is recorded with its working folder.
setup_up() { # setup_up <name>
  local w="$ROOT/$1"; rm -rf "${w:?}"; mkdir -p "$w/work/out" "$w/bin" "$w/flavors" "$w/src/config" "$w/oldsrc/nextcloud/config"
  write_mock
  jq -nc '{flavor:"demo", build_number:7}' > "$w/src/version.json"
  echo '["firstrunwizard","workflowengine","ghostapp"]' > "$w/src/removed-apps.json"
  echo '<?php // flavor partial' > "$w/src/config/50-flavor.config.php"
  cat > "$w/src/ncw-configure.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "configure: SMTP_PASSWORD=${SMTP_PASSWORD:-} cwd=$PWD" >> "$STUB_DIR/configure.log"
[ "${STUB_FAIL:-}" != configure ] || { echo "ncw-configure: boom" >&2; exit 1; }
"${PHP:-php}" "$(dirname "${BASH_SOURCE[0]}")/occ" config:import x
SCRIPT
  echo '<?php // new' > "$w/src/occ"
  ( cd "$w/src" && zip -qr "$w/work/out/ncw-demo-v33.0.9.7.zip" . )
  echo '<?php // old' > "$w/oldsrc/nextcloud/occ"; echo old > "$w/oldsrc/nextcloud/old-marker"
  echo '<?php // sample' > "$w/oldsrc/nextcloud/config/config.sample.php"
  ( cd "$w/oldsrc" && zip -qr "$w/vanilla.zip" nextcloud )
  # the old version has the removed apps (workflowengine always enabled), the new list is the good one
  echo '{"enabled":{"contacts":"8.9.0","dav":"1.0.0","files":"2.4.0","firstrunwizard":"6.0.0","workflowengine":"1.0.0"},"disabled":{"talk":"22.0.0"}}' > "$w/applist-before.json"
  cp "$FIX/applist-ok.json" "$w/applist.json"
  cp "$FIX/resolved.yaml" "$w/resolved.yaml"
  : > "$w/php.log"
  cat > "$w/bin/ncw" <<'STUB'
#!/usr/bin/env bash
[ "$1" = resolve ] || exit 2
cat "$STUB_RESOLVED"
STUB
  cat > "$w/bin/php" <<'STUB'
#!/usr/bin/env bash
echo "php[$PWD] $*" >> "$STUB_DIR/php.log"
case "$1" in
  -r) if [ -n "${SMOKE_SQL:-}" ]; then
        # the MariaDB root statements: the server version decides which isolation variable exists (10.x: tx_isolation, 11.1+: transaction_isolation)
        echo "$SMOKE_SQL" >> "$STUB_DIR/sql.log"
        case "$SMOKE_SQL" in
          *transaction_isolation*) [ "${STUB_MARIADB:-}" != 10 ] || { echo "SQLSTATE[HY000]: General error: 1193 Unknown system variable 'transaction_isolation'" >&2; exit 255; } ;;
          *tx_isolation*) [ "${STUB_MARIADB:-}" != 12 ] || { echo "SQLSTATE[HY000]: General error: 1193 Unknown system variable 'tx_isolation'" >&2; exit 255; } ;;
          *binlog_format*) [ "${STUB_SQL_FAIL:-}" != binlog ] || { echo "SQLSTATE[HY000]: General error: 1227 Access denied; you need SUPER" >&2; exit 255; } ;;
          *"CREATE DATABASE"*) [ "${STUB_SQL_FAIL:-}" != create ] || { echo "SQLSTATE[HY000]: General error: 1044 Access denied" >&2; exit 255; } ;;
        esac
        [ "${STUB_SQL_FAIL:-}" != both ] || case "$SMOKE_SQL" in *isolation*) echo "SQLSTATE[HY000]: General error: 1227 Access denied" >&2; exit 255 ;; esac
        exit 0
      fi
      echo 8.3.0; exit 0 ;;
  -m) printf '%s\n' ctype curl dom fileinfo gd mbstring openssl posix session SimpleXML xmlreader xmlwriter zip zlib pdo_sqlite pdo_mysql libxml filter hash iconv intl; exit 0 ;;
  -d) exec "$REAL_PHP" "$@" ;;
esac
case "$(basename "$1")" in
  occ)
    shift
    case "$1" in
      maintenance:install)
        [ "${STUB_FAIL:-}" = install ] && { echo "install failed: boom" >&2; exit 1; }
        [ -f old-marker ] || { echo "the install must run in the vanilla tree" >&2; exit 1; }
        while [ $# -gt 0 ]; do [ "$1" != --data-dir ] || dd=$2; shift; done
        mkdir -p "$dd"; echo "$dd" > "$STUB_DIR/datadir"; : > "$dd/nextcloud.log"
        mkdir -p config; echo '<?php // kept: instanceid' > config/config.php
        [ -z "${STUB_LOG_LINE:-}" ] || echo "$STUB_LOG_LINE" >> "$dd/nextcloud.log" ;;
      app:list) if [ -f "$STUB_DIR/upgraded" ]; then cat "$STUB_DIR/applist.json"; else cat "$STUB_DIR/applist-before.json"; fi ;;
      status) v='33.0.9.1'; [ ! -f "$STUB_DIR/upgraded" ] || v='33.0.9.1.7'
              echo "{\"installed\":true,\"version\":\"$v\"}" ;;
      app:disable)
        [ -f old-marker ] || { echo "app:disable must run on the OLD tree" >&2; exit 1; }
        echo "$2" >> "$STUB_DIR/disabled.log"
        [ "${STUB_FAIL:-}" != disable ] || { echo "Error: boom" >&2; exit 1; }
        if [ "$2" = workflowengine ]; then echo "workflowengine can't be disabled."; exit 2; fi
        echo "$2 6.0.0 disabled" ;;
      upgrade)
        [ ! -f old-marker ] || { echo "the upgrade ran on the OLD tree" >&2; exit 1; }
        [ -f version.json ] && [ -f config/50-flavor.config.php ] || { echo "the new tree is not in place" >&2; exit 1; }
        grep -q 'kept: instanceid' config/config.php || { echo "config/config.php was not kept" >&2; exit 1; }
        [ "${STUB_FAIL:-}" != upgrade ] || { echo "Update failed" >&2; exit 5; }
        [ "${STUB_FAIL:-}" = noop ] || touch "$STUB_DIR/upgraded"
        [ -z "${STUB_UPGRADE_LOG:-}" ] || echo "$STUB_UPGRADE_LOG" >> "$(cat "$STUB_DIR/datadir")/nextcloud.log"
        echo "Update successful" ;;
      files:scan) echo scanned ;;
      config:system:get) [ ! -f "$STUB_DIR/sysconf/$2" ] || cat "$STUB_DIR/sysconf/$2" ;;
      config:import|config:app:set) echo "occ $*" >> "$STUB_DIR/occ.log" ;;
      *) echo "stub occ: $*" ;;
    esac ;;
  cron.php) echo cron ;;
  ionos-smoke-mail.php) if [ -f "$STUB_DIR/mail.json" ]; then cat "$STUB_DIR/mail.json"; else echo '{"class":"OC\\Mail\\EMailTemplate","html":"<p>mail</p>","text":"mail"}'; fi ;;
  *) echo "stub php: unexpected $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$w/bin/ncw" "$w/bin/php"
}
run_up() { # run_up <world> [VAR=value ...]
  local w="$ROOT/$1"; shift
  local port
  for port in $(seq 28500 28600); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break; done
  rm -rf "${w:?}/tmp" "${w:?}/logs" "${w:?}/upgraded" "${w:?}/disabled.log"
  run "$(basename "$w")-run" env PATH="$w/bin:$PATH" REAL_PHP="$(command -v php)" STUB_DIR="$w" STUB_RESOLVED="$w/resolved.yaml" \
    NCW="$w/bin/ncw" WORK="$w/work" FLAVORS_DIR="$w/flavors" SMOKE_TMP="$w/tmp" SMOKE_LOGS="$w/logs" SMOKE_PORT="$port" VANILLA_ZIP="$w/vanilla.zip" \
    MOCK_DIR="$w/mock" MOCK_PASS=Smoke-Test-Admin-Pw-1 SMOKE_ALLOWLIST="$FIX/allow.txt" SMOKE_SERVER_ARGS="$ROOT/mock/router.php" "$@" \
    bash "$HERE/ionos-smoke-upgrade.sh"
}
sc_upgrade() {
  local w r v
  setup_up u1; w="$ROOT/u1"; run_up u1
  r=u1-run
  check "a healthy upgrade passes the whole test" test "$(status $r)" = 0
  check "the vanilla tree is installed on SQLite with the data dir outside the tree" bash -c "grep -q 'maintenance:install.*--database sqlite' '$w/php.log' && grep -q -- '--data-dir $w/tmp/demo/data' '$w/php.log' && ! grep -q -- '--data-dir $w/tmp/demo/live' '$w/php.log'"
  check "the apps of removed-apps.json that are installed are disabled on the old tree" bash -c "grep -qx firstrunwizard '$w/disabled.log' && grep -qx workflowengine '$w/disabled.log'"
  check "an app that the old version does not have is skipped, not disabled (idempotent)" bash -c "! grep -qx ghostapp '$w/disabled.log' && grep -q 'ghostapp: not enabled on the old version' '$w/logs/demo/disable.log'"
  check "an always-enabled app that occ refuses to disable is noted and left to occ upgrade" bash -c "grep -q 'workflowengine: always enabled on the old version' '$w/logs/demo/disable.log' && grep -qx workflowengine '$w/logs/demo/disable-refused.txt'"
  check "the order is install, disable, upgrade, configure" bash -c "a=\$(grep -n 'maintenance:install' '$w/php.log' | head -1 | cut -d: -f1); b=\$(grep -n 'app:disable' '$w/php.log' | head -1 | cut -d: -f1); c=\$(grep -n ' upgrade' '$w/php.log' | head -1 | cut -d: -f1); d=\$(grep -n 'config:import' '$w/php.log' | head -1 | cut -d: -f1); test \$a -lt \$b -a \$b -lt \$c -a \$c -lt \$d"
  check "ncw-configure.sh ran after the upgrade with the test values of the declared variables" grep -q 'SMTP_PASSWORD=smoke-test-value-smtp-password' "$w/configure.log"
  check "the version is checked: old and new are in the log" said $r "33.0.9.1 -> 33.0.9.1.7"
  check "the probes, cron and the scan ran" bash -c "grep -q 'ok - status' '$ROOT/$r.log' && grep -q cron.php '$w/php.log' && grep -q 'files:scan' '$w/php.log'"
  check "the brand check and the theme probes ran on the upgraded instance" bash -c "grep -q 'brand check and theme probes' '$ROOT/$r.log' && test -f '$w/logs/demo/brand.log' -a -f '$w/logs/demo/brand/pages/login.html'"
  setup_up u1b; run_up u1b MOCK_BRAND=login
  check "a Nextcloud text on the login page fails the upgrade smoke test too" bash -c "test '$(status u1b-run)' != 0 && grep -q 'brand check.*page login: 1 occurrence' '$ROOT/u1b-run.log'"
  check "the logs and timings are kept" test -f "$w/logs/demo/upgrade.log" -a -f "$w/logs/demo/app-list-before.json" -a -f "$w/logs/demo/app-list.json" -a -s "$w/logs/demo/timings.txt"
  check "timings name the phases" bash -c "grep -q '^install vanilla ' '$w/logs/demo/timings.txt' && grep -q '^occ upgrade ' '$w/logs/demo/timings.txt'"
  check "the unpacked trees are removed afterwards" test ! -e "$w/tmp/demo"
  check "the run names the flavor and the verdict" said_re $r "demo: PASSED"

  setup_up u2; run_up u2 STUB_FAIL=upgrade
  check "a failing occ upgrade fails the run" test "$(status u2-run)" != 0
  check "its output is kept and the failure named" bash -c "grep -q 'Update failed' '$ROOT/u2/logs/demo/upgrade.log' && grep -q 'occ upgrade failed' '$ROOT/u2-run.log'"
  setup_up u3; run_up u3 STUB_FAIL=noop
  check "an upgrade that leaves the version alone fails (the build number must show as a version change)" test "$(status u3-run)" != 0
  check "it names the expected version" said_re u3-run "expected '33.0.9.1.7'"
  setup_up u4; run_up u4 STUB_FAIL=disable
  check "an app:disable that fails for another reason fails the run" test "$(status u4-run)" != 0
  check "the upgrade is not run after that" bash -c "! grep -q ' upgrade' '$ROOT/u4/php.log'"
  setup_up u5; run_up u5 STUB_FAIL=install
  check "a failing install of the vanilla release fails the run" test "$(status u5-run)" != 0

  # app states after the upgrade
  setup_up u6; cp "$FIX/applist-removed-enabled.json" "$ROOT/u6/applist.json"; run_up u6
  check "a removed app that is still there after the upgrade fails the run" test "$(status u6-run)" != 0
  check "the removed app is named" said_re u6-run "'firstrunwizard'.*removed"
  setup_up u7; cp "$FIX/applist-missing.json" "$ROOT/u7/applist.json"; run_up u7
  check "an app that vanished in the upgrade fails the run" test "$(status u7-run)" != 0

  # the log check
  setup_up u8; run_up u8 STUB_UPGRADE_LOG="$(jq -cn '{level:1,app:"updater",message:"\\OC\\Updater::incompatibleAppDisabled: Disabled incompatible app: workflowengine"}')"
  check "the incompatible-app line for the always-enabled removed app is accepted" test "$(status u8-run)" = 0
  setup_up u9; run_up u9 STUB_UPGRADE_LOG="$(jq -cn '{level:1,app:"updater",message:"\\OC\\Updater::incompatibleAppDisabled: Disabled incompatible app: contacts"}')"
  check "the same line for another app fails the run" test "$(status u9-run)" != 0
  setup_up u10; run_up u10 STUB_UPGRADE_LOG="$(logline 3 "Real trouble in the upgrade")"
  check "an error entry that the upgrade wrote fails the run" test "$(status u10-run)" != 0
  setup_up u11; run_up u11 STUB_LOG_LINE="$(logline 3 "Could not connect to the lookup server")"
  check "the same allow-list applies (an allow-listed entry passes)" test "$(status u11-run)" = 0

  # the archive is checked before anything is installed
  setup_up u12; echo '{"flavor":"demo"}' > "$ROOT/u12/src/version.json"; rm -f "$ROOT/u12/work/out/"*.zip; ( cd "$ROOT/u12/src" && zip -qr "$ROOT/u12/work/out/ncw-demo-v33.0.9.7.zip" . ); run_up u12
  check "an archive without a build number fails before the install" bash -c "test '$(status u12-run)' != 0 && ! grep -q maintenance:install '$ROOT/u12/php.log'"
  setup_up u13; rm -f "$ROOT/u13/work/out/"*.zip; ( cd "$ROOT/u13/src" && rm removed-apps.json && zip -qr "$ROOT/u13/work/out/ncw-demo-v33.0.9.7.zip" . ); run_up u13
  check "an archive without removed-apps.json fails" test "$(status u13-run)" != 0
  setup_up u14; rm -f "$ROOT/u14/work/out/"*.zip; echo '<?php' > "$ROOT/u14/src/config/config.php"; ( cd "$ROOT/u14/src" && zip -qr "$ROOT/u14/work/out/ncw-demo-v33.0.9.7.zip" . ); run_up u14
  check "an archive that ships its own config/config.php fails (the deployment persists that file)" test "$(status u14-run)" != 0
  setup_up u15; echo '["../evil"]' > "$ROOT/u15/src/removed-apps.json"; rm -f "$ROOT/u15/work/out/"*.zip; ( cd "$ROOT/u15/src" && zip -qr "$ROOT/u15/work/out/ncw-demo-v33.0.9.7.zip" . ); run_up u15
  check "an app id in removed-apps.json that is no app id is refused (never used as a path or option)" bash -c "test '$(status u15-run)' != 0 && ! grep -q 'evil' '$ROOT/u15/php.log'"
  setup_up u16; run_up u16 VANILLA_ZIP="$ROOT/u16/nothing.zip"
  check "a missing vanilla archive fails" test "$(status u16-run)" != 0
  setup_up u17; rm -f "$ROOT/u17/work/out/"*.zip; run_up u17
  check "no archive fails (nothing tested is no pass)" test "$(status u17-run)" != 0

  # the breaks: the run must fail; a pass is itself a failure
  setup_up u18; run_up u18 SMOKE_BREAK=removed-in-shipped
  check "an upgrade break that the test does not catch fails the run (the gate proves nothing)" test "$(status u18-run)" != 0
  check "that failure says the gate did not catch the break" said_re u18-run "did not catch"
  setup_up u19; run_up u19 SMOKE_BREAK=removed-in-shipped STUB_FAIL=upgrade
  check "an upgrade break that is caught still fails the run, and says so" bash -c "test '$(status u19-run)' != 0 && grep -q 'was caught' '$ROOT/u19-run.log'"
  setup_up u20; run_up u20 SMOKE_BREAK=missing-app
  check "a break meant for the fresh-install test is ignored here (the run passes)" test "$(status u20-run)" = 0

  # MariaDB: a database per flavor through the root account, the install with the mysql driver
  setup_up u21; run_up u21 SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke SMOKE_DB_PASS=pw SMOKE_DB_ROOT_PASS=rootpw SMOKE_DB_PORT=3307
  check "the MariaDB run passes" test "$(status u21-run)" = 0
  check "the install uses the mysql driver, the host and port, and a database of its own" grep -q 'maintenance:install.*--database mysql --database-host 127.0.0.1:3307 --database-name ncw_demo --database-user ncw_smoke' "$ROOT/u21/php.log"
  check "the database is prepared as root (isolation, binlog, drop, create, grant: five statements)" bash -c "test \$(grep -c '^php\[[^]]*\] -r' '$ROOT/u21/php.log') -ge 5"
  check "the MariaDB run is labelled as such" bash -c "grep -q 'upgrade smoke test (mariadb)' '$ROOT/u21-run.log'"
  for v in 10 12; do
    setup_up u21v$v; run_up u21v$v SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke SMOKE_DB_PASS=pw SMOKE_DB_ROOT_PASS=rootpw STUB_MARIADB=$v
    check "MariaDB $v.x (unknown-variable error 1193 for one of the two names): the run passes" test "$(status u21v$v-run)" = 0
    check "MariaDB $v.x: READ-COMMITTED was set with the name the server knows" bash -c "grep -q \"SET GLOBAL $([ $v = 10 ] && echo tx_isolation || echo transaction_isolation) = 'READ-COMMITTED'\" '$ROOT/u21v$v/sql.log'"
  done
  setup_up u21b; run_up u21b SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke SMOKE_DB_PASS=pw SMOKE_DB_ROOT_PASS=rootpw STUB_SQL_FAIL=both
  check "MariaDB: an error other than 1193 on the isolation level fails the run with the server's message" bash -c "test '$(status u21b-run)' != 0 && grep -q 'Access denied' '$ROOT/u21b-run.log'"
  setup_up u21c; run_up u21c SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke SMOKE_DB_PASS=pw SMOKE_DB_ROOT_PASS=rootpw STUB_SQL_FAIL=binlog
  check "MariaDB: binlog_format is best effort (the image runs without a binary log): a refusal does not fail the run" test "$(status u21c-run)" = 0
  setup_up u21d; run_up u21d SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke SMOKE_DB_PASS=pw SMOKE_DB_ROOT_PASS=rootpw STUB_SQL_FAIL=create
  check "MariaDB: a failing CREATE DATABASE fails the run" test "$(status u21d-run)" != 0
  setup_up u22; run_up u22 SMOKE_DB=mariadb SMOKE_DB_USER=ncw_smoke
  check "MariaDB without the other credentials fails" test "$(status u22-run)" != 0
  setup_up u23; run_up u23 SMOKE_DB=postgres
  check "an unknown database fails" test "$(status u23-run)" != 0
}

# ---------------------------------------------------------------- scenario: gate (needs/if logic in front of publish)
gate() { # gate <name> <expected status 0|1> <description> VAR=value...
  local n=$1 want=$2 d=$3; shift 3
  run "$n" env -i PATH="$PATH" "$@" bash "$HERE/ionos-build-gate.sh"
  if [ "$want" = 0 ]; then check "$d" test "$(status "$n")" = 0; else check "$d" test "$(status "$n")" != 0; fi
}
sc_gate() {
  local all=(BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=success UPGRADE_SQLITE_RESULT=success)
  gate g1 0 "release, everything succeeded: publish" "${all[@]}" KIND=release UPGRADE_MARIADB_RESULT=success
  gate g2 0 "dev, MariaDB job skipped: a skipped job is not a failure for a dev build" "${all[@]}" KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g3 0 "dev, MariaDB job ran and succeeded" "${all[@]}" KIND=dev UPGRADE_MARIADB_RESULT=success
  gate g4 1 "release, MariaDB job skipped: blocks (a release must have run on MariaDB)" "${all[@]}" KIND=release UPGRADE_MARIADB_RESULT=skipped
  gate g5 1 "release, MariaDB job failed: blocks" "${all[@]}" KIND=release UPGRADE_MARIADB_RESULT=failure
  gate g6 1 "dev, MariaDB job failed: blocks" "${all[@]}" KIND=dev UPGRADE_MARIADB_RESULT=failure
  gate g7 1 "dev, MariaDB job cancelled: blocks" "${all[@]}" KIND=dev UPGRADE_MARIADB_RESULT=cancelled
  gate g8 1 "release, MariaDB job cancelled: blocks" "${all[@]}" KIND=release UPGRADE_MARIADB_RESULT=cancelled
  gate g9 1 "SQLite upgrade failed: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=success UPGRADE_SQLITE_RESULT=failure KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g10 1 "SQLite upgrade skipped: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=success UPGRADE_SQLITE_RESULT=skipped KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g11 1 "SQLite upgrade cancelled: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=success UPGRADE_SQLITE_RESULT=cancelled KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g12 1 "fresh-install smoke failed: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=failure UPGRADE_SQLITE_RESULT=success KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g13 1 "fresh-install smoke skipped: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=skipped UPGRADE_SQLITE_RESULT=success KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g14 1 "build failed: blocks" BUILD=true PLAN_RESULT=success BUILD_RESULT=failure SMOKE_RESULT=skipped UPGRADE_SQLITE_RESULT=skipped KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g15 1 "plan failed: blocks" BUILD= PLAN_RESULT=failure BUILD_RESULT=skipped SMOKE_RESULT=skipped UPGRADE_SQLITE_RESULT=skipped KIND= UPGRADE_MARIADB_RESULT=skipped
  gate g16 0 "nothing to build (scheduled, no change): every later job skipped, the gate passes" BUILD=false PLAN_RESULT=success BUILD_RESULT=skipped SMOKE_RESULT=skipped UPGRADE_SQLITE_RESULT=skipped KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g17 1 "nothing to build but a later job ran: inconsistent, blocks" BUILD=false PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=skipped UPGRADE_SQLITE_RESULT=skipped KIND=dev UPGRADE_MARIADB_RESULT=skipped
  gate g18 1 "an unknown result value blocks" "${all[@]}" KIND=dev UPGRADE_MARIADB_RESULT=weird
  gate g19 1 "a missing result blocks" "${all[@]}" KIND=release
  gate g20 1 "an unknown build kind blocks" "${all[@]}" KIND=hotfix UPGRADE_MARIADB_RESULT=success
  gate g21 1 "a missing plan output blocks" PLAN_RESULT=success BUILD_RESULT=success SMOKE_RESULT=success UPGRADE_SQLITE_RESULT=success KIND=dev UPGRADE_MARIADB_RESULT=success

  # the workflow wires it up the way the script assumes (read from the YAML)
  local wf="$HERE/../workflows/ionos-build.yml" needs_publish needs_gate all got
  needs_publish=$(awk '/^  publish:$/ {f=1} f && /^    needs:/ {print; exit}' "$wf")
  needs_gate=$(awk '/^  gate:$/ {f=1} f && /^    needs:/ {print; exit}' "$wf" | sed 's/^    needs: *//; s/[][,]/ /g')
  check "workflow: publish needs the gate (and so skips when it fails)" grep -q '\bgate\b' <<<"$needs_publish"
  check "workflow: publish has a condition with a status function (a skipped job anywhere upstream, the MariaDB job on dev builds, skips a job without one) and names the results it needs" bash -c "awk '/^  publish:\$/,0' '$wf' | sed -n '1,30p' | grep -E '^    if:' | grep -qE '!cancelled\(\)|always\(\)' && awk '/^  publish:\$/,0' '$wf' | sed -n '1,30p' | grep -E '^    if:' | grep -q \"needs.gate.result == 'success'\" && awk '/^  publish:\$/,0' '$wf' | sed -n '1,30p' | grep -E '^    if:' | grep -q \"needs.build.result == 'success'\" && awk '/^  publish:\$/,0' '$wf' | sed -n '1,30p' | grep -E '^    if:' | grep -q \"needs.plan.result == 'success'\""
  check "workflow: publish does not need a test job directly (the gate decides)" bash -c "! grep -qE 'smoke|upgrade' <<<'$needs_publish'"
  all=$(grep -E '^  [a-z][a-z-]*:$' "$wf" | sed 's/[ :]//g' | grep -vxE 'gate|publish|schedule' | sort | tr '\n' ' ')
  got=$(tr ' ' '\n' <<<"$needs_gate" | grep . | sort | tr '\n' ' ')
  check "workflow: the gate needs every other job except publish (a new job must be added to it): $got" test "$all" = "$got"
  check "workflow: the gate runs always (a skipped need must not skip it)" bash -c "awk '/^  gate:\$/,/^  publish:\$/' '$wf' | grep -q 'if: \${{ always() }}'"
  check "workflow: the gate gets every result through env, never inside run" bash -c "awk '/^  gate:\$/,/^  publish:\$/' '$wf' | grep -q 'UPGRADE_MARIADB_RESULT: \${{ needs.upgrade-smoke-mariadb.result }}' && ! awk '/^  gate:\$/,/^  publish:\$/' '$wf' | grep -E '^ +run:' | grep -q '\${{'"
  check "workflow: the MariaDB job runs for release builds only" bash -c "awk '/^  upgrade-smoke-mariadb:\$/,/^  gate:\$/' '$wf' | grep -q \"if: needs.plan.outputs.build == 'true' && needs.plan.outputs.kind == 'release'\""
  check "workflow: the SQLite job runs for every build" bash -c "awk '/^  upgrade-smoke-sqlite:\$/,/^  upgrade-smoke-mariadb:\$/' '$wf' | grep -q \"if: needs.plan.outputs.build == 'true'\$\""
  check "workflow: the upgrade jobs have read-only permissions" bash -c "awk '/^  upgrade-smoke-sqlite:\$/,/^  gate:\$/' '$wf' | grep -A1 'permissions:' | grep -c 'contents: read' | grep -qx 2 && ! awk '/^  upgrade-smoke-sqlite:\$/,/^  gate:\$/' '$wf' | grep -q 'write'"
  check "workflow: both upgrade jobs keep their logs with if: always()" test "$(awk '/^  upgrade-smoke-sqlite:$/,/^  gate:$/' "$wf" | grep -c -A1 'if: always()')" -ge 2
  check "workflow: only GitHub-owned actions, all pinned by a full commit sha" bash -c "! grep -E '^ +uses:' '$wf' | grep -vE 'uses: actions/[a-z/-]+@[0-9a-f]{40} # v'"
  check "workflow: the MariaDB image is pinned by digest, in one place, with a repository variable override" bash -c "test \$(grep -c 'mariadb:[0-9.]*@sha256:[0-9a-f]\{64\}' '$wf') = 1 && grep -q 'vars.IONOS_MARIADB_IMAGE' '$wf'"
  check "workflow: smoke_break lists the upgrade modes" bash -c "grep -q 'options: \[none, missing-app, extra-app, wrong-mode, skip-enable, brand, removed-in-shipped, no-buildnumber\]' '$wf'"
  check "workflow: no expression inside any run block" bash -c "! awk '/^ +run: \\|\$/ {f=1; next} /^ +run: / {print; next} f && /^      [^ ]/ {f=0} f {print}' '$wf' | grep -q '\${{'"
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
$theme = getenv('MOCK_THEME') ?: '';
$brand = getenv('MOCK_BRAND') ?: '';
$state = fn(string $id, string $value) => '<input type="hidden" id="initial-state-' . $id . '" value="' . base64_encode($value) . '">';
$page = fn(string $t, string $extra = '') => print("<html><head data-requesttoken=\"tok123\"></head><body" . ($theme !== '' && $fail !== 'notheme' ? " data-theme-$theme" : '') . ">$t $extra" . ($brand === $t ? ' Welcome to Nextcloud ' : '') . str_repeat('x', 400) . "</body></html>");
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
} elseif (preg_match('#^/index\.php/apps/theming/theme/([a-z0-9-]+)\.css$#', $uri, $m)) {
    if ($fail === 'css') { http_response_code(404); echo '<!DOCTYPE html>'; return; }
    header('Content-Type: text/css');
    echo $fail === 'cssbody' ? 'body { color: red }' : "[data-theme-{$m[1]}] { --color-primary:#123456; }";
} elseif (in_array($uri, ['/index.php/apps/files/', '/index.php/settings/admin', '/index.php/settings/admin/overview', '/index.php/settings/user', '/index.php/settings/user/theming', '/index.php/settings/admin/theming'], true)) {
    if (!$session) { http_response_code(401); echo 'login required'; return; }
    $key = ['/index.php/apps/files/' => 'files', '/index.php/settings/admin' => 'settings', '/index.php/settings/admin/overview' => 'overview',
        '/index.php/settings/user' => 'personal', '/index.php/settings/user/theming' => 'user-theming', '/index.php/settings/admin/theming' => 'admin-theming'][$uri];
    if ($fail === $key) { http_response_code(500); echo 'Internal Server Error'; return; }
    $extra = '';
    if ($key === 'user-theming') {
        $listed = getenv('MOCK_THEMES') ?: ($theme !== '' ? json_encode([['id' => $theme]]) : '[]');
        $extra = $state('theming-themes', $listed) . $state('theming-isUserThemingDisabled', getenv('MOCK_USER_THEMING') === 'on' ? 'false' : 'true');
    }
    if ($key === 'admin-theming') { $extra = $state('theming-adminThemingInfo', json_encode(['isThemeable' => getenv('MOCK_ADMIN_THEMEABLE') === '1'])); }
    $page($key, $extra);
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
  # a stand-in for the generated ncw-configure.sh: it records that it ran, with which variables, and calls occ like the real one
  cat > "$w/src/ncw-configure.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "configure: SMTP_PASSWORD=${SMTP_PASSWORD:-} cwd=$PWD" >> "$STUB_DIR/configure.log"
[ "${STUB_FAIL:-}" != configure ] || { echo "ncw-configure: boom" >&2; exit 1; }
"${PHP:-php}" "$(dirname "${BASH_SOURCE[0]}")/occ" config:import x
SCRIPT
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
      config:system:get) [ ! -f "$STUB_DIR/sysconf/$2" ] || cat "$STUB_DIR/sysconf/$2" ;;
      config:import|config:app:set) echo "occ $*" >> "$STUB_DIR/occ.log" ;;
      *) echo "stub occ: $*" ;;
    esac ;;
  cron.php) [ "${STUB_FAIL:-}" = cron ] && exit 1; echo cron ;;
  ionos-smoke-mail.php) if [ -f "$STUB_DIR/mail.json" ]; then cat "$STUB_DIR/mail.json"; else echo '{"class":"OC\\Mail\\EMailTemplate","html":"<p>mail</p>","text":"mail"}'; fi ;;
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
  check "ncw-configure.sh of the archive ran (as bash <script>) after the install, with the test values of the declared variables" bash -c "grep -q 'SMTP_PASSWORD=smoke-test-value-smtp-password' '$w/configure.log' && test \"\$(grep -n 'maintenance:install' '$w/php.log' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'config:import' '$w/php.log' | head -1 | cut -d: -f1)\""
  check "it ran with the archive's own occ (not the smoke test's own import)" grep -q '^occ config:import x' "$w/occ.log"
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

  setup_run r21; run_smoke r21 MOCK_BRAND=login
  check "a Nextcloud text on the login page fails the whole smoke run" test "$(status r21-run)" != 0
  check "the failure is named as the brand check and the page is shown" said_re r21-run "brand check.*page login: 1 occurrence"
  check "the brand logs are kept (brand.log and the pages)" test -f "$ROOT/r21/logs/demo/brand.log" -a -f "$ROOT/r21/logs/demo/brand/pages/login.html"
  check "a healthy run also keeps them" test -f "$ROOT/r1/logs/demo/brand.log" -a -f "$ROOT/r1/logs/demo/brand/pages/mail-html.html"
  setup_run r17; run_smoke r17 STUB_FAIL=configure
  check "a failing ncw-configure.sh fails the run" test "$(status r17-run)" != 0
  check "its message is shown" said r17-run "ncw-configure: boom"
  setup_run r18; rm -f "$ROOT/r18/src/ncw-configure.sh"; rm -f "$ROOT/r18/work/out/"*.zip
  ( cd "$ROOT/r18/src" && rm -f ncw-configure.sh && zip -qr "$ROOT/r18/work/out/ncw-demo-v33.0.9.7.zip" . ); run_smoke r18
  check "an archive without ncw-configure.sh fails the run and says so" bash -c "test '$(status r18-run)' != 0 && grep -q 'ncw-configure.sh' '$ROOT/r18-run.log'"
  check "the install is not even started without the script" bash -c "! grep -q maintenance:install '$ROOT/r18/php.log'"
  setup_run r19; sed 's/^app_folders:/enable_after_install:\n  - talk\napp_folders:/' "$FIX/resolved.yaml" > "$ROOT/r19/resolved.yaml"
  cp "$FIX/applist-talk-enabled.json" "$ROOT/r19/applist.json"; run_smoke r19
  check "the expected states include the enable_after_install apps (enabled passes)" test "$(status r19-run)" = 0
  setup_run r20; sed 's/^app_folders:/enable_after_install:\n  - talk\napp_folders:/' "$FIX/resolved.yaml" > "$ROOT/r20/resolved.yaml"; run_smoke r20
  check "an enable_after_install app that stays disabled fails the run" test "$(status r20-run)" != 0
  check "and the failure says it must be enabled" said_re r20-run "'talk'.*must be enabled"

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

ALL="apps logs break brand brand_run probes run apps_upgrade logs_expected break_upgrade vanilla upgrade gate"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
mock_stop
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
