#!/usr/bin/env bash
# Tests for the ionos-build-*.sh scripts. Everything heavy (npm, composer, the flavors tool) is
# replaced by stubs through variables, and `gh` is a stub with a small stateful list of releases
# in $STUB_STATE. Nothing here talks to the network or to GitHub.
# Usage: ionos-build.test.sh [scenario ...]   (default: all scenarios)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$ROOT"' EXIT; else echo "keeping $ROOT" >&2; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

# Isolated git configuration: never use the developer's signing settings.
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name "Test"
git config --global user.email "test@example.invalid"
git config --global commit.gpgsign false
git config --global tag.gpgsign false
git config --global init.defaultBranch main
git config --global protocol.file.allow always

# ---------------------------------------------------------------- stub gh
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: releases live in $STUB_STATE/releases.json (the shape of GET /repos/{r}/releases).
S="$STUB_STATE"
echo "gh $*" >> "$S/calls.log"
save() { jq "$1" "$S/releases.json" > "$S/r.tmp" && mv "$S/r.tmp" "$S/releases.json"; }
exists() { jq -e --arg t "$1" 'any(.[]; .tag_name == $t)' "$S/releases.json" >/dev/null; }
case "$1" in
  api)
    shift
    args=("$@")
    ep=""; for a in "${args[@]}"; do case "$a" in repos/*) ep="$a" ;; esac; done
    case "$ep" in
      */releases/tags/*) t="${ep##*/releases/tags/}"; jq -r --arg t "$t" '.[]|select(.tag_name==$t)|.body' "$S/releases.json" ;;
      */git/matching-refs/tags/*) [ "${STUB_FAIL:-}" = tags ] && { echo "gh: boom (HTTP 500)" >&2; exit 1; }
        p="refs/tags/${ep#*/git/matching-refs/tags/}"; jq --arg p "$p" '[.[]|select(.ref|startswith($p))]' "$S/tags.json" 2>/dev/null || echo '[]' ;;
      */git/tags/*) cat "$S/tagobjs/${ep##*/git/tags/}.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
      */releases) [ "${STUB_FAIL:-}" = list ] && { echo "gh: boom (HTTP 500)" >&2; exit 1; }; cat "$S/releases.json" ;;
      *) echo "stub gh: unexpected api $ep" >&2; exit 2 ;;
    esac ;;
  release)
    sub="$2"; shift 2
    case "$sub" in
      view)
        tag="$1"; shift; json=""; jqx=""
        while [ $# -gt 0 ]; do case "$1" in --json) json="$2"; shift 2 ;; --jq) jqx="$2"; shift 2 ;; -R) shift 2 ;; *) shift ;; esac; done
        exists "$tag" || exit 1
        if [ "$json" = assets ]; then
          out="$(jq -c --arg t "$tag" '.[]|select(.tag_name==$t)|{assets:[.assets[]|{name:.}]}' "$S/releases.json")"
          if [ -n "$jqx" ]; then jq -r "$jqx" <<<"$out"; else echo "$out"; fi
        fi ;;
      upload)
        tag="$1"; shift; assets=()
        while [ $# -gt 0 ]; do case "$1" in -R) shift 2 ;; --clobber) echo "clobber" >> "$S/clobber.log"; shift ;; --*) shift ;; *) assets+=("$1"); shift ;; esac; done
        exists "$tag" || { echo "gh: release not found" >&2; exit 1; }
        [ "${STUB_FAIL:-}" = upload ] && { echo "gh: upload failed (HTTP 500)" >&2; exit 1; }
        for a in "${assets[@]}"; do
          n="$(basename "$a")"
          jq -e --arg t "$tag" --arg n "$n" 'any(.[]|select(.tag_name==$t)|.assets[]; .==$n)' "$S/releases.json" >/dev/null \
            && { echo "gh: asset $n already exists (HTTP 422)" >&2; exit 1; }
        done
        mkdir -p "$S/assets/$tag"
        for a in "${assets[@]}"; do
          cp "$a" "$S/assets/$tag/"
          save "map(if .tag_name == $(jq -Rn --arg t "$tag" '$t') then .assets += [$(jq -Rn --arg t "$(basename "$a")" '$t')] else . end)"
        done ;;
      edit)
        tag="$1"; shift; notes=""; title=""
        while [ $# -gt 0 ]; do case "$1" in --notes-file) notes="$2"; shift 2 ;; --title) title="$2"; shift 2 ;; -R) shift 2 ;; *) shift ;; esac; done
        exists "$tag" || { echo "gh: release not found" >&2; exit 1; }
        [ "${STUB_FAIL:-}" = edit ] && { echo "gh: edit failed (HTTP 500)" >&2; exit 1; }
        [ -z "$notes" ] || save "map(if .tag_name == $(jq -Rn --arg t "$tag" '$t') then .body = $(jq -Rn --arg t "$(cat "$notes")" '$t') else . end)"
        [ -z "$title" ] || save "map(if .tag_name == $(jq -Rn --arg t "$tag" '$t') then .name = $(jq -Rn --arg t "$title" '$t') else . end)" ;;
      download)
        tag="$1"; shift; pat=""; dir="."
        while [ $# -gt 0 ]; do case "$1" in -p|--pattern) pat="$2"; shift 2 ;; -D|--dir) dir="$2"; shift 2 ;; -R) shift 2 ;; *) shift ;; esac; done
        exists "$tag" || { echo "gh: release not found" >&2; exit 1; }
        mkdir -p "$dir"
        for f in "$S/assets/$tag/"*; do
          [ -e "$f" ] || continue
          # shellcheck disable=SC2254
          case "$(basename "$f")" in $pat) cp "$f" "$dir/" ;; esac
        done ;;
      create)
        tag="$1"; shift; title=""; notes=""; target=""; pre=false; latest=unset; verify=false; assets=(); files=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --notes-file) notes="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            -R) shift 2 ;;
            --prerelease) pre=true; shift ;;
            --latest=*) latest="${1#--latest=}"; shift ;;
            --verify-tag) verify=true; shift ;;
            --*) shift ;;
            *) assets+=("$(basename "$1")"); files+=("$1"); shift ;;
          esac
        done
        [ "${STUB_FAIL:-}" = release ] && { echo "gh: release failed (HTTP 500)" >&2; exit 1; }
        exists "$tag" && { echo "gh: tag exists (HTTP 422)" >&2; exit 1; }
        if [ "$verify" = true ]; then
          jq -e --arg r "refs/tags/$tag" 'any(.[]; .ref == $r)' "$S/tags.json" >/dev/null 2>&1 || { echo "gh: tag $tag does not exist (--verify-tag)" >&2; exit 1; }
        fi
        body="$(cat "$notes")"
        n="$(jq 'length' "$S/releases.json")"
        mkdir -p "$S/assets/$tag"; for f in "${files[@]}"; do cp "$f" "$S/assets/$tag/"; done
        save ". + [{\"tag_name\":$(jq -Rn --arg t "$tag" '$t'),\"name\":$(jq -Rn --arg t "$title" '$t'),\"prerelease\":$pre,\"latest\":\"$latest\",\"verify_tag\":$verify,\"draft\":false,\"target_commitish\":$(jq -Rn --arg t "$target" '$t'),\"body\":$(jq -Rn --arg t "$body" '$t'),\"assets\":$(printf '%s\n' "${assets[@]}" | jq -R . | jq -sc .),\"id\":$((n + 1))}]" ;;
      delete)
        tag="$1"; exists "$tag" || { echo "gh: not found" >&2; exit 1; }
        save "map(select(.tag_name != $(jq -Rn --arg t "$tag" '$t')))"
        echo "$tag" >> "$S/deleted.log" ;;
      *) echo "stub gh: unsupported release $sub" >&2; exit 2 ;;
    esac ;;
  *) echo "stub gh: unsupported: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/gh"

# ---------------------------------------------------------------- helpers
# newworld <name>: a state directory with an empty release list and an empty call log
newworld() {
  local w="$ROOT/$1"
  mkdir -p "$w/state"
  echo '[]' > "$w/state/releases.json"
  : > "$w/state/calls.log"
}
# addrel <world> <tag> <prerelease true|false> [<server_commit> <flavors_commit> [<flavors_scope: all|subset|empty for none>]]
addrel() {
  local body="" scope="${6-all}"
  [ -n "${4:-}" ] && body=$'Dev build\n\nserver_commit: '"$4"$'\nflavors_commit: '"$5"$'\n'
  [ -n "${4:-}" ] && [ -n "$scope" ] && body+="flavors_scope: $scope"$'\n'
  jq --arg t "$2" --argjson p "$3" --arg b "$body" '. + [{"tag_name":$t,"prerelease":$p,"draft":false,"body":$b}]' \
    "$ROOT/$1/state/releases.json" > "$ROOT/$1/state/r.tmp" && mv "$ROOT/$1/state/r.tmp" "$ROOT/$1/state/releases.json"
}
tags() { jq -r '[.[].tag_name] | sort | join(" ")' "$ROOT/$1/state/releases.json"; }
# run_in <world> <script> [VAR=value ...]: runs a script in $ROOT/$1/repo, output in out.log, status in status
run_in() {
  local w="$ROOT/$1" script="$2"; shift 2
  ( cd "$w/repo" 2>/dev/null || cd "$w" || exit 1
    : > "$w/gh_output"
    env PATH="$ROOT/bin:$PATH" STUB_STATE="$w/state" GITHUB_REPOSITORY=acme/server GITHUB_OUTPUT="$w/gh_output" "$@" \
      bash "$HERE/$script" ${SCRIPT_ARGS:+"$SCRIPT_ARGS"} > "$w/out.log" 2>&1
    echo $? > "$w/status" )
}
status() { cat "$ROOT/$1/status"; }
output() { grep -m1 "^$2=" "$ROOT/$1/gh_output" | cut -d= -f2-; }
logged() { grep -q -- "$2" "$ROOT/$1/out.log"; }
n_calls() { grep -c -- "$2" "$ROOT/$1/state/calls.log"; }

# repo <world>: a git repo with a commit and a gitlink IONOS (the flavors submodule pin)
FLAVORS_SHA=1111111111111111111111111111111111111111
repo() {
  local w="$ROOT/$1"; mkdir -p "$w/repo"
  git -C "$w/repo" init -q -b ionos-dev-v33
  echo x > "$w/repo/file"; git -C "$w/repo" add file
  git -C "$w/repo" update-index --add --cacheinfo "160000,${2:-$FLAVORS_SHA},IONOS"
  git -C "$w/repo" commit -q -m "IONOS(x): one"
}
head_of() { git -C "$ROOT/$1/repo" rev-parse HEAD; }

# ---------------------------------------------------------------- plan
sc_plan() {
  newworld p1; repo p1
  run_in p1 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "scheduled run with no earlier dev pre-release builds" test "$(output p1 build)" = true
  check "plan exits 0" test "$(status p1)" = 0
  check "plan reports the line derived from the branch name" test "$(output p1 line)" = 33
  check "plan reports the commits" test "$(output p1 server_commit)" = "$(head_of p1)" -a "$(output p1 flavors_commit)" = "$FLAVORS_SHA"

  newworld p2; repo p2
  addrel p2 dev-v33.0.9.5 true "$(head_of p2)" "$FLAVORS_SHA"
  run_in p2 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "scheduled run skips when nothing changed since the last dev pre-release" test "$(output p2 build)" = false
  check "the skip is logged and the run succeeds" bash -c "grep -q 'nothing changed' '$ROOT/p2/out.log' && test '$(status p2)' = 0"

  run_in p2 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=ionos-dev-v33
  check "a manual run builds although nothing changed" test "$(output p2 build)" = true
  run_in p2 ionos-build-plan.sh EVENT_NAME=schedule FORCE=true KIND=dev REF_NAME=ionos-dev-v33
  check "force builds although nothing changed" test "$(output p2 build)" = true

  echo y >> "$ROOT/p2/repo/file"; git -C "$ROOT/p2/repo" add file && git -C "$ROOT/p2/repo" commit -qm "IONOS(x): two"
  run_in p2 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "scheduled run builds when the server commit changed" test "$(output p2 build)" = true

  newworld p3; repo p3 2222222222222222222222222222222222222222
  addrel p3 dev-v33.0.9.5 true "$(head_of p3)" "$FLAVORS_SHA"
  run_in p3 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "scheduled run builds when the flavors commit changed" test "$(output p3 build)" = true

  newworld p4; repo p4
  addrel p4 dev-v33.0.9.9 true "deadbeef" "deadbeef"
  addrel p4 dev-v33.0.9.12 true "$(head_of p4)" "$FLAVORS_SHA"
  addrel p4 v33.0.9 false "$(head_of p4)" "$FLAVORS_SHA"
  run_in p4 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "the newest dev pre-release is the one with the highest build number" test "$(output p4 build)" = false

  newworld p5; repo p5
  addrel p5 dev-v33.0.9.3 false "$(head_of p5)" "$FLAVORS_SHA"
  addrel p5 v33.0.9 true "$(head_of p5)" "$FLAVORS_SHA"
  run_in p5 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "only dev- pre-releases count (a final release or another pre-release does not)" test "$(output p5 build)" = true

  newworld p7; repo p7
  addrel p7 dev-v33.0.9.5 true "$(head_of p7)" "$FLAVORS_SHA" subset
  run_in p7 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "a subset run is no baseline: the scheduled run builds although the commits are the same" test "$(output p7 build)" = true
  newworld p8; repo p8
  addrel p8 dev-v33.0.9.4 true "$(head_of p8)" "$FLAVORS_SHA" all
  addrel p8 dev-v33.0.9.5 true "$(head_of p8)" "$FLAVORS_SHA" subset
  run_in p8 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "a subset run after a full run: the previous pre-release is the subset one, so it builds" test "$(output p8 build)" = true
  newworld p9; repo p9
  addrel p9 dev-v33.0.9.5 true "$(head_of p9)" "$FLAVORS_SHA" ""
  run_in p9 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "a pre-release that does not say which flavors it covered is no baseline" test "$(output p9 build)" = true
  run_in p9 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=ionos-dev-v33 FLAVORS=flavor1
  check "plan accepts the flavors input" test "$(status p9)" = 0
  run_in p9 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=ionos-dev-v33 'FLAVORS=a/../b'
  check "plan refuses a flavors input with a bad name early" test "$(status p9)" != 0

  newworld p6; repo p6
  run_in p6 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=release REF_NAME=ionos-dev-v33
  check "release kind on the dev branch fails early" test "$(status p6)" != 0
  check "and says release builds run only from a snapshot branch" logged p6 'rc/ncw-v<nn>-<n>'
  check "release kind sets no build output" test -z "$(output p6 build)"
  run_in p6 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=rc/ncw-v33-1
  check "a dev build from a snapshot branch is refused" test "$(status p6)" != 0
  run_in p6 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=bogus REF_NAME=ionos-dev-v33
  check "an unknown kind fails" test "$(status p6)" != 0
  run_in p6 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=main
  check "a ref that is not a dev branch fails" test "$(status p6)" != 0
  check "a ref that is not a dev branch is named in the error" logged p6 '::error::.*main'
  run_in p6 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33 STUB_FAIL=list
  check "a failing release listing fails the run (no silent skip)" test "$(status p6)" != 0
}

