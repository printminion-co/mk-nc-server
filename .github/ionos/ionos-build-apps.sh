#!/usr/bin/env bash
# Builds every out-of-tree app of $WORK/apps-all.txt from source. A submodule is initialised shallowly
# (only these, never all). The recipe is the script .github/ionos/build-recipes/<app id>.sh when it
# exists (run with the app folder as the current folder and APP set), else the default:
#   composer install --no-dev -a        when composer.json exists
#   npm ci --ignore-scripts && npm run build   when package.json has a build script
# with the checks of default_recipe below: committed built files are deleted first and the build must
# produce new ones. Needs jq.
#
# Environment:  WORK, NPM (default npm), COMPOSER (default composer), RECIPES_DIR
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
RECIPES_DIR=${RECIPES_DIR:-$ROOT/.github/ionos/build-recipes}
read -r -a NPM_CMD <<<"${NPM:-npm}"
read -r -a COMPOSER_CMD <<<"${COMPOSER:-composer}"

# The default recipe, run in the app folder (APP is set). Built files are never trusted:
#  - an app with committed js/ or css/ files, no package.json build script and no recipe is an error: it
#    cannot be rebuilt from source here (add .github/ionos/build-recipes/<app>.sh, even a no-op one that
#    says the files are sources);
#  - composer.json: vendor/ is deleted, `composer install --no-dev -a` must produce vendor/autoload.php;
#  - a package.json build script: js/ and css/ are deleted, `npm ci --ignore-scripts && npm run build` must
#    produce files in js/ or css/;
#  - node_modules is deleted afterwards.
# Every command ends in `|| return 1`: this runs under `||` in the caller, where `set -e` does nothing.
default_recipe() {
  local has_composer=false has_build=false
  [ -f composer.json ] && has_composer=true
  if [ -f package.json ] && jq -e '.scripts.build' package.json >/dev/null; then has_build=true; fi

  if [ "$has_build" = false ] && [ -n "$(git ls-files -- js css | head -n1)" ]; then
    echo "::error::ionos-build: $APP has committed js/ or css/ files but no package.json build script and no recipe in .github/ionos/build-recipes/$APP.sh: it cannot be built from source" >&2
    return 1
  fi
  if [ "$has_composer" = true ]; then
    rm -rf vendor
    "${COMPOSER_CMD[@]}" install --no-dev -a --no-interaction --quiet || return 1
    [ -f vendor/autoload.php ] || { echo "::error::ionos-build: $APP has a composer.json but composer install produced no vendor/autoload.php" >&2; return 1; }
  fi
  if [ "$has_build" = true ]; then
    rm -rf js css
    "${NPM_CMD[@]}" ci --ignore-scripts || return 1
    "${NPM_CMD[@]}" run build || return 1
    if [ -z "$(find js css -type f -print -quit 2>/dev/null)" ]; then
      echo "::error::ionos-build: $APP has a build script but the build produced no files in js/ or css/ (add a recipe if it builds elsewhere)" >&2
      return 1
    fi
  fi
  rm -rf node_modules
}

build_app() { # build_app <path>
  local path="$1" id; id=$(basename "$1")
  if is_gitlink "$ROOT" "$path"; then
    log "$id: initialising the submodule $path (shallow)"
    git -C "$ROOT" submodule update --init --depth 1 -- "$path" || return 1
  fi
  if [ -z "$(ls -A "$ROOT/$path" 2>/dev/null)" ]; then
    warn "$id: $path is empty after initialising"
    return 1
  fi
  if [ -f "$RECIPES_DIR/$id.sh" ]; then
    log "$id: build recipe $RECIPES_DIR/$id.sh"
    ( cd "$ROOT/$path" && APP="$id" bash "$RECIPES_DIR/$id.sh" ) || return 1
  else
    log "$id: default recipe"
    ( cd "$ROOT/$path" && APP="$id" default_recipe ) || return 1
  fi
}

while read -r path; do
  [ -n "$path" ] || continue
  build_app "$path" || die "the build of app $(basename "$path") ($path) failed"
done < "$WORK/apps-all.txt"
log "apps built: $(wc -l < "$WORK/apps-all.txt")"
