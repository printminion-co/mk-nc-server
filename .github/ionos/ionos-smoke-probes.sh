#!/usr/bin/env bash
# HTTP probes of a freshly installed instance (07-validation.md): status.php, the login page, OCS capabilities,
# a WebDAV listing, an upload and a download with a content compare, then (with a session from the login form)
# the files page, the admin settings and the admin overview. Every probe runs; each prints "ok - <name>" or
# "FAIL - <name>: <why>"; the exit status is 1 when one failed. The answers are kept in the output folder.
#   ionos-smoke-probes.sh <base url> <output folder>
# Environment: SMOKE_ADMIN_USER, SMOKE_ADMIN_PASS (the admin of the test instance).
# Paths use /index.php/..., /remote.php/... and /ocs/v2.php/..., which works without a router on `php -S`.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

[ $# -eq 2 ] || die "usage: ionos-smoke-probes.sh <base url> <output folder>"
BASE=${1%/}
OUT=$2
USER_NAME=${SMOKE_ADMIN_USER:?SMOKE_ADMIN_USER is required}
PASS=${SMOKE_ADMIN_PASS:?SMOKE_ADMIN_PASS is required}
mkdir -p "$OUT"
JAR="$OUT/cookies.txt"
: > "$JAR"
failed=0

pass() { echo "ok - $1"; }
miss() { echo "::error::${LOG_PREFIX}: FAIL - $1: $2"; failed=$((failed + 1)); }

# req <output file> <curl args...>: runs curl, prints the HTTP status code (000 when curl itself failed).
req() {
  local out=$1; shift
  curl -sS --max-time 120 -o "$out" -w '%{http_code}' "$@" 2>>"$OUT/curl-errors.log" || true
}
# expect <name> <wanted codes, space separated> <got>: pass or fail on the status code
expect() {
  case " $2 " in
    *" $3 "*) return 0 ;;
    *) miss "$1" "HTTP $3, wanted $2"; return 1 ;;
  esac
}
auth=(-u "$USER_NAME:$PASS")

# 1. status.php
code=$(req "$OUT/status.json" "$BASE/status.php")
if expect "status" 200 "$code"; then
  if jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' "$OUT/status.json" >/dev/null 2>&1; then
    pass "status ($(jq -r '.version' "$OUT/status.json"))"
  else miss "status" "status.php does not say installed, not in maintenance and no upgrade needed: $(head -c 200 "$OUT/status.json")"; fi
fi

# 2. login page, and the request token for the form
code=$(req "$OUT/login-page.html" -c "$JAR" -b "$JAR" "$BASE/index.php/login")
token=""
if expect "login page" 200 "$code"; then
  token=$(grep -o 'data-requesttoken="[^"]*"' "$OUT/login-page.html" | head -n1 | sed 's/^data-requesttoken="//; s/"$//' || true)
  if [ -n "$token" ]; then pass "login page"; else miss "login page" "no request token in the page"; fi
fi

# 3. OCS capabilities (basic auth)
code=$(req "$OUT/capabilities.json" "${auth[@]}" -H 'OCS-APIRequest: true' "$BASE/ocs/v2.php/cloud/capabilities?format=json")
if expect "capabilities" 200 "$code"; then
  if jq -e '.ocs.meta.statuscode == 200 and (.ocs.data.capabilities.core | type == "object")' "$OUT/capabilities.json" >/dev/null 2>&1; then
    pass "capabilities"
  else miss "capabilities" "OCS answer is not status 200 with core capabilities: $(head -c 200 "$OUT/capabilities.json")"; fi
fi

# 4. WebDAV listing
code=$(req "$OUT/propfind.xml" "${auth[@]}" -X PROPFIND -H 'Depth: 1' "$BASE/remote.php/dav/files/$USER_NAME/")
if expect "dav list" 207 "$code"; then
  if grep -qi 'multistatus' "$OUT/propfind.xml"; then pass "dav list"; else miss "dav list" "no multistatus in the answer"; fi
fi

# 5. upload and download, compare the content
name="ionos-smoke-$$.txt"
head -c 3000 /dev/urandom | base64 > "$OUT/upload.txt"
code=$(req "$OUT/put.out" "${auth[@]}" -T "$OUT/upload.txt" "$BASE/remote.php/dav/files/$USER_NAME/$name")
if expect "upload" "201 204" "$code"; then
  pass "upload"
  code=$(req "$OUT/download.txt" "${auth[@]}" "$BASE/remote.php/dav/files/$USER_NAME/$name")
  if expect "download" 200 "$code"; then
    if cmp -s "$OUT/upload.txt" "$OUT/download.txt"; then pass "download (content equals the upload)"
    else miss "download" "the downloaded content differs from the upload"; fi
  fi
  req "$OUT/delete.out" "${auth[@]}" -X DELETE "$BASE/remote.php/dav/files/$USER_NAME/$name" >/dev/null
fi

# 6. a session through the login form (the pages need one)
session=false
if [ -n "$token" ]; then
  code=$(curl -sS --max-time 120 -o "$OUT/login-post.html" -w '%{http_code} %{redirect_url}' -c "$JAR" -b "$JAR" -H "Origin: $BASE" \
    --data-urlencode "user=$USER_NAME" --data-urlencode "password=$PASS" --data-urlencode "requesttoken=$token" \
    --data-urlencode timezone=UTC --data-urlencode timezone_offset=0 "$BASE/index.php/login" 2>>"$OUT/curl-errors.log" || true)
  case "$code" in
    30[123]\ *"/login"*) miss "login session" "the login form sent us back to the login page (HTTP $code)" ;;
    30[123]\ *) session=true; pass "login session" ;;
    *) miss "login session" "HTTP $code, wanted a redirect" ;;
  esac
else
  miss "login session" "skipped: no request token"
fi

# 7. pages (need the session): the files page and the admin settings and overview
page() { # page <name> <path> <file>
  local c
  if [ "$session" != true ]; then miss "$1" "skipped: no session"; return; fi
  c=$(req "$OUT/$3" -c "$JAR" -b "$JAR" -L "$BASE$2")
  if expect "$1" 200 "$c"; then
    if grep -q 'data-requesttoken' "$OUT/$3" && ! grep -qi 'Internal Server Error' "$OUT/$3"; then pass "$1"
    else miss "$1" "the answer is not a regular Nextcloud page"; fi
  fi
}
page "files page" /index.php/apps/files/ files-page.html
page "admin settings" /index.php/settings/admin admin-settings.html
page "admin overview" /index.php/settings/admin/overview admin-overview.html

rm -f "$JAR"
if [ "$failed" -gt 0 ]; then echo "${LOG_PREFIX}: probes: $failed failed" >&2; exit 1; fi
log "all probes passed"