# ---------------------------------------------------------------- retention
sc_retention() {
  newworld r1; local i
  for i in $(seq 1 20); do addrel r1 "dev-v33.0.9.$i" true; done
  addrel r1 v33.0.9 false
  addrel r1 v33.0.10rc1 true
  addrel r1 dev-v33.0.9.99 false
  addrel r1 dev-v33.0.9.x true
  addrel r1 snapshot-dev-v33.0.9.1 true
  local before; before="$(tags r1)"
  run_in r1 ionos-build-retain.sh DRY_RUN=true
  check "dry run succeeds" test "$(status r1)" = 0
  check "dry run changes nothing" test "$(tags r1)" = "$before"
  check "dry run says what it would delete" logged r1 'would delete dev-v33.0.9.1\b'
  check "dry run makes no delete call" test "$(n_calls r1 'release delete')" = 0

  run_in r1 ionos-build-retain.sh
  check "retention succeeds" test "$(status r1)" = 0
  local left; left="$(jq -r '[.[]|select(.prerelease and (.tag_name|test("^dev-v33\\.0\\.9\\.[0-9]+$")))|.tag_name|split(".")[3]|tonumber]|sort|join(" ")' "$ROOT/r1/state/releases.json")"
  check "the newest 14 dev pre-releases are kept (7 to 20)" test "$left" = "7 8 9 10 11 12 13 14 15 16 17 18 19 20"
  check "the 6 oldest are deleted" test "$(wc -l < "$ROOT/r1/state/deleted.log")" = 6
  check "a final release, another pre-release, a non-pre-release dev tag and odd tags are untouched" \
    bash -c "jq -e '[.[].tag_name] | (index(\"v33.0.9\") and index(\"v33.0.10rc1\") and index(\"dev-v33.0.9.99\") and index(\"dev-v33.0.9.x\") and index(\"snapshot-dev-v33.0.9.1\"))' '$ROOT/r1/state/releases.json'"
  check "the tag is cleaned up with the release" grep -q -- '--cleanup-tag' "$ROOT/r1/state/calls.log"
  check "deletions are logged" logged r1 'deleting dev-v33.0.9.1\b'
  run_in r1 ionos-build-retain.sh
  check "a second run deletes nothing more" test "$(wc -l < "$ROOT/r1/state/deleted.log")" = 6

  newworld r2
  for i in $(seq 1 5); do addrel r2 "dev-v33.0.9.$i" true; done
  run_in r2 ionos-build-retain.sh KEEP=2
  check "KEEP is configurable" test "$(tags r2)" = "dev-v33.0.9.4 dev-v33.0.9.5"
  run_in r2 ionos-build-retain.sh KEEP=0
  check "KEEP below 1 is refused" test "$(status r2)" != 0
  run_in r2 ionos-build-retain.sh KEEP=abc
  check "a non-numeric KEEP is refused" test "$(status r2)" != 0
  check "nothing was deleted by the refused runs" test "$(tags r2)" = "dev-v33.0.9.4 dev-v33.0.9.5"
  newworld r3; addrel r3 dev-v33.0.9.1 true
  run_in r3 ionos-build-retain.sh STUB_FAIL=list
  check "a failing listing deletes nothing and fails" test "$(status r3)" != 0 -a "$(tags r3)" = dev-v33.0.9.1
}

# ---------------------------------------------------------------- publish
# pubworld <name>: a work directory with two flavors' archives and checksums
pubworld() { # pubworld <name> [build number, default 42]
  local bn="${2:-42}"
  newworld "$1"
  local w="$ROOT/$1/work"; mkdir -p "$w/out"
  local f
  for f in flavor1 flavor2; do
    echo "zip $f $bn" > "$w/out/ncw-$f-v33.0.9.$bn.zip"
    (cd "$w/out" && sha256sum "ncw-$f-v33.0.9.$bn.zip" > "ncw-$f-v33.0.9.$bn.zip.sha256")
  done
  printf 'flavor1\nflavor2\n' > "$w/flavors.txt"
  echo 33.0.9 > "$w/base-release"; echo all > "$w/scope"
  cp "$w/flavors.txt" "$w/validated"
}
PUB="BUILD_NUMBER=42 SERVER_COMMIT=aaaaaaa FLAVORS_COMMIT=bbbbbbb RUN_URL=https://example.invalid/run/1"
sc_publish() {
  pubworld u1
  # shellcheck disable=SC2086
  run_in u1 ionos-build-publish.sh WORK="$ROOT/u1/work" $PUB
  check "publish succeeds" test "$(status u1)" = 0
  check "one pre-release tagged dev-v<base>.<build number>" test "$(tags u1)" = dev-v33.0.9.42
  check "it is a pre-release" jq -e '.[0].prerelease' "$ROOT/u1/state/releases.json"
  check "it is created on the built commit" test "$(jq -r '.[0].target_commitish' "$ROOT/u1/state/releases.json")" = aaaaaaa
  check "title names the build number and the base release" test "$(jq -r '.[0].name' "$ROOT/u1/state/releases.json")" = "Dev build 42 (v33.0.9 base)"
  check "assets: every zip and its checksum" test "$(jq -r '.[0].assets | sort | join(" ")' "$ROOT/u1/state/releases.json")" = "ncw-flavor1-v33.0.9.42.zip ncw-flavor1-v33.0.9.42.zip.sha256 ncw-flavor2-v33.0.9.42.zip ncw-flavor2-v33.0.9.42.zip.sha256"
  local body; body="$(jq -r '.[0].body' "$ROOT/u1/state/releases.json")"
  check "body has the machine-readable lines" bash -c "grep -qx 'server_commit: aaaaaaa' <<<'$body' && grep -qx 'flavors_commit: bbbbbbb' <<<'$body' && grep -qx 'build_number: 42' <<<'$body'"
  check "body lists the flavors and links the run" bash -c "grep -q 'flavor1' <<<'$body' && grep -q 'flavor2' <<<'$body' && grep -q 'https://example.invalid/run/1' <<<'$body'"
  check "the planner reads the body back" bash -c "test \"\$(cd '$ROOT/u1' && . '$HERE/ionos-lib.sh' && body_value server_commit <<<'$body')\" = aaaaaaa"

  check "body names the scope and the flavors of the run" bash -c "grep -qx 'flavors_scope: all' <<<'$body' && grep -qx 'flavors: flavor1,flavor2' <<<'$body'"
  pubworld u2; echo bundle > "$ROOT/u2/work/out/ncw-build-42.attestation.jsonl"
  # shellcheck disable=SC2086
  run_in u2 ionos-build-publish.sh WORK="$ROOT/u2/work" $PUB
  check "an attestation bundle in the output folder is attached too" bash -c "jq -e '.[0].assets | index(\"ncw-build-42.attestation.jsonl\")' '$ROOT/u2/state/releases.json'"

  pubworld u3; addrel u3 dev-v33.0.9.42 true
  # shellcheck disable=SC2086
  run_in u3 ionos-build-publish.sh WORK="$ROOT/u3/work" $PUB
  check "an existing tag for the build number fails without touching it" test "$(status u3)" != 0 -a "$(n_calls u3 'release create')" = 0

  pubworld u4; rm "$ROOT/u4/work/out/ncw-flavor2-v33.0.9.42.zip.sha256"
  # shellcheck disable=SC2086
  run_in u4 ionos-build-publish.sh WORK="$ROOT/u4/work" $PUB
  check "a zip without a checksum fails before any release call" test "$(status u4)" != 0 -a "$(n_calls u4 'release create')" = 0

  pubworld u5; rm "$ROOT/u5/work/out/"*.zip
  # shellcheck disable=SC2086
  run_in u5 ionos-build-publish.sh WORK="$ROOT/u5/work" $PUB
  check "no archive fails before any release call" test "$(status u5)" != 0 -a "$(n_calls u5 'release create')" = 0

  pubworld u6; rm "$ROOT/u6/work/out/ncw-flavor2-v33.0.9.42.zip" "$ROOT/u6/work/out/ncw-flavor2-v33.0.9.42.zip.sha256"
  # shellcheck disable=SC2086
  run_in u6 ionos-build-publish.sh WORK="$ROOT/u6/work" $PUB
  check "a flavor of the run without an archive fails before any release call" test "$(status u6)" != 0 -a "$(n_calls u6 'release create')" = 0

  pubworld c1
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c1 ionos-build-publish.sh WORK="$ROOT/c1/work" $PUB
  check "--check passes for a good run and makes no release call" test "$(status c1)" = 0 -a "$(n_calls c1 'release create')" = 0
  pubworld c2; echo corrupt >> "$ROOT/c2/work/out/ncw-flavor1-v33.0.9.42.zip"
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c2 ionos-build-publish.sh WORK="$ROOT/c2/work" $PUB
  check "--check fails when an archive does not match its checksum" test "$(status c2)" != 0
  pubworld c3; rm "$ROOT/c3/work/validated"
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c3 ionos-build-publish.sh WORK="$ROOT/c3/work" $PUB
  check "--check fails without the validated marker" test "$(status c3)" != 0
  pubworld c4; echo flavor1 > "$ROOT/c4/work/validated"
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c4 ionos-build-publish.sh WORK="$ROOT/c4/work" $PUB
  check "--check fails when the marker does not match the flavor list" test "$(status c4)" != 0
  pubworld c5; addrel c5 dev-v33.0.9.42 true
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c5 ionos-build-publish.sh WORK="$ROOT/c5/work" $PUB
  check "--check fails when the release exists already" test "$(status c5)" != 0
  pubworld c6; echo weird > "$ROOT/c6/work/scope"
  # shellcheck disable=SC2086
  SCRIPT_ARGS=--check run_in c6 ionos-build-publish.sh WORK="$ROOT/c6/work" $PUB
  check "--check fails on an unknown scope" test "$(status c6)" != 0

  pubworld u7
  # shellcheck disable=SC2086
  run_in u7 ionos-build-publish.sh WORK="$ROOT/u7/work" $PUB DRY_RUN=true
  check "dry run creates nothing" test "$(n_calls u7 'release create')" = 0 -a "$(status u7)" = 0
}

