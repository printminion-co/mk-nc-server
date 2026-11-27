#!/usr/bin/env bash
# Tests for ionos-snapshot.sh. The fork is a throwaway local bare repository and `gh` is a stub on PATH that
# serves the few GitHub API calls the script makes from that repository (refs, tag objects, version.php) and logs
# `gh workflow run`. Nothing here talks to the network or to GitHub.
# Usage: ionos-snapshot.test.sh [scenario ...]   (default: all scenarios)
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

# ---------------------------------------------------------------- stub gh
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: the fork is the bare repository $STUB_FORK; calls.log holds every call, dispatch.log every workflow run.
# STUB_FAIL: tagobj | branchref | tagref | dispatch (fails STUB_FAIL_N times, default always) | read
S="$STUB_STATE"
echo "gh $*" >> "$S/calls.log"
http() { echo "gh: $2 (HTTP $1)" >&2; exit 1; }
if [ "${1:-}" = workflow ]; then
  [ "$2" = run ] || { echo "stub gh: unsupported $*" >&2; exit 2; }
  echo "$*" >> "$S/dispatch.log"
  if [ "${STUB_FAIL:-}" = dispatch ]; then
    n=$(cat "$S/dispatch.fails" 2>/dev/null || echo 0)
    if [ "$n" -lt "${STUB_FAIL_N:-999}" ]; then echo $((n + 1)) > "$S/dispatch.fails"; http 500 "Server Error"; fi
  fi
  exit 0
fi
[ "${1:-}" = api ] || { echo "stub gh: unsupported: $*" >&2; exit 2; }
shift
method=GET; endpoint=""; jqexpr=""; declare -A F
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    -f|-F|--field|--raw-field) F["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --jq|-q) jqexpr="$2"; shift 2 ;;
    -H|--header) shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
[ "${method}" != GET ] || [ -z "${F[ref]:-}${F[sha]:-}" ] || true
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
case "$method $endpoint" in
  "GET repos/"*/git/ref/heads/*)
    [ "${STUB_FAIL:-}" = read ] && http 500 "Server Error"
    b="${endpoint#*/git/ref/heads/}"
    sha=$(git -C "$STUB_FORK" rev-parse --verify -q "refs/heads/$b") || http 404 "Not Found"
    jq -n --arg r "refs/heads/$b" --arg s "$sha" '{ref:$r, object:{sha:$s, type:"commit"}}' | emit ;;
  "GET repos/"*/contents/version.php)
    c=$(git -C "$STUB_FORK" show "${F[ref]}:version.php" 2>/dev/null | base64) || http 404 "Not Found"
    [ -n "$c" ] || http 404 "Not Found"
    jq -n --arg c "$c" '{content:$c, encoding:"base64"}' | emit ;;
  "GET repos/"*/git/matching-refs/*)
    p="refs/${endpoint#*/git/matching-refs/}"
    git -C "$STUB_FORK" for-each-ref --format='%(refname)%09%(objecttype)%09%(objectname)' "$p*" \
      | jq -R -s '[split("\n")[] | select(length>0) | split("\t") | {ref:.[0], object:{type:.[1], sha:.[2]}}]' | emit ;;
  "POST repos/"*/git/tags)
    [ "${STUB_FAIL:-}" = tagobj ] && http 500 "Server Error"
    printf 'object %s\ntype commit\ntag %s\ntagger Test <test@example.invalid> 0 +0000\n\n%s\n' "${F[object]}" "${F[tag]}" "${F[message]}" > "$S/tag.tmp"
    sha=$(git -C "$STUB_FORK" hash-object -t tag -w --stdin < "$S/tag.tmp") || http 422 "Validation Failed"
    jq -n --arg s "$sha" '{sha:$s}' | emit ;;
  "POST repos/"*/git/refs)
    case "${F[ref]}" in refs/heads/*) [ "${STUB_FAIL:-}" = branchref ] && http 500 "Server Error" ;; refs/tags/*) [ "${STUB_FAIL:-}" = tagref ] && http 500 "Server Error" ;; esac
    git -C "$STUB_FORK" rev-parse --verify -q "${F[ref]}" >/dev/null && http 422 "Reference already exists"
    git -C "$STUB_FORK" cat-file -e "${F[sha]}" 2>/dev/null || http 422 "Object does not exist"
    git -C "$STUB_FORK" update-ref "${F[ref]}" "${F[sha]}"
    jq -n --arg r "${F[ref]}" --arg s "${F[sha]}" '{ref:$r, object:{sha:$s}}' | emit ;;
  "GET repos/"*/git/tags/*)
    sha="${endpoint#*/git/tags/}"
    git -C "$STUB_FORK" cat-file -e "$sha" 2>/dev/null || http 404 "Not Found"
    git -C "$STUB_FORK" cat-file -p "$sha" | jq -R -s --arg s "$sha" '
      split("\n\n") as $p | ($p[0] | split("\n")) as $h
      | {sha:$s, message:($p[1:] | join("\n\n")), object:{type:($h[1] | sub("^type ";"")), sha:($h[0] | sub("^object ";""))}}' | emit ;;
  *) echo "stub gh: unexpected $method $endpoint" >&2; exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/gh"

