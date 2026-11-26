#!/usr/bin/env bash
# Builds every out-of-tree app of $WORK/apps-all.txt from source. A submodule is initialised shallowly
# (only these, never all). The recipe is the script .github/ionos/build-recipes/<app id>.sh when it
# exists (run with the app folder as the current folder and APP set), else the default:
#   composer install --no-dev -a        when composer.json exists
#   npm ci && npm run build             when package.json has a build script
# and node_modules is deleted afterwards. Needs jq.
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

# Every command ends in `|| return 1`: these functions run under `||` in the caller, where `set -e` does nothing.
default_recipe() { # run in the app folder
  if [ -f composer.json ]; then
    "${COMPOSER_CMD[@]}" install --no-dev -a --no-interaction --quiet || return 1
  fi
  if [ -f package.json ] && jq -e '.scripts.build' package.json >/dev/null; then
    "${NPM_CMD[@]}" ci || return 1
    "${NPM_CMD[@]}" run build || return 1
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
    ( cd "$ROOT/$path" && default_recipe ) || return 1
  fi
}

while read -r path; do
  [ -n "$path" ] || continue
  build_app "$path" || die "the build of app $(basename "$path") ($path) failed"
done < "$WORK/apps-all.txt"
log "apps built: $(wc -l < "$WORK/apps-all.txt")"