# ---------------------------------------------------------------- release builds: plan
# msg <rehearsal> <line> <base> <nr> <source branch> <source commit> <scope>: a snapshot tag annotation
msg() { ( . "$HERE/ionos-lib.sh"; snapshot_tag_message "$@" ); }
# addtag <world> <tag name> <annotated true|false> <commit> <annotation>: a tag of the stubbed fork
addtag() {
  local w="$ROOT/$1/state" obj="obj-$2"
  [ -f "$w/tags.json" ] || echo '[]' > "$w/tags.json"
  mkdir -p "$w/tagobjs"
  if [ "$3" = true ]; then
    jq --arg r "refs/tags/$2" --arg o "$obj" '. + [{ref:$r,object:{type:"tag",sha:$o}}]' "$w/tags.json" > "$w/t.tmp"
    jq -n --arg c "$4" --arg m "$5" '{object:{type:"commit",sha:$c},message:$m}' > "$w/tagobjs/$obj.json"
  else
    jq --arg r "refs/tags/$2" --arg c "$4" '. + [{ref:$r,object:{type:"commit",sha:$c}}]' "$w/tags.json" > "$w/t.tmp"
  fi
  mv "$w/t.tmp" "$w/tags.json"
}
RPLAN=(EVENT_NAME=workflow_dispatch KIND=release REF_TYPE=branch)
sc_release_plan() {
  newworld q; repo q; local h; h=$(head_of q)
  addtag q ncw-v33.0.9-1 true "$h" "$(msg false 33 33.0.9 1 ionos-dev-v33 "$h" 'First release: flavor1 = x')"
  run_in q ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "a release build of a snapshot branch with its tag is planned" test "$(status q)" = 0 -a "$(output q build)" = true
  check "kind, tag and base release are reported" test "$(output q kind)" = release -a "$(output q tag)" = ncw-v33.0.9-1 -a "$(output q base_release)" = 33.0.9
  check "line, release number, snapshot branch, rehearsal" test "$(output q line)" = 33 -a "$(output q release_nr)" = 1 -a "$(output q snapshot_branch)" = rc/ncw-v33-1 -a "$(output q rehearsal)" = false
  check "the scope is read from the tag annotation (with = and spaces intact)" test "$(output q scope)" = 'First release: flavor1 = x'
  check "source branch and commit come from the annotation too" test "$(output q source_branch)" = ionos-dev-v33 -a "$(output q source_commit)" = "$h"
  check "the commits built are reported" test "$(output q server_commit)" = "$h" -a "$(output q flavors_commit)" = "$FLAVORS_SHA"
  run_in q ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1 FORCE=false EVENT_NAME=schedule
  check "a release build is never started by a schedule" test "$(status q)" != 0
  run_in q ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1 FLAVORS=flavor1
  check "a release build builds every flavor: the flavors input is refused" test "$(status q)" != 0
  check "and says why" logged q 'flavors'
  run_in q ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1 FORCE=true
  check "force makes no sense for a release build and is refused" test "$(status q)" != 0
  run_in q ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1 REF_TYPE=tag
  check "a tag ref named like a snapshot branch is refused" test "$(status q)" != 0
  local bad
  for bad in main ionos-dev-v33 rc/ncw-v33-01 rc/ncw-v33-0 rc/ncw-v33-x rc/ncw-v33 rc/ncw-v33-1/x candidate/ionos-dev-v33/v33.0.10 rehearsal/ncw-v33-1x 'rc/ncw-v33-1;id' foo/ncw-v33-1; do
    run_in q ionos-build-plan.sh "${RPLAN[@]}" "REF_NAME=$bad"
    check "ref '$bad' is refused for a release build" test "$(status q)" != 0 -a -z "$(output q build)"
  done

  newworld q2; repo q2; h=$(head_of q2)
  run_in q2 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "a snapshot branch without any tag is refused" test "$(status q2)" != 0
  check "the message says the snapshot workflow makes the tag" logged q2 'snapshot workflow'
  addtag q2 ncw-v33.0.9-1 false "$h" ""
  run_in q2 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "a lightweight tag is refused (it cannot carry the scope)" test "$(status q2)" != 0 -a -z "$(output q2 build)"
  check "and the message says lightweight" logged q2 'lightweight'

  newworld q3; repo q3; h=$(head_of q3)
  addtag q3 ncw-v33.0.9-1 true 9999999999999999999999999999999999999999 "$(msg false 33 33.0.9 1 ionos-dev-v33 "$h" 's')"
  run_in q3 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "a tag that points at another commit than the one built is refused" test "$(status q3)" != 0 -a -z "$(output q3 build)"
  check "and the message names both commits" logged q3 '9999999999999999999999999999999999999999'

  newworld q4; repo q4; h=$(head_of q4)
  addtag q4 ncw-v33.0.9-1 true "$h" "$(msg false 33 33.0.9 2 ionos-dev-v33 "$h" 's')"
  run_in q4 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "an annotation with another release number than the branch is refused" test "$(status q4)" != 0
  newworld q5; repo q5; h=$(head_of q5)
  addtag q5 ncw-v33.0.9-1 true "$h" "$(msg true 33 33.0.9 1 ionos-dev-v33 "$h" 's')"
  run_in q5 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "an annotation of a rehearsal on a real branch is refused" test "$(status q5)" != 0
  newworld q6; repo q6; h=$(head_of q6)
  addtag q6 ncw-v33.0.9-1 true "$h" "$(msg false 33 33.0.10 1 ionos-dev-v33 "$h" 's')"
  run_in q6 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "an annotation whose base release does not fit the tag name is refused" test "$(status q6)" != 0
  newworld q7; repo q7; h=$(head_of q7)
  addtag q7 ncw-v33.0.9-1 true "$h" "no keys at all"
  run_in q7 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "an annotation without the snapshot facts is refused" test "$(status q7)" != 0
  newworld q8; repo q8; h=$(head_of q8)
  addtag q8 ncw-v33.0.9-1 true "$h" "$(msg false 33 33.0.9 1 ionos-dev-v33 "$h" 's')"
  addtag q8 ncw-v33.0.8-1 true "$h" "$(msg false 33 33.0.8 1 ionos-dev-v33 "$h" 's')"
  run_in q8 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "two tags with the same release number on the line are refused" test "$(status q8)" != 0
  newworld q9; repo q9; h=$(head_of q9)
  addtag q9 ncw-v33.0.9-10 true "$h" "$(msg false 33 33.0.9 10 ionos-dev-v33 "$h" 'ten')"
  run_in q9 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "the tag of release 10 is not the tag of release 1" test "$(status q9)" != 0
  addtag q9 rehearsal-v33.0.9-1 true "$h" "$(msg true 33 33.0.9 1 ionos-dev-v33 "$h" 'rehearse')"
  run_in q9 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rc/ncw-v33-1
  check "a rehearsal tag is never the tag of a real snapshot branch" test "$(status q9)" != 0
  run_in q9 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rehearsal/ncw-v33-1
  check "a rehearsal branch finds its rehearsal tag" test "$(status q9)" = 0 -a "$(output q9 rehearsal)" = true -a "$(output q9 tag)" = rehearsal-v33.0.9-1
  check "the rehearsal flag comes from the ref, the scope from the annotation" test "$(output q9 snapshot_branch)" = rehearsal/ncw-v33-1 -a "$(output q9 scope)" = rehearse
  run_in q9 ionos-build-plan.sh "${RPLAN[@]}" REF_NAME=rehearsal/ncw-v33-1 STUB_FAIL=tags
  check "a failing tag listing fails the run" test "$(status q9)" != 0

  # dev behavior is unchanged
  newworld q10; repo q10
  run_in q10 ionos-build-plan.sh EVENT_NAME=workflow_dispatch KIND=dev REF_NAME=ionos-dev-v33
  check "a dev run still reports kind dev and no snapshot facts" test "$(output q10 kind)" = dev -a -z "$(output q10 tag)" -a -z "$(output q10 scope)"
  run_in q10 ionos-build-plan.sh EVENT_NAME=schedule KIND=dev REF_NAME=ionos-dev-v33
  check "a scheduled dev run still reports kind dev" test "$(output q10 kind)" = dev
}

# ---------------------------------------------------------------- release builds: package
sc_release_package() {
  [ -d "$ROOT/src/a" ] || mkapp a
  fork z1 a
  run_build z1 ionos-build-select.sh
  run_build z1 ionos-build-apps.sh
  run_build z1 ionos-build-assemble.sh
  local sha=0123456789abcdef0123456789abcdef01234567 fsha=fedcba9876543210fedcba9876543210fedcba98
  local rel=(KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 "RELEASE_SCOPE=First release: \$(x) & y" SNAPSHOT_BASE=33.0.9)
  run_build z1 ionos-build-package.sh BUILD_NUMBER=58 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha "${rel[@]}"
  check "a release package succeeds" test "$(status z1)" = 0
  check "build gets kind release" grep -q 'ncw build flavor1 kind=release bn=58 ' "$ROOT/z1/ncw.log"
  check "build gets snapshot branch, release number and the scope text intact" grep -qF 'sb=rc/ncw-v33-1 rn=1 scope=First release: $(x) & y' "$ROOT/z1/ncw.log"
  check "every flavor gets them" test "$(grep -c 'kind=release bn=58 .*sb=rc/ncw-v33-1 rn=1' "$ROOT/z1/ncw.log" | head -1)" = 2
  check "the archives carry the release build number" test -f "$ROOT/z1/work/out/ncw-flavor1-v33.0.9.58.zip.sha256"
  check "validate runs for a release build too" test "$(grep -c '^ncw validate' "$ROOT/z1/ncw.log")" = 2
  check "a release build records the used app builds too (key and checksum of a)" bash -c "jq -e '(.a.key|length==64) and (.a.checksum|length==64)' '$ROOT/z1/ncw.log.keys.flavor1'"
  check "the run is marked validated" test "$(cat "$ROOT/z1/work/validated")" = "$(cat "$ROOT/z1/work/flavors.txt")"
  run_build z1 ionos-build-package.sh BUILD_NUMBER=58 LINE=33 "SERVER_COMMIT=$sha" "FLAVORS_COMMIT=$fsha" KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 "RELEASE_SCOPE=--kind dev" SNAPSHOT_BASE=33.0.9
  check "a scope that looks like an option is passed as the value of --scope, not parsed as an option" test "$(status z1)" = 0 -a "$(grep -c 'kind=release bn=58 .* scope=--kind dev$' "$ROOT/z1/ncw.log")" -ge 1
  local base_args=(BUILD_NUMBER=59 LINE=33 "SERVER_COMMIT=$sha" "FLAVORS_COMMIT=$fsha")
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release RELEASE_NR=1 RELEASE_SCOPE=s SNAPSHOT_BASE=33.0.9
  check "a release build without the snapshot branch is refused" test "$(status z1)" != 0
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_SCOPE=s SNAPSHOT_BASE=33.0.9
  check "a release build without the release number is refused" test "$(status z1)" != 0
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 SNAPSHOT_BASE=33.0.9
  check "a release build without the scope is refused" test "$(status z1)" != 0
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 RELEASE_SCOPE=s SNAPSHOT_BASE=33.0.10
  check "a base release that differs from the snapshot tag's is refused before anything is built" test "$(status z1)" != 0 -a ! -e "$ROOT/z1/work/out/ncw-flavor1-v33.0.9.59.zip"
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 RELEASE_SCOPE=s
  check "a release build must know the snapshot tag's base release" test "$(status z1)" != 0
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=release SNAPSHOT_BRANCH=main RELEASE_NR=1 RELEASE_SCOPE=s SNAPSHOT_BASE=33.0.9
  check "a snapshot branch that is not one is refused" test "$(status z1)" != 0
  run_build z1 ionos-build-package.sh "${base_args[@]}" KIND=bogus
  check "an unknown kind is refused" test "$(status z1)" != 0
  : > "$ROOT/z1/ncw.log"
  run_build z1 ionos-build-package.sh "${base_args[@]}" SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 RELEASE_SCOPE=leak
  check "a dev build passes no snapshot facts even if some are set" test "$(status z1)" = 0 -a "$(grep -c 'kind=dev bn=59 .* sb= rn= scope=$' "$ROOT/z1/ncw.log")" = 2
}

