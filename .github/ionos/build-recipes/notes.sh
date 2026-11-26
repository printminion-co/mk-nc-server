#!/usr/bin/env bash
# notes (apps-flavor1/notes). css/ holds handwritten stylesheets (css/global.css, css/notes.css) that the
# default recipe would delete, and composer.json has only dev packages (no runtime vendor/; upstream's
# krankerl.toml runs only npm ci and the build). webpack writes to js/.
set -euo pipefail
read -r -a npm <<<"${NPM:-npm}"
rm -rf js
"${npm[@]}" ci --ignore-scripts
"${npm[@]}" run build
[ -n "$(find js -type f -print -quit 2>/dev/null)" ] || { echo "$APP: the build produced no files in js/" >&2; exit 1; }
rm -rf node_modules
