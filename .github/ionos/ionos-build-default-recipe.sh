# shellcheck shell=bash
# The default build recipe of the out-of-tree apps, as a function. Source it, do not run it. It is its own file
# because the text of this file is part of every cache key of an app built with the default recipe
# (ionos-cache-lib.sh): any change of the build rules, even of a comment, builds every such app anew once.
# Bump RECIPE_RULES_VERSION for a change of the rules that is not visible in this text (for example a tool
# the recipe calls changing its meaning).
# Needs NPM_CMD and COMPOSER_CMD (arrays) and jq.
# shellcheck disable=SC2034  # read by nobody: it is only part of this file's text, which the cache key hashes
RECIPE_RULES_VERSION=1

# The default recipe, run in the app folder (APP is set). Built output is never trusted, and nothing that git
# tracks is ever deleted (js/ and css/ can hold handwritten sources):
#  - an app with committed js/ or css/ files, no package.json build script and no recipe is an error: it
#    cannot be rebuilt from source here (add .github/ionos/build-recipes/<app>.sh, even a no-op one that
#    says the files are sources);
#  - composer.json (always, also when it requires only php, ext-* or bamarni/*): untracked and ignored files
#    of vendor/ are removed, `composer install --no-dev -a --no-scripts` runs (post-install-cmd, for example
#    `composer bin all install`, is dev tooling) and vendor/autoload.php must exist, else the app fails;
#  - a package.json build script: untracked and ignored files of js/ and css/ are removed, a marker is
#    taken, `npm ci && npm run build` runs, and the build must have written at least one
#    file newer than the marker in js/ or css/ (so a build that writes nothing fails);
#  - node_modules is deleted afterwards.
# Every command ends in `|| return 1`: this runs under `||` in the caller, where `set -e` does nothing.
# Messages are plain lines naming the app; the one ::error:: of the step lists all failing apps.
default_recipe() {
  local has_composer=false has_build=false marker
  # composer always runs when there is a composer.json: Nextcloud apps load composer/autoload.php, which requires
  # ../vendor/autoload.php even when the app needs no package (calendar, contacts); without it the install dies
  if [ -f composer.json ]; then has_composer=true; fi
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