# ---------------------------------------------------------------- release builds: publish
REL_SCOPE='First release: flavor1'
# relpub <extra env...>: the environment of a release publish for the snapshot ncw-v33.0.9-1
relenv() { # relenv <build number> [VAR=value ...]
  local bn="$1"; shift
  RELENV=(BUILD_NUMBER="$bn" SERVER_COMMIT=aaaaaaa FLAVORS_COMMIT=bbbbbbb RUN_URL="https://example.invalid/run/$bn" KIND=release
    SNAPSHOT_TAG=ncw-v33.0.9-1 SNAPSHOT_BRANCH=rc/ncw-v33-1 RELEASE_NR=1 "RELEASE_SCOPE=$REL_SCOPE" SNAPSHOT_BASE=33.0.9 REHEARSAL=false
    SOURCE_BRANCH=ionos-dev-v33 SOURCE_COMMIT=cccccccccccccccccccccccccccccccccccccccc "$@")
}
relpub() { # relpub <world> <build number> [VAR=value ...]  (the world's work dir holds the archives of that build)
  local w="$1" bn="$2"; shift 2
  relenv "$bn" "$@"
  run_in "$w" ionos-build-publish.sh WORK="$ROOT/$w/work" "${RELENV[@]}"
}
# newbuild <world> <build number>: archives of another build for the same world (a rebuild)
newbuild() {
  local w="$ROOT/$1/work" bn="$2" f
  rm -rf "$w/out"; mkdir -p "$w/out"
  for f in flavor1 flavor2; do
    echo "zip $f $bn" > "$w/out/ncw-$f-v33.0.9.$bn.zip"
    (cd "$w/out" && sha256sum "ncw-$f-v33.0.9.$bn.zip" > "ncw-$f-v33.0.9.$bn.zip.sha256")
  done
  echo bundle > "$w/out/ncw-build-$bn.attestation.jsonl"
}
reljson() { jq -r "$2" "$ROOT/$1/state/releases.json"; }
sc_release_publish() {
  pubworld v1 57; echo bundle > "$ROOT/v1/work/out/ncw-build-57.attestation.jsonl"
  addtag v1 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v1 57
  check "the release publish succeeds" test "$(status v1)" = 0
  check "one release on the existing snapshot tag" test "$(tags v1)" = ncw-v33.0.9-1
  check "the tag is only verified, never created: --verify-tag, no --target" test "$(reljson v1 '.[0].verify_tag')" = true -a "$(reljson v1 '.[0].target_commitish')" = ""
  check "it is a real release, not a pre-release" test "$(reljson v1 '.[0].prerelease')" = false
  check "it is not marked as the latest release" test "$(reljson v1 '.[0].latest')" = false
  check "title is the tag name" test "$(reljson v1 '.[0].name')" = ncw-v33.0.9-1
  check "assets: every zip, its checksum and the attestation bundle" test "$(reljson v1 '.[0].assets | sort | join(" ")')" = "ncw-build-57.attestation.jsonl ncw-flavor1-v33.0.9.57.zip ncw-flavor1-v33.0.9.57.zip.sha256 ncw-flavor2-v33.0.9.57.zip ncw-flavor2-v33.0.9.57.zip.sha256"
  local body; body=$(reljson v1 '.[0].body')
  local sha1 sha2; sha1=$(cut -d' ' -f1 "$ROOT/v1/work/out/ncw-flavor1-v33.0.9.57.zip.sha256"); sha2=$(cut -d' ' -f1 "$ROOT/v1/work/out/ncw-flavor2-v33.0.9.57.zip.sha256")
  check "body shows the scope" grep -qF "$REL_SCOPE" <<<"$body"
  check "body shows the base release, release number, snapshot branch and tag" bash -c "grep -q 'v33.0.9' <<<'$body' && grep -q 'rc/ncw-v33-1' <<<'$body' && grep -q 'ncw-v33.0.9-1' <<<'$body' && grep -Eq 'Release number.*1' <<<'$body'"
  check "body has a table row per archive with flavor, file, build number and sha256" bash -c "grep -F 'flavor1' <<<'$body' | grep -F 'ncw-flavor1-v33.0.9.57.zip' | grep -F '57' | grep -qF '$sha1' && grep -F 'flavor2' <<<'$body' | grep -F 'ncw-flavor2-v33.0.9.57.zip' | grep -qF '$sha2'"
  check "body gives the verify hints with the repository" bash -c "grep -q 'gh attestation verify' <<<'$body' && grep -q 'acme/server' <<<'$body' && grep -q 'sha256sum' <<<'$body'"
  check "body has the machine-readable lines" bash -c "grep -qx 'release_nr: 1' <<<'$body' && grep -qx 'base_release: v33.0.9' <<<'$body' && grep -qx 'snapshot_branch: rc/ncw-v33-1' <<<'$body' && grep -qx 'snapshot_tag: ncw-v33.0.9-1' <<<'$body' && grep -qx 'latest_build_number: 57' <<<'$body' && grep -qx 'server_commit: aaaaaaa' <<<'$body'"
  check "body links the run" grep -q 'https://example.invalid/run/57' <<<"$body"
  check "body does not claim to be a rehearsal" bash -c "! grep -qi 'rehearsal' <<<'$body'"
  check "no gh call deletes or clobbers anything" bash -c "! grep -Eq 'delete|--clobber' '$ROOT/v1/state/calls.log'"

  # a rebuild: a new run on the same snapshot attaches new assets to the SAME release and extends the table
  newbuild v1 63
  relpub v1 63
  check "the rebuild succeeds" test "$(status v1)" = 0
  check "there is still exactly one release" test "$(tags v1)" = ncw-v33.0.9-1
  check "new assets with the new build number are attached" test "$(reljson v1 '.[0].assets | map(select(test("\\.63\\.")) ) | length')" = 4
  check "the earlier assets are all still there" test "$(reljson v1 '.[0].assets | map(select(test("\\.57\\."))) | length')" = 4 -a "$(reljson v1 '.[0].assets | index("ncw-build-57.attestation.jsonl") != null')" = true
  check "the new attestation bundle is attached" test "$(reljson v1 '.[0].assets | index("ncw-build-63.attestation.jsonl") != null')" = true
  check "release was created once, uploaded once, edited once" test "$(n_calls v1 'release create')" = 1 -a "$(n_calls v1 'release upload')" = 1 -a "$(n_calls v1 'release edit')" = 1
  check "the upload never clobbers" test ! -e "$ROOT/v1/state/clobber.log"
  body=$(reljson v1 '.[0].body')
  check "the table now lists the old and the new archives" bash -c "grep -c 'ncw-flavor[12]-v33.0.9.\\(57\\|63\\).zip' <<<'$body' | grep -qx '[4-9]'"
  check "old rows keep their sha256" bash -c "grep -F 'ncw-flavor1-v33.0.9.57.zip' <<<'$body' | grep -qF '$sha1'"
  check "new rows have the new sha256" bash -c "grep -F 'ncw-flavor1-v33.0.9.63.zip' <<<'$body' | grep -qF '$(cut -d' ' -f1 "$ROOT/v1/work/out/ncw-flavor1-v33.0.9.63.zip.sha256")'"
  check "the newest build comes first" bash -c "[ \$(grep -n 'v33.0.9.63.zip' <<<'$body' | head -1 | cut -d: -f1) -lt \$(grep -n 'v33.0.9.57.zip' <<<'$body' | head -1 | cut -d: -f1) ]"
  check "latest_build_number follows the rebuild" bash -c "grep -qx 'latest_build_number: 63' <<<'$body'"
  check "the scope stays in the body" grep -qF "$REL_SCOPE" <<<"$body"
  check "the title is unchanged" test "$(reljson v1 '.[0].name')" = ncw-v33.0.9-1
  check "still not a pre-release" test "$(reljson v1 '.[0].prerelease')" = false

  # build numbers must increase
  local assets_before; assets_before=$(reljson v1 '.[0].assets | sort | join(" ")')
  for bn in 63 60 57 1; do
    newbuild v1 "$bn"; relpub v1 "$bn"
    check "build number $bn is not larger than the attached 63: refused" test "$(status v1)" != 0
  done
  check "the refusal says which build number is the highest" logged v1 '63'
  check "refused runs changed nothing" test "$(reljson v1 '.[0].assets | sort | join(" ")')" = "$assets_before" -a "$(n_calls v1 'release upload')" = 1
  newbuild v1 64; relpub v1 64
  check "a larger number is accepted after the refusals" test "$(status v1)" = 0

  # an attestation bundle of a higher build counts too
  pubworld v2 70; addtag v2 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  addrel v2 ncw-v33.0.9-1 false
  jq '.[0].assets = ["ncw-build-80.attestation.jsonl"]' "$ROOT/v2/state/releases.json" > "$ROOT/v2/state/r.tmp" && mv "$ROOT/v2/state/r.tmp" "$ROOT/v2/state/releases.json"
  relpub v2 70
  check "a bundle of a higher build counts for the strictly-larger rule" test "$(status v2)" != 0 -a "$(n_calls v2 'release upload')" = 0

  # failures leave the release as it is
  pubworld v3 5; addtag v3 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v3 5
  newbuild v3 6
  relpub v3 6 STUB_FAIL=upload
  check "a failing upload fails the run" test "$(status v3)" != 0
  check "and the body is not edited (it still lists only build 5)" bash -c "! grep -q 'v33.0.9.6.zip' <<<\"\$(jq -r '.[0].body' '$ROOT/v3/state/releases.json')\""
  relpub v3 6 STUB_FAIL=edit
  check "a failing body update fails the run" test "$(status v3)" != 0
  check "and says the assets are attached and the notes must be edited by hand" bash -c "grep -q 'attached' '$ROOT/v3/out.log' && grep -q 'edit' '$ROOT/v3/out.log'"
  relpub v3 6
  check "the same build number is refused after its assets were attached (never replaced)" test "$(status v3)" != 0

  # refusals before any release call
  pubworld v4 9
  relpub v4 9
  check "without the snapshot tag the verify-tag guard stops the release and nothing is created" test "$(status v4)" != 0 -a "$(tags v4)" = ""
  pubworld v5 9; addtag v5 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v5 9 SNAPSHOT_TAG=ncw-v33.0.9-2
  check "a snapshot tag that does not fit branch, base and number is refused" test "$(status v5)" != 0 -a "$(n_calls v5 'release create')" = 0
  relpub v5 9 SNAPSHOT_BASE=33.0.10 SNAPSHOT_TAG=ncw-v33.0.10-1
  check "a tree whose base release differs from the tag's is refused" test "$(status v5)" != 0 -a "$(n_calls v5 'release create')" = 0
  relpub v5 9 RELEASE_SCOPE=
  check "an empty scope is refused" test "$(status v5)" != 0 -a "$(n_calls v5 'release create')" = 0
  relpub v5 9 SNAPSHOT_BRANCH=ionos-dev-v33
  check "a branch that is not a snapshot branch is refused" test "$(status v5)" != 0 -a "$(n_calls v5 'release create')" = 0
  relpub v5 9 KIND=bogus
  check "an unknown kind is refused" test "$(status v5)" != 0
  rm "$ROOT/v5/work/out/ncw-flavor2-v33.0.9.9.zip.sha256"
  relpub v5 9
  check "the common gate applies: a zip without checksum is refused" test "$(status v5)" != 0 -a "$(n_calls v5 'release create')" = 0

  # --check
  pubworld v6 9; addtag v6 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  SCRIPT_ARGS=--check relpub v6 9
  check "--check passes for a good first build without any release call" test "$(status v6)" = 0 -a "$(n_calls v6 'release create')" = 0
  relpub v6 9
  newbuild v6 9
  SCRIPT_ARGS=--check relpub v6 9
  check "--check refuses a build number that is not larger than the attached ones" test "$(status v6)" != 0
  newbuild v6 10
  SCRIPT_ARGS=--check relpub v6 10
  check "--check passes for a rebuild with a larger number and uploads nothing" test "$(status v6)" = 0 -a "$(n_calls v6 'release upload')" = 0

  # dry run
  pubworld v7 9; addtag v7 ncw-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v7 9 DRY_RUN=true
  check "a dry run creates nothing" test "$(status v7)" = 0 -a "$(n_calls v7 'release create')" = 0

  # rehearsal
  pubworld v8 3; addtag v8 rehearsal-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v8 3 REHEARSAL=true SNAPSHOT_TAG=rehearsal-v33.0.9-1 SNAPSHOT_BRANCH=rehearsal/ncw-v33-1
  check "a rehearsal release is published on the rehearsal tag" test "$(status v8)" = 0 -a "$(tags v8)" = rehearsal-v33.0.9-1
  check "it is a pre-release (never the production channel)" test "$(reljson v8 '.[0].prerelease')" = true
  check "title and body say rehearsal" bash -c "jq -r '.[0].name' '$ROOT/v8/state/releases.json' | grep -qi rehearsal && jq -r '.[0].body' '$ROOT/v8/state/releases.json' | grep -qi 'rehearsal'"
  check "a rehearsal never touches a real tag" test "$(n_calls v8 'ncw-v33')" = 0
  pubworld v9 3; addtag v9 rehearsal-v33.0.9-1 true cccccccccccccccccccccccccccccccccccccccc "x"
  relpub v9 3 REHEARSAL=false SNAPSHOT_TAG=rehearsal-v33.0.9-1 SNAPSHOT_BRANCH=rehearsal/ncw-v33-1
  check "a rehearsal tag with REHEARSAL=false is refused" test "$(status v9)" != 0
  relpub v9 3 REHEARSAL=true SNAPSHOT_TAG=ncw-v33.0.9-1 SNAPSHOT_BRANCH=rc/ncw-v33-1
  check "a real tag with REHEARSAL=true is refused" test "$(status v9)" != 0

  # the dev path is untouched by all of this
  pubworld v10
  # shellcheck disable=SC2086
  run_in v10 ionos-build-publish.sh WORK="$ROOT/v10/work" $PUB
  check "a dev publish (no KIND) is still a dev pre-release" test "$(tags v10)" = dev-v33.0.9.42 -a "$(reljson v10 '.[0].prerelease')" = true

  # the workflow: retention only for dev
  check "the workflow prunes dev pre-releases only for dev builds" bash -c "grep -B3 'ionos-build-retain.sh' '$HERE/../workflows/ionos-build.yml' | grep -q \"needs.plan.outputs.kind == 'dev'\""
}

# ---------------------------------------------------------------- heavy command stubs
# npm: `ci` makes node_modules, `run build` makes js/built.js; composer: `install` makes vendor/.
# Every call is logged to $CMD_LOG as "<cwd relative to $CMD_BASE>: <command> <args>".
cat > "$ROOT/bin/heavy-stub" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
# the toolchain version probe of the cache key is not a build command: not logged
[ "$name $1" = "composer-stub --version" ] && { echo "Composer version ${STUB_COMPOSER_VERSION:-2.7.1} 2024-02-09 15:26:28"; exit 0; }
echo "${PWD#"$CMD_BASE"/}: $name $*" >> "$CMD_LOG"
case "$name $1 $2" in
  "npm-stub ci "*) mkdir -p node_modules/dep && echo dev > node_modules/dep/index.js ;;
  "npm-stub run build") [ "${NPM_FAIL:-}" = "$(basename "$PWD")" ] && exit 1
     [ "${NPM_NOBUILD:-}" = "$(basename "$PWD")" ] || { mkdir -p js && echo built > "js/${NPM_OUT:-built}.js"; }
     [ "$(basename "$PWD")" = "$(basename "$CMD_BASE")" ] && { mkdir -p dist && echo built > dist/core.js; } ;;
  "composer-stub install "*) [ "${COMPOSER_NOBUILD:-}" = "$(basename "$PWD")" ] || { mkdir -p vendor/pkg/tests && echo x > vendor/pkg/tests/t.php && echo x > vendor/autoload.php; } ;;
