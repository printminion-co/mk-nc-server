#!/usr/bin/env bash
# For every flavor of the run: writes the app pins file, runs `ncw build` on the assembly tree
# ($WORK/tree), then `ncw validate --artifact` on the zip, then writes <zip>.sha256. A failing flavor leaves
# no archive and no checksum; the other flavors are still built, all failures are reported at the end and
# the step fails (nothing is published). Only when every flavor passed does it
# write $WORK/validated (a copy of flavors.txt), which the publish script requires. Needs jq and git.
# All flavors share BUILD_NUMBER. No cache keys are passed (the cache comes with its own ticket).
#
# Environment:
#   WORK, ROOT (see ionos-build-assemble.sh)
#   BUILD_NUMBER   the run number
#   LINE           the stable line, for example 33
#   SERVER_COMMIT, FLAVORS_COMMIT   the commits built (full shas)
#   KIND           dev (default) or release. A release build also needs SNAPSHOT_BRANCH, RELEASE_NR and RELEASE_SCOPE (all read by
#                  the plan job from the snapshot tag's annotation) and SNAPSHOT_BASE (the base release of that tag, which
#                  must be the base release of the built tree); they become --snapshot-branch, --release-number and --scope
#                  of `ncw build`, so they end up in version.json. A dev build passes none of them.
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
KIND=${KIND:-dev}
SNAPSHOT_ARGS=()
case "$KIND" in
  dev) ;;
  release)
    [[ ${SNAPSHOT_BRANCH:-} =~ $SNAPSHOT_BRANCH_RE ]] || die "a release build needs SNAPSHOT_BRANCH, a snapshot branch rc/ncw-v<nn>-<n>"
    [[ ${RELEASE_NR:-} =~ ^[1-9][0-9]*$ ]] || die "a release build needs RELEASE_NR, a positive integer"
    valid_scope "${RELEASE_SCOPE:-}" || die "a release build needs RELEASE_SCOPE, the scope text of the snapshot tag"
    [[ ${SNAPSHOT_BASE:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "a release build needs SNAPSHOT_BASE, the base release of the snapshot tag"
    [ "$(cat "$WORK/base-release" 2>/dev/null)" = "$SNAPSHOT_BASE" ] \
      || die "the built tree has base release '$(cat "$WORK/base-release" 2>/dev/null)' but the snapshot tag says $SNAPSHOT_BASE: nothing is built"
    SNAPSHOT_ARGS=(--snapshot-branch "$SNAPSHOT_BRANCH" --release-number "$RELEASE_NR" "--scope=$RELEASE_SCOPE")
    ;;
  *) die "KIND '$KIND' is not dev or release" ;;
esac
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

# build_flavor <flavor>: build, validate, checksum. Returns 1 on the first problem of this flavor and leaves
# no archive and no checksum of it behind. Explicit returns: it runs under `if !`, where `set -e` does nothing.
build_flavor() {
  local flavor="$1" pins zip
  pins=$(pins_file "$flavor") || return 1
  log "building flavor $flavor (build $BUILD_NUMBER)"
  zip=$("${NCW_CMD[@]}" build --flavors "$FLAVORS_DIR" --flavor "$flavor" --tree "$TREE" --line "$LINE" --kind "$KIND" \
    --build-number "$BUILD_NUMBER" --out "$OUT" --server-commit "$SERVER_COMMIT" --flavors-commit "$FLAVORS_COMMIT" \
    --app-pins "$pins" "${SNAPSHOT_ARGS[@]}") || { warn "the build of flavor $flavor failed"; return 1; }
  [ -f "$zip" ] || { warn "the build of flavor $flavor printed '$zip', which is not a file"; return 1; }
  log "validating $(basename "$zip")"
  if ! "${NCW_CMD[@]}" validate --flavors "$FLAVORS_DIR" --flavor "$flavor" --artifact "$zip"; then
    rm -f "$zip"
    warn "the static checks of flavor $flavor failed"
    return 1
  fi
  ( cd "$OUT" && sha256sum "$(basename "$zip")" > "$(basename "$zip").sha256" ) || return 1
}

rm -rf "$OUT"; mkdir -p "$OUT"
rm -f "$WORK/validated"
failed=()
while read -r flavor; do
  if ! build_flavor "$flavor"; then failed+=("$flavor"); fi
done < "$WORK/flavors.txt"

[ ${#failed[@]} -eq 0 ] || die "these flavors failed: ${failed[*]}; nothing will be published"
cp "$WORK/flavors.txt" "$WORK/validated"
log "built and validated: $(paste -sd' ' "$WORK/flavors.txt")"
