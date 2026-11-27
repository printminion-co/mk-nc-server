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
      */releases) [ "${STUB_FAIL:-}" = list ] && { echo "gh: boom (HTTP 500)" >&2; exit 1; }; cat "$S/releases.json" ;;
      *) echo "stub gh: unexpected api $ep" >&2; exit 2 ;;
    esac ;;
  release)
    sub="$2"; shift 2
    case "$sub" in
      view) exists "$1" ;;
      create)
        tag="$1"; shift; title=""; notes=""; target=""; pre=false; assets=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --notes-file) notes="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            -R) shift 2 ;;
            --prerelease) pre=true; shift ;;
            --*) shift ;;
            *) assets+=("$(basename "$1")"); shift ;;
          esac
        done
        [ "${STUB_FAIL:-}" = release ] && { echo "gh: release failed (HTTP 500)" >&2; exit 1; }
        exists "$tag" && { echo "gh: tag exists (HTTP 422)" >&2; exit 1; }
        body="$(cat "$notes")"
        n="$(jq 'length' "$S/releases.json")"
        save ". + [{\"tag_name\":$(jq -Rn --arg t "$tag" '$t'),\"name\":$(jq -Rn --arg t "$title" '$t'),\"prerelease\":$pre,\"draft\":false,\"target_commitish\":$(jq -Rn --arg t "$target" '$t'),\"body\":$(jq -Rn --arg t "$body" '$t'),\"assets\":$(printf '%s\n' "${assets[@]}" | jq -R . | jq -sc .),\"id\":$((n + 1))}]" ;;
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
  check "release kind fails early" test "$(status p6)" != 0
  check "release kind says release builds arrive with the snapshot ticket" logged p6 'snapshot ticket'
  check "release kind sets no build output" test -z "$(output p6 build)"
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
pubworld() {
  newworld "$1"
  local w="$ROOT/$1/work"; mkdir -p "$w/out"
  local f
  for f in flavor1 flavor2; do
    echo "zip $f" > "$w/out/ncw-$f-v33.0.9.42.zip"
    (cd "$w/out" && sha256sum "ncw-$f-v33.0.9.42.zip" > "ncw-$f-v33.0.9.42.zip.sha256")
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

# ---------------------------------------------------------------- heavy command stubs
# npm: `ci` makes node_modules, `run build` makes js/built.js; composer: `install` makes vendor/.
# Every call is logged to $CMD_LOG as "<cwd relative to $CMD_BASE>: <command> <args>".
cat > "$ROOT/bin/heavy-stub" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
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

# the flavors tool: resolve prints $RESOLVE_DIR/<flavor>.yaml, build writes a fake archive, validate
# fails for the flavor in $VALIDATE_FAIL
cat > "$ROOT/bin/ncw-stub" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
declare -A A
while [ $# -gt 0 ]; do A["${1#--}"]="$2"; shift 2; done
echo "ncw $cmd ${A[flavor]:-} kind=${A[kind]:-} bn=${A[build-number]:-} line=${A[line]:-} sc=${A[server-commit]:-} fc=${A[flavors-commit]:-} tree=${A[tree]:-}" >> "$NCW_LOG"
case "$cmd" in
  resolve) cat "$RESOLVE_DIR/${A[flavor]}.yaml" ;;
  build)
    [[ ",${BUILD_FAIL:-}," == *",${A[flavor]},"* ]] && { echo "ncw: boom" >&2; exit 2; }
    [ -n "${A[app-pins]:-}" ] && cp "${A[app-pins]}" "$NCW_LOG.pins.${A[flavor]}"
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
  check "a composer.json that requires only php, extensions and the bin plugin has nothing to install: composer is not run" test "$(status a12)" = 0 -a "$(grep -c 'apps-x/cx: composer' "$ROOT/a12/cmd.log")" = 0
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
  check "no cache keys are passed" test "$(grep -c 'cache-keys' "$ROOT/k1/ncw.log")" = 0
  check "the run is marked validated for the publish step" test "$(cat "$ROOT/k1/work/validated")" = "$(cat "$ROOT/k1/work/flavors.txt")"

  fork k2
  run_build k2 ionos-build-select.sh
  run_build k2 ionos-build-assemble.sh
  run_build k2 ionos-build-package.sh BUILD_NUMBER=7 LINE=33 SERVER_COMMIT=$sha FLAVORS_COMMIT=$fsha
  check "with no out-of-tree apps the pins are an empty object" test "$(jq -c . "$ROOT/k2/ncw.log.pins.flavor1")" = '{}'
  check "package succeeds with none" test "$(status k2)" = 0

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
}

ALL="plan retention publish select apps recipes server assemble package"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