esac
exit 0
STUB
chmod +x "$ROOT/bin/heavy-stub"
ln -sf heavy-stub "$ROOT/bin/npm-stub"; ln -sf heavy-stub "$ROOT/bin/composer-stub"
# node and php are only asked for their version (the cache key); the stubs make the versions a test input
cat > "$ROOT/bin/node" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_NODE_VERSION:-v24.1.0}"
STUB
cat > "$ROOT/bin/php" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_PHP_VERSION:-8.3.6}"
STUB
chmod +x "$ROOT/bin/node" "$ROOT/bin/php"

# the flavors tool: resolve prints $RESOLVE_DIR/<flavor>.yaml, build writes a fake archive, validate
# fails for the flavor in $VALIDATE_FAIL
cat > "$ROOT/bin/ncw-stub" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
declare -A A
while [ $# -gt 0 ]; do
  case "$1" in --*=*) k="${1%%=*}"; A["${k#--}"]="${1#*=}"; shift ;; *) A["${1#--}"]="$2"; shift 2 ;; esac
done
echo "ncw $cmd ${A[flavor]:-} kind=${A[kind]:-} bn=${A[build-number]:-} line=${A[line]:-} sc=${A[server-commit]:-} fc=${A[flavors-commit]:-} tree=${A[tree]:-} sb=${A[snapshot-branch]:-} rn=${A[release-number]:-} scope=${A[scope]:-}" >> "$NCW_LOG"
case "$cmd" in
  resolve) cat "$RESOLVE_DIR/${A[flavor]}.yaml" ;;
  build)
    [[ ",${BUILD_FAIL:-}," == *",${A[flavor]},"* ]] && { echo "ncw: boom" >&2; exit 2; }
    [ -n "${A[app-pins]:-}" ] && cp "${A[app-pins]}" "$NCW_LOG.pins.${A[flavor]}"
    [ -n "${A[cache-keys]:-}" ] && cp "${A[cache-keys]}" "$NCW_LOG.keys.${A[flavor]}"
    mkdir -p "${A[out]}"; f="${A[out]}/ncw-${A[flavor]}-v33.0.9.${A[build-number]}.zip"
    echo "zip ${A[flavor]}" > "$f"; echo "$f" ;;
  validate) [[ ",${VALIDATE_FAIL:-}," == *",${A[flavor]},"* ]] && { echo "ncw: invalid" >&2; exit 2; }; exit 0 ;;
esac
STUB
chmod +x "$ROOT/bin/ncw-stub"

# ---------------------------------------------------------------- a fork-like world
# mkapp <name> [both|composer|plainjs|static]: a local "upstream app" repository with a composer.json, a package.json with a build script,
# and a .nextcloudignore
mkapp() {
  local kind="${2:-both}" d="$ROOT/src/$1"; mkdir -p "$d/src" "$d/tests" "$d/lib"
  git init -q "$d"; git -C "$d" config uploadpack.allowAnySHA1InWant true
  case "$kind" in
    both) echo '{"require":{"x/y":"1"}}' > "$d/composer.json"; echo '{"scripts":{"build":"x"}}' > "$d/package.json" ;;
    composer) echo '{"require":{"x/y":"1"}}' > "$d/composer.json" ;;
    plainjs) echo '{"name":"no-build-script"}' > "$d/package.json" ;;
    static) ;;
    devonly) echo '{"require":{"php":">=8.1","ext-json":"*","bamarni/composer-bin-plugin":"^1.8"}}' > "$d/composer.json"; echo '{"scripts":{"build":"x"}}' > "$d/package.json" ;;
  esac
  # committed built output, which must never be trusted
  case "$kind" in both|composer) mkdir -p "$d/vendor"; echo stale > "$d/vendor/stale.php" ;; esac
  case "$kind" in both|plainjs|static) mkdir -p "$d/js"; echo stale > "$d/js/stale.js" ;; esac
  # a handwritten source in an output dir: git tracks it, so nothing may delete it
  case "$kind" in both) mkdir -p "$d/css"; echo hand > "$d/css/hand.css" ;; esac
  printf '/src\ntests\n.nextcloudignore\n' > "$d/.nextcloudignore"
  echo s > "$d/src/s.js"; echo t > "$d/tests/t.php"; echo l > "$d/lib/l.php"
  git -C "$d" add -A; git -C "$d" commit -q -m "app $1"; git -C "$d" tag v1.0.0
}
# fork <name> <app...>: a fork-like repository with the server files, the flavors folder and the apps as submodules
fork() {
  local n="$1"; shift
  local w="$ROOT/$n" r="$ROOT/$n/repo"; mkdir -p "$w/state" "$r" "$w/work" "$w/resolve"
  echo '[]' > "$w/state/releases.json"; : > "$w/state/calls.log"
  git init -q -b ionos-dev-v33 "$r"
  (
    cd "$r" || exit 1
    printf 'tests\n/build\n/config/config.php\n/data\n.nextcloudignore\n.gitignore\n.github\n' > .nextcloudignore
    echo "<?php \$OC_VersionString = '33.0.9';" > version.php
    mkdir -p lib apps/files/tests apps/files/lib build config dist .github/ionos/build-recipes IONOS/flavors/flavor1 IONOS/flavors/flavor2 IONOS/tools
    echo a > lib/a.php; echo t > apps/files/tests/t.php; echo f > apps/files/lib/f.php; echo b > build/x
    echo c > config/config.php; echo c > config/config.sample.php
    echo old > dist/core.js; echo old > dist/stale.js; ln -s core.js.license dist/core.js.map.license
    echo flavor > IONOS/flavors/flavor1/flavor.yaml; echo flavor > IONOS/flavors/flavor2/flavor.yaml; echo tool > IONOS/tools/x.ts
    echo '{"scripts":{"build":"x"}}' > package.json
    git add -A; git commit -q -m "IONOS(x): base"
  )
  # 3rdparty: its own repository, not tracked by the fork repository in this fake
  mkdir -p "$r/3rdparty/vendor"; git init -q "$r/3rdparty"; echo auto > "$r/3rdparty/autoload.php"; echo r > "$r/3rdparty/README.md"
  echo ci > "$r/3rdparty/.gitignore"; mkdir -p "$r/3rdparty/.github"; echo w > "$r/3rdparty/.github/w.yml"; echo v > "$r/3rdparty/vendor/v.php"
  local a
  for a in "$@"; do
    [ -d "$ROOT/src/$a" ] || mkapp "$a"
    git -C "$r" submodule -q add "file://$ROOT/src/$a" "apps-x/$a" 2>/dev/null
  done
  git -C "$r" commit -q -m "IONOS(x): apps" --allow-empty
  # submodules are not checked out in the worktree after the commit: make them uninitialised like a fresh checkout
  rm -rf "$r/apps-x" "$r/.git/modules"; git -C "$r" checkout -q -- apps-x 2>/dev/null || true
  git -C "$r" submodule deinit -q --all -f 2>/dev/null || true
  mkdir -p "$r/apps-x"; for a in "$@"; do mkdir -p "$r/apps-x/$a"; done
  cat > "$w/resolve/flavor1.yaml" <<'YAML'
order:
  - flavors/flavor1
apps:
  a: default
  c: removed
  files: always
app_folders:
  - apps-x
themes: []
YAML
  cat > "$w/resolve/flavor2.yaml" <<'YAML'
apps:
  b: always
  c: removed
app_folders:
  - apps-x
themes: []
YAML
  cat > "$r/.github/ionos/build-recipes/b.sh" <<'REC'
#!/usr/bin/env bash
echo "recipe for $APP in $(basename "$PWD")" > recipe-ran
mkdir -p vendor && echo r > vendor/recipe.php
REC
  git -C "$r" add -A -f .github >/dev/null 2>&1; git -C "$r" commit -q -m "IONOS(x): recipe" --allow-empty
}
# run_build <world> <script> [VAR=value ...]: a script in the fork repo with the stubs wired in
run_build() {
  local n="$1" script="$2"; shift 2
  local w="$ROOT/$n"
  run_in "$n" "$script" WORK="$w/work" NCW="$ROOT/bin/ncw-stub" NPM="$ROOT/bin/npm-stub" COMPOSER="$ROOT/bin/composer-stub" \
    CMD_LOG="$w/cmd.log" CMD_BASE="$w/repo" NCW_LOG="$w/ncw.log" RESOLVE_DIR="$w/resolve" "$@"
}
sc_select() {
  mkapp a; mkapp b; mkapp c
  fork s1 a b c
  run_build s1 ionos-build-select.sh
  check "select succeeds" test "$(status s1)" = 0
  check "without a list every flavor of IONOS/flavors is built" test "$(cat "$ROOT/s1/work/flavors.txt")" = "$(printf 'flavor1\nflavor2')"
  check "flavor1 needs its default app and the unclassified-by-mode folder entries but not the removed one" test "$(cat "$ROOT/s1/work/apps/flavor1.txt")" = "$(printf 'apps-x/a\napps-x/b')"
  check "flavor2 needs b and a (a has no mode in flavor2) but not the removed c" test "$(cat "$ROOT/s1/work/apps/flavor2.txt")" = "$(printf 'apps-x/a\napps-x/b')"
  check "the union is sorted and unique" test "$(cat "$ROOT/s1/work/apps-all.txt")" = "$(printf 'apps-x/a\napps-x/b')"

  run_build s1 ionos-build-select.sh FLAVORS="flavor2"
  check "a flavor list selects only those flavors" test "$(cat "$ROOT/s1/work/flavors.txt")" = flavor2
  check "a subset is recorded as scope subset" test "$(cat "$ROOT/s1/work/scope")" = subset
  run_build s1 ionos-build-select.sh FLAVORS="flavor1, flavor2"
  check "the list tolerates spaces" test "$(cat "$ROOT/s1/work/flavors.txt")" = "$(printf 'flavor1\nflavor2')"
  run_build s1 ionos-build-select.sh FLAVORS="flavor1, flavor2"
  check "naming every flavor is scope all" test "$(cat "$ROOT/s1/work/scope")" = all
  run_build s1 ionos-build-select.sh
  check "no list is scope all" test "$(cat "$ROOT/s1/work/scope")" = all
  run_build s1 ionos-build-select.sh FLAVORS="nope"
  check "an unknown flavor fails" test "$(status s1)" != 0
  run_build s1 ionos-build-select.sh 'FLAVORS=../x'
  check "a flavor name with a path is refused" test "$(status s1)" != 0

  # a folder of IONOS/flavors without flavor.yaml (sorted last) is not a flavor and must not stop the step
  mkdir -p "$ROOT/s1/repo/IONOS/flavors/zzz-notes"
  run_build s1 ionos-build-select.sh
  check "a folder without flavor.yaml is skipped, the others are still selected" test "$(status s1)" = 0 -a "$(cat "$ROOT/s1/work/flavors.txt")" = "$(printf 'flavor1\nflavor2')"
  rm -f "$ROOT/s1/repo/IONOS/flavors/flavor1/flavor.yaml" "$ROOT/s1/repo/IONOS/flavors/flavor2/flavor.yaml"
  run_build s1 ionos-build-select.sh
  check "no flavor at all fails with a message" test "$(status s1)" != 0 -a -n "$(grep 'no flavors' "$ROOT/s1/out.log")"

  # none: a flavor whose app folder does not exist in the fork and that has no out-of-tree apps
  fork s2
  cat > "$ROOT/s2/resolve/flavor1.yaml" <<'YAML'
apps:
  files: always
app_folders:
  - apps-gone
themes: []
YAML
  cat > "$ROOT/s2/resolve/flavor2.yaml" <<'YAML'
apps: {}
app_folders: []
themes: []
YAML
  run_build s2 ionos-build-select.sh
  check "no out-of-tree apps at all is fine" test "$(status s2)" = 0
  check "and the union is empty" test ! -s "$ROOT/s2/work/apps-all.txt"
  check "an empty per-flavor list exists" test -f "$ROOT/s2/work/apps/flavor2.txt"
}

