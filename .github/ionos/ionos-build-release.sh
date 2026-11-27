# shellcheck shell=bash
# shellcheck disable=SC2154  # zips, assets, BASE, BUILD_NUMBER, REPO, OUT ... come from ionos-build-publish.sh, which sources this file
# The release path of ionos-build-publish.sh (see ionos-build.md). Source it, do not run it: it needs the variables and
# the arrays (zips, assets, flavors) that the publish script has built after its gate, and defines publish_release.
#
# A release build publishes a GitHub release ON THE EXISTING snapshot tag (the tag is never created here: --verify-tag
# makes gh refuse when it is missing). The first build creates the release; every rebuild of the same snapshot attaches
# its new assets to the SAME release and rewrites the body's archive table. Nothing is ever replaced or deleted: assets are
# uploaded without --clobber, and a build number that is not strictly larger than every one already attached is refused.
#
# Environment (besides the publish script's own; KIND=release):
#   SNAPSHOT_TAG, SNAPSHOT_BRANCH, RELEASE_NR, SNAPSHOT_BASE, RELEASE_SCOPE, SOURCE_BRANCH, SOURCE_COMMIT
#                      the facts the plan job read from the snapshot tag's annotation
#   REHEARSAL          true or false; must agree with the prefix of SNAPSHOT_BRANCH (rc/ or rehearsal/)

# The highest build number among the assets named on stdin (archives, checksums and attestation bundles); 0 for none.
highest_attached_build() {
  local n max=0 b
  while read -r n; do
    b=""
    if [[ $n =~ -v[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)\.zip(\.sha256)?$ ]]; then b=${BASH_REMATCH[1]}
    elif [[ $n =~ ^ncw-build-([0-9]+)\.attestation\.jsonl$ ]]; then b=${BASH_REMATCH[1]}; fi
    [ -z "$b" ] || [ "$b" -le "$max" ] || max=$b
  done
  echo "$max"
}

