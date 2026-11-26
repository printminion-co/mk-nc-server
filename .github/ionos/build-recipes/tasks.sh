#!/usr/bin/env bash
# tasks (apps-flavor1/tasks). css/ holds a handwritten file (css/tasks-icon.css) next to what vite builds, so
# the default recipe (rm -rf css) does not fit: built css is removed with git, tracked css is restored.
# composer.json requires only php (no runtime packages) and the app never loads vendor/autoload.php, so
# composer is not run.
set -euo pipefail
read -r -a npm <<<"${NPM:-npm}"
rm -rf js
git clean -fdxq -- css
git checkout -q -- css
"${npm[@]}" ci --ignore-scripts
"${npm[@]}" run build
[ -n "$(find js -type f -print -quit 2>/dev/null)" ] || { echo "$APP: the build produced no files in js/" >&2; exit 1; }
rm -rf node_modules
