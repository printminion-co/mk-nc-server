#!/usr/bin/env bash
# Builds every out-of-tree app of $WORK/apps-all.txt from source. A submodule is initialised shallowly
# (only these, never all). The recipe is the script .github/ionos/build-recipes/<app id>.sh when it
# exists (run with the app folder as the current folder and APP set), else the default:
#   composer install --no-dev -a --no-scripts   when composer.json has runtime packages
#   npm ci && npm run build                     when package.json has a build script (lifecycle scripts run:
#                                               vue-demi's postinstall is needed by text, viewer, photos)
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

# The default recipe, run in the app folder (APP is set). Built output is never trusted, and nothing that git
# tracks is ever deleted (js/ and css/ can hold handwritten sources):
#  - an app with committed js/ or css/ files, no package.json build script and no recipe is an error: it
#    cannot be rebuilt from source here (add .github/ionos/build-recipes/<app>.sh, even a no-op one that
#    says the files are sources);
#  - composer.json with runtime packages (anything but php, ext-* and bamarni/*): untracked and ignored files
#    of vendor/ are removed, `composer install --no-dev -a --no-scripts` runs (post-install-cmd is dev tooling)
#    and vendor/autoload.php must exist;
#  - a package.json build script: untracked and ignored files of js/ and css/ are removed, a marker is
#    taken, `npm ci && npm run build` runs, and the build must have written at least one
#    file newer than the marker in js/ or css/ (so a build that writes nothing fails);
#  - node_modules is deleted afterwards.
# Every command ends in `|| return 1`: this runs under `||` in the caller, where `set -e` does nothing.
# Messages are plain lines naming the app; the one ::error:: of the step lists all failing apps.
default_recipe() {
  local has_composer=false has_build=false marker
  # like upstream's release build: composer only when there are runtime packages (not php, ext-* or the bin plugin)
  if [ -f composer.json ] && jq -e '.require // {} | keys | map(select(. != "php" and (startswith("ext-") | not) and (startswith("bamarni/") | not))) | length > 0' composer.json >/dev/null; then
    has_composer=true
  fi
  if [ -f package.json ] && jq -e '.scripts.build' package.json >/dev/null; then has_build=true; fi

  if [ "$has_build" = false ] && [ -n "$(git ls-files -- js css | head -n1)" ]; then
    echo "ionos-build: $APP has committed js/ or css/ files but no package.json build script and no recipe in .github/ionos/build-recipes/$APP.sh: it cannot be built from source" >&2
    return 1
  fi
  if [ "$has_composer" = true ]; then
    git clean -fdxq -- vendor || return 1
    "${COMPOSER_CMD[@]}" install --no-dev -a --no-scripts --no-interaction --quiet || return 1
    [ -f vendor/autoload.php ] || { echo "ionos-build: $APP has a composer.json but composer install produced no vendor/autoload.php" >&2; return 1; }
  fi
  if [ "$has_build" = true ]; then
    git clean -fdxq -- js css || return 1
    "${NPM_CMD[@]}" ci || return 1
    marker=$(mktemp) || return 1
    sleep 1
    "${NPM_CMD[@]}" run build || { rm -f "$marker"; return 1; }
    if [ -z "$(find js css -type f -newer "$marker" -print -quit 2>/dev/null)" ]; then
      rm -f "$marker"
      echo "ionos-build: $APP has a build script but the build wrote no new file in js/ or css/ (add a recipe if it builds elsewhere)" >&2
      return 1
    fi
    rm -f "$marker"
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

failed=()
while read -r path; do
  [ -n "$path" ] || continue
  if ! build_app "$path"; then
    echo "ionos-build: the build of app $(basename "$path") ($path) failed" >&2
    failed+=("$(basename "$path")")
  fi
done < "$WORK/apps-all.txt"
[ ${#failed[@]} -eq 0 ] || die "these apps failed to build: ${failed[*]}"
log "apps built: $(wc -l < "$WORK/apps-all.txt")"
