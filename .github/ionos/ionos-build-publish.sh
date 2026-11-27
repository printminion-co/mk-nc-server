#!/usr/bin/env bash
# Publishes the archives of a run: a dev build as ONE GitHub pre-release on a new tag dev-v<base>.<n>, a release build
# (KIND=release) as a GitHub release on the existing snapshot tag (ionos-build-release.sh). Needs gh and the files the build job handed
# over in $WORK. With --check it only runs the gate (everything below that refuses) and publishes nothing:
# the workflow runs it before the attestation, so only archives that pass are attested. Refuses (before any release call) when an archive has no checksum, when a flavor of
# the run has no archive, when the run did not validate every flavor, or when the release for this build number already exists.
#
# Environment:
#   WORK                the run's work folder: out/ (archives, .sha256 files, optional *.attestation.jsonl),
#                       flavors.txt (one flavor per line), validated, scope (all or subset),
#                       base-release (for example 33.0.9)
#   BUILD_NUMBER        the run number
#   SERVER_COMMIT, FLAVORS_COMMIT   the commits built (recorded in the release body)
#   RUN_URL             link to the workflow run
#   GITHUB_REPOSITORY   owner/name of this fork
#   DRY_RUN             "true" to check everything and print the command instead of running it
#   KIND                dev (default) or release; a release build also needs the SNAPSHOT_* and RELEASE_SCOPE variables of
#                       ionos-build-release.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-build
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

CHECK_ONLY=false
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  *) die "unknown argument '$1'" ;;
esac

WORK=${WORK:?WORK is required}
BUILD_NUMBER=${BUILD_NUMBER:?BUILD_NUMBER is required}
SERVER_COMMIT=${SERVER_COMMIT:?SERVER_COMMIT is required}
FLAVORS_COMMIT=${FLAVORS_COMMIT:?FLAVORS_COMMIT is required}
RUN_URL=${RUN_URL:-}
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
DRY_RUN=${DRY_RUN:-false}
OUT="$WORK/out"

[[ $BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER '$BUILD_NUMBER' is not a positive integer"
BASE=$(cat "$WORK/base-release")
[[ $BASE =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "base release '$BASE' is not <major>.<minor>.<patch>"
KIND=${KIND:-dev}
case "$KIND" in dev|release) ;; *) die "unknown build kind '$KIND', expected dev or release" ;; esac
TAG="dev-v$BASE.$BUILD_NUMBER"

cmp -s "$WORK/validated" "$WORK/flavors.txt" \
  || die "this run did not pass the static checks of every flavor (no $WORK/validated): nothing is published"

shopt -s nullglob
zips=("$OUT"/*.zip)
[ ${#zips[@]} -gt 0 ] || die "no archive in $OUT"
assets=()
for z in "${zips[@]}"; do
  [ -s "$z.sha256" ] || die "no checksum for $(basename "$z")"
  assets+=("$z" "$z.sha256")
done
flavors=()
while read -r f; do
  [ -n "$f" ] || continue
  [ -f "$OUT/ncw-$f-v$BASE.$BUILD_NUMBER.zip" ] || die "flavor $f has no archive ncw-$f-v$BASE.$BUILD_NUMBER.zip"
  flavors+=("$f")
done < "$WORK/flavors.txt"
[ ${#flavors[@]} -gt 0 ] || die "no flavors recorded in $WORK/flavors.txt"
( cd "$OUT" && sha256sum --check --quiet -- *.zip.sha256 ) || die "an archive does not match its checksum"
SCOPE=$(cat "$WORK/scope" 2>/dev/null || true)
[ "$SCOPE" = all ] || [ "$SCOPE" = subset ] || die "the scope of the run is '$SCOPE', expected all or subset"
for b in "$OUT"/*.attestation.jsonl; do assets+=("$b"); done

if [ "$KIND" = release ]; then
  # shellcheck source=ionos-build-release.sh
  . "$HERE/ionos-build-release.sh"
  publish_release
  exit 0
fi

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  die "the release $TAG exists already: a re-run of a finished run keeps its build number; start a new run"
fi

if [ "$CHECK_ONLY" = true ]; then
  log "checks passed for $TAG: ${#zips[@]} archive(s), flavors $(paste -sd' ' "$WORK/flavors.txt")"
  exit 0
fi

notes="$WORK/release-notes.md"
{
  echo "Development build $BUILD_NUMBER on the base release v$BASE. Not for production."
  echo
  echo "server_commit: $SERVER_COMMIT"
  echo "flavors_commit: $FLAVORS_COMMIT"
  echo "build_number: $BUILD_NUMBER"
  echo "base_release: v$BASE"
  echo "flavors_scope: $SCOPE"
  echo "flavors: $(IFS=,; echo "${flavors[*]}")"
  echo
  echo "Flavors:"
  for f in "${flavors[@]}"; do echo "- $f"; done
  echo
  echo "Every archive has a .sha256 file. Verify the provenance with: gh attestation verify <archive> -R $REPO"
  [ -z "$RUN_URL" ] || { echo; echo "Run: $RUN_URL"; }
} > "$notes"

if [ "$DRY_RUN" = true ]; then
  log "would create the pre-release $TAG on $SERVER_COMMIT with ${#assets[@]} assets"
  exit 0
fi
log "creating the pre-release $TAG on $SERVER_COMMIT with ${#assets[@]} assets"
gh release create "$TAG" -R "$REPO" --target "$SERVER_COMMIT" --prerelease --latest=false \
  --title "Dev build $BUILD_NUMBER (v$BASE base)" --notes-file "$notes" "${assets[@]}"
