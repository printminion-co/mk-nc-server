#!/usr/bin/env bash
# Compares the app states of an installed instance with the RESOLVED flavor. No flavor specific code: the
# expectation is whatever `ncw resolve` printed.
#   ionos-smoke-apps.sh <app-list.json> <resolved.yaml> [<app-list-before.json>]
# <app-list.json> is the output of `occ app:list --output=json_pretty`: {"enabled": {id: version}, "disabled": {id: version}}.
# Rules (07-validation.md): `always` and `default` apps are enabled, `available` apps are present but disabled
# unless the flavor lists them in `enable_after_install` (ncw-configure.sh enables those, so they must be enabled),
# `removed` apps are absent, and an app that the flavor does not list at all is an error (the app list of a flavor
# is a complete allowlist). Every problem is reported, naming the app; the exit status is 1 when there is one.
#
# After an UPGRADE (the third argument: the app list of the old version before anything was changed) the rules
# follow the deployment contract (05-deployment.md): `default` and `available` only decide fresh installs, on an
# existing instance only `always` and `removed` change a state. So an app that the old version had keeps the state it
# had (enabled stays enabled, disabled stays disabled, whatever the mode says), except that `always` must be enabled,
# `removed` must be absent and an enable_after_install app must be enabled; an app that is new on the instance is
# judged by the fresh-install rules.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then die "usage: ionos-smoke-apps.sh <app-list.json> <resolved.yaml> [<app-list-before.json>]"; fi
LIST=$1
RESOLVED=$2
BEFORE=${3:-}
[ -f "$LIST" ] || die "no app list at $LIST"
[ -f "$RESOLVED" ] || die "no resolved flavor at $RESOLVED"
jq -e '(.enabled | type == "object") and (.disabled | type == "object")' "$LIST" >/dev/null 2>&1 \
  || die "$LIST is not the JSON of 'occ app:list' (an object with enabled and disabled)"

if [ -n "$BEFORE" ]; then
  [ -f "$BEFORE" ] || die "no app list of the old version at $BEFORE"
  jq -e '(.enabled | type == "object") and (.disabled | type == "object")' "$BEFORE" >/dev/null 2>&1 \
    || die "$BEFORE is not the JSON of 'occ app:list' (an object with enabled and disabled)"
fi

declare -A mode=() state=() after=() was=()
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
if [ -n "$BEFORE" ]; then
  while read -r id; do was[$id]=enabled; done < <(jq -r '.enabled | keys[]' "$BEFORE")
  while read -r id; do was[$id]=disabled; done < <(jq -r '.disabled | keys[]' "$BEFORE")
fi

problems=0
fail() { echo "::error::${LOG_PREFIX}: $*"; problems=$((problems + 1)); }

for id in $(printf '%s\n' "${!mode[@]}" | sort); do
  m=${mode[$id]}
  s=${state[$id]:-absent}
  # an app of the old version keeps its state in an upgrade, apart from the modes that change a state
  if [ -n "$BEFORE" ] && [ -n "${was[$id]:-}" ] && { [ "$m" = default ] || [ "$m" = available ]; } && [ -z "${after[$id]:-}" ]; then
    case "$s" in
      "${was[$id]}") ;;
      absent) fail "app '$id' has mode $m and was ${was[$id]} before the upgrade, but it is not in the app list now: it is missing from the archive" ;;
      *) fail "app '$id' has mode $m and was ${was[$id]} before the upgrade: an upgrade must keep that state, but it is $s now" ;;
    esac
    continue
  fi
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
