#!/usr/bin/env bash
# Prepares the CLEAN assembly tree $WORK/tree from the built checkout. The flavors tool loads the whole
# tree into memory, so nothing that must not ship is copied or is left in it. Follows upstream's release
# build (nextcloud-releases/server, .github/scripts), without signing:
#   - the checkout is copied without .git, node_modules, IONOS (the flavors submodule) and 3rdparty;
#   - 3rdparty is copied without .git, .github, .gitignore and README.md;
#   - what the server's root .nextcloudignore lists is removed (git ls-files -cio --exclude-from, so the
#     gitignore semantics are git's), and for every built out-of-tree app what its own .nextcloudignore
#     lists, except composer.json, composer.lock, package.json and package-lock.json;
#   - *.map.license files (symbolic links in the repository) are removed, as upstream does;
#   - config/config.php and data/ are removed, empty folders are removed;
#   - a symbolic link left in the tree is an error (the official archive has none and the tool cannot
#     ship broken ones).
# It also writes $WORK/base-release (for example 33.0.9). Needs git, rsync and find.
#
# Environment:  WORK, and optionally ROOT (default: the top level of the current checkout)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

ROOT=$(build_root)
WORK=${WORK:?WORK is required}
TREE="$WORK/tree"
KEEP_RE='^(composer\.(json|lock)|package(-lock)?\.json)$'

case "$(cd "$WORK" && pwd)/" in "$ROOT"/*) die "WORK ($WORK) must not be inside the checkout" ;; esac
[ -f "$ROOT/version.php" ] || die "$ROOT is not a server checkout (no version.php)"
[ -n "$(ls -A "$ROOT/3rdparty" 2>/dev/null)" ] || die "3rdparty is empty: the submodule was not initialised"

rm -rf "$TREE"; mkdir -p "$TREE"
log "copying the checkout"
rsync -a --exclude=.git --exclude=node_modules --exclude=/IONOS --exclude=/3rdparty "$ROOT/" "$TREE/"
mkdir -p "$TREE/3rdparty"
rsync -a --exclude=/.git --exclude=/.github --exclude=/.gitignore --exclude=/README.md "$ROOT/3rdparty/" "$TREE/3rdparty/"

# remove_ignored <source folder> <folder in the tree>: what <source>/.nextcloudignore lists
remove_ignored() {
  local src="$1" dst="$2"
  [ -f "$src/.nextcloudignore" ] || { log "$(basename "$src") has no .nextcloudignore"; return 0; }
  ( cd "$src" && git ls-files -cioz --exclude-from=.nextcloudignore ) \
    | { grep -zEv "$KEEP_RE" || true; } \
    | ( cd "$dst" && xargs -0 -r rm -rf -- )
}

log "applying .nextcloudignore of the server"
remove_ignored "$ROOT" "$TREE"
if [ -s "$WORK/apps-all.txt" ]; then
  while read -r path; do
    [ -n "$path" ] || continue
    log "applying .nextcloudignore of $path"
    remove_ignored "$ROOT/$path" "$TREE/$path"
  done < "$WORK/apps-all.txt"
fi

find "$TREE" -name '*.map.license' \( -type f -o -type l \) -delete
rm -rf "$TREE/config/config.php" "$TREE/data"
find "$TREE" -type d -empty -delete
mkdir -p "$TREE"

links=$(find "$TREE" -type l | head -n 20)
if [ -n "$links" ]; then
  warn "symbolic links in the assembly tree:"
  while read -r l; do echo "  ${l#"$TREE"/}" >&2; done <<<"$links"
  die "the assembly tree has symbolic links (first 20 listed); the official archive has none"
fi

base=$(base_release_of "$TREE")
[ -n "$base" ] || die "no \$OC_VersionString in version.php"
echo "$base" > "$WORK/base-release"
log "assembled $TREE (base release $base, $(find "$TREE" -type f | wc -l) files)"