# ---------------------------------------------------------------- world
# world <name> [version]: a bare "fork" with ionos-dev-v33 (and a decoy branch main) whose version.php says <version>
SRC_SHA=""
world() {
  local w="$ROOT/$1" version="${2:-33.0.9}"
  mkdir -p "$w/state" "$w/work"
  : > "$w/state/calls.log"
  git init -q --bare "$w/fork.git"
  git init -q "$w/fk-work"
  (
    cd "$w/fk-work" || exit 1
    git checkout -q -b ionos-dev-v33
    printf '<?php\n$OC_Version = [33, 0, 9, 1];\n$OC_VersionString = '"'%s'"';\n' "$version" > version.php
    git add . && git commit -q -m "IONOS(x): base"
    echo more > f && git add f && git commit -q -m "IONOS(x): tip"
    git branch other
    git push -q "$w/fork.git" ionos-dev-v33 other
  )
  SRC_SHA=$(git -C "$w/fork.git" rev-parse ionos-dev-v33)
}
refs() { git -C "$ROOT/$1/fork.git" for-each-ref --format='%(refname) %(objectname)' refs/heads/rc refs/heads/rehearsal refs/tags | sort; }
has_ref() { git -C "$ROOT/$1/fork.git" rev-parse --verify -q "$2" >/dev/null; }
status() { cat "$ROOT/$1/status"; }
logged() { grep -q -- "$2" "$ROOT/$1/out.log"; }
dispatches() { if [ -f "$ROOT/$1/state/dispatch.log" ]; then wc -l < "$ROOT/$1/state/dispatch.log"; else echo 0; fi; }
# snap <world> [VAR=value ...]: runs the script with a valid default input
snap() {
  local w="$ROOT/$1"; shift
  : > "$w/gh_output"; : > "$w/summary"
  env PATH="$ROOT/bin:$PATH" STUB_STATE="$w/state" STUB_FORK="$w/fork.git" GITHUB_REPOSITORY=acme/server \
    GITHUB_OUTPUT="$w/gh_output" GITHUB_STEP_SUMMARY="$w/summary" GH_TOKEN=secret-token-value HAS_SYNC_TOKEN=true \
    RELEASE_NR=1 SOURCE_BRANCH=ionos-dev-v33 SCOPE="First release: flavor1" REHEARSAL=false DRY_RUN=false \
    RETRIES=3 RETRY_SLEEP=0 "$@" bash "$HERE/ionos-snapshot.sh" > "$w/out.log" 2>&1
  echo $? > "$w/status"
}
tagmsg() { git -C "$ROOT/$1/fork.git" cat-file -p "$2" | sed '1,/^$/d'; }