sc_apps() {
  mkapp a; mkapp b; mkapp c
  fork a1 a b c
  run_build a1 ionos-build-select.sh
  run_build a1 ionos-build-apps.sh
  local r="$ROOT/a1/repo"
  check "apps succeeds" test "$(status a1)" = 0
  check "a needed app is initialised" test -f "$r/apps-x/a/composer.json"
  check "an app only a removed flavor entry names is not initialised" test ! -e "$r/apps-x/c/composer.json"
  check "the submodule clone is shallow" test "$(git -C "$r/apps-x/a" rev-parse --is-shallow-repository)" = true
  check "default recipe: composer install --no-dev -a" grep -q 'apps-x/a: composer-stub install --no-dev -a' "$ROOT/a1/cmd.log"
  check "default recipe: npm ci then npm run build" bash -c "grep -n 'apps-x/a: npm-stub' '$ROOT/a1/cmd.log' | cut -d: -f3- | tr '\n' ';' | grep -q 'npm-stub ci.*npm-stub run build'"
  check "default recipe: built files are there" test -f "$r/apps-x/a/js/built.js" -a -f "$r/apps-x/a/vendor/autoload.php"
  check "default recipe: nothing that git tracks is deleted (js/, css/ and vendor/ files)" test -f "$r/apps-x/a/vendor/stale.php" -a -f "$r/apps-x/a/js/stale.js" -a "$(cat "$r/apps-x/a/css/hand.css")" = hand
  run_build a1 ionos-build-apps.sh NPM_OUT=second
  check "default recipe: untracked leftovers of an earlier build are removed before the next" test ! -e "$r/apps-x/a/js/built.js" -a -f "$r/apps-x/a/js/second.js"
  check "default recipe: a second build still keeps the tracked files" test -f "$r/apps-x/a/js/stale.js" -a -f "$r/apps-x/a/css/hand.css"
  check "default recipe: npm ci runs lifecycle scripts (vue-demi's postinstall is needed by text, viewer, photos)" grep -q 'apps-x/a: npm-stub ci$' "$ROOT/a1/cmd.log"
  check "default recipe: composer runs without scripts (post-install-cmd runs dev tooling)" grep -q 'apps-x/a: composer-stub install --no-dev -a --no-scripts' "$ROOT/a1/cmd.log"
  check "default recipe: node_modules is deleted afterwards" test ! -e "$r/apps-x/a/node_modules"
  check "a recipe in build-recipes replaces the default for that app" test -f "$r/apps-x/b/recipe-ran"
  check "the recipe knows the app id" grep -q 'recipe for b' "$r/apps-x/b/recipe-ran"
  check "the default recipe did not run for the overridden app" test "$(grep -c 'apps-x/b:' "$ROOT/a1/cmd.log")" = 0

  fork a2 a
  rm "$ROOT/a2/repo/apps-x/a" -rf; mkdir -p "$ROOT/a2/repo/apps-x/a"
  run_build a2 ionos-build-select.sh
  run_build a2 ionos-build-apps.sh NPM_FAIL=a
  check "a failing app build fails the step" test "$(status a2)" != 0
  check "the failing app is named" logged a2 '::error::.*\ba\b'

  # the rule for built files (see ionos-build.md)
  mkapp ca composer; mkapp cb both; mkapp cc plainjs; mkapp cd static; mkapp ce both
  fork a4 ca; run_build a4 ionos-build-select.sh; run_build a4 ionos-build-apps.sh
  check "composer-only app: built from source, vendor/ comes from composer" test "$(status a4)" = 0 -a -f "$ROOT/a4/repo/apps-x/ca/vendor/autoload.php"
  check "composer-only app: no npm call" test "$(grep -c 'apps-x/ca: npm' "$ROOT/a4/cmd.log")" = 0
  fork a5 ca; run_build a5 ionos-build-select.sh; run_build a5 ionos-build-apps.sh COMPOSER_NOBUILD=ca
  check "an app with a composer.json whose build produced no vendor/ fails and is named" test "$(status a5)" != 0 -a -n "$(grep '::error::.*ca' "$ROOT/a5/out.log")"
  fork a6 cb; run_build a6 ionos-build-select.sh; run_build a6 ionos-build-apps.sh NPM_NOBUILD=cb
  check "an app with a build script that wrote no new file in js/ or css/ fails and is named (tracked files do not count)" test "$(status a6)" != 0 -a -n "$(grep '::error::.*cb' "$ROOT/a6/out.log")"
  fork a7 cc; run_build a7 ionos-build-select.sh; run_build a7 ionos-build-apps.sh
  check "committed js/ without a build script and without a recipe fails and is named" test "$(status a7)" != 0 -a -n "$(grep '::error::.*cc' "$ROOT/a7/out.log")"
  check "that failure happens before anything is deleted or built" test ! -e "$ROOT/a7/cmd.log" -o "$(grep -c 'apps-x/cc' "$ROOT/a7/cmd.log" 2>/dev/null)" = 0
  fork a8 cd; run_build a8 ionos-build-select.sh; run_build a8 ionos-build-apps.sh
  check "committed js/ with no package.json and no recipe fails too" test "$(status a8)" != 0
  fork a9 ce; run_build a9 ionos-build-select.sh
  mkdir -p "$ROOT/a9/repo/.github/ionos/build-recipes"; printf '#!/usr/bin/env bash\nset -euo pipefail\nrm -rf js\necho ok > ok\n' > "$ROOT/a9/repo/.github/ionos/build-recipes/ce.sh"
  run_build a9 ionos-build-apps.sh
  check "a recipe is trusted to build what it says: no check, no default build" test "$(status a9)" = 0 -a -f "$ROOT/a9/repo/apps-x/ce/ok" -a ! -s "$ROOT/a9/cmd.log"
  mkapp cf plainjs; fork a10 cf
  mkdir -p "$ROOT/a10/repo/.github/ionos/build-recipes"; printf '#!/usr/bin/env bash\ntrue\n' > "$ROOT/a10/repo/.github/ionos/build-recipes/cf.sh"
  run_build a10 ionos-build-select.sh; run_build a10 ionos-build-apps.sh
  check "an app with committed js/ and no build script is fine with a recipe" test "$(status a10)" = 0

  mkapp cx devonly; fork a12 cx; run_build a12 ionos-build-select.sh; run_build a12 ionos-build-apps.sh
  check "a composer.json that requires only php, extensions and the bin plugin still runs composer without scripts (the app's composer/autoload.php needs vendor/autoload.php)" test "$(status a12)" = 0 -a "$(grep -c 'apps-x/cx: composer-stub install --no-dev -a --no-scripts' "$ROOT/a12/cmd.log")" = 1 -a -f "$ROOT/a12/repo/apps-x/cx/vendor/autoload.php"
  fork a13 cx; run_build a13 ionos-build-select.sh; run_build a13 ionos-build-apps.sh COMPOSER_NOBUILD=cx
  check "a dev-only composer.json whose composer run leaves no vendor/autoload.php fails and names the app" test "$(status a13)" != 0 -a -n "$(grep 'cx.*vendor/autoload.php' "$ROOT/a13/out.log")"
  check "and such an app is still built with npm" test -f "$ROOT/a12/repo/apps-x/cx/js/built.js"
  # every app is tried; ONE error lists all failing apps
  mkapp cg both
  fork a11 ca cb cg; run_build a11 ionos-build-select.sh; run_build a11 ionos-build-apps.sh COMPOSER_NOBUILD=ca NPM_NOBUILD=cb
  check "a failing app does not stop the others: the last app is built" test -f "$ROOT/a11/repo/apps-x/cg/js/built.js"
  check "the step fails" test "$(status a11)" != 0
  check "exactly one ::error:: line" test "$(grep -c '::error::' "$ROOT/a11/out.log")" = 1
  check "that line lists every failing app and not the good one" bash -c "grep '::error::' '$ROOT/a11/out.log' | grep -q 'ca' && grep '::error::' '$ROOT/a11/out.log' | grep -q 'cb' && ! grep '::error::' '$ROOT/a11/out.log' | grep -q 'cg'"

  fork a3
  run_build a3 ionos-build-select.sh
  : > "$ROOT/a3/work/apps-all.txt"
  run_build a3 ionos-build-apps.sh
  check "no apps to build is fine and builds nothing" test "$(status a3)" = 0 -a ! -s "$ROOT/a3/cmd.log"
}

sc_server() {
  fork v1
  run_build v1 ionos-build-server.sh
  check "server build succeeds" test "$(status v1)" = 0
  check "npm ci runs before npm run build" bash -c "tr '\n' ';' < '$ROOT/v1/cmd.log' | grep -q 'npm-stub ci.*npm-stub run build'"
  check "the server needs its postinstall (build/demi.sh ci): npm ci runs WITHOUT --ignore-scripts" test "$(grep -c 'ignore-scripts' "$ROOT/v1/cmd.log")" = 0
  check "the committed dist is never trusted: stale files of it are gone" test ! -e "$ROOT/v1/repo/dist/stale.js"
  check "the built dist is there" test "$(cat "$ROOT/v1/repo/dist/core.js")" = built
  fork v2
  run_build v2 ionos-build-server.sh NPM_FAIL=repo
  check "a failing server build fails the step" test "$(status v2)" != 0
}

sc_assemble() {
  mkapp a; mkapp b; mkapp c
  fork m1 a b c
  run_build m1 ionos-build-select.sh
  run_build m1 ionos-build-server.sh
  run_build m1 ionos-build-apps.sh
  run_build m1 ionos-build-assemble.sh
  local t="$ROOT/m1/work/tree"
  check "assemble succeeds" test "$(status m1)" = 0
  check "the tree has the server files" test -f "$t/lib/a.php" -a -f "$t/version.php" -a -f "$t/config/config.sample.php"
  check "the built server files are in the tree" test "$(cat "$t/dist/core.js")" = built
  check ".nextcloudignore of the server is applied (tests, build, config.php)" test ! -e "$t/apps/files/tests" -a ! -e "$t/build" -a ! -e "$t/config/config.php"
  check "other server files stay" test -f "$t/apps/files/lib/f.php"
  check "no .git, node_modules, IONOS or CI files" test ! -e "$t/.git" -a ! -e "$t/node_modules" -a ! -e "$t/IONOS" -a ! -e "$t/.github"
  check "3rdparty is copied without .git, .github, .gitignore and README.md" test -f "$t/3rdparty/autoload.php" -a -f "$t/3rdparty/vendor/v.php" -a ! -e "$t/3rdparty/.git" -a ! -e "$t/3rdparty/.github" -a ! -e "$t/3rdparty/.gitignore" -a ! -e "$t/3rdparty/README.md"
  check "an app's own .nextcloudignore is applied (src and tests gone, also in vendor)" test ! -e "$t/apps-x/a/src" -a ! -e "$t/apps-x/a/tests" -a ! -e "$t/apps-x/a/vendor/pkg/tests"
  check "an app keeps its code, built files, composer.json and package.json" test -f "$t/apps-x/a/lib/l.php" -a -f "$t/apps-x/a/js/built.js" -a -f "$t/apps-x/a/vendor/autoload.php" -a -f "$t/apps-x/a/composer.json" -a -f "$t/apps-x/a/package.json"
  check "the app has no node_modules and no .git file" test ! -e "$t/apps-x/a/node_modules" -a ! -e "$t/apps-x/a/.git"
  check "an app that was not built leaves no empty folder" test ! -e "$t/apps-x/c"
  check "*.map.license symlinks are dropped" test ! -e "$t/dist/core.js.map.license" -a ! -L "$t/dist/core.js.map.license"
  check "the base release is recorded" test "$(cat "$ROOT/m1/work/base-release")" = 33.0.9
  check "the source checkout is unchanged except the builds (version.php still there)" test -f "$ROOT/m1/repo/version.php"

  fork m2
  ln -s /nonexistent "$ROOT/m2/repo/lib/odd-link"
  run_build m2 ionos-build-select.sh
  run_build m2 ionos-build-assemble.sh
  check "a symbolic link left in the tree fails the step and is named" test "$(status m2)" != 0 -a -n "$(grep 'odd-link' "$ROOT/m2/out.log")"

  fork m4
  echo 'license text' > "$ROOT/m4/repo/lib/LICENSES.txt"
  ln -s LICENSES.txt "$ROOT/m4/repo/lib/a.js.license"
  run_build m4 ionos-build-select.sh
  run_build m4 ionos-build-assemble.sh
  check "a symbolic link to a file inside the tree is replaced by a copy of the file" test "$(status m4)" = 0 -a ! -L "$ROOT/m4/work/tree/lib/a.js.license" -a "$(cat "$ROOT/m4/work/tree/lib/a.js.license")" = "license text"

  fork m5
  echo 'secret' > "$ROOT/m5/outside.txt"
  ln -s "$ROOT/m5/outside.txt" "$ROOT/m5/repo/lib/out-link"
  run_build m5 ionos-build-select.sh
  run_build m5 ionos-build-assemble.sh
  check "a symbolic link to a file outside the tree is not copied but fails the step and is named" test "$(status m5)" != 0 -a -n "$(grep 'out-link' "$ROOT/m5/out.log")"

  fork m3
  rm -rf "$ROOT/m3/repo/3rdparty"; mkdir "$ROOT/m3/repo/3rdparty"
  run_build m3 ionos-build-select.sh
  run_build m3 ionos-build-assemble.sh
  check "an empty 3rdparty (submodule not initialised) fails the step" test "$(status m3)" != 0
}

