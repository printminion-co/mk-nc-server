#!/usr/bin/env bash
# Tests for ionos-sync.sh. Builds throwaway local repositories (a bare "upstream" and a bare
# "fork") and a stub `gh` on PATH. Nothing here talks to the network or to GitHub.
# Usage: ionos-sync.test.sh [scenario ...]   (default: all scenarios)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/ionos-sync.sh"
ROOT="$(mktemp -d)"
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$ROOT"' EXIT; else echo "keeping $ROOT" >&2; fi

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

# ---------------------------------------------------------------- world
# world <name> <conflict|clean> <final|rc>
# upstream: v33.0.9 on stable33, then v33.0.10 (final) or v33.0.10rc1 (rc) one commit later
#           that changes a.txt.
# fork:     ionos-dev-v33 = v33.0.9 + 2 commits; the second touches a.txt (conflict) or b.txt (clean).
world() {
  local kind="$2" tagkind="$3" w="$ROOT/$1"
  mkdir -p "$w/bin" "$w/state"
  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" config uploadpack.allowFilter true
  git -C "$w/upstream.git" config uploadpack.allowAnySHA1InWant true
  git init -q "$w/up-work"
  (
    cd "$w/up-work" || exit 1
    git checkout -q -b stable33
    printf 'a1\na2\na3\n' > a.txt; printf 'b1\nb2\nb3\n' > b.txt
    git add . && git commit -q -m "release 33.0.9" && git tag v33.0.9
    git branch master
    printf 'a1\nA-UPSTREAM\na3\n' > a.txt
    git commit -qam "release 33.0.10"
    if [ "$tagkind" = final ]; then git tag v33.0.10; else git tag v33.0.10rc1; fi
    git push -q "$w/upstream.git" stable33 master --tags
  )
  git init -q --bare "$w/fork.git"
  git -C "$w/fork.git" config uploadpack.allowFilter true
  git init -q "$w/fk-work"
  (
    cd "$w/fk-work" || exit 1
    git fetch -q "$w/upstream.git" stable33
    git checkout -q -b ionos-dev-v33 "$(git -C "$w/upstream.git" rev-parse v33.0.9)"
    printf 'ours\n' > ionos-x.txt; git add . && git commit -q -m "IONOS(x): add file"
    if [ "$kind" = conflict ]; then printf 'a1\nA-OURS\na3\n' > a.txt; else printf 'b1\nB-OURS\nb3\n' > b.txt; fi
    git commit -qam "IONOS(y): change a file"
    # the fork mirrors are at v33.0.9 (the stub's merge-upstream does not advance them)
    git push -q "$w/fork.git" ionos-dev-v33 \
      "$(git -C "$w/upstream.git" rev-parse v33.0.9)":refs/heads/stable33 \
      "$(git -C "$w/upstream.git" rev-parse v33.0.9)":refs/heads/master
  )
  # state of the stubbed GitHub API
  cat > "$w/state/workflows.json" <<'JSON'
{"workflows":[
 {"id":1,"path":".github/workflows/phpunit-mysql.yml","state":"active"},
 {"id":2,"path":".github/workflows/ionos-commit-lint.yml","state":"active"},
 {"id":3,"path":".github/workflows/lint-php.yml","state":"active"},
 {"id":4,"path":".github/workflows/node.yml","state":"disabled_manually"}
]}
JSON
  echo '[]' > "$w/state/issues.json"
  : > "$w/state/calls.log"
  cat > "$w/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: records every call and answers only the API calls ionos-sync.sh uses.
S="$STUB_STATE"
echo "gh $*" >> "$S/calls.log"
[ "${1:-}" = api ] || { echo "stub gh: unsupported: $*" >&2; exit 2; }
shift
method=GET; endpoint=""; declare -A F
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -f|-F) F["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --paginate|--silent) shift ;;
    --jq|-q) shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$method $endpoint" in
  "POST repos/"*/merge-upstream)
    b="${F[branch]}"; v="STUB_MERGE_${b//[^A-Za-z0-9]/_}"
    if [ "${!v:-}" = 409 ]; then echo '{"message":"There are merge conflicts"}'; echo "gh: HTTP 409" >&2; exit 1; fi
    echo '{"message":"Successfully fetched and fast-forwarded from upstream.","merge_type":"fast-forward"}' ;;
  "GET repos/"*/actions/workflows*) cat "$S/workflows.json" ;;
  "PUT repos/"*/actions/workflows/*/disable)
    id="${endpoint#*/workflows/}"; id="${id%/disable}"
    jq --argjson id "$id" '(.workflows[]|select(.id==$id)).state="disabled_manually"' "$S/workflows.json" > "$S/w.tmp" && mv "$S/w.tmp" "$S/workflows.json" ;;
  "GET repos/"*/issues*) jq -c '.[]' "$S/issues.json" | jq -s '.' ;;
  "POST repos/"*/issues)
    jq --arg t "${F[title]}" --arg b "${F[body]}" '. + [{"number":(length+1),"title":$t,"body":$b,"state":"open"}]' "$S/issues.json" > "$S/i.tmp" && mv "$S/i.tmp" "$S/issues.json"
    echo '{"number":1}' ;;
  *) echo "stub gh: unexpected $method $endpoint" >&2; exit 2 ;;
