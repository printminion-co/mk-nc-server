# shellcheck shell=bash
# The app build cache: key, checksum and the layout of the cache folder. Source it, do not run it.
# Needs ionos-lib.sh (die, log), jq, git, sha256sum and the tools whose versions go into the key
# (node, php and composer, which is COMPOSER or "composer").
#
# Layout of the cache folder (one folder, restored and saved as a whole by actions/cache):
#   <cache>/<app id>/tree        the built app folder without .git (node_modules is deleted by every recipe)
#   <cache>/<app id>/meta.json   key, checksum, app_commit, node, php, composer, recipe_hash
# Whatever is in a restored folder is untrusted input, like any build output. It is used only after its
# checksum is verified (cache_entry_valid) and then only as the tree of an app, which the assembly and the
# static checks of the flavors tool treat like a freshly built one. Nothing in it is ever executed.

# Version of the key and checksum rules. Part of every key, so a change here discards the whole cache.
CACHE_KEY_VERSION=1
# The portable prefix of the cache folder's key. The folder's key is this prefix and the sha256 of all per-app
# keys; the prefix is also the restore prefix that finds the newest folder. Nothing runner specific is in it.
CACHE_PREFIX="ionos-app-build-v${CACHE_KEY_VERSION}-"

cache_sha256_of() { sha256sum < "$1" | cut -d' ' -f1; }

cache_node_version() { node --version; }
cache_php_version() { php -r 'echo PHP_VERSION;'; }
# the major version of composer (2 for 2.7.1)
cache_composer_major() {
  local -a cmd; read -r -a cmd <<<"${COMPOSER:-composer}"
  "${cmd[@]}" --version | sed -n 's/^Composer version \([0-9][0-9]*\)\..*/\1/p' | head -n1
}

# The text a recipe is hashed by: the recipe file of the app when there is one, else the default recipe file
# (DEFAULT_RECIPE_FILE, set by ionos-build-apps.sh), which also holds the version of the rules.
cache_recipe_file() { # cache_recipe_file <app id>
  if [ -f "$RECIPES_DIR/$1.sh" ]; then echo "$RECIPES_DIR/$1.sh"; else echo "$DEFAULT_RECIPE_FILE"; fi
}

# cache_toolchain: "<node> <php> <composer major>" of this run, dies when one cannot be read (a key with a
# hole in it would match too much)
cache_toolchain() {
  local n p c
  n=$(cache_node_version) || die "cannot read the Node version (node --version)"
  p=$(cache_php_version) || die "cannot read the PHP version (php -r 'echo PHP_VERSION;')"
  c=$(cache_composer_major) || true
  if [ -z "$n" ] || [ -z "$p" ]; then die "empty Node or PHP version: no cache key can be made"; fi
  [ -n "$c" ] || die "cannot read the Composer major version (composer --version)"
  echo "$n $p $c"
}

# cache_app_key <app id> <app commit> <node> <php> <composer major>: the per-app key, a sha256 over a fixed
# text. No run id, no path, no runner name. The commit is the app's submodule commit (the tree id for an
# app that is not a submodule).
cache_app_key() {
  printf 'ncw-app-build-key v%s\napp=%s\ncommit=%s\nrecipe=%s\nnode=%s\nphp=%s\ncomposer=%s\n' \
    "$CACHE_KEY_VERSION" "$1" "$2" "$(cache_sha256_of "$(cache_recipe_file "$1")")" "$3" "$4" "$5" | sha256sum | cut -d' ' -f1
}

# What the checksum ignores, besides the top-level .git (not part of the app). Each entry is a `find` test and
# MUST name why. Measured by building all pinned apps twice (ionos-build.md, "Reproducibility of the app builds"):
#   *.map             source maps: debugging aids, never loaded by the server; app_api's js is identical in two builds but
#                     its js/app_api-adminSettings.js.map has other `mappings`
#   ./webpack-stats.json   the build report of the text app (untracked, left at the app root): `builtAt` is the build
#                     time and the asset order differs; not read at run time
# Nothing else is ignored. calendar's js (identifier mangling of two chunks) differs between builds and cannot be
# normalized: see ionos-cache-check-known.txt.
CACHE_CHECKSUM_IGNORE=( -path ./.git -o -name '*.map' -o -path ./webpack-stats.json )

# cache_tree_checksum <folder>: a deterministic sha256 of an app tree: the sorted list of every file with the
# sha256 of its content and of every symbolic link with its target (a link is never followed), as paths relative
# to the folder, except what CACHE_CHECKSUM_IGNORE names. Not part of it: timestamps, owners, modes and empty folders.
cache_tree_checksum() {
  local d="$1"
  [ -d "$d" ] || return 1
  (
    cd "$d" || exit 1
    export LC_ALL=C
    echo "ncw-tree-checksum v$CACHE_KEY_VERSION"
    find . \( "${CACHE_CHECKSUM_IGNORE[@]}" \) -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum -z -- | tr '\0' '\n' | sed 's/^/F /'
    find . \( "${CACHE_CHECKSUM_IGNORE[@]}" \) -prune -o -type l -printf 'L %l\0%p\0' | tr '\0' '\n' | paste -d' ' - - | sort
  ) | sha256sum | cut -d' ' -f1
}

