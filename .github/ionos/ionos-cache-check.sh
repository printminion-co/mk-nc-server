#!/usr/bin/env bash
# The weekly comparison of clean and cached app builds (workflow ionos-app-cache-check.yml, see ionos-build.md,
# "Cache"). Reads the cache folder (restored by the workflow, NEVER changed or saved here), rebuilds every pinned
# app of every app folder (apps-*) of the checked-out commit WITHOUT the cache, with the same build logic as the
# build (ionos-build-apps.sh with NO_CACHE=true), and compares the checksum of each rebuilt tree with the checksum
# recorded in the cache for the same key. Apps not in the cache, or cached under another key (other app commit,
# recipe or toolchain), are skipped and not rebuilt: there is nothing to compare, and that is not a mismatch.
# A build that fails fails this script (it is a build problem, not a cache problem).
# Apps listed in ionos-cache-check-known.txt are rebuilt and compared like the others but a difference is
# reported as known and is no mismatch (see the file for why each is there).
#
# Writes $REPORT (default $WORK/report.md; the issue script posts it) and to $GITHUB_OUTPUT: mismatch=true|false,
# mismatched=<app ids>, compared=<number>. Exit 0 also with a mismatch: the issue job acts on the output.
#
# Environment:  WORK, CACHE_DIR, REPORT, and what ionos-build-apps.sh reads (NPM, COMPOSER, RECIPES_DIR)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-cache-check
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"
# shellcheck source=ionos-cache-lib.sh
. "$HERE/ionos-cache-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
CACHE_DIR=${CACHE_DIR:?CACHE_DIR is required}
REPORT=${REPORT:-$WORK/report.md}
KNOWN_FILE=${KNOWN_FILE:-$HERE/ionos-cache-check-known.txt}
RECIPES_DIR=${RECIPES_DIR:-$ROOT/.github/ionos/build-recipes}
DEFAULT_RECIPE_FILE=${DEFAULT_RECIPE_FILE:-$HERE/ionos-build-default-recipe.sh}
mkdir -p "$WORK"

read -r NODE_V PHP_V COMPOSER_V < <(cache_toolchain) || exit 1

# known <id>: the reason an app is known to build differently every time, empty for any other app
known() { if [ -f "$KNOWN_FILE" ]; then sed -n "s/^$1 //p" "$KNOWN_FILE" | head -n1; fi; }

: > "$WORK/apps-all.txt"
skipped=()
while read -r path; do
  [ -n "$path" ] || continue
  id=$(basename "$path")
  commit=$(git -C "$ROOT" rev-parse "HEAD:$path") || die "cannot read the pin of $path"
  key=$(cache_app_key "$id" "$commit" "$NODE_V" "$PHP_V" "$COMPOSER_V")
  if [ ! -e "$CACHE_DIR/$id" ]; then
    skipped+=("$id (not in the cache)")
  elif [ ! -d "$CACHE_DIR/$id" ] || [ -L "$CACHE_DIR/$id" ] || ! [ "$(jq -r '.key // empty' "$CACHE_DIR/$id/meta.json" 2>/dev/null)" ]; then
    skipped+=("$id (cache entry unreadable)")
  elif [ "$(jq -r '.key' "$CACHE_DIR/$id/meta.json")" != "$key" ]; then
    skipped+=("$id (cached under another key)")
  else
    echo "$path" >> "$WORK/apps-all.txt"
  fi
done < <(pinned_app_paths "$ROOT")

compared=$(wc -l < "$WORK/apps-all.txt")
mismatched=(); known_diff=(); details=(); filelists=()
if [ "$compared" -gt 0 ]; then
  log "rebuilding $compared app(s) without the cache"
  env -u CACHE_DIR NO_CACHE=true WORK="$WORK" RECIPES_DIR="$RECIPES_DIR" DEFAULT_RECIPE_FILE="$DEFAULT_RECIPE_FILE" \
    bash "$HERE/ionos-build-apps.sh" || die "the clean rebuild failed (see the log above)"
  while read -r path; do
    id=$(basename "$path")
    cached=$(jq -r '.checksum // ""' "$CACHE_DIR/$id/meta.json")
    rebuilt=$(jq -r --arg id "$id" '.[$id].checksum' "$WORK/app-builds.json")
    if [ "$cached" = "$rebuilt" ]; then continue; fi
    # which files differ: the restored cache tree against the tree just rebuilt in the app folder (the same
    # normalization as the checksum), for known apps too
    files=$(cache_tree_diff "$CACHE_DIR/$id/tree" "$ROOT/$path" 30 || true)
    [ -z "$files" ] || filelists+=("### Files of $id"$'\n\n```\n'"$files"$'\n```')
    reason=$(known "$id")
    if [ -n "$reason" ]; then
      known_diff+=("$id")
      details+=("- $id cached=$cached rebuilt=$rebuilt (known: $reason)")
    else
      mismatched+=("$id")
      details+=("- $id cached=$cached rebuilt=$rebuilt")
    fi
  done < "$WORK/apps-all.txt"
else
  warn "nothing was compared: no pinned app is in the cache under its current key (empty or missing cache, or other Node, PHP or recipe versions)"
fi

join() { local IFS=', '; echo "$*"; }
{
  echo "# App cache check"
  echo
  echo "compared: $compared"
  if [ ${#mismatched[@]} -eq 0 ]; then echo "mismatch: none"; else echo "mismatch: ${mismatched[*]}"; fi
  [ ${#known_diff[@]} -eq 0 ] || echo "known to differ: ${known_diff[*]}"
  [ ${#skipped[@]} -eq 0 ] && echo "skipped: none" || echo "skipped: $(join "${skipped[@]}")"
  echo "toolchain: node $NODE_V, php $PHP_V, composer $COMPOSER_V"
  if [ ${#details[@]} -gt 0 ]; then
    echo
    echo "A clean rebuild of these apps differs from the cached build of the same key:"
    echo
    printf '%s\n' "${details[@]}"
  fi
  if [ ${#filelists[@]} -gt 0 ]; then
    echo
    echo "Files that differ between the cached tree and the clean rebuild (at most 30 per app; the checksum's ignored patterns are left out):"
    for f in "${filelists[@]}"; do echo; echo "$f"; done
  fi
} > "$REPORT"
cat "$REPORT"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    if [ ${#mismatched[@]} -gt 0 ]; then echo "mismatch=true"; else echo "mismatch=false"; fi
    echo "mismatched=${mismatched[*]:-}"
    echo "compared=$compared"
  } >> "$GITHUB_OUTPUT"
fi
if [ ${#mismatched[@]} -gt 0 ]; then warn "clean rebuilds differ from the cache: ${mismatched[*]}"; fi
