#!/usr/bin/env bash
# The "import the app configuration" step of the deployment contract (05-deployment.md, 02-flavor-model.md), done
# right after `occ maintenance:install`: fills the ${ENV_VAR} placeholders of app-config.json from the
# environment and imports it with `occ config:import`, then sets every entry of app-config-special.json (the
# sensitive, lazy and typed settings the import cannot set) with `occ config:app:set --value ... [--type T]
# [--lazy] [--sensitive]`. A placeholder without a value in the environment fails the step: a literal ${...} is
# never imported.
#   ionos-smoke-appconfig.sh <unpacked tree> <scratch folder for the filled files>
# Environment: OCC is the occ command (default `php occ`), run from inside the tree. Values are never printed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

[ $# -eq 2 ] || die "usage: ionos-smoke-appconfig.sh <unpacked tree> <scratch folder>"
TREE=$1
SCRATCH=$2
[ -d "$TREE" ] || die "no tree at $TREE"
[ -f "$TREE/app-config.json" ] || die "$TREE has no app-config.json"
read -r -a OCC_CMD <<<"${OCC:-php occ}"

mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

PLACEHOLDERS='\\$\\{(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}'

# fill <in> <out>: copies a JSON file, replacing the placeholders in every string; fails naming a missing variable.
fill() {
  local name
  jq -e . "$1" >/dev/null 2>&1 || die "$1 is not valid JSON"
  while read -r name; do
    [ -n "$name" ] || continue
    [ -n "${!name+x}" ] || die "$(basename "$1") uses \${$name} but the environment has no $name"
  done < <(jq -r "[.. | strings | scan(\"$PLACEHOLDERS\") | .[0]] | unique[]" "$1")
  jq "walk(if type == \"string\" then gsub(\"$PLACEHOLDERS\"; \$ENV[.n]) else . end)" "$1" > "$2"
}

fill "$TREE/app-config.json" "$SCRATCH/app-config.json"
( cd "$TREE" && "${OCC_CMD[@]}" config:import "$SCRATCH/app-config.json" ) || die "occ config:import failed"
log "imported app-config.json"

if [ -f "$TREE/app-config-special.json" ]; then
  fill "$TREE/app-config-special.json" "$SCRATCH/special.json"
  count=$(jq 'length' "$SCRATCH/special.json")
  for ((i = 0; i < count; i++)); do
    field() { jq -r --argjson i "$i" ".[\$i].$1 // \"\"" "$SCRATCH/special.json"; }
    args=("$(field app)" "$(field key)" "--value=$(field value)")
    [ -z "$(field type)" ] || args+=("--type=$(field type)")
    [ "$(field lazy)" != true ] || args+=(--lazy)
    [ "$(field sensitive)" != true ] || args+=(--sensitive)
    ( cd "$TREE" && "${OCC_CMD[@]}" config:app:set "${args[@]}" ) >/dev/null || die "occ config:app:set failed for ${args[0]} ${args[1]}"
  done
  log "set $count special setting(s) from app-config-special.json"
fi