# cache_tree_diff <cached tree> <rebuilt tree> [limit, default 30]: which files differ, for a human who has to find
# out why two checksums differ. Same files as the checksum (CACHE_CHECKSUM_IGNORE does not show). Prints nothing for
# equal trees, else a summary line, then at most <limit> lines "<marker>  <path>  cached=<size> rebuilt=<size>" sorted
# by path (markers: changed, only in cache, only in rebuild; a link shows "link"), then "... and N more". Control
# characters in paths are shown as "?".
cache_tree_diff() {
  local a="$1" b="$2" limit="${3:-30}" p shown
  local -A ha=() hb=() sa=() sb=()
  cache__list() { # cache__list <dir> <hash array> <size array>
    local -n _h="$2" _s="$3"; local line hash path
    while IFS= read -r -d '' line; do
      hash="${line%%  *}"; path="${line#*  ./}"; _h["$path"]="$hash"; _s["$path"]="$(stat -c %s -- "$1/$path") B"
    done < <(cd "$1" && find . \( "${CACHE_CHECKSUM_IGNORE[@]}" \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -z --)
    while IFS= read -r -d '' path; do
      _h["${path#./}"]="L:$(readlink -- "$1/$path")"; _s["${path#./}"]="link"
    done < <(cd "$1" && find . \( "${CACHE_CHECKSUM_IGNORE[@]}" \) -prune -o -type l -print0)
  }
  cache__list "$a" ha sa; cache__list "$b" hb sb
  local -a lines=(); local changed=0 oc=0 or=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    shown="${p//[^[:print:]]/?}"
    if [ -z "${hb[$p]+x}" ]; then lines+=("only in cache  $shown  cached=${sa[$p]} rebuilt=-"); oc=$((oc + 1))
    elif [ -z "${ha[$p]+x}" ]; then lines+=("only in rebuild  $shown  cached=- rebuilt=${sb[$p]}"); or=$((or + 1))
    elif [ "${ha[$p]}" != "${hb[$p]}" ]; then lines+=("changed  $shown  cached=${sa[$p]} rebuilt=${sb[$p]}"); changed=$((changed + 1)); fi
  done < <(printf '%s\n' "${!ha[@]}" "${!hb[@]}" | LC_ALL=C sort -u)
  [ ${#lines[@]} -gt 0 ] || return 0
  echo "${#lines[@]} files differ ($changed changed, $oc only in cache, $or only in rebuild)"
  printf '%s\n' "${lines[@]:0:$limit}"
  if [ ${#lines[@]} -gt "$limit" ]; then echo "... and $(( ${#lines[@]} - limit )) more"; fi
}

# cache_entry_valid <cache folder> <app id> <key>: succeeds when the cache holds a usable build of the app for
# exactly this key: a real folder (never a link) with a tree and a readable meta.json whose key equals <key>
# and whose checksum equals the checksum of the tree as it is now. Prints why not on failure (to stderr).
cache_entry_valid() {
  local dir="$1/$2" key="$3" mkey msum now
  [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "not a plain app id" >&2; return 1; }
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then echo "not in the cache" >&2; return 1; fi
  if [ ! -f "$dir/meta.json" ] || [ -L "$dir/meta.json" ]; then echo "no meta.json" >&2; return 1; fi
  mkey=$(jq -er '.key' "$dir/meta.json" 2>/dev/null) || { echo "meta.json is unreadable" >&2; return 1; }
  msum=$(jq -er '.checksum' "$dir/meta.json" 2>/dev/null) || { echo "meta.json has no checksum" >&2; return 1; }
  [ "$mkey" = "$key" ] || { echo "cached under another key" >&2; return 1; }
  if [ ! -d "$dir/tree" ] || [ -L "$dir/tree" ]; then echo "no tree" >&2; return 1; fi
  now=$(cache_tree_checksum "$dir/tree") || return 1
  [ "$now" = "$msum" ] || { echo "the cached tree does not match the checksum of its meta.json (checksum $now, recorded $msum)" >&2; return 1; }
}

# cache_folder_key <cache folder>: CACHE_PREFIX and the sha256 of the sorted "<app id> <key>" lines of every
# entry with a readable meta.json: the same set of keys gives the same folder key.
cache_folder_key() {
  local m id sum
  sum=$(for m in "$1"/*/meta.json; do
    [ -f "$m" ] || continue
    id=$(basename "$(dirname "$m")")
    printf '%s %s\n' "$id" "$(jq -r '.key // ""' "$m" 2>/dev/null)"
  done | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
  echo "${CACHE_PREFIX}${sum}"
}

# pinned_app_paths: every app of the app folders of the checked-out commit ($ROOT), as paths
# <folder>/<app id>, sorted: the entries of every top-level folder named apps-<something>.
pinned_app_paths() {
  local root="${1:-$(build_root)}" folder
  git -C "$root" ls-tree --name-only HEAD | { grep -E '^apps-[A-Za-z0-9._-]+$' || true; } | while read -r folder; do
    git -C "$root" ls-tree --name-only HEAD -- "$folder/"
  done | LC_ALL=C sort
}