# archive_rows <dir>...: one line "<build>\t<flavor>\t<file>\t<sha256>" per <archive>.sha256 file found in the folders.
archive_rows() {
  local d f name sha
  for d in "$@"; do
    for f in "$d"/*.zip.sha256; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .sha256)
      sha=$(cut -d' ' -f1 "$f")
      if [[ $name =~ ^ncw-(.+)-v[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)\.zip$ ]]; then
        printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "$name" "$sha"
      fi
    done
  done
}

# release_notes <file> <rows file>: the release page.
release_notes() {
  local file="$1" rows="$2" build flavor name sha newest
  newest=$(sort -t$'\t' -k1,1nr "$rows" | head -n1 | cut -f1)
  {
    if [ "$REHEARSAL" = true ]; then
      echo "**REHEARSAL: this is a rehearsal of the release process, not a release. Do not deploy it.**"
      echo
    fi
    echo "> $RELEASE_SCOPE"
    echo
    echo "Release number: **$RELEASE_NR** (line $LINE) | Base release: **v$BASE**"
    echo
    echo "Snapshot: branch \`$SNAPSHOT_BRANCH\`, annotated tag \`$SNAPSHOT_TAG\`, taken from \`$SOURCE_BRANCH\` at \`$SOURCE_COMMIT\`. The snapshot is never rewritten."
    echo
    echo "## Archives"
    echo
    echo "| Flavor | File | Build number | SHA-256 |"
    echo "| --- | --- | --- | --- |"
    sort -t$'\t' -k1,1nr -k2,2 "$rows" | while IFS=$'\t' read -r build flavor name sha; do
      echo "| $flavor | [$name](https://github.com/$REPO/releases/download/$SNAPSHOT_TAG/$name) | $build | \`$sha\` |"
    done
    echo
    echo "Every archive has a \`.sha256\` file and a build provenance attestation (one bundle \`ncw-build-<build number>.attestation.jsonl\` per build). Verify an archive:"
    echo
    echo '```'
    echo "sha256sum -c <archive>.sha256"
    echo "gh attestation verify <archive> -R $REPO"
    echo '```'
    echo
    echo "A rebuild of this snapshot attaches archives with a new build number to this release; earlier archives stay."
    echo
    echo "release_nr: $RELEASE_NR"
    echo "base_release: v$BASE"
    echo "snapshot_branch: $SNAPSHOT_BRANCH"
    echo "snapshot_tag: $SNAPSHOT_TAG"
    echo "source_branch: $SOURCE_BRANCH"
    echo "source_commit: $SOURCE_COMMIT"
    echo "server_commit: $SERVER_COMMIT"
    echo "flavors_commit: $FLAVORS_COMMIT"
    echo "scope: $RELEASE_SCOPE"
    [ "$REHEARSAL" != true ] || echo "rehearsal: true"
    echo "latest_build_number: $newest"
    [ -z "$RUN_URL" ] || { echo; echo "Latest run: $RUN_URL"; }
  } > "$file"
}

publish_release() {
  local branch="${SNAPSHOT_BRANCH:-}" tag_expected prefix attached highest title exists=false
  SNAPSHOT_TAG=${SNAPSHOT_TAG:-}; RELEASE_NR=${RELEASE_NR:-}; RELEASE_SCOPE=${RELEASE_SCOPE-}; REHEARSAL=${REHEARSAL:-false}
  SOURCE_BRANCH=${SOURCE_BRANCH:-}; SOURCE_COMMIT=${SOURCE_COMMIT:-}; SNAPSHOT_BASE=${SNAPSHOT_BASE:-}
  [[ $branch =~ $SNAPSHOT_BRANCH_RE ]] || die "a release is published for a snapshot branch rc/ncw-v<nn>-<n>, not '$branch'"
  prefix=${BASH_REMATCH[1]}; LINE=${BASH_REMATCH[2]}
  [ "$RELEASE_NR" = "${BASH_REMATCH[3]}" ] || die "RELEASE_NR '$RELEASE_NR' is not the release number of $branch"
  case "$REHEARSAL" in true|false) ;; *) die "REHEARSAL must be true or false" ;; esac
  if [ "$prefix" = rehearsal ]; then [ "$REHEARSAL" = true ] || die "$branch is a rehearsal branch but REHEARSAL is $REHEARSAL"
  else [ "$REHEARSAL" = false ] || die "$branch is a real snapshot branch but REHEARSAL is $REHEARSAL: a rehearsal never uses the real names"; fi
  [ "$SNAPSHOT_BASE" = "$BASE" ] || die "the built tree has base release $BASE but the snapshot tag says '$SNAPSHOT_BASE'"
  tag_expected=$(snapshot_tag_name "$REHEARSAL" "$SNAPSHOT_BASE" "$RELEASE_NR")
  [ "$SNAPSHOT_TAG" = "$tag_expected" ] || die "the snapshot tag '$SNAPSHOT_TAG' is not $tag_expected, the tag of $branch on base release $BASE"
  valid_scope "$RELEASE_SCOPE" || die "no usable scope: it is read from the annotation of $SNAPSHOT_TAG"
  TAG=$SNAPSHOT_TAG

  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then exists=true; fi
  if [ "$exists" = true ]; then
    attached=$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name') || die "could not list the assets of the release $TAG"
    highest=$(highest_attached_build <<<"$attached")
    [ "$BUILD_NUMBER" -gt "$highest" ] \
      || die "build number $BUILD_NUMBER is not larger than $highest, the highest build already attached to the release $TAG: assets are never replaced, start a new run (a re-run of a finished run keeps its number)"
    local a
    for a in "${assets[@]}"; do
      ! grep -qxF "$(basename "$a")" <<<"$attached" || die "the asset $(basename "$a") is already attached to $TAG"
    done
  fi

  if [ "$CHECK_ONLY" = true ]; then
    log "checks passed for the release $TAG ($([ "$exists" = true ] && echo "rebuild: build $BUILD_NUMBER is above $highest" || echo "first build")): ${#zips[@]} archive(s), flavors $(paste -sd' ' "$WORK/flavors.txt")"
    return 0
  fi

  # The archive table lists every archive of the release: the checksums of the earlier builds are read back from the
  # release itself (its .sha256 assets), not from the old body, so a hand-edited body cannot lose a row.
  rm -rf "$WORK/previous"; mkdir -p "$WORK/previous"
  if [ "$exists" = true ]; then
    gh release download "$TAG" -R "$REPO" -p '*.sha256' -D "$WORK/previous" || die "could not read the checksums attached to $TAG"
  fi
  archive_rows "$WORK/previous" "$OUT" > "$WORK/rows.tsv"
  local notes="$WORK/release-notes.md"
  release_notes "$notes" "$WORK/rows.tsv"
  title=$TAG
  [ "$REHEARSAL" != true ] || title="$TAG (rehearsal, not a release)"

  if [ "$DRY_RUN" = true ]; then
    log "would $([ "$exists" = true ] && echo "attach" || echo "create the release $TAG with") ${#assets[@]} assets $([ "$exists" = true ] && echo "to the release $TAG and update its notes")"
    return 0
  fi
  if [ "$exists" = true ]; then
    log "attaching ${#assets[@]} assets of build $BUILD_NUMBER to the release $TAG"
    gh release upload "$TAG" -R "$REPO" "${assets[@]}"
    gh release edit "$TAG" -R "$REPO" --notes-file "$notes" \
      || die "the assets of build $BUILD_NUMBER are attached to $TAG, but its notes could not be updated: edit the release notes by hand (the new archive table is in $notes of this run) or leave them; nothing was replaced"
  else
    local flags=(--verify-tag --latest=false)
    [ "$REHEARSAL" != true ] || flags+=(--prerelease)
    log "creating the release $TAG on the existing snapshot tag with ${#assets[@]} assets"
    gh release create "$TAG" -R "$REPO" "${flags[@]}" --title "$title" --notes-file "$notes" "${assets[@]}"
  fi
}
