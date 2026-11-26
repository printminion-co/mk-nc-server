#!/usr/bin/env bash
# For every flavor of the run: writes the app pins file, runs `ncw build` on the assembly tree
# ($WORK/tree), then `ncw validate --artifact` on the zip, then writes <zip>.sha256. The first failure
# stops the step (nothing after it runs, nothing is published). Only when every flavor passed does it
# write $WORK/validated (a copy of flavors.txt), which the publish script requires. Needs jq and git.
# All flavors share BUILD_NUMBER. No cache keys are passed (the cache comes with its own ticket).
#
# Environment:
#   WORK, ROOT (see ionos-build-assemble.sh)
#   BUILD_NUMBER   the run number
#   LINE           the stable line, for example 33
#   SERVER_COMMIT, FLAVORS_COMMIT   the commits built (full shas)
#   NCW            the flavors tool command, default "node IONOS/tools/src/cli.ts"
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
BUILD_NUMBER=${BUILD_NUMBER:?BUILD_NUMBER is required}
LINE=${LINE:?LINE is required}
SERVER_COMMIT=${SERVER_COMMIT:?SERVER_COMMIT is required}
FLAVORS_COMMIT=${FLAVORS_COMMIT:?FLAVORS_COMMIT is required}
read -r -a NCW_CMD <<<"${NCW:-node $ROOT/IONOS/tools/src/cli.ts}"
FLAVORS_DIR="$ROOT/IONOS"
TREE="$WORK/tree"
OUT="$WORK/out"

[[ $BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER '$BUILD_NUMBER' is not a positive integer"
[[ $LINE =~ ^[0-9]+$ ]] || die "LINE '$LINE' is not a number"
[[ $SERVER_COMMIT =~ ^[0-9a-f]{7,64}$ && $FLAVORS_COMMIT =~ ^[0-9a-f]{7,64}$ ]] || die "SERVER_COMMIT and FLAVORS_COMMIT must be hex commit shas"
[ -f "$TREE/version.php" ] || die "no assembly tree in $TREE; run ionos-build-assemble.sh first"

# pins_file <flavor>: {"<app>": {"commit": <sha>, "describe": <git describe>}} of the flavor's built submodule apps
pins_file() {
  local flavor="$1" file="$WORK/pins-$1.json" path id commit describe status
  echo '{}' > "$file"
  while read -r path; do
    [ -n "$path" ] || continue
    is_gitlink "$ROOT" "$path" || continue
    id=$(basename "$path")
    status=$(git -C "$ROOT" submodule status -- "$path")
    [ "${status:0:1}" = " " ] || die "app $id: the submodule $path is not at its pinned commit (git submodule status: '${status:0:1}')"
    commit=$(git -C "$ROOT/$path" rev-parse HEAD)
    if [ "$(git -C "$ROOT/$path" rev-parse --is-shallow-repository)" = true ]; then
      git -C "$ROOT/$path" fetch --quiet --filter=blob:none --unshallow --tags 2>/dev/null \
        || warn "app $id: could not fetch the history to describe $commit"
    fi
    describe=$(git -C "$ROOT/$path" describe --tags --always)
    jq --arg id "$id" --arg c "$commit" --arg d "$describe" '. + {($id): {commit: $c, describe: $d}}' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  done < "$WORK/apps/$flavor.txt"
  echo "$file"
}

rm -rf "$OUT"; mkdir -p "$OUT"
rm -f "$WORK/validated"
while read -r flavor; do
  pins=$(pins_file "$flavor")
  log "building flavor $flavor (build $BUILD_NUMBER)"
  zip=$("${NCW_CMD[@]}" build --flavors "$FLAVORS_DIR" --flavor "$flavor" --tree "$TREE" --line "$LINE" --kind dev \
    --build-number "$BUILD_NUMBER" --out "$OUT" --server-commit "$SERVER_COMMIT" --flavors-commit "$FLAVORS_COMMIT" \
    --app-pins "$pins") || die "the build of flavor $flavor failed"
  [ -f "$zip" ] || die "the build of flavor $flavor printed '$zip', which is not a file"
  log "validating $(basename "$zip")"
  "${NCW_CMD[@]}" validate --flavors "$FLAVORS_DIR" --flavor "$flavor" --artifact "$zip" \
    || die "the static checks of flavor $flavor failed: nothing will be published"
  ( cd "$OUT" && sha256sum "$(basename "$zip")" > "$(basename "$zip").sha256" )
done < "$WORK/flavors.txt"

cp "$WORK/flavors.txt" "$WORK/validated"
log "built and validated: $(paste -sd' ' "$WORK/flavors.txt")"
