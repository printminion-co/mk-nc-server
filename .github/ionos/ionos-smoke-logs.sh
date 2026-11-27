#!/usr/bin/env bash
# Checks nextcloud.log of a fresh install (every entry is new).
#   ionos-smoke-logs.sh <nextcloud.log> <allowlist file> [<expected incompatible apps file>]
# Fails on
#   - any line with "Disabled incompatible app", whatever its level and whatever the allow-list says, and
#   - any entry at level 3 (error) or higher whose message does not match an entry of the allow-list.
# A line that is not JSON counts as an entry at level error (its raw text is its message). The allow-list has one
# extended regular expression per line (grep -E, applied to the message); empty lines and lines starting with #
# are ignored; an entry that is blank or not a valid expression fails the check (a blank one would allow everything).
# The optional third argument is for the upgrade smoke test only: a file with one app id per line, the apps of
# removed-apps.json that occ refuses to disable on the old version (always-enabled core apps such as workflowengine).
# `occ upgrade` takes those out itself and logs exactly "Disabled incompatible app: <id>" (at level info) for each
# one; that line, for exactly those ids, is accepted. Any other app, or any other wording, still fails.
# A log file that does not exist counts as no entries (a clean install may write none).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then die "usage: ionos-smoke-logs.sh <nextcloud.log> <allowlist file> [<expected incompatible apps file>]"; fi
LOG=$1
ALLOW=$2
EXPECTED=${3:-}
expected=()
if [ -n "$EXPECTED" ]; then
  [ -f "$EXPECTED" ] || die "no file of expected incompatible apps at $EXPECTED"
  while IFS= read -r id || [ -n "$id" ]; do
    [ -z "$id" ] || { [[ $id =~ ^[a-z0-9_]+$ ]] || die "$EXPECTED lists '$id', which is no app id"; expected+=("$id"); }
  done < "$EXPECTED"
fi
[ -f "$ALLOW" ] || die "no allow-list at $ALLOW"

patterns=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  [[ $line =~ ^[[:space:]]*# ]] && continue
  [ -n "$line" ] || continue
  [[ $line =~ [^[:space:]] ]] || die "$ALLOW line $n is blank: it would allow every message"
  rc=0; grep -Eq -e "$line" <<<"" || rc=$?
  [ "$rc" -le 1 ] || die "$ALLOW line $n is not a valid regular expression: $line"
  patterns+=("$line")
done < "$ALLOW"

if [ ! -f "$LOG" ]; then
  log "no log file at $LOG: no entries"
  exit 0
fi

problems=0
if grep -F -q 'Disabled incompatible app' "$LOG"; then
  while IFS= read -r l; do
    msg=$(jq -r '(.message? // "") | tostring' <<<"$l" 2>/dev/null || true)
    hit=false
    for id in "${expected[@]}"; do
      [ "$msg" = "\\OC\\Updater::incompatibleAppDisabled: Disabled incompatible app: $id" ] && hit=true
    done
    if [ "$hit" = true ]; then
      log "an expected app was disabled as incompatible by occ upgrade (it is removed from the flavor): ${msg##*: }"
      continue
    fi
    echo "::error::${LOG_PREFIX}: an app was disabled as incompatible (never allowed): ${l:0:400}"
    problems=$((problems + 1))
  done < <(grep -F 'Disabled incompatible app' "$LOG")
fi

entries=0
allowed=0
# one compact JSON object per entry at level 3 or higher; level 99 marks a line that is not JSON
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  entries=$((entries + 1))
  msg=$(jq -r '.m' <<<"$entry")
  hit=false
  for re in "${patterns[@]}"; do
    if grep -Eq -e "$re" <<<"$msg"; then hit=true; break; fi
  done
  if [ "$hit" = true ]; then
    allowed=$((allowed + 1))
    continue
  fi
  echo "::error::${LOG_PREFIX}: log entry at level $(jq -r '.l' <<<"$entry") (app $(jq -r '.a' <<<"$entry")) is not on the allow-list: ${msg:0:600}"
  problems=$((problems + 1))
done < <(jq -Rc '(try fromjson catch null) as $j
    | if ($j | type) == "object"
      then {l: (($j.level // 0) | tonumber? // 0), a: ($j.app // "-"), m: (($j.message // "") | tostring)}
      else {l: 99, a: "-", m: .} end
    | select(.l >= 3)' "$LOG")

if [ "$problems" -gt 0 ]; then
  echo "${LOG_PREFIX}: log check: $problems problem(s)" >&2
  exit 1
fi
log "log check passed ($entries entries at error level or higher, $allowed on the allow-list)"
