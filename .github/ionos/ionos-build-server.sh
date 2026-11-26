#!/usr/bin/env bash
# Builds the server frontend from source: `npm ci && npm run build` at the root of the checkout. The
# committed dist/ is deleted first and never trusted: what ships is what the build wrote.
#
# Environment:  NPM   the npm command, default npm
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

ROOT=$(build_root)
read -r -a NPM_CMD <<<"${NPM:-npm}"
cd "$ROOT"

rm -rf dist
# No --ignore-scripts: the server's postinstall (build/demi.sh ci) installs the frontend builds that
# `npm run build` needs.
log "server: npm ci"
"${NPM_CMD[@]}" ci || die "server: npm ci failed"
log "server: npm run build"
"${NPM_CMD[@]}" run build || die "server: npm run build failed"
[ -n "$(ls -A dist 2>/dev/null)" ] || die "server: the build wrote nothing to dist/"
log "server: built"