sc_package() {
  mkapp a; mkapp b; mkapp c
  fork k1 a b c
  run_build k1 ionos-build-select.sh
  run_build k1 ionos-build-apps.sh
  run_build k1 ionos-build-assemble.sh
  local sha=0123456789abcdef0123456789abcdef01234567 fsha=fedcba9876543210fedcba9876543210fedcba98
  run_build k1 ionos-build-package.sh BUILD_NUMBER=42 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha
  local o="$ROOT/k1/work/out"
  check "package succeeds" test "$(status k1)" = 0
  check "one archive per flavor with the right name" test "$(cd "$o" && echo *.zip)" = "ncw-flavor1-v33.0.9.42.zip ncw-flavor2-v33.0.9.42.zip"
  check "every archive has a sha256 file that verifies" bash -c "cd '$o' && sha256sum -c ncw-flavor1-v33.0.9.42.zip.sha256 ncw-flavor2-v33.0.9.42.zip.sha256"
  check "the checksum file names the archive without a path" bash -c "grep -q ' ncw-flavor1-v33.0.9.42.zip\$' '$o/ncw-flavor1-v33.0.9.42.zip.sha256'"
  check "build gets kind dev, the run number, the line and both commits" grep -q "ncw build flavor1 kind=dev bn=42 line=33 sc=$sha fc=$fsha" "$ROOT/k1/ncw.log"
  check "every artifact is validated" test "$(grep -c '^ncw validate' "$ROOT/k1/ncw.log")" = 2
  check "all flavors share the build number" test "$(grep '^ncw build' "$ROOT/k1/ncw.log" | grep -c 'bn=42')" = 2
  local expect; expect="$(git -C "$ROOT/k1/repo/apps-x/a" rev-parse HEAD)"
  check "the pins file holds commit and describe of each built app" bash -c "jq -e --arg c '$expect' '.a.commit == \$c and .a.describe == \"v1.0.0\" and (.b.commit|length==40)' '$ROOT/k1/ncw.log.pins.flavor1'"
  check "the pins file has no removed or unbuilt app" test "$(jq -r 'keys|join(",")' "$ROOT/k1/ncw.log.pins.flavor1")" = a,b
  check "the used app builds are passed as --cache-keys: key and checksum of each built app, nothing else" bash -c "jq -e '(keys == [\"a\",\"b\"]) and (.a.key|test(\"^[0-9a-f]{64}\$\")) and (.a.checksum|test(\"^[0-9a-f]{64}\$\")) and (.a|keys == [\"checksum\",\"key\"])' '$ROOT/k1/ncw.log.keys.flavor1'"
  check "every flavor gets its own apps' keys" test "$(jq -r 'keys|join(",")' "$ROOT/k1/ncw.log.keys.flavor2")" = a,b
  check "the run is marked validated for the publish step" test "$(cat "$ROOT/k1/work/validated")" = "$(cat "$ROOT/k1/work/flavors.txt")"

  fork k2
  run_build k2 ionos-build-select.sh
  run_build k2 ionos-build-assemble.sh
  run_build k2 ionos-build-package.sh BUILD_NUMBER=7 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha
  check "with no out-of-tree apps the pins are an empty object" test "$(jq -c . "$ROOT/k2/ncw.log.pins.flavor1")" = '{}'
  check "package succeeds with none" test "$(status k2)" = 0
  check "with no out-of-tree apps the cache keys are an empty object" test "$(jq -c . "$ROOT/k2/ncw.log.keys.flavor1")" = '{}'

  # a static-check failure stops the run before anything is published
  fork k3
  run_build k3 ionos-build-select.sh
  run_build k3 ionos-build-assemble.sh
  run_build k3 ionos-build-package.sh BUILD_NUMBER=9 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha VALIDATE_FAIL=flavor2
  check "a failing validate fails the package step" test "$(status k3)" != 0
  check "no validated marker is written" test ! -e "$ROOT/k3/work/validated"
  run_build k3 ionos-build-publish.sh BUILD_NUMBER=9 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha
  check "publish refuses a run that did not pass validation" test "$(status k3)" != 0
  check "and makes no gh release call" test "$(n_calls k3 'release')" = 0
  run_build k3 ionos-build-package.sh BUILD_NUMBER=9 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha BUILD_FAIL=flavor1
  check "a failing build fails the package step" test "$(status k3)" != 0
  check "the remaining flavors are still built after a failure" grep -q '^ncw build flavor2' "$ROOT/k3/ncw.log"
  run_build k3 ionos-build-package.sh BUILD_NUMBER=9 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha BUILD_FAIL=flavor1 VALIDATE_FAIL=flavor2
  check "all failing flavors are reported" test -n "$(grep '::error::.*flavor1.*flavor2' "$ROOT/k3/out.log")"
  run_build k3 ionos-build-package.sh BUILD_NUMBER=9 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha VALIDATE_FAIL=flavor2
  check "a flavor that failed validation leaves no archive and no checksum" test ! -e "$ROOT/k3/work/out/ncw-flavor2-v33.0.9.9.zip" -a ! -e "$ROOT/k3/work/out/ncw-flavor2-v33.0.9.9.zip.sha256"
  check "a flavor that passed keeps its archive and checksum" test -f "$ROOT/k3/work/out/ncw-flavor1-v33.0.9.9.zip.sha256"
  run_build k3 ionos-build-package.sh BUILD_NUMBER=0 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha
  check "a bad build number is refused" test "$(status k3)" != 0
}

# The real recipes of .github/ionos/build-recipes (see the table in ionos-build.md). Apps without a recipe use the
# default recipe, checked above; a real run over every pinned app was done by hand (the table says so).
sc_recipes() {
  local id d
  for id in calendar groupfolders notes tasks contacts; do
    check "$id builds with the default recipe (no recipe file)" test ! -e "$HERE/build-recipes/$id.sh"
  done
  mkdir -p "$ROOT/rc"
  for id in serverinfo survey_client; do
    check "$id has a recipe" test -f "$HERE/build-recipes/$id.sh"
    d="$ROOT/rc/$id"; rm -rf "$d"; mkdir -p "$d/js" "$d/css"; git init -q "$d"
    echo src > "$d/js/script.js"; echo src > "$d/css/style.css"; echo '{"require":null}' > "$d/composer.json"
    git -C "$d" add -A; git -C "$d" commit -q -m app
    : > "$ROOT/rc/cmd.log"
    ( cd "$d" && env APP="$id" NPM="$ROOT/bin/npm-stub" COMPOSER="$ROOT/bin/composer-stub" CMD_LOG="$ROOT/rc/cmd.log" CMD_BASE="$ROOT/rc" bash "$HERE/build-recipes/$id.sh" ) > "$ROOT/rc/out.log" 2>&1
    check "$id: the recipe succeeds and leaves the handwritten js/ and css/ alone" test "$?" = 0 -a "$(cat "$d/js/script.js")" = src -a "$(cat "$d/css/style.css")" = src
    check "$id: the recipe runs no npm and no composer" test ! -s "$ROOT/rc/cmd.log"
  done
  # related_resources commits its built js/, partly stale; a faithful rebuild may write no new file
  id=related_resources; d="$ROOT/rc/$id"; rm -rf "$d"; mkdir -p "$d/js" "$d/css" "$d/src"; git init -q "$d"
  echo '{"scripts":{"build":"x"}}' > "$d/package.json"; echo '{"require":null}' > "$d/composer.json"
  echo stale > "$d/js/stale-chunk.js"; echo hand > "$d/css/icons.scss"
  git -C "$d" add -A; git -C "$d" commit -q -m app
  check "$id has a recipe" test -f "$HERE/build-recipes/$id.sh"
  : > "$ROOT/rc/cmd.log"
  ( cd "$d" && env APP="$id" NPM="$ROOT/bin/npm-stub" COMPOSER="$ROOT/bin/composer-stub" CMD_LOG="$ROOT/rc/cmd.log" CMD_BASE="$ROOT/rc" bash "$HERE/build-recipes/$id.sh" ) > "$ROOT/rc/out.log" 2>&1
  check "$id: the recipe succeeds, the committed built js/ is replaced by what the build writes, the other tracked files stay" test "$?" = 0 -a ! -e "$d/js/stale-chunk.js" -a -f "$d/js/built.js" -a "$(cat "$d/css/icons.scss")" = hand
  check "$id: composer and npm run in order and node_modules is gone" bash -c "tr '\n' ';' < '$ROOT/rc/cmd.log' | grep -q 'composer-stub install.*npm-stub ci.*npm-stub run build' && test ! -e '$d/node_modules'"
  ( cd "$d" && env APP="$id" NPM_NOBUILD="$id" NPM="$ROOT/bin/npm-stub" COMPOSER="$ROOT/bin/composer-stub" CMD_LOG="$ROOT/rc/cmd.log" CMD_BASE="$ROOT/rc" bash "$HERE/build-recipes/$id.sh" ) > "$ROOT/rc/out.log" 2>&1
  check "$id: a build that writes no file at all fails" test "$?" != 0
}