esac
STUB
  chmod +x "$w/bin/gh"
}

# run_sync <world> [VAR=value ...]  -> runs the script, output in $W/out.log, status in $W/status
run_sync() {
  local w="$ROOT/$1"; shift
  env PATH="$w/bin:$PATH" STUB_STATE="$w/state" GITHUB_REPOSITORY=acme/server \
    UPSTREAM_URL="$w/upstream.git" FORK_URL="$w/fork.git" "$@" \
    bash "$SYNC" > "$w/out.log" 2>&1
  echo $? > "$w/status"
}

fork_ref() { git -C "$ROOT/$1/fork.git" rev-parse --verify -q "$2"; }
up_tag()   { git -C "$ROOT/$1/upstream.git" rev-parse --verify -q "$2^{commit}"; }
calls()    { grep -c "$2" "$ROOT/$1/state/calls.log"; }
n_issues() { jq length "$ROOT/$1/state/issues.json"; }
state_of() { jq -r --argjson id "$2" '.workflows[]|select(.id==$id).state' "$ROOT/$1/state/workflows.json"; }

CAND=refs/heads/candidate/ionos-dev-v33/v33.0.10

# ---------------------------------------------------------------- scenarios
sc_clean() {
  world clean clean final
  local dev0; dev0="$(fork_ref clean refs/heads/ionos-dev-v33)"
  run_sync clean
  check "exit status 0" test "$(cat "$ROOT/clean/status")" = 0
  local cand tag; cand="$(fork_ref clean $CAND)"; tag="$(up_tag clean v33.0.10)"
  check "candidate branch candidate/ionos-dev-v33/v33.0.10 exists" test -n "$cand"
  check "candidate is the series (2 commits) on top of v33.0.10" \
    test "$(git -C "$ROOT/clean/fork.git" rev-list --count "$tag..$cand" 2>/dev/null)" = 2 -a "$(git -C "$ROOT/clean/fork.git" rev-parse "$cand~2" 2>/dev/null)" = "$tag"
  check "commit subjects are kept" \
    test "$(git -C "$ROOT/clean/fork.git" log --format=%s "$tag..$cand" 2>/dev/null | tr '\n' '|')" = "IONOS(y): change a file|IONOS(x): add file|"
  check "candidate commits are unsigned" \
    test "$(git -C "$ROOT/clean/fork.git" log --format=%G? "$tag..$cand" 2>/dev/null | sort -u)" = N
  check "ionos-dev-v33 is not moved" test "$(fork_ref clean refs/heads/ionos-dev-v33)" = "$dev0"
  check "no issue opened" test "$(n_issues clean)" = 0
}

sc_conflict() {
  world conflict conflict final
  local dev0; dev0="$(fork_ref conflict refs/heads/ionos-dev-v33)"
  run_sync conflict
  check "exit status 0" test "$(cat "$ROOT/conflict/status")" = 0
  check "no candidate branch" test -z "$(fork_ref conflict $CAND)"
  check "ionos-dev-v33 is not moved" test "$(fork_ref conflict refs/heads/ionos-dev-v33)" = "$dev0"
  check "exactly one issue created" test "$(calls conflict 'POST repos/acme/server/issues')" = 1
  check "issue title names the tag" test "$(jq -r '.[0].title' "$ROOT/conflict/state/issues.json")" = "Rebase of ionos-dev-v33 onto v33.0.10 conflicts"
  check "issue body names the conflicting file" grep -q 'a.txt' <(jq -r '.[0].body' "$ROOT/conflict/state/issues.json")
  check "issue body explains the manual rebase" grep -q 'git rebase --onto v33.0.10 v33.0.9' <(jq -r '.[0].body' "$ROOT/conflict/state/issues.json")
}

sc_idempotent_clean() {
  world idem clean final
  run_sync idem
  local c1; c1="$(fork_ref idem $CAND)"
  : > "$ROOT/idem/state/calls.log"
  run_sync idem
  check "second run exits 0" test "$(cat "$ROOT/idem/status")" = 0
  check "candidate branch unchanged" test "$(fork_ref idem $CAND)" = "$c1"
  check "second run says the candidate exists" grep -q 'already exists' "$ROOT/idem/out.log"
  # merge-upstream is a POST but a no-op when the mirror is current, so it is not counted
  check "second run makes no mutating gh call (besides the no-op mirror sync)" \
    test "$(grep -v merge-upstream "$ROOT/idem/state/calls.log" | grep -cE 'PUT|POST|DELETE|PATCH')" = 0
}

