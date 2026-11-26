#!/usr/bin/env bash
# Resolves the flavors of a run and selects the out-of-tree apps they need. Writes, in $WORK:
#   flavors.txt        the flavors to build, one per line
#   scope              all when that is every flavor of IONOS/flavors, else subset
#   apps/<flavor>.txt  the out-of-tree apps of that flavor, as paths <app folder>/<app id>
#   apps-all.txt       the union of those, sorted
#   resolved/<flavor>.yaml   what `ncw resolve` printed, for the log and for later steps
# An out-of-tree app is an entry of an ACTIVE app folder of the flavor (the folder lists apps as
# submodules) whose mode in the flavor is not `removed`. No such app is fine.
#
# Environment:
#   WORK      the run's work folder
#   FLAVORS   optional comma separated list of flavors, default every folder of IONOS/flavors
#   NCW       the flavors tool command, default "node IONOS/tools/src/cli.ts" (run from the checkout)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
FLAVORS=${FLAVORS:-}
read -r -a NCW_CMD <<<"${NCW:-node $ROOT/IONOS/tools/src/cli.ts}"
FLAVORS_DIR="$ROOT/IONOS"
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# The lines of a top-level section of `ncw resolve` output: "  id: mode" entries (kind=map) or "  - item" (kind=list).
section() { # section <name> <yaml file>
  awk -v want="$1" '
    /^[A-Za-z_]+:/ { sec = $1; sub(/:$/, "", sec); next }
    sec == want && /^  [^ ]/ { sub(/^  /, ""); sub(/^- /, ""); print }' "$2"
}

mkdir -p "$WORK/apps" "$WORK/resolved"
: > "$WORK/flavors.txt"; : > "$WORK/apps-all.txt"

if [ -z "$FLAVORS" ]; then
  for d in "$FLAVORS_DIR"/flavors/*/; do
    if [ -f "$d/flavor.yaml" ]; then basename "$d"; fi
  done | sort > "$WORK/flavors.txt"
else
  IFS=',' read -r -a want <<<"$FLAVORS"
  for f in "${want[@]}"; do
    f=$(echo "$f" | tr -d '[:space:]')
    [ -n "$f" ] || continue
    [[ $f =~ $NAME_RE ]] || die "'$f' is not a flavor name"
    [ -f "$FLAVORS_DIR/flavors/$f/flavor.yaml" ] || die "there is no flavor '$f' in IONOS/flavors"
    echo "$f"
  done | sort -u > "$WORK/flavors.txt"
fi
[ -s "$WORK/flavors.txt" ] || die "no flavors to build"
# scope all = every flavor of IONOS/flavors; the flavors commit fixes that set
for d in "$FLAVORS_DIR"/flavors/*/; do
  if [ -f "$d/flavor.yaml" ]; then basename "$d"; fi
done | sort > "$WORK/flavors-found.txt"
if cmp -s "$WORK/flavors.txt" "$WORK/flavors-found.txt"; then echo all > "$WORK/scope"; else echo subset > "$WORK/scope"; fi
rm -f "$WORK/flavors-found.txt"
log "scope: $(cat "$WORK/scope")"
log "flavors: $(paste -sd' ' "$WORK/flavors.txt")"

while read -r flavor; do
  "${NCW_CMD[@]}" resolve --flavors "$FLAVORS_DIR" --flavor "$flavor" > "$WORK/resolved/$flavor.yaml" \
    || die "could not resolve flavor $flavor"
  : > "$WORK/apps/$flavor.txt"
  removed=$(section apps "$WORK/resolved/$flavor.yaml" | sed -n 's/^\([^:]*\): removed$/\1/p')
  folders=$(section app_folders "$WORK/resolved/$flavor.yaml")
  while read -r folder; do
    [ -n "$folder" ] || continue
    [[ $folder =~ ^[A-Za-z0-9._-]+$ ]] || die "flavor $flavor: app folder '$folder' is not a plain folder name"
    entries=$(git -C "$ROOT" ls-tree HEAD -- "$folder/" | cut -f2 || true)
    [ -n "$entries" ] || log "flavor $flavor: app folder $folder has no entries in this checkout"
    while read -r path; do
      [ -n "$path" ] || continue
      grep -qx "$(basename "$path")" <<<"$removed" && continue
      echo "$path" >> "$WORK/apps/$flavor.txt"
    done <<<"$entries"
  done <<<"$folders"
  sort -u -o "$WORK/apps/$flavor.txt" "$WORK/apps/$flavor.txt"
  log "flavor $flavor: $(wc -l < "$WORK/apps/$flavor.txt") out-of-tree app(s)"
done < "$WORK/flavors.txt"

cat "$WORK"/apps/*.txt | sort -u > "$WORK/apps-all.txt"
log "apps to build: $(paste -sd' ' "$WORK/apps-all.txt")"
