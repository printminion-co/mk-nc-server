#!/usr/bin/env bash
# Compares the app states of an installed instance with the RESOLVED flavor. No flavor specific code: the
# expectation is whatever `ncw resolve` printed.
#   ionos-smoke-apps.sh <app-list.json> <resolved.yaml>
# <app-list.json> is the output of `occ app:list --output=json_pretty`: {"enabled": {id: version}, "disabled": {id: version}}.
# Rules (07-validation.md): `always` and `default` apps are enabled, `available` apps are present but disabled
# unless the flavor lists them in `enable_after_install` (ncw-configure.sh enables those, so they must be enabled),
# `removed` apps are absent, and an app that the flavor does not list at all is an error (the app list of a flavor
# is a complete allowlist). Every problem is reported, naming the app; the exit status is 1 when there is one.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

[ $# -eq 2 ] || die "usage: ionos-smoke-apps.sh <app-list.json> <resolved.yaml>"
LIST=$1
RESOLVED=$2
[ -f "$LIST" ] || die "no app list at $LIST"
[ -f "$RESOLVED" ] || die "no resolved flavor at $RESOLVED"
jq -e '(.enabled | type == "object") and (.disabled | type == "object")' "$LIST" >/dev/null 2>&1 \
  || die "$LIST is not the JSON of 'occ app:list' (an object with enabled and disabled)"

declare -A mode=() state=() after=()
while read -r id m; do
  [ -n "$id" ] || continue
  mode[$id]=$m
done < <(resolved_apps "$RESOLVED")
while read -r id; do
  [ -n "$id" ] || continue
  after[$id]=1
done < <(resolved_enable_after_install "$RESOLVED")
[ ${#mode[@]} -gt 0 ] || die "the resolved flavor $RESOLVED lists no apps: nothing to compare"
while read -r id; do state[$id]=enabled; done < <(jq -r '.enabled | keys[]' "$LIST")
while read -r id; do state[$id]=disabled; done < <(jq -r '.disabled | keys[]' "$LIST")

problems=0
fail() { echo "::error::${LOG_PREFIX}: $*"; problems=$((problems + 1)); }

for id in $(printf '%s\n' "${!mode[@]}" | sort); do
  m=${mode[$id]}
  s=${state[$id]:-absent}
  case "$m" in
    always|default)
      case "$s" in
        enabled) ;;
        disabled) fail "app '$id' has mode $m and must be enabled after a fresh install, but it is disabled" ;;
        absent)   fail "app '$id' has mode $m but is not in the app list: it is missing from the archive" ;;
      esac ;;
    available)
      case "$s" in
        disabled)
          [ -z "${after[$id]:-}" ] || fail "app '$id' has mode available and is listed in enable_after_install: it must be enabled after ncw-configure.sh has run, but it is disabled" ;;
        enabled)
          [ -n "${after[$id]:-}" ] || fail "app '$id' has mode available and must be disabled after a fresh install, but it is enabled" ;;
        absent)   fail "app '$id' has mode available but is not in the app list: it is missing from the archive" ;;
      esac ;;
    removed)
      [ "$s" = absent ] || fail "app '$id' has mode removed but is present ($s)" ;;
    *) fail "app '$id' has the unknown mode '$m' in the resolved flavor" ;;
  esac
done
for id in $(printf '%s\n' "${!state[@]}" | sort); do
  [ -n "${mode[$id]:-}" ] || fail "app '$id' is ${state[$id]} but is not in the resolved flavor (an extra app in the archive)"
done

if [ "$problems" -gt 0 ]; then
  echo "${LOG_PREFIX}: app states: $problems problem(s)" >&2
  exit 1
fi
log "app states match the resolved flavor (${#mode[@]} apps in the flavor, ${#state[@]} in the app list)"