sc_idempotent_conflict() {
  world idemc conflict final
  run_sync idemc
  run_sync idemc
  check "second run exits 0" test "$(cat "$ROOT/idemc/status")" = 0
  check "still exactly one issue" test "$(n_issues idemc)" = 1
  check "still no candidate branch" test -z "$(fork_ref idemc $CAND)"
}

sc_disable_workflows() {
  world dis clean final
  run_sync dis
  check "non-ionos active workflows are disabled" test "$(state_of dis 1)$(state_of dis 3)" = disabled_manuallydisabled_manually
  check "ionos- workflow stays active" test "$(state_of dis 2)" = active
  check "already disabled workflow is not touched" test "$(calls dis 'PUT repos/acme/server/actions/workflows/4/')" = 0
  check "exactly two disable calls" test "$(calls dis 'PUT .*/disable')" = 2
  : > "$ROOT/dis/state/calls.log"
  run_sync dis
  check "second run makes no disable call" test "$(calls dis 'PUT')" = 0
}

sc_dry_run() {
  world dry clean final
  local dev0; dev0="$(fork_ref dry refs/heads/ionos-dev-v33)"
  run_sync dry DRY_RUN=true
  check "exit status 0" test "$(cat "$ROOT/dry/status")" = 0
  check "no candidate branch" test -z "$(fork_ref dry $CAND)"
  check "no mutating gh call" test "$(grep -cE 'PUT|POST|DELETE|PATCH' "$ROOT/dry/state/calls.log")" = 0
  check "workflows unchanged" test "$(state_of dry 1)" = active
  check "reports what it would do" grep -q 'would: push candidate/ionos-dev-v33/v33.0.10' "$ROOT/dry/out.log"
  check "ionos-dev-v33 is not moved" test "$(fork_ref dry refs/heads/ionos-dev-v33)" = "$dev0"
  world dryc conflict final
  run_sync dryc DRY_RUN=true
  check "dry run on conflict opens no issue" test "$(n_issues dryc)" = 0
}

sc_prerelease_ignored() {
  world rc clean rc
  run_sync rc
  check "exit status 0" test "$(cat "$ROOT/rc/status")" = 0
  check "no candidate for v33.0.10rc1" test -z "$(git -C "$ROOT/rc/fork.git" for-each-ref refs/heads/candidate)"
  check "no issue" test "$(n_issues rc)" = 0
  run_sync rc UPSTREAM_TAG=v33.0.10rc1
  check "override with a non-final tag fails" test "$(cat "$ROOT/rc/status")" != 0
  check "still no candidate" test -z "$(git -C "$ROOT/rc/fork.git" for-each-ref refs/heads/candidate)"
}

sc_tag_override() {
  world ovr clean final
  run_sync ovr UPSTREAM_TAG=v33.0.10
  check "override with a final tag creates its candidate" test -n "$(fork_ref ovr $CAND)"
  world ovr2 clean final
  run_sync ovr2 UPSTREAM_TAG=v33.0.99
  check "override with an unknown tag fails" test "$(cat "$ROOT/ovr2/status")" != 0
}

sc_mirrors() {
  world mir clean final
  run_sync mir
  check "merge-upstream called for master" test "$(calls mir 'POST repos/acme/server/merge-upstream -f branch=master')" = 1
  check "merge-upstream called for stable33" test "$(calls mir 'POST repos/acme/server/merge-upstream -f branch=stable33')" = 1
  check "mirrors are never pushed to directly" test "$(calls mir 'force')" = 0
  world mir409 clean final
  run_sync mir409 STUB_MERGE_stable33=409
  check "a 409 fails the run" test "$(cat "$ROOT/mir409/status")" != 0
  check "the 409 is reported" grep -q 'stable33' <(grep -i 'error' "$ROOT/mir409/out.log")
  check "it is not forced (merge-upstream tried once, no retry or push to the mirror)" \
    test "$(calls mir409 'branch=stable33')" = 1 -a "$(fork_ref mir409 refs/heads/stable33)" = "$(up_tag mir409 v33.0.9)"
  check "other steps still run after a 409" test -n "$(fork_ref mir409 $CAND)"
}

ALL="clean conflict idempotent_clean idempotent_conflict disable_workflows dry_run prerelease_ignored tag_override mirrors"
if [ $# -gt 0 ]; then SELECT=("$@"); else read -r -a SELECT <<< "$ALL"; fi
for s in "${SELECT[@]}"; do
  echo "scenario: $s"
  "sc_$s"
done
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