# ---------------------------------------------------------------- the happy path
sc_create() {
  world a
  snap a
  check "the first snapshot succeeds" test "$(status a)" = 0
  check "branch rc/ncw-v33-1 exists at the source tip (no new commit)" test "$(git -C "$ROOT/a/fork.git" rev-parse refs/heads/rc/ncw-v33-1)" = "$SRC_SHA"
  check "the source branch did not move" test "$(git -C "$ROOT/a/fork.git" rev-parse refs/heads/ionos-dev-v33)" = "$SRC_SHA"
  check "tag ncw-v33.0.9-1 exists" has_ref a refs/tags/ncw-v33.0.9-1
  check "the tag is ANNOTATED" test "$(git -C "$ROOT/a/fork.git" cat-file -t refs/tags/ncw-v33.0.9-1)" = tag
  check "the tag points at the source commit" test "$(git -C "$ROOT/a/fork.git" rev-parse 'refs/tags/ncw-v33.0.9-1^{commit}')" = "$SRC_SHA"
  local m; m=$(tagmsg a ncw-v33.0.9-1)
  check "annotation: scope" grep -qx 'scope: First release: flavor1' <<<"$m"
  check "annotation: release number, line and base release" bash -c "grep -qx 'release_nr: 1' <<<'$m' && grep -qx 'line: 33' <<<'$m' && grep -qx 'base_release: 33.0.9' <<<'$m'"
  check "annotation: source branch and commit" bash -c "grep -qx 'source_branch: ionos-dev-v33' <<<'$m' && grep -qx 'source_commit: $SRC_SHA' <<<'$m'"
  check "annotation: snapshot branch and rehearsal flag" bash -c "grep -qx 'snapshot_branch: rc/ncw-v33-1' <<<'$m' && grep -qx 'rehearsal: false' <<<'$m'"
  check "the release build is started on the snapshot branch with kind=release" grep -qx 'workflow run ionos-build.yml -R acme/server --ref rc/ncw-v33-1 -f kind=release' "$ROOT/a/state/dispatch.log"
  check "exactly one dispatch" test "$(dispatches a)" = 1
  check "the token value never appears in the log" bash -c "! grep -q secret-token-value '$ROOT/a/out.log'"
  check "outputs name the branch and the tag" bash -c "grep -qx 'branch=rc/ncw-v33-1' '$ROOT/a/gh_output' && grep -qx 'tag=ncw-v33.0.9-1' '$ROOT/a/gh_output'"
  check "the step summary links the release builds of the branch" grep -q 'rc/ncw-v33-1' "$ROOT/a/summary"

  # a second release number is fine, and so is 10 next to 1 (the matching-refs lookup is a prefix match)
  snap a RELEASE_NR=2
  check "release number 2 works next to 1" test "$(status a)" = 0
  check "release number 2 made its own branch and tag" bash -c "git -C '$ROOT/a/fork.git' rev-parse -q --verify refs/heads/rc/ncw-v33-2 && git -C '$ROOT/a/fork.git' rev-parse -q --verify refs/tags/ncw-v33.0.9-2"
  snap a RELEASE_NR=10
  check "release number 10 works although 1 exists (no prefix confusion)" test "$(status a)" = 0
  snap a RELEASE_NR=1
  check "release number 1 is still taken although 10 and 2 exist" test "$(status a)" != 0
}

