#!/usr/bin/env bash
# Builds every out-of-tree app of $WORK/apps-all.txt from source. A submodule is initialised shallowly
# (only these, never all). The recipe is the script .github/ionos/build-recipes/<app id>.sh when it
# exists (run with the app folder as the current folder and APP set), else the default:
#   composer install --no-dev -a --no-scripts   when there is a composer.json (always: the app's composer/autoload.php
#                                               requires vendor/autoload.php even when no package is needed)
#   npm ci && npm run build                     when package.json has a build script (lifecycle scripts run:
#                                               vue-demi's postinstall is needed by text, viewer, photos)
# with the checks of default_recipe (ionos-build-default-recipe.sh): committed built files are deleted first and the
# build must produce new ones. Needs jq, rsync and git.
#
# The app build cache (see ionos-build.md, "Cache", and ionos-cache-lib.sh): with CACHE_DIR set and NO_CACHE not
# true, an app is not built when the cache folder holds a build of it under exactly the freshly computed key
# (app commit, recipe, Node, PHP, Composer major) and its tree still matches the checksum of its meta.json; the
# tree is then copied into the app folder. Every other app is built and stored in the folder. The submodule is
# always initialised (the assembly and the pins need the git checkout). If anything was stored or dropped, the
# script writes cache_save=true and cache_key=<key of the folder> to $GITHUB_OUTPUT, for the save step of the
# workflow. With NO_CACHE=true the folder is neither read nor written.
# Always written: $WORK/app-builds.json, {"<app id>": {"key": ..., "checksum": ...}} of every USED build
# (reused or fresh), which ionos-build-package.sh hands to `ncw build --cache-keys`.
#
# Environment:  WORK, NPM (default npm), COMPOSER (default composer), RECIPES_DIR, CACHE_DIR, NO_CACHE,
#               DEFAULT_RECIPE_FILE (default: ionos-build-default-recipe.sh next to this script)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"
# shellcheck source=ionos-cache-lib.sh
. "$HERE/ionos-cache-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
RECIPES_DIR=${RECIPES_DIR:-$ROOT/.github/ionos/build-recipes}
read -r -a NPM_CMD <<<"${NPM:-npm}"
read -r -a COMPOSER_CMD <<<"${COMPOSER:-composer}"
DEFAULT_RECIPE_FILE=${DEFAULT_RECIPE_FILE:-$HERE/ionos-build-default-recipe.sh}
# shellcheck source=ionos-build-default-recipe.sh
. "$DEFAULT_RECIPE_FILE"
CACHE_DIR=${CACHE_DIR:-}
USE_CACHE=false
if [ -n "$CACHE_DIR" ] && [ "${NO_CACHE:-false}" != true ]; then USE_CACHE=true; fi
BUILDS="$WORK/app-builds.json"

# record_build <id> <key> <checksum>: the used build of an app, for version.json
record_build() {
  jq --arg id "$1" --arg k "$2" --arg c "$3" '. + {($id): {key: $k, checksum: $c}}' "$BUILDS" > "$BUILDS.tmp" || return 1
  mv "$BUILDS.tmp" "$BUILDS"
}

# store_entry <id> <path> <key> <commit> <checksum>: the built app folder (without .git) and its meta.json
# replace the entry of the app in the cache folder
store_entry() {
  local id="$1" path="$2" dest="$CACHE_DIR/$1"
  rm -rf "$dest.new" "$dest"; mkdir -p "$dest.new/tree" || return 1
  rsync -a --exclude=/.git "$ROOT/$path/" "$dest.new/tree/" || return 1
  jq -n --arg id "$id" --arg k "$3" --arg c "$5" --arg commit "$4" --arg n "$NODE_V" --arg p "$PHP_V" --arg cv "$COMPOSER_V" \
    --arg r "$(cache_sha256_of "$(cache_recipe_file "$id")")" \
    '{app: $id, key: $k, checksum: $c, app_commit: $commit, node: $n, php: $p, composer: $cv, recipe_hash: $r}' > "$dest.new/meta.json" || return 1
  mv "$dest.new" "$dest"
}

