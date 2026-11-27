#!/usr/bin/env bash
# Tampers with a downloaded flavor archive so that the fresh-install smoke test MUST fail: it proves the gate in a
# real run (workflow input smoke_break). It only ever edits the copy the smoke job downloaded; the publish job
# downloads its own, untouched copy.
#   ionos-smoke-break.sh <mode> <archive.zip>...   (every archive is tampered with the same way)
# Modes:
#   none          do nothing
#   missing-app   delete the folder of one app that a fresh install enables, so the app is missing
#   extra-app     add a valid app folder apps/ionos_smoke_extra that the flavor does not list
#   wrong-mode    take one default app out of defaultEnabled in core/shipped.json, so it is installed disabled
#   skip-enable   empty the ENABLE_APPS list of ncw-configure.sh, so the apps of enable_after_install stay disabled
# The app is the last entry of defaultEnabled (sorted) whose folder is in the archive; no flavor is named here.
# App ids are only used when they are plain ([a-z0-9_]), never as a zip pattern.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke-break
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

[ $# -ge 2 ] || die "usage: ionos-smoke-break.sh <none|missing-app|extra-app|wrong-mode|skip-enable> <archive.zip>..."
MODE=$1
shift
case "$MODE" in none|missing-app|extra-app|wrong-mode|skip-enable) ;; *) die "unknown mode '$MODE'" ;; esac
for a in "$@"; do [ -f "$a" ] || die "no archive at $a"; done
[ "$MODE" != none ] || { log "mode none: the archives are left as they are"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The folder of the app <id> in the archive: <app folder>/<id>, found by its appinfo/info.xml.
app_folder() {
  grep -E "^[A-Za-z0-9._-]+/$1/appinfo/info\.xml\$" "$TMP/list" | head -n1 | sed 's#/appinfo/info\.xml$##' || true
}

pick_app() {
  unzip -p "$ARCHIVE" core/shipped.json > "$TMP/shipped.json" 2>/dev/null || die "the archive has no core/shipped.json"
  local id
  while read -r id; do
    [[ $id =~ ^[a-z0-9_]+$ ]] || continue
    [ -z "$(app_folder "$id")" ] || { echo "$id"; return 0; }
  done < <(jq -r '.defaultEnabled // [] | sort | reverse | .[]' "$TMP/shipped.json")
  return 1
}

tamper() {
  ARCHIVE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  rm -rf "$TMP/edit"
  unzip -Z1 "$ARCHIVE" > "$TMP/list"
  case "$MODE" in
  missing-app)
    id=$(pick_app) || die "no app in defaultEnabled has a folder in the archive: nothing to remove"
    folder=$(app_folder "$id")
    zip -q -d "$ARCHIVE" "$folder/*" >/dev/null || die "could not remove $folder from the archive"
    unzip -Z1 "$ARCHIVE" | grep -q "^$folder/" && die "$folder is still in the archive"
    log "missing-app: removed the app '$id' ($folder)" ;;
  wrong-mode)
    id=$(pick_app) || die "no app in defaultEnabled has a folder in the archive: nothing to change"
    mkdir -p "$TMP/edit/core"
    jq --arg id "$id" '.defaultEnabled |= map(select(. != $id))' "$TMP/shipped.json" > "$TMP/edit/core/shipped.json"
    ( cd "$TMP/edit" && zip -q "$ARCHIVE" core/shipped.json ) || die "could not write core/shipped.json to the archive"
    unzip -p "$ARCHIVE" core/shipped.json | jq -e --arg id "$id" '.defaultEnabled | index($id) | not' >/dev/null \
      || die "core/shipped.json still lists $id"
    log "wrong-mode: took the app '$id' out of defaultEnabled (it is installed disabled)" ;;
  skip-enable)
    unzip -p "$ARCHIVE" ncw-configure.sh > "$TMP/configure.sh" 2>/dev/null || die "the archive has no ncw-configure.sh"
    grep -q '^ENABLE_APPS=(.\+)$' "$TMP/configure.sh" || die "ncw-configure.sh enables no app: nothing to skip"
    mkdir -p "$TMP/edit"
    sed 's/^ENABLE_APPS=(.*)$/ENABLE_APPS=()/' "$TMP/configure.sh" > "$TMP/edit/ncw-configure.sh"
    ( cd "$TMP/edit" && zip -q "$ARCHIVE" ncw-configure.sh ) || die "could not write ncw-configure.sh to the archive"
    unzip -p "$ARCHIVE" ncw-configure.sh | grep -q '^ENABLE_APPS=()$' || die "ncw-configure.sh still lists apps to enable"
    log "skip-enable: emptied ENABLE_APPS in ncw-configure.sh" ;;
  extra-app)
    ! grep -q '^apps/ionos_smoke_extra/' "$TMP/list" || die "apps/ionos_smoke_extra exists already"
    mkdir -p "$TMP/edit/apps/ionos_smoke_extra/appinfo"
    cat > "$TMP/edit/apps/ionos_smoke_extra/appinfo/info.xml" <<'XML'
<?xml version="1.0"?>
<info xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:noNamespaceSchemaLocation="https://apps.nextcloud.com/schema/apps/info.xsd">
	<id>ionos_smoke_extra</id>
	<name>Smoke test extra app</name>
	<summary>An app the flavor does not list, added to prove the smoke gate</summary>
	<description>Added by ionos-smoke-break.sh. It must make the smoke test fail.</description>
	<version>1.0.0</version>
	<licence>agpl</licence>
	<author>ionos-smoke-break</author>
	<namespace>IonosSmokeExtra</namespace>
	<category>tools</category>
	<dependencies>
		<nextcloud min-version="30" max-version="99"/>
	</dependencies>
</info>
XML
    ( cd "$TMP/edit" && zip -q -r "$ARCHIVE" apps/ionos_smoke_extra ) || die "could not add the app to the archive"
    unzip -Z1 "$ARCHIVE" | grep -qx 'apps/ionos_smoke_extra/appinfo/info.xml' || die "the extra app is not in the archive"
    log "extra-app: added the app 'ionos_smoke_extra' (apps/ionos_smoke_extra)" ;;
esac
}

for a in "$@"; do tamper "$a"; done