# ---------------------------------------------------------------- the same number twice
sc_duplicate() {
  world d
  snap d
  local before; before=$(refs d)
  snap d
  check "the second run with the same release number fails" test "$(status d)" != 0
  check "it says the number is used and which refs exist" bash -c "grep -q 'already used' '$ROOT/d/out.log' && grep -q 'rc/ncw-v33-1' '$ROOT/d/out.log' && grep -q 'ncw-v33.0.9-1' '$ROOT/d/out.log'"
  check "no ref was created, moved or deleted" test "$(refs d)" = "$before"
  check "the build was not started a second time" test "$(dispatches d)" = 1

  world d2
  git -C "$ROOT/d2/fork.git" update-ref refs/heads/rc/ncw-v33-3 "$SRC_SHA"
  before=$(refs d2)
  snap d2 RELEASE_NR=3
  check "an existing branch alone burns the number" test "$(status d2)" != 0 -a "$(refs d2)" = "$before" -a "$(dispatches d2)" = 0

  world d3
  tagobj=$(printf 'object %s\ntype commit\ntag ncw-v33.0.8-4\ntagger T <t@e.invalid> 0 +0000\n\nold\n' "$SRC_SHA" | git -C "$ROOT/d3/fork.git" hash-object -t tag -w --stdin)
  git -C "$ROOT/d3/fork.git" update-ref refs/tags/ncw-v33.0.8-4 "$tagobj"
  before=$(refs d3)
  snap d3 RELEASE_NR=4
  check "a tag of ANOTHER base release of the line with the same number burns it" test "$(status d3)" != 0 -a "$(refs d3)" = "$before" -a "$(dispatches d3)" = 0
  git -C "$ROOT/d3/fork.git" update-ref refs/tags/ncw-v34.0.1-5 "$tagobj"
  snap d3 RELEASE_NR=5
  check "a tag of another line does not count" test "$(status d3)" = 0

  # lightweight tag of the same number is a tag too
  world d4
  git -C "$ROOT/d4/fork.git" update-ref refs/tags/ncw-v33.0.9-6 "$SRC_SHA"
  snap d4 RELEASE_NR=6
  check "a lightweight tag with the number burns it" test "$(status d4)" != 0 -a "$(dispatches d4)" = 0

  # nothing may be created when the listing of existing refs fails
  world d5
  snap d5 STUB_FAIL=read
  check "an unreadable source branch fails before anything is created" test "$(status d5)" != 0 -a -z "$(refs d5)"
}

# ---------------------------------------------------------------- rehearsal
sc_rehearsal() {
  world r
  snap r
  local real; real=$(refs r)
  snap r REHEARSAL=true
  check "a rehearsal succeeds although the real number 1 exists" test "$(status r)" = 0
  check "rehearsal branch rehearsal/ncw-v33-1 at the source tip" test "$(git -C "$ROOT/r/fork.git" rev-parse refs/heads/rehearsal/ncw-v33-1)" = "$SRC_SHA"
  check "rehearsal tag rehearsal-v33.0.9-1 is annotated" test "$(git -C "$ROOT/r/fork.git" cat-file -t refs/tags/rehearsal-v33.0.9-1)" = tag
  check "the real refs are untouched" test "$(refs r | grep -E ' refs/(heads/rc|tags/ncw)' )" = "$(grep -E ' refs/(heads/rc|tags/ncw)' <<<"$real")"
  local m; m=$(tagmsg r refs/tags/rehearsal-v33.0.9-1)
  check "annotation says rehearsal: true and names the rehearsal branch" bash -c "grep -qx 'rehearsal: true' <<<'$m' && grep -qx 'snapshot_branch: rehearsal/ncw-v33-1' <<<'$m'"
  check "the build is started on the rehearsal branch" grep -qx 'workflow run ionos-build.yml -R acme/server --ref rehearsal/ncw-v33-1 -f kind=release' "$ROOT/r/state/dispatch.log"
  snap r REHEARSAL=true
  check "a second rehearsal with the same number fails (refs are never updated)" test "$(status r)" != 0
  check "the rehearsal failure says how to reuse the number" logged r 'delete'
  world r2
  snap r2 REHEARSAL=true
  snap r2
  check "the real number 1 is free after a rehearsal 1" bash -c "[ '$(status r2)' = 0 ] && git -C '$ROOT/r2/fork.git' rev-parse -q --verify refs/heads/rc/ncw-v33-1"
}