build_app() { # build_app <path>
  local path="$1" id commit key sum reason; id=$(basename "$1")
  if is_gitlink "$ROOT" "$path"; then
    log "$id: initialising the submodule $path (shallow)"
    git -C "$ROOT" submodule update --init --depth 1 -- "$path" || return 1
  fi
  if [ -z "$(ls -A "$ROOT/$path" 2>/dev/null)" ]; then
    warn "$id: $path is empty after initialising"
    return 1
  fi
  commit=$(git -C "$ROOT" rev-parse "HEAD:$path") || return 1
  key=$(cache_app_key "$id" "$commit" "$NODE_V" "$PHP_V" "$COMPOSER_V") || return 1
  if [ "$USE_CACHE" = true ]; then
    if reason=$(cache_entry_valid "$CACHE_DIR" "$id" "$key" 2>&1); then
      rsync -a --delete --exclude=/.git "$CACHE_DIR/$id/tree/" "$ROOT/$path/" || return 1
      log "$id: reused from the cache (key $key)"
      record_build "$id" "$key" "$(jq -r .checksum "$CACHE_DIR/$id/meta.json")" || return 1
      reused+=("$id")
      return 0
    fi
    log "$id: not reused: $reason"
  fi
  log "$id: building (key $key)"
  if [ -f "$RECIPES_DIR/$id.sh" ]; then
    log "$id: build recipe $RECIPES_DIR/$id.sh"
    ( cd "$ROOT/$path" && APP="$id" bash "$RECIPES_DIR/$id.sh" ) || return 1
  else
    log "$id: default recipe"
    ( cd "$ROOT/$path" && APP="$id" default_recipe ) || return 1
  fi
  sum=$(cache_tree_checksum "$ROOT/$path") || return 1
  record_build "$id" "$key" "$sum" || return 1
  built+=("$id")
  if [ "$USE_CACHE" = true ]; then
    mkdir -p "$CACHE_DIR" && store_entry "$id" "$path" "$key" "$commit" "$sum" || return 1
  fi
}

read -r NODE_V PHP_V COMPOSER_V < <(cache_toolchain) || exit 1
echo '{}' > "$BUILDS"
log "toolchain for the cache keys: node $NODE_V, php $PHP_V, composer $COMPOSER_V; cache: $(if [ "$USE_CACHE" = true ]; then echo "$CACHE_DIR"; elif [ -n "$CACHE_DIR" ]; then echo "ignored (no_cache)"; else echo off; fi)"
failed=(); built=(); reused=(); dropped=()
while read -r path; do
  [ -n "$path" ] || continue
  if ! build_app "$path"; then
    echo "ionos-build: the build of app $(basename "$path") ($path) failed" >&2
    failed+=("$(basename "$path")")
  fi
done < "$WORK/apps-all.txt"
[ ${#failed[@]} -eq 0 ] || die "these apps failed to build: ${failed[*]}"

# Entries of the folder that are no pinned app any more are dropped (an app pinned but not part of this run stays).
if [ "$USE_CACHE" = true ] && [ -d "$CACHE_DIR" ]; then
  pinned=$(pinned_app_paths "$ROOT" | xargs -r -n1 basename)
  if [ -n "$pinned" ]; then
    shopt -s nullglob dotglob
    for entry in "$CACHE_DIR"/*; do
      name=$(basename "$entry")
      grep -qxF -- "$name" <<<"$pinned" && continue
      log "$name: not a pinned app any more, dropped from the cache"
      rm -rf -- "$entry"; dropped+=("$name")
    done
    shopt -u nullglob dotglob
  fi
fi

log "apps: $(wc -l < "$WORK/apps-all.txt") (reused ${#reused[@]}, built ${#built[@]})"
if [ "$USE_CACHE" = true ] && [ $(( ${#built[@]} + ${#dropped[@]} )) -gt 0 ] && compgen -G "$CACHE_DIR/*/meta.json" >/dev/null; then
  folder_key=$(cache_folder_key "$CACHE_DIR")
  log "the cache folder changed (built ${#built[@]}, dropped ${#dropped[@]}): save it as $folder_key"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then { echo "cache_save=true"; echo "cache_key=$folder_key"; } >> "$GITHUB_OUTPUT"; fi
else
  log "the cache folder is not saved ($(if [ "$USE_CACHE" = true ]; then echo "nothing changed"; else echo "cache not used"; fi))"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### App build cache"
    echo "Reused ${#reused[@]}, built ${#built[@]}, dropped ${#dropped[@]} (cache $(if [ "$USE_CACHE" = true ]; then echo on; else echo off; fi))."
    [ ${#built[@]} -eq 0 ] || echo "Built: ${built[*]}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