# ---------------------------------------------------------------- app build cache
# Everything runs the real scripts against stub npm/composer/node/php. The cache folder is $ROOT/<world>/cache.
cache_run() { # cache_run <world> [VAR=value ...]: ionos-build-apps.sh with the cache folder of that world
  local n="$1"; shift
  run_build "$n" ionos-build-apps.sh CACHE_DIR="$ROOT/$n/cache" "$@"
}
npm_calls() { grep -c "apps-x/$2: npm-stub ci" "$ROOT/$1/cmd.log" 2>/dev/null || true; }
meta() { jq -r "$2" "$ROOT/$1/cache/$3/meta.json"; }
builds() { jq -r "$2" "$ROOT/$1/work/app-builds.json"; }
# the pinned commit of an app of the world is moved to a new commit of its source repository
bump_pin() { # bump_pin <world> <app>
  echo more >> "$ROOT/src/$2/lib/l.php"; git -C "$ROOT/src/$2" commit -qam "bump"
  git -C "$ROOT/$1/repo" update-index --cacheinfo "160000,$(git -C "$ROOT/src/$2" rev-parse HEAD),apps-x/$2"
  git -C "$ROOT/$1/repo" commit -q -m "IONOS(x): bump $2"
}
need_apps() { local x; for x in "$@"; do [ -d "$ROOT/src/$x" ] || mkapp "$x"; done; }
sc_cache() {
  need_apps a b d; fork c1 a b d
  run_build c1 ionos-build-select.sh FLAVORS=flavor1
  # flavor1 resolves a, b, d (c removed): apps-x/a, apps-x/b (recipe), apps-x/d (default recipe)
  local c="$ROOT/c1/cache"
  cache_run c1
  check "cold cache: the run succeeds" test "$(status c1)" = 0
  check "cold cache: every app is built (npm ci for a and d)" test "$(npm_calls c1 a)" = 1 -a "$(npm_calls c1 d)" = 1
  check "layout: <cache>/<app>/tree and meta.json for every app" test -f "$c/a/meta.json" -a -f "$c/d/tree/js/built.js" -a -f "$c/b/tree/recipe-ran"
  check "the cached tree has no .git and no node_modules" test ! -e "$c/a/tree/.git" -a ! -e "$c/a/tree/node_modules"
  check "the cached tree holds the built files and the tracked sources" test -f "$c/a/tree/vendor/autoload.php" -a -f "$c/a/tree/lib/l.php"
  check "meta.json has key, checksum, app commit, node, php and recipe hash" bash -c "jq -e '(.key|test(\"^[0-9a-f]{64}\$\")) and (.checksum|test(\"^[0-9a-f]{64}\$\")) and (.app_commit|length==40) and .node==\"v24.1.0\" and .php==\"8.3.6\" and (.recipe_hash|length==64)' '$c/a/meta.json'"
  check "the app commit in meta.json is the pinned submodule commit" test "$(meta c1 .app_commit a)" = "$(git -C "$ROOT/src/a" rev-parse HEAD)"
  check "app-builds.json holds key and checksum of every used build" test "$(builds c1 'keys|join(",")')" = a,b,d -a "$(builds c1 .a.key)" = "$(meta c1 .key a)" -a "$(builds c1 .a.checksum)" = "$(meta c1 .checksum a)"
  check "the key is a plain sha256: nothing of the runner in it" bash -c "[[ \"\$(jq -r .a.key '$ROOT/c1/work/app-builds.json')\" =~ ^[0-9a-f]{64}\$ ]]"
  check "a cold run asks for a save under a key with the portable prefix" bash -c "grep -q '^cache_save=true' '$ROOT/c1/gh_output' && grep -q '^cache_key=ionos-app-build-v1-[0-9a-f]\{64\}\$' '$ROOT/c1/gh_output'"
  local key1 first; key1="$(output c1 cache_key)"; first="$(cat "$ROOT/c1/work/app-builds.json")"

  : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "unchanged inputs: the run succeeds" test "$(status c1)" = 0
  check "unchanged inputs: npm is not called at all" test ! -s "$ROOT/c1/cmd.log"
  check "unchanged inputs: the cached tree is put back into the app folder" test -f "$ROOT/c1/repo/apps-x/a/js/built.js" -a -f "$ROOT/c1/repo/apps-x/a/vendor/autoload.php"
  check "unchanged inputs: the recipe of b was not run again" bash -c "grep -q 'b: reused' '$ROOT/c1/out.log' && grep -q 'd: reused' '$ROOT/c1/out.log'"
  check "unchanged inputs: the used keys and checksums are the same" test "$(cat "$ROOT/c1/work/app-builds.json")" = "$first"
  check "unchanged inputs: nothing is saved" bash -c "! grep -q 'cache_save=true' '$ROOT/c1/gh_output'"
  # a reused tree behaves like a built one: the assembly accepts it
  run_build c1 ionos-build-assemble.sh
  check "the assembly works on reused trees" test "$(status c1)" = 0 -a -f "$ROOT/c1/work/tree/apps-x/a/js/built.js"

  # the key follows the app commit
  bump_pin c1 a
  : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "a new app commit gives a new key for that app" test "$(builds c1 .a.key)" != "$(jq -r .a.key <<<"$first")" -a "$(builds c1 .a.key)" = "$(meta c1 .key a)"
  check "a new app commit rebuilds only that app" test "$(npm_calls c1 a)" = 1 -a "$(npm_calls c1 d)" = 0
  check "the other apps keep their key" test "$(builds c1 .d.key)" = "$(jq -r .d.key <<<"$first")"
  check "the rebuilt app is saved under a new folder key" bash -c "grep -q '^cache_save=true' '$ROOT/c1/gh_output'" 
  local key2; key2="$(output c1 cache_key)"
  check "the folder key follows the per-app keys" test -n "$key2" -a "$key2" != "$key1"
  check "meta.json holds the new app commit" test "$(meta c1 .app_commit a)" = "$(git -C "$ROOT/src/a" rev-parse HEAD)"

  # the key follows the recipe: a recipe file, and the text of the default recipe
  : > "$ROOT/c1/cmd.log"; local kb kb2; kb="$(builds c1 .b.key)"
  echo '# changed' >> "$ROOT/c1/repo/.github/ionos/build-recipes/b.sh"
  cache_run c1
  kb2="$(builds c1 .b.key)"
  check "a changed recipe file gives a new key for that app and rebuilds it" test "$kb2" != "$kb" -a "$(grep -c 'b: building' "$ROOT/c1/out.log")" = 1
  check "a changed recipe does not touch the other apps" test "$(npm_calls c1 a)" = 0 -a "$(npm_calls c1 d)" = 0
  local kd; kd="$(builds c1 .d.key)"
  cp "$HERE/ionos-build-default-recipe.sh" "$ROOT/c1/default-recipe.sh"; echo '# changed text' >> "$ROOT/c1/default-recipe.sh"
  : > "$ROOT/c1/cmd.log"
  cache_run c1 DEFAULT_RECIPE_FILE="$ROOT/c1/default-recipe.sh"
  check "a changed text of the default recipe gives new keys for the default-recipe apps" test "$(builds c1 .d.key)" != "$kd" -a "$(npm_calls c1 d)" = 1 -a "$(npm_calls c1 a)" = 1
  check "but not for an app with its own recipe" test "$(builds c1 .b.key)" = "$kb2" -a "$(grep -c 'b: reused' "$ROOT/c1/out.log")" = 1
  : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "back with the original default recipe the original key is back (a key is content, not a counter)" test "$(builds c1 .d.key)" = "$kd" -a "$(status c1)" = 0

  # toolchain versions
  local ka; cache_run c1; ka="$(builds c1 .a.key)"
  : > "$ROOT/c1/cmd.log"
  cache_run c1 STUB_NODE_VERSION=v22.9.0
  check "a new Node version gives new keys and rebuilds" test "$(builds c1 .a.key)" != "$ka" -a "$(npm_calls c1 a)" = 1 -a "$(meta c1 .node a)" = v22.9.0
  cache_run c1 STUB_NODE_VERSION=v22.9.0 STUB_PHP_VERSION=8.4.1
  check "a new PHP version gives new keys" test "$(builds c1 .a.key)" != "$ka" -a "$(meta c1 .php a)" = 8.4.1
  local kp; kp="$(builds c1 .a.key)"
  cache_run c1 STUB_NODE_VERSION=v22.9.0 STUB_PHP_VERSION=8.4.1 STUB_COMPOSER_VERSION=3.0.0
  check "a new Composer major version gives new keys" test "$(builds c1 .a.key)" != "$kp"
  local kc; kc="$(builds c1 .a.key)"
  cache_run c1 STUB_NODE_VERSION=v22.9.0 STUB_PHP_VERSION=8.4.1 STUB_COMPOSER_VERSION=3.4.5
  check "a new Composer minor version does not" test "$(builds c1 .a.key)" = "$kc" -a "$(grep -c 'a: reused' "$ROOT/c1/out.log")" = 1

  # a tampered tree is rebuilt, and said so
  cache_run c1
  echo evil > "$c/a/tree/js/built.js"; echo evil2 > "$c/a/tree/extra.php"
  : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "a cached tree that does not match its checksum is rebuilt" test "$(status c1)" = 0 -a "$(npm_calls c1 a)" = 1
  check "and the mismatch is logged" grep -q 'a: .*checksum' "$ROOT/c1/out.log"
  check "nothing of the tampered tree is used" test ! -e "$ROOT/c1/repo/apps-x/a/extra.php" -a "$(cat "$ROOT/c1/repo/apps-x/a/js/built.js")" = built
  check "the rebuilt app replaces the bad entry and a save is asked for" bash -c "test ! -e '$c/a/tree/extra.php' && test \"\$(cat '$c/a/tree/js/built.js')\" = built && grep -q '^cache_save=true' '$ROOT/c1/gh_output'"
  echo not json > "$c/d/meta.json"; : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "an unreadable meta.json means rebuild" test "$(status c1)" = 0 -a "$(npm_calls c1 d)" = 1
  rm -rf "$c/d/tree"; : > "$ROOT/c1/cmd.log"
  cache_run c1
  check "a missing tree means rebuild" test "$(status c1)" = 0 -a "$(npm_calls c1 d)" = 1
  rm -rf "$c/a/tree"; ln -s /etc "$c/a/tree"
  cache_run c1
  check "a symbolic link in place of the tree is never followed" test "$(status c1)" = 0 -a ! -L "$c/a/tree" -a -f "$c/a/tree/js/built.js"
  # a link inside a cached tree is data, not followed: the checksum records the target
  cache_run c1
  ln -s /etc/passwd "$c/a/tree/link"
  cache_run c1
  check "a tree with an added symbolic link does not match its checksum" test ! -e "$c/a/tree/link" -a "$(status c1)" = 0

  # no_cache
  cache_run c1
  local before; before="$(cd "$c" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  : > "$ROOT/c1/cmd.log"
  cache_run c1 NO_CACHE=true
  check "no_cache: every app is built although the cache is intact" test "$(status c1)" = 0 -a "$(npm_calls c1 a)" = 1 -a "$(npm_calls c1 d)" = 1
  check "no_cache: the cache is ignored (nothing reused)" bash -c "! grep -q 'reused from the cache' '$ROOT/c1/out.log'"
  check "no_cache: no save is asked for" bash -c "! grep -q 'cache_save' '$ROOT/c1/gh_output'"
  check "no_cache: the cache folder is not changed" test "$(cd "$c" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" = "$before"
  check "no_cache: the used keys and checksums are still recorded" test "$(builds c1 '.a.key|length')" = 64 -a "$(builds c1 '.a.checksum|length')" = 64
  check "no_cache: the key and checksum equal the cached ones (the stubs are deterministic)" test "$(builds c1 .a.checksum)" = "$(meta c1 .checksum a)"
  fork c2 a; run_build c2 ionos-build-select.sh
  cache_run c2 NO_CACHE=true
  check "no_cache on an empty cache folder creates nothing" test "$(status c2)" = 0 -a ! -e "$ROOT/c2/cache"

  # no cache folder at all (a direct run): builds as before, still records the builds
  fork c3 a; run_build c3 ionos-build-select.sh; run_build c3 ionos-build-apps.sh
  check "without CACHE_DIR the apps are built and recorded, no save is asked for" test "$(status c3)" = 0 -a "$(jq -r '.a.key|length' "$ROOT/c3/work/app-builds.json")" = 64 -a ! -s "$ROOT/c3/gh_output"

  # save only when something changed; an app that is gone from the pins is dropped, one not selected stays
  fork c4 a b d; run_build c4 ionos-build-select.sh
  cache_run c4
  mkdir -p "$ROOT/c4/cache/gone/tree"; echo x > "$ROOT/c4/cache/gone/tree/x"; echo '{"key":"deadbeef"}' > "$ROOT/c4/cache/gone/meta.json"
  cache_run c4
  check "an app that is not pinned any more is dropped from the folder and that asks for a save" bash -c "test ! -e '$ROOT/c4/cache/gone' && grep -q '^cache_save=true' '$ROOT/c4/gh_output'"
  check "the dropped app does not count in the folder key (the key is that of the three apps)" bash -c ". '$HERE/ionos-cache-lib.sh'; [ \"\$(grep '^cache_key=' '$ROOT/c4/gh_output' | cut -d= -f2)\" = \"\$(cache_folder_key '$ROOT/c4/cache')\" ]"
  printf 'apps-x/a\n' > "$ROOT/c4/work/apps-all.txt"
  cache_run c4
  check "an app that is pinned but not selected in this run stays in the folder" test -f "$ROOT/c4/cache/d/meta.json" -a -f "$ROOT/c4/cache/b/meta.json" -a "$(status c4)" = 0
  check "and the run with the subset saves nothing" bash -c "! grep -q 'cache_save=true' '$ROOT/c4/gh_output'"
  check "the subset run records only its apps" test "$(builds c4 'keys|join(",")')" = a

  # an app that fails to build is not cached and fails the step
  fork c5 a; run_build c5 ionos-build-select.sh
  cache_run c5 NPM_FAIL=a
  check "a failed app build fails the step and is not cached, no save" bash -c "test \"\$(cat '$ROOT/c5/status')\" != 0 && test ! -e '$ROOT/c5/cache/a/meta.json' && ! grep -q cache_save '$ROOT/c5/gh_output'"

  # the package step: the keys file is the used builds, the checksum is of the tree that was assembled
  check "the checksum of a reused app is that of its tree in the app folder" bash -c ". '$HERE/ionos-cache-lib.sh'; [ \"\$(cache_tree_checksum '$ROOT/c1/repo/apps-x/a')\" = \"\$(jq -r .a.checksum '$ROOT/c1/work/app-builds.json')\" ]"

  # the checksum itself
  local t="$ROOT/ck" sum
  rm -rf "$t"; mkdir -p "$t/x/y"; echo 1 > "$t/x/y/f"; echo 2 > "$t/g"; ln -s g "$t/l"; mkdir -p "$t/.git"; echo g > "$t/.git/ignored"
  sum() { bash -c ". '$HERE/ionos-cache-lib.sh'; cache_tree_checksum '$1'"; }
  sum="$(sum "$t")"
  check "checksum: a sha256" bash -c "[[ '$sum' =~ ^[0-9a-f]{64}\$ ]]"
  touch -d '2001-01-01' "$t/x/y/f"; mkdir "$t/empty"
  check "checksum: not changed by timestamps and empty folders" test "$(sum "$t")" = "$sum"
  echo changed > "$t/.git/ignored"
  check "checksum: .git of the app folder is not part of it" test "$(sum "$t")" = "$sum"
  # the documented ignore list (ionos-cache-lib.sh): source maps and the root webpack-stats.json, measured nondeterministic
  mkdir -p "$t/js"; echo '{"mappings":"a"}' > "$t/js/main.js.map"; echo '{"builtAt":1}' > "$t/webpack-stats.json"; sum="$(sum "$t")"
  echo '{"mappings":"b"}' > "$t/js/main.js.map"; echo '{"builtAt":2}' > "$t/webpack-stats.json"
  check "checksum: source maps (*.map) and the root webpack-stats.json are ignored" test "$(sum "$t")" = "$sum"
  echo changed > "$t/js/main.js"
  check "checksum: the js next to a source map is not ignored" test "$(sum "$t")" != "$sum"
  rm "$t/js/main.js"; mkdir -p "$t/sub"; echo 1 > "$t/sub/webpack-stats.json"
  check "checksum: only the webpack-stats.json at the root is ignored" test "$(sum "$t")" != "$sum"
  rm -r "$t/sub"; echo x > "$t/js/main.js.map.license"
  check "checksum: a *.map.license file is not a source map" test "$(sum "$t")" != "$sum"
  rm "$t/js/main.js.map.license"
  check "checksum: back to the same content, the same checksum" test "$(sum "$t")" = "$sum"
  echo 3 > "$t/g"
  check "checksum: a changed file changes it" test "$(sum "$t")" != "$sum"
  echo 2 > "$t/g"; ln -sf x "$t/l"
  check "checksum: a changed link target changes it" test "$(sum "$t")" != "$sum"
  ln -sf g "$t/l"; mv "$t/x/y/f" "$t/x/y/f2"
  check "checksum: a renamed file changes it" test "$(sum "$t")" != "$sum"
  mv "$t/x/y/f2" "$t/x/y/f"; : > "$t/new file"
  check "checksum: an added file (also with a space in its name) changes it" test "$(sum "$t")" != "$sum"

  # the workflow: restore, the static steps, the save, no_cache
  local wf="$HERE/../workflows/ionos-build.yml"
  check "workflow: input no_cache, a boolean that defaults to false" bash -c "grep -A3 '^      no_cache:' '$wf' | grep -q 'type: boolean' && grep -A4 '^      no_cache:' '$wf' | grep -q 'default: false'"
  check "workflow: the restore step is skipped for no_cache" bash -c "grep -B2 -A8 'actions/cache/restore@' '$wf' | grep -q 'inputs.no_cache'"
  check "workflow: the restore uses a key prefix so the newest folder is found" bash -c "grep -A8 'actions/cache/restore@' '$wf' | grep -q 'restore-keys' && grep -A10 'actions/cache/restore@' '$wf' | grep -q 'ionos-app-build-v1-'"
  check "workflow: the save step takes the key from the apps step and only runs when asked" bash -c "grep -B3 -A6 'actions/cache/save@' '$wf' | grep -q 'steps.apps.outputs.cache_key' && grep -B3 'actions/cache/save@' '$wf' | grep -q \"cache_save == 'true'\""
  check "workflow: cache actions are pinned by full commit sha" test "$(grep -c 'uses: actions/cache/\(restore\|save\)@[0-9a-f]\{40\} # v' "$wf")" = 2
  check "workflow: the prefix is the one the script uses" bash -c ". '$HERE/ionos-cache-lib.sh'; [ \"\$CACHE_PREFIX\" = ionos-app-build-v1- ]"
}

ALL="plan release_plan retention publish release_publish select apps recipes server assemble package release_package cache"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
