#!/usr/bin/env bash
# groupfolders (apps-flavor1/groupfolders). composer.json requires only the composer-bin plugin (dev tools live
# in vendor-bin, started by a post-install-cmd), the app has no runtime packages and never loads
# vendor/autoload.php; upstream's krankerl.toml runs only npm ci and the build. So no composer here.
set -euo pipefail
read -r -a npm <<<"${NPM:-npm}"
rm -rf vendor js css
"${npm[@]}" ci --ignore-scripts
"${npm[@]}" run build
[ -n "$(find js css -type f -print -quit 2>/dev/null)" ] || { echo "$APP: the build produced no files in js/ or css/" >&2; exit 1; }
rm -rf node_modules