# ---------------------------------------------------------------- inputs
sc_inputs() {
  world i
  local before bad
  before=$(refs i)
  for bad in 0 01 -1 abc '1 2' '1;touch pwned' '$(touch pwned)' '' 1.5 ' 1' '99999999999999999999'; do
    snap i "RELEASE_NR=$bad"
    check "release number '$bad' is refused" test "$(status i)" != 0
  done
  for bad in main other 'ionos-dev-v33;touch pwned' ionos-dev-v rc/ncw-v33-1 'ionos-dev-v33 ' '../ionos-dev-v33' 'ionos-dev-v33/x' ''; do
    snap i "SOURCE_BRANCH=$bad"
    check "source branch '$bad' is refused" test "$(status i)" != 0
  done
  snap i "SCOPE="
  check "an empty scope is refused" test "$(status i)" != 0
  snap i "SCOPE=   "
  check "a blank scope is refused" test "$(status i)" != 0
  snap i "SCOPE=$(printf 'two\nlines')"
  check "a scope with a newline is refused" test "$(status i)" != 0
  snap i "SCOPE=$(printf 'tab\there')"
  check "a scope with a control character is refused" test "$(status i)" != 0
  snap i "SCOPE=$(printf 'x%.0s' $(seq 1 501))"
  check "a scope of 501 characters is refused" test "$(status i)" != 0
  snap i REHEARSAL=maybe
  check "rehearsal must be true or false" test "$(status i)" != 0
  snap i DRY_RUN=1
  check "dry_run must be true or false" test "$(status i)" != 0
  check "refused inputs create nothing and start nothing" test "$(refs i)" = "$before" -a "$(dispatches i)" = 0
  check "no injected command ran" test ! -e "$ROOT/i/pwned" -a ! -e "$HERE/pwned" -a ! -e "$PWD/pwned"
  check "no gh call was made for a refused release number" bash -c "! grep -q 'git/refs' '$ROOT/i/state/calls.log'"

  # the scope is text: shell syntax in it is stored as is and never run
  world i2
  local evil='$(touch pwned) `touch pwned2` ; touch pwned3 "quoted" & more'
  snap i2 "SCOPE=$evil"
  check "a scope full of shell syntax is accepted as text" test "$(status i2)" = 0
  check "it is stored verbatim in the tag annotation" bash -c "git -C '$ROOT/i2/fork.git' cat-file -p refs/tags/ncw-v33.0.9-1 | grep -qxF 'scope: $evil'"
  check "nothing was executed" test ! -e "$ROOT/i2/pwned" -a ! -e "$ROOT/i2/pwned2" -a ! -e "$ROOT/i2/pwned3" -a ! -e "$PWD/pwned" -a ! -e "$PWD/pwned2" -a ! -e "$PWD/pwned3"
  check "the scope only travels inside the -f message= argument of the tag object call (no path, no other call)" test "$(grep -c pwned "$ROOT/i2/state/calls.log")" = 1 -a "$(grep -c '^gh .*pwned' "$ROOT/i2/state/calls.log")" = 0
  local longest; longest=$(printf 'y%.0s' $(seq 1 500))
  snap i2 RELEASE_NR=2 "SCOPE=$longest"
  check "a scope of 500 characters is accepted" test "$(status i2)" = 0
  snap i2 RELEASE_NR=3 "SCOPE=Ünïcode scope, 日本語"
  check "a scope with non-ASCII text is accepted" test "$(status i2)" = 0
}

# ---------------------------------------------------------------- the source
sc_source() {
  world s
  snap s SOURCE_BRANCH=ionos-dev-v34
  check "a source branch that does not exist fails and creates nothing" test "$(status s)" != 0 -a -z "$(refs s)"

  world s2 34.0.1
  snap s2
  check "a source whose version.php belongs to another line fails" test "$(status s2)" != 0 -a -z "$(refs s2)"
  check "and says so" logged s2 '34.0.1'

  world s3 abc
  snap s3
  check "a source with no readable base release fails" test "$(status s3)" != 0 -a -z "$(refs s3)"

  world s4
  git -C "$ROOT/s4/fork.git" update-ref refs/heads/ionos-dev-v35 "$SRC_SHA"
  snap s4 SOURCE_BRANCH=ionos-dev-v35
  check "the line is taken from the branch name and checked against version.php" test "$(status s4)" != 0 -a -z "$(refs s4)"

  world s5 33.0.10
  snap s5 RELEASE_NR=7
  check "the base release is read from version.php of the source" has_ref s5 refs/tags/ncw-v33.0.10-7
}

