#!/usr/bin/env bash
# calendar (apps-flavor1/calendar). The default recipe does not fit: composer.json has a post-install-cmd
# that runs `composer bin all install`, which would download the dev tools of vendor-bin on every build.
# Like upstream's krankerl.toml: composer install --no-dev -o (here without scripts), then npm ci and the build.
set -euo pipefail
read -r -a npm <<<"${NPM:-npm}"
read -r -a composer <<<"${COMPOSER:-composer}"
rm -rf vendor js css
"${composer[@]}" install --no-dev -a --no-scripts --no-interaction --quiet
[ -f vendor/autoload.php ] || { echo "$APP: composer install produced no vendor/autoload.php" >&2; exit 1; }
"${npm[@]}" ci --ignore-scripts
"${npm[@]}" run build
[ -n "$(find js css -type f -print -quit 2>/dev/null)" ] || { echo "$APP: the build produced no files in js/ or css/" >&2; exit 1; }
rm -rf node_modules
