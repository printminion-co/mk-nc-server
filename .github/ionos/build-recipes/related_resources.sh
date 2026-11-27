#!/usr/bin/env bash
# related_resources (apps-upstream/related_resources). The app commits its built js/ (all of js/ is webpack output)
# and the committed files are partly stale (names of chunks that the current build no longer writes). The default
# recipe cannot be used: it never deletes tracked files and then requires the build to write a new file, but webpack
# does not rewrite a file whose content is unchanged, so a faithful rebuild writes nothing and the check fails.
# This recipe deletes the committed built output first, so that only what the build writes ships, and builds as the
# default recipe does (composer for the autoloader, npm ci with lifecycle scripts, npm run build).
set -euo pipefail
read -r -a NPM_CMD <<<"${NPM:-npm}"
read -r -a COMPOSER_CMD <<<"${COMPOSER:-composer}"

rm -rf js
git clean -fdxq -- vendor
"${COMPOSER_CMD[@]}" install --no-dev -a --no-scripts --no-interaction --quiet
[ -f vendor/autoload.php ] || { echo "ionos-build: $APP: composer install produced no vendor/autoload.php" >&2; exit 1; }
"${NPM_CMD[@]}" ci
"${NPM_CMD[@]}" run build
[ -n "$(find js -type f -print -quit 2>/dev/null)" ] || { echo "ionos-build: $APP: the build wrote no file in js/" >&2; exit 1; }
rm -rf node_modules