# ---------------------------------------------------------------- dry run
sc_dry() {
  world y
  snap y DRY_RUN=true
  check "a dry run succeeds" test "$(status y)" = 0
  check "it creates no ref" test -z "$(refs y)"
  check "it starts no build" test "$(dispatches y)" = 0
  check "it says what it would do" bash -c "grep -q 'rc/ncw-v33-1' '$ROOT/y/out.log' && grep -q 'ncw-v33.0.9-1' '$ROOT/y/out.log' && grep -qi 'would' '$ROOT/y/out.log'"
  check "it makes no write call" bash -c "! grep -q -- '-X POST' '$ROOT/y/state/calls.log'"
  snap y
  snap y DRY_RUN=true
  check "a dry run of a used number still fails (the check is real)" test "$(status y)" != 0
}

# ---------------------------------------------------------------- partial failures: nothing is ever undone
sc_failure() {
  world f
  snap f STUB_FAIL=dispatch
  check "a failing dispatch fails the run" test "$(status f)" != 0
  check "the branch and the annotated tag stay" bash -c "[ -n \"\$(git -C '$ROOT/f/fork.git' rev-parse -q --verify refs/heads/rc/ncw-v33-1)\" ] && [ \"\$(git -C '$ROOT/f/fork.git' cat-file -t refs/tags/ncw-v33.0.9-1)\" = tag ]"
  check "the dispatch was retried" test "$(dispatches f)" = 3
  check "the error gives the exact command to restart the release build" grep -q 'gh workflow run ionos-build.yml --ref rc/ncw-v33-1 -f kind=release' "$ROOT/f/out.log"
  check "the error names the Actions page alternative" logged f 'Run workflow'
  check "no ref was deleted" bash -c "! grep -q -- '-X DELETE' '$ROOT/f/state/calls.log'"
  snap f
  check "running the snapshot workflow again is refused: the snapshot is spent, the restart command is the way" test "$(status f)" != 0

  world f2
  snap f2 STUB_FAIL=dispatch STUB_FAIL_N=1
  check "a dispatch that fails once is retried and succeeds" test "$(status f2)" = 0 -a "$(dispatches f2)" = 2

  world f3
  snap f3 STUB_FAIL=tagref
  check "a failing tag creation after the branch exists fails the run" test "$(status f3)" != 0
  check "the branch stays and nothing is deleted" bash -c "git -C '$ROOT/f3/fork.git' rev-parse -q --verify refs/heads/rc/ncw-v33-1 >/dev/null && ! grep -q -- '-X DELETE' '$ROOT/f3/state/calls.log'"
  check "the message says which ref exists and that the number is burnt" bash -c "grep -q 'rc/ncw-v33-1' '$ROOT/f3/out.log' && grep -q 'new release number' '$ROOT/f3/out.log'"
  check "no build was started without a tag" test "$(dispatches f3)" = 0

  world f4
  snap f4 STUB_FAIL=branchref
  check "a failing branch creation creates nothing and starts nothing" test "$(status f4)" != 0 -a -z "$(refs f4)" -a "$(dispatches f4)" = 0
  world f5
  snap f5 STUB_FAIL=tagobj
  check "a failing tag object creation creates no ref" test "$(status f5)" != 0 -a -z "$(refs f5)" -a "$(dispatches f5)" = 0
}

# ---------------------------------------------------------------- the token
sc_token() {
  world t
  snap t HAS_SYNC_TOKEN=false
  check "without IONOS_SYNC_TOKEN the run warns" grep -q '::warning::.*IONOS_SYNC_TOKEN' "$ROOT/t/out.log"
  check "and still works with the default token (the dispatch is allowed)" test "$(status t)" = 0
  world t2
  snap t2 HAS_SYNC_TOKEN=true
  check "with the token there is no warning" bash -c "! grep -q '::warning::' '$ROOT/t2/out.log'"
}

ALL="create duplicate rehearsal inputs source dry failure token"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
