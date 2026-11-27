#!/usr/bin/env bash
# Tests for ionos-app-pins.sh. The seam is the script run as a process against a stub `gh`:
# a small stateful fake of the GitHub API (fixtures for what upstream and the fork hold, state
# for what the script creates). Assertions look at that state, never at the gh calls.
# Nothing here talks to GitHub.
# Usage: bash .github/ionos/ionos-app-pins.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/ionos-app-pins.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILS=0
PASSES=0
OLD1=1111111111111111111111111111111111111111
NEW1=2222222222222222222222222222222222222222
SAME=3333333333333333333333333333333333333333
NEW_E=4444444444444444444444444444444444444444
NEWER=5555555555555555555555555555555555555555
BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ROOT_TREE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
APPS_TREE=cccccccccccccccccccccccccccccccccccccccc
AU_TREE=dddddddddddddddddddddddddddddddddddddddd
C9=9999999999999999999999999999999999999999
C10=1010101010101010101010101010101010101010
C11=1111111111111111111111111111111111111110
T10=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# --- stub gh ---------------------------------------------------------------
make_stub() {
  mkdir -p "$T/bin" "$T/fx" "$T/log" "$T/state"
  echo '[]' >"$T/state/pulls.json"
  # upstream workflows are still active when the pull request event fires (GitHub lists them lazily)
  cat >"$T/state/workflows.json" <<'JSON'
{"workflows":[
 {"id":1,"path":".github/workflows/cypress.yml","state":"active"},
 {"id":2,"path":".github/workflows/ionos-build.yml","state":"active"},
 {"id":3,"path":"dynamic/pages/pages-build-deployment","state":"active"},
 {"id":4,"path":".github/workflows/lint-php.yml","state":"disabled_manually"}
]}
JSON
  cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: only `gh api <endpoint> [-X M] [-f k=v] [--input -] [-H h] [--paginate]`.
set -u
[ "${1:-}" = api ] || { echo "stub gh: unsupported: $*" >&2; exit 2; }
shift
method=GET endpoint="" input=""
declare -A F
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -f|-F|--field|--raw-field) F["${2%%=*}"]="${2#*=}"; shift 2 ;;
    -H|--header) shift 2 ;;
    --paginate|--silent) shift ;;
    -*) echo "stub gh: unsupported flag $1" >&2; exit 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
path=${endpoint%%\?*}
if [[ $endpoint == *\?* ]]; then
  IFS='&' read -ra kv <<<"${endpoint#*\?}"
  for p in "${kv[@]}"; do F["${p%%=*}"]="${p#*=}"; done
fi
# The organization rule: nextcloud/* and nextcloud-releases/* reject the sync token (STUB_ORG_REJECT holds its value)
if [ -n "${STUB_ORG_REJECT:-}" ] && [ "${GH_TOKEN:-}" = "$STUB_ORG_REJECT" ] && [[ $path == repos/nextcloud/* || $path == repos/nextcloud-releases/* ]]; then
  echo '{"message":"The nextcloud organization forbids access via a fine-grained personal access tokens if the token'"'"'s lifetime is greater than 366 days."}'
  echo "gh: The 'nextcloud' organization forbids access via a fine-grained personal access tokens if the token's lifetime is greater than 366 days. (HTTP 403)" >&2
  exit 1
fi
# STUB_HTTP=<part of an endpoint>=<code>: any call whose path contains the part fails with that code
if [ -n "${STUB_HTTP:-}" ] && [[ $path == *"${STUB_HTTP%%=*}"* ]]; then
  echo '{"message":"stub failure"}'; echo "gh: stub failure (HTTP ${STUB_HTTP#*=})" >&2; exit 1
fi
n=$(( $(find "$STUB_DIR/log" -name 'call.*' | wc -l) + 1 ))
echo "$method $endpoint" >"$STUB_DIR/log/call.$n"   # debugging aid only; tests assert on state
body=""
if [ -n "$input" ]; then body=$(cat); fi
fxkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
fxput() { printf '%s' "$2" >"$STUB_DIR/fx/$(fxkey "$1")"; }
sha1() { sha1sum | cut -c1-40; }
notfound() { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
S="$STUB_DIR/state"
R="$STUB_REPO"
key=$path
[ -n "${F[sha]:-}" ] && key+="?sha=${F[sha]}"
[ -n "${F[ref]:-}" ] && key+="?ref=${F[ref]}"
if [ "$method" = GET ]; then
  if [ "$path" = "repos/$R/actions/workflows" ]; then cat "$S/workflows.json"; exit 0; fi
  if [ "$path" = "repos/$R/pulls" ]; then
    jq -c --arg h "${F[head]:-}" --arg b "${F[base]:-}" --arg s "${F[state]:-open}" \
      '[.[] | select(.state == $s and .head_label == $h and .base == $b) | {number}]' "$S/pulls.json"
    exit 0
  fi
  f="$STUB_DIR/fx/$(fxkey "$key")"
  if [ -n "${STUB_RACE:-}" ] && [[ $path == repos/$R/git/ref/heads/* ]] && [ -f "$f" ]; then
    # somebody pushes to the branch between the helper's two reads of it
    echo x >>"$STUB_DIR/state/reads.$(fxkey "$path")"
    if [ "$(wc -l <"$STUB_DIR/state/reads.$(fxkey "$path")")" -ge 2 ]; then echo '{"object":{"sha":"beef0000"}}'; exit 0; fi
  fi
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  notfound
fi
S="$STUB_DIR/state"
sha=$(printf '%s' "$body" | sha1)
case "$method $path" in
  "PUT repos/$R/actions/workflows/"*/disable)
    id=${path#repos/$R/actions/workflows/}; id=${id%/disable}
    code=$(jq -r --argjson id "$id" '[.workflows[]|select(.id==$id).deny]|first // empty' "$S/workflows.json")
    if [ -n "$code" ]; then echo "{\"message\":\"denied\"}"; echo "gh: denied (HTTP $code)" >&2; exit 1; fi
    jq --argjson id "$id" '(.workflows[]|select(.id==$id)).state = "disabled_manually"' "$S/workflows.json" >"$S/w.tmp" && mv "$S/w.tmp" "$S/workflows.json" ;;
  "POST repos/$R/git/blobs") mkdir -p "$S/blobs"; printf '%s' "$body" >"$S/blobs/$sha"; echo "{\"sha\":\"$sha\"}" ;;
  "POST repos/$R/git/trees")
    # the real API resolves base_tree plus entries into a full tree: do the same for the two
    # levels the script touches (root and apps-upstream/)
    base=$(jq -r .base_tree <<<"$body")
    root=$(cat "$STUB_DIR/fx/$(fxkey "repos/$R/git/trees/$base")")
    au_sha=$(jq -r '.tree[] | select(.path == "apps-upstream") | .sha' <<<"$root")
    au='{"tree":[]}'
    [ -f "$STUB_DIR/fx/$(fxkey "repos/$R/git/trees/$au_sha")" ] && au=$(cat "$STUB_DIR/fx/$(fxkey "repos/$R/git/trees/$au_sha")")
    new_au=$(jq -c --argjson d "$body" '
      ($d.tree | map(select(.path | startswith("apps-upstream/"))) | map(.path |= ltrimstr("apps-upstream/"))) as $ch
      | {tree: ([.tree[] | select(.path as $p | $ch | map(.path) | index($p) | not)]
                + [$ch[] | select(.sha != null)] | sort_by(.path))}' <<<"$au")
    au_new=$(printf '%s' "$new_au" | sha1)
    fxput "repos/$R/git/trees/$au_new" "$new_au"
    new_root=$(jq -c --argjson d "$body" --arg au "$au_new" '
      ($d.tree | map(select(.path | startswith("apps-upstream/") | not))) as $other
      | {tree: ([.tree[] | select(.path != "apps-upstream" and (.path as $p | $other | map(.path) | index($p) | not))]
                + [{path: "apps-upstream", mode: "040000", type: "tree", sha: $au}] + $other)}' <<<"$root")
    root_new=$(printf '%s' "$new_root" | sha1)
    fxput "repos/$R/git/trees/$root_new" "$new_root"
    mkdir -p "$S/trees"; printf '%s' "$body" >"$S/trees/$root_new"
    echo "{\"sha\":\"$root_new\"}" ;;
  "POST repos/$R/git/commits")
    mkdir -p "$S/commits"; printf '%s' "$body" >"$S/commits/$sha"
    fxput "repos/$R/git/commits/$sha" "{\"tree\":{\"sha\":\"$(jq -r .tree <<<"$body")\"}}"
    echo "{\"sha\":\"$sha\"}" ;;
  "POST repos/$R/git/refs")
    ref=$(jq -r .ref <<<"$body"); csha=$(jq -r .sha <<<"$body")
    echo "$ref $csha" >>"$S/refs"
    fxput "repos/$R/git/ref/${ref#refs/}" "{\"object\":{\"sha\":\"$csha\"}}"
    echo '{"ref":"ok"}' ;;
  "PATCH repos/$R/git/refs/heads/"*)
    b=${path#repos/$R/git/refs/}
    [ "$(jq -r '.force // false' <<<"$body")" = true ] || { echo '{"message":"Update is not a fast forward"}'; echo "gh: Update is not a fast forward (HTTP 422)" >&2; exit 1; }
    csha=$(jq -r .sha <<<"$body")
    echo "refs/$b $csha" >>"$S/refs"
    fxput "repos/$R/git/ref/$b" "{\"object\":{\"sha\":\"$csha\"}}"
    echo '{"ref":"ok"}' ;;
  "POST repos/$R/pulls")
    jq -c . <<<"$body" >>"$S/pulls.jsonl"
    jq -c --argjson d "$body" '. + [{number: 7, state: "open", head_label: ("ionos:" + $d.head), base: $d.base}]' "$S/pulls.json" >"$S/p.tmp" && mv "$S/p.tmp" "$S/pulls.json"
    echo '{"number":7,"html_url":"https://example.invalid/pull/7"}' ;;
  *) echo "stub gh: unexpected $method $path" >&2; exit 2 ;;
esac
STUB
  chmod +x "$T/bin/gh"
}

fx() { # fx <endpoint> <content>   (content from stdin if "-")
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  if [ "$2" = - ]; then cat >"$T/fx/$key"; else printf '%s' "$2" >"$T/fx/$key"; fi
}

# Default scenario: line 33. Upstream tags: v33.0.11 (final, NOT in the dev branch: newer than the
# server code), v33.0.10 (final, annotated, an ancestor of the dev branch: the base), v33.0.9 (final,
# also an ancestor), v33.0.12rc1 and v33.1.0beta1 (not final). Config lists a_one, b_two (upstream
# org), c_tree (in the fork's apps/), d_priv (private repo outside nextcloud/). Current pins on the
# dev branch: a_one old, b_two current. There are no app tags for v33.0.11 at all.
scenario() {
  T=$(mktemp -d -p "$WORK")
  make_stub
  fx 'repos/nextcloud/server/git/matching-refs/tags/v33.' \
    "[{\"ref\":\"refs/tags/v33.0.9\",\"object\":{\"type\":\"commit\",\"sha\":\"$C9\"}},{\"ref\":\"refs/tags/v33.0.10\",\"object\":{\"type\":\"tag\",\"sha\":\"$T10\"}},{\"ref\":\"refs/tags/v33.0.11\",\"object\":{\"type\":\"commit\",\"sha\":\"$C11\"}},{\"ref\":\"refs/tags/v33.0.12rc1\",\"object\":{\"type\":\"commit\",\"sha\":\"$C11\"}},{\"ref\":\"refs/tags/v33.1.0beta1\",\"object\":{\"type\":\"commit\",\"sha\":\"$C11\"}}]"
  fx "repos/nextcloud/server/git/tags/$T10" "{\"object\":{\"type\":\"commit\",\"sha\":\"$C10\"}}"
  fx "repos/ionos/nc/compare/$C11...$BASE_SHA" '{"status":"behind"}'
  fx "repos/ionos/nc/compare/$C10...$BASE_SHA" '{"status":"ahead"}'
  fx "repos/ionos/nc/compare/$C9...$BASE_SHA" '{"status":"ahead"}'
  fx 'repos/nextcloud-releases/server/contents/stable33.json' \
    '[{"id":"a_one","repo":"nextcloud/a_one"},{"id":"b_two","repo":"nextcloud/b_two"},{"id":"c_tree","repo":"nextcloud/c_tree"},{"id":"d_priv","repo":"nextcloud-gmbh/d_priv"}]'
  fx 'repos/ionos/nc/commits?sha=ionos-dev-v33' "[{\"sha\":\"$BASE_SHA\",\"commit\":{\"tree\":{\"sha\":\"$ROOT_TREE\"}}}]"
  fx "repos/ionos/nc/git/commits/$BASE_SHA" "{\"tree\":{\"sha\":\"$ROOT_TREE\"}}"
  fx "repos/ionos/nc/git/trees/$ROOT_TREE" \
    "{\"tree\":[{\"path\":\"apps\",\"mode\":\"040000\",\"type\":\"tree\",\"sha\":\"$APPS_TREE\"},{\"path\":\"apps-upstream\",\"mode\":\"040000\",\"type\":\"tree\",\"sha\":\"$AU_TREE\"},{\"path\":\".gitmodules\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"9\"}]}"
  fx "repos/ionos/nc/git/trees/$APPS_TREE" \
    '{"tree":[{"path":"c_tree","mode":"040000","type":"tree","sha":"5"},{"path":"files","mode":"040000","type":"tree","sha":"6"}]}'
  fx "repos/ionos/nc/git/trees/$AU_TREE" \
    "{\"tree\":[{\"path\":\"a_one\",\"mode\":\"160000\",\"type\":\"commit\",\"sha\":\"$OLD1\"},{\"path\":\"b_two\",\"mode\":\"160000\",\"type\":\"commit\",\"sha\":\"$SAME\"}]}"
  fx "repos/ionos/nc/contents/.gitmodules?ref=$BASE_SHA" - <<'G'
# header
[submodule "3rdparty"]
	path = 3rdparty
	url = https://github.com/nextcloud/3rdparty.git
[submodule "apps-upstream/a_one"]
	path = apps-upstream/a_one
	url = https://github.com/nextcloud/a_one.git
[submodule "apps-upstream/b_two"]
	path = apps-upstream/b_two
	url = https://github.com/nextcloud/b_two.git
[submodule "IONOS"]
	path = IONOS
	url = https://github.com/printminion-co/ncw-flavors.git
	branch = v33
G
  tag_ref v33.0.10 a_one "$NEW1"
  tag_ref v33.0.10 b_two "$SAME"
}

tag_ref() { # tag_ref <tag> <app> <sha>
  fx "repos/nextcloud/$2/git/ref/tags/$1" "{\"object\":{\"type\":\"commit\",\"sha\":\"$3\"}}"
}

# The dev branch's server code is now based on v33.0.11 (a candidate was promoted)
promote_base_to_0_11() {
  fx "repos/ionos/nc/compare/$C11...$BASE_SHA" '{"status":"identical"}'
  tag_ref v33.0.11 a_one "$NEWER"
  tag_ref v33.0.11 b_two "$SAME"
}

# seed_branch <name> <commit sha> <app=sha>...: an existing branch holding these pins
seed_branch() {
  local name=$1 csha=$2 entries="" a tree
  shift 2
  for a in "$@"; do entries+="{\"path\":\"${a%%=*}\",\"mode\":\"160000\",\"type\":\"commit\",\"sha\":\"${a#*=}\"},"; done
  fx "repos/ionos/nc/git/trees/${csha}au" "{\"tree\":[${entries%,}]}"
  tree="${csha}root"
  fx "repos/ionos/nc/git/trees/$tree" \
    "{\"tree\":[{\"path\":\"apps\",\"mode\":\"040000\",\"type\":\"tree\",\"sha\":\"$APPS_TREE\"},{\"path\":\"apps-upstream\",\"mode\":\"040000\",\"type\":\"tree\",\"sha\":\"${csha}au\"}]}"
  fx "repos/ionos/nc/git/commits/$csha" "{\"tree\":{\"sha\":\"$tree\"}}"
  fx "repos/ionos/nc/git/ref/heads/$name" "{\"object\":{\"sha\":\"$csha\"}}"
}

seed_open_pull() { # seed_open_pull <branch> <number>
  jq -c --arg h "ionos:$1" --argjson n "$2" '. + [{number: $n, state: "open", head_label: $h, base: "ionos-dev-v33"}]' \
    "$T/state/pulls.json" >"$T/state/p.tmp" && mv "$T/state/p.tmp" "$T/state/pulls.json"
}

run_script() { # extra env as args; sets OUT and RC
  OUT=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" STUB_REPO=ionos/nc GH_TOKEN=x GITHUB_REPOSITORY=ionos/nc "$@" \
    bash "$SCRIPT" 2>&1)
  RC=$?
}

# State the stub holds after a run
written() { { find "$T/state" -type f ! -name refs ! -name pulls.jsonl ! -name pulls.json ! -name p.tmp ! -name 'reads.*' ! -name workflows.json ! -name w.tmp; cat "$T/state/refs" "$T/state/pulls.jsonl" 2>/dev/null; } | wc -l; }
branch_sha() { awk -v r="refs/heads/$1" '$1 == r { s = $2 } END { print s }' "$T/state/refs" 2>/dev/null; }
branch_commit() { cat "$T/state/commits/$(branch_sha "$1")" 2>/dev/null; }
branch_tree() { cat "$T/state/trees/$(branch_commit "$1" | jq -r .tree)" 2>/dev/null; }
pulls() { cat "$T/state/pulls.jsonl" 2>/dev/null; }
blob() { cat "$T/state/blobs/$1" 2>/dev/null; }
exists() { [ -n "$(branch_sha "$1")" ] && echo yes || echo no; }

ok() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; [ -z "${2:-}" ] || echo "       $2"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi
}
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in output: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$3] found in output: $2" ;; *) ok "$1" ;; esac; }
assert_fails() { assert_eq "$1" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes; }

# --- tests -----------------------------------------------------------------
test_pins_differ_opens_one_pull_request() {
  echo "pins differ: one branch, one commit, one pull request, only pin paths"
  scenario
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "branch app-pins/v33.0.10 exists" "$(exists app-pins/v33.0.10)" yes
  assert_eq "exactly one branch was created" "$(wc -l <"$T/state/refs")" 1
  assert_eq "exactly one pull request" "$(pulls | wc -l)" 1
  assert_eq "commit tree entries" "$(branch_tree app-pins/v33.0.10 | jq -c '[.tree[]|[.path,.mode,.sha]]')" \
    "[[\"apps-upstream/a_one\",\"160000\",\"$NEW1\"]]"
  assert_eq "tree is based on the base commit's tree" "$(branch_tree app-pins/v33.0.10 | jq -r .base_tree)" "$ROOT_TREE"
  assert_eq "commit parent is the base branch head" "$(branch_commit app-pins/v33.0.10 | jq -c .parents)" "[\"$BASE_SHA\"]"
  assert_eq "commit message" "$(branch_commit app-pins/v33.0.10 | jq -r .message)" "IONOS(apps): pin upstream's bundled apps for v33.0.10"
  assert_eq "pull request head and base" "$(pulls | jq -c '[.head,.base]')" '["app-pins/v33.0.10","ionos-dev-v33"]'
}

test_base_is_the_release_of_the_dev_branch() {
  echo "base release: the newest final tag that is an ancestor of the dev branch, never a newer upstream release"
  scenario
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "pins for v33.0.10, not the newer v33.0.11" "$(exists app-pins/v33.0.10)$(exists app-pins/v33.0.11)" yesno
  assert_contains "says which release it pins" "$OUT" "v33.0.10"
}

test_base_moves_after_promotion() {
  echo "dev branch is based on a newer release: pins are proposed for that release"
  scenario
  promote_base_to_0_11
  fx 'repos/ionos/nc/git/ref/heads/ionos-dev-v33' "{\"object\":{\"sha\":\"$BASE_SHA\"}}"
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "branch for v33.0.11" "$(exists app-pins/v33.0.11)$(exists app-pins/v33.0.10)" yesno
  assert_eq "tree entries" "$(branch_tree app-pins/v33.0.11 | jq -c '[.tree[]|[.path,.sha]]')" "[[\"apps-upstream/a_one\",\"$NEWER\"]]"
}

test_no_ancestor_tag_fails() {
  echo "no release tag is an ancestor of the dev branch: fail, nothing created"
  scenario
  for c in "$C10" "$C9"; do fx "repos/ionos/nc/compare/$c...$BASE_SHA" '{"status":"diverged"}'; done
  run_script
  assert_fails "fails"
  assert_eq "nothing was created" "$(written)" 0
}

test_pins_equal_does_nothing() {
  echo "pins equal: nothing created"
  scenario
  tag_ref v33.0.10 a_one "$OLD1"
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "nothing was created" "$(written)" 0
  assert_contains "says up to date" "$OUT" "already match"
}

test_second_run_is_idempotent() {
  echo "second run after a proposal: nothing more is created"
  scenario
  run_script
  local before after
  before=$(branch_sha app-pins/v33.0.10)
  run_script
  after=$(branch_sha app-pins/v33.0.10)
  assert_eq "exit code" "$RC" 0
  assert_eq "branch unchanged" "$after" "$before"
  assert_eq "still one branch and one pull request" "$(wc -l <"$T/state/refs")$(pulls | wc -l)" 11
}

test_existing_branch_with_same_pins_does_nothing() {
  echo "existing branch with the right pins: nothing"
  scenario
  seed_branch app-pins/v33.0.10 cafe0001 a_one="$NEW1" b_two="$SAME"
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "nothing was created" "$(written)" 0
  assert_contains "mentions the branch" "$OUT" "app-pins/v33.0.10 already exists"
}

test_existing_branch_with_stale_pins_is_refreshed() {
  echo "existing branch with outdated pins and no open pull request: updated by force"
  scenario
  seed_branch app-pins/v33.0.10 cafe0002 a_one="$OLD1" b_two="$SAME"
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "branch moved to a new commit" "$([ -n "$(branch_sha app-pins/v33.0.10)" ] && [ "$(branch_sha app-pins/v33.0.10)" != cafe0002 ] && echo yes)" yes
  assert_eq "new commit holds the new pin" "$(branch_tree app-pins/v33.0.10 | jq -c '[.tree[]|[.path,.sha]]')" "[[\"apps-upstream/a_one\",\"$NEW1\"]]"
  assert_eq "new commit sits on the dev branch head" "$(branch_commit app-pins/v33.0.10 | jq -c .parents)" "[\"$BASE_SHA\"]"
  assert_eq "a pull request is opened for the refreshed branch (none was open)" "$(pulls | wc -l)" 1
}

test_branch_moved_meanwhile_is_not_overwritten() {
  echo "branch pushed to while the helper ran: not overwritten"
  scenario
  seed_branch app-pins/v33.0.10 cafe0005 a_one="$OLD1" b_two="$SAME"
  run_script STUB_RACE=1
  assert_fails "fails"
  assert_eq "branch was not moved" "$(branch_sha app-pins/v33.0.10)" ""
  assert_eq "no pull request" "$(pulls | wc -l)" 0
}

test_existing_branch_with_open_pull_request_is_left() {
  echo "existing branch with outdated pins and an open pull request: left alone"
  scenario
  seed_branch app-pins/v33.0.10 cafe0003 a_one="$OLD1" b_two="$SAME"
  seed_open_pull app-pins/v33.0.10 5
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "nothing was created or moved" "$(written)" 0
  assert_contains "mentions the pull request" "$OUT" "pull request #5"
}

test_open_pull_request_does_nothing() {
  echo "open pull request for the branch: nothing"
  scenario
  seed_open_pull app-pins/v33.0.10 5
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "nothing was created" "$(written)" 0
  assert_contains "mentions the pull request" "$OUT" "pull request #5"
}

test_dry_run_does_nothing() {
  echo "dry run: nothing is created"
  scenario
  run_script DRY_RUN=true
  assert_eq "exit code" "$RC" 0
  assert_eq "nothing was created" "$(written)" 0
  assert_contains "reports the planned change" "$OUT" "apps-upstream/a_one"
  scenario
  seed_branch app-pins/v33.0.10 cafe0004 a_one="$OLD1" b_two="$SAME"
  run_script DRY_RUN=true
  assert_eq "dry run does not refresh a stale branch either" "$(written)" 0
}

test_base_release_override() {
  echo "base_release override: uses that tag"
  scenario
  tag_ref v33.0.9 a_one "$OLD1"
  tag_ref v33.0.9 b_two "$NEW1"
  run_script BASE_RELEASE=v33.0.9
  assert_eq "exit code" "$RC" 0
  assert_eq "tree entries" "$(branch_tree app-pins/v33.0.9 | jq -c '[.tree[]|[.path,.sha]]')" \
    "[[\"apps-upstream/b_two\",\"$NEW1\"]]"
}

test_invalid_base_release_is_rejected() {
  echo "invalid base_release: rejected, nothing created"
  scenario
  tag_ref v34.0.1 a_one "$NEW1"
  tag_ref v34.0.1 b_two "$NEW1"
  run_script 'BASE_RELEASE=v34.0.1'
  assert_fails "fails"
  assert_eq "nothing was created" "$(written)" 0
}

test_missing_app_tag_fails_without_partial_change() {
  echo "listed public app without the release tag: clear message, nothing created"
  scenario
  rm "$T/fx/repos_nextcloud_b_two_git_ref_tags_v33.0.10"
  run_script
  assert_fails "fails"
  assert_contains "names the repository and the tag" "$OUT" "nextcloud/b_two"
  assert_contains "says the tag was not found" "$OUT" "v33.0.10"
  assert_not_contains "no raw gh abort" "$OUT" "HTTP 404"
  assert_eq "nothing was created" "$(written)" 0
}

test_upstream_reads_use_the_read_token() {
  echo "the org rejects the sync token for nextcloud/*: upstream reads use READ_TOKEN, fork writes keep GH_TOKEN"
  scenario
  run_script STUB_ORG_REJECT=x READ_TOKEN=default
  assert_eq "exit code" "$RC" 0
  assert_eq "one pull request" "$(pulls | wc -l)" 1
  scenario
  run_script STUB_ORG_REJECT=x
  assert_fails "without a read token the rejected token is used and the run fails"
  assert_contains "the failure shows gh's message" "$OUT" "forbids access"
  assert_not_contains "and not the misleading text" "$OUT" "does not tag every"
  assert_not_contains "nor the misleading ancestor text" "$OUT" "is an ancestor"
  assert_eq "nothing was created" "$(written)" 0
}

test_error_messages_say_what_failed() {
  echo "a genuine 404 says the tag is missing; any other failure shows gh's message"
  scenario
  rm "$T/fx/repos_nextcloud_b_two_git_ref_tags_v33.0.10"
  run_script
  assert_contains "404: tag not found in the repository" "$OUT" "tag v33.0.10 not found in nextcloud/b_two (app b_two)"
  scenario
  run_script STUB_HTTP=b_two/git/ref/tags=500
  assert_fails "500 fails"
  assert_contains "500: cannot read tag" "$OUT" "cannot read tag v33.0.10 of nextcloud/b_two"
  assert_contains "500: gh's message is shown" "$OUT" "stub failure (HTTP 500)"
  assert_not_contains "500 is not reported as a missing tag" "$OUT" "not found"
  scenario
  run_script STUB_HTTP=/compare/=500
  assert_fails "a failing compare fails"
  assert_contains "compare: clear message with gh's text" "$OUT" "cannot compare"
  assert_contains "compare: gh's message is shown" "$OUT" "stub failure (HTTP 500)"
  scenario
  run_script STUB_HTTP=matching-refs=500
  assert_fails "a failing tag listing fails"
  assert_contains "tag listing: clear message" "$OUT" "cannot list the tags of nextcloud/server"
  assert_contains "tag listing: gh's message is shown" "$OUT" "stub failure (HTTP 500)"
  scenario
  run_script STUB_HTTP=stable33.json=500
  assert_contains "app list: clear message" "$OUT" "cannot read the app list"
  assert_contains "app list: gh's message is shown" "$OUT" "stub failure (HTTP 500)"
}

wf_state() { jq -r --argjson id "$1" '.workflows[]|select(.id==$id).state' "$T/state/workflows.json"; }
# the number of the first stub call that matches a pattern (calls are numbered in order)
first_call() { grep -l -e "$1" "$T"/log/call.* 2>/dev/null | sed 's/.*call\.//' | sort -n | head -1; }

test_upstream_workflows_are_disabled_before_the_pull_request() {
  echo "upstream workflows are disabled before anything is created, on every real run"
  scenario
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "an active upstream workflow is disabled" "$(wf_state 1)" disabled_manually
  assert_eq "an ionos- workflow stays active" "$(wf_state 2)" active
  assert_eq "a dynamic workflow is left alone" "$(wf_state 3)" active
  assert_eq "an already disabled workflow stays so" "$(wf_state 4)" disabled_manually
  assert_eq "the disabling came before the branch was created" \
    "$([ "$(first_call 'PUT repos/ionos/nc/actions/workflows/1/disable')" -lt "$(first_call 'POST repos/ionos/nc/git/refs')" ] && echo yes)" yes
  assert_eq "and before the pull request was opened" \
    "$([ "$(first_call 'PUT repos/ionos/nc/actions/workflows/1/disable')" -lt "$(first_call 'POST repos/ionos/nc/pulls')" ] && echo yes)" yes
  scenario
  seed_branch app-pins/v33.0.10 cafe0009 a_one="$OLD1" b_two="$SAME"
  run_script
  assert_eq "a stale branch is refreshed only after the disabling" \
    "$([ "$(first_call 'PUT repos/ionos/nc/actions/workflows/1/disable')" -lt "$(first_call 'PATCH repos/ionos/nc/git/refs')" ] && echo yes)" yes
  scenario
  tag_ref v33.0.10 a_one "$OLD1"
  run_script
  assert_contains "nothing to do" "$OUT" "already match"
  assert_eq "even a run with nothing to do disables them (cheap and idempotent)" "$(wf_state 1)" disabled_manually
  scenario
  run_script
  run_script
  assert_eq "a second run is a no-op for workflows" "$(grep -c 'PUT repos/ionos/nc/actions/workflows' "$T"/log/call.* | awk -F: '{n+=$2} END {print n}')" 1
}

test_workflow_disabling_dry_run_and_failures() {
  echo "dry run changes nothing; a 4xx warns and continues; another failure stops before anything is created"
  scenario
  run_script DRY_RUN=true
  assert_eq "dry run leaves the workflow active" "$(wf_state 1)" active
  assert_contains "dry run says what it would do" "$OUT" "would: disable workflow .github/workflows/cypress.yml"
  scenario
  jq '(.workflows[]|select(.id==1)).deny = 403 | .workflows += [{"id":5,"path":".github/workflows/block-merge.yml","state":"active"}]' "$T/state/workflows.json" >"$T/state/w.tmp" && mv "$T/state/w.tmp" "$T/state/workflows.json"
  run_script
  assert_eq "a 4xx on one workflow does not fail the run" "$RC" 0
  assert_contains "the 4xx is a warning" "$OUT" "::warning::"
  assert_eq "the other workflow is still disabled" "$(wf_state 5)" disabled_manually
  assert_eq "the pull request is still opened" "$(pulls | wc -l)" 1
  scenario
  jq '(.workflows[]|select(.id==1)).deny = 500' "$T/state/workflows.json" >"$T/state/w.tmp" && mv "$T/state/w.tmp" "$T/state/workflows.json"
  run_script
  assert_fails "a failure other than 4xx fails the run"
  assert_eq "and nothing was created" "$(written)" 0
}

test_app_set_change_updates_gitmodules() {
  echo "app set changed: .gitmodules is part of the commit, removed app dropped"
  scenario
  fx 'repos/nextcloud-releases/server/contents/stable33.json' \
    '[{"id":"a_one","repo":"nextcloud/a_one"},{"id":"e_new","repo":"nextcloud/e_new"},{"id":"c_tree","repo":"nextcloud/c_tree"}]'
  tag_ref v33.0.10 e_new "$NEW_E"
  tag_ref v33.0.10 a_one "$OLD1"
  run_script
  assert_eq "exit code" "$RC" 0
  local gmsha gm
  gmsha=$(branch_tree app-pins/v33.0.10 | jq -r '.tree[]|select(.path==".gitmodules").sha')
  assert_eq "tree entries" "$(branch_tree app-pins/v33.0.10 | jq -c '[.tree[]|[.path,.mode,(if .path==".gitmodules" then "blob" else .sha end)]]|sort')" \
    "[[\".gitmodules\",\"100644\",\"blob\"],[\"apps-upstream/b_two\",\"160000\",null],[\"apps-upstream/e_new\",\"160000\",\"$NEW_E\"]]"
  gm=$(blob "$gmsha" | jq -r .content)
  assert_contains ".gitmodules gets the new app" "$gm" '[submodule "apps-upstream/e_new"]'
  assert_contains ".gitmodules keeps the new app url" "$gm" 'url = https://github.com/nextcloud/e_new.git'
  assert_contains ".gitmodules keeps the 3rdparty entry" "$gm" '[submodule "3rdparty"]'
  assert_contains ".gitmodules keeps the IONOS entry" "$gm" 'branch = v33'
  assert_not_contains ".gitmodules drops the removed app" "$gm" b_two
}

test_untrusted_upstream_data_is_validated() {
  echo "untrusted values from upstream's app list: validated before any use"
  local bad_id
  for bad_id in 'x"; system("id")' 'Upper' '../etc' 'a b' 'a.b'; do
    scenario
    fx 'repos/nextcloud-releases/server/contents/stable33.json' \
      "$(jq -nc --arg i "$bad_id" '[{id: $i, repo: "nextcloud/a_one"}]')"
    run_script
    assert_fails "app id [$bad_id] is rejected"
    assert_eq "nothing was created for [$bad_id]" "$(written)" 0
  done
  local bad_repo
  for bad_repo in 'nextcloud/../../x' 'nextcloud/a one' 'nextcloud/a_one?x=1' 'nextcloud/a/b' 'nextcloud/..' 'nextcloud/a_one%2f'; do
    scenario
    fx 'repos/nextcloud-releases/server/contents/stable33.json' \
      "$(jq -nc --arg r "$bad_repo" '[{id: "a_one", repo: $r}]')"
    run_script
    assert_fails "repository [$bad_repo] is rejected"
    assert_eq "nothing was created for [$bad_repo]" "$(written)" 0
  done
  scenario
  fx 'repos/nextcloud-releases/server/contents/stable33.json' '[{"id":"a_one","repo":"nextcloud-gmbh/support"}]'
  run_script
  assert_eq "a repository outside nextcloud/ is still just skipped, not an error" "$RC" 0
}

test_dev_branch_name_is_validated() {
  echo "dev branch name is validated, not concatenated into requests"
  scenario
  run_script 'BASE_BRANCH=ionos-dev-v33&x=1'
  assert_fails "a branch name with URL syntax is rejected"
  assert_eq "nothing was created" "$(written)" 0
}

test_dev_branch_follows_the_line() {
  echo "dev branch derives from LINE"
  scenario
  run_script LINE=34
  assert_fails "line 34 has no dev branch in the fixture, so it fails instead of using ionos-dev-v33"
  assert_eq "nothing was created" "$(written)" 0
}

test_token_warning() {
  echo "without IONOS_SYNC_TOKEN the log says why the pull request will not trigger checks"
  scenario
  run_script HAS_SYNC_TOKEN=false
  assert_contains "mentions the secret" "$OUT" "IONOS_SYNC_TOKEN"
  assert_eq "still opens the pull request" "$(pulls | wc -l)" 1
  scenario
  run_script HAS_SYNC_TOKEN=true
  assert_not_contains "no warning with the secret" "$OUT" "IONOS_SYNC_TOKEN"
}

for t in test_upstream_workflows_are_disabled_before_the_pull_request test_workflow_disabling_dry_run_and_failures test_upstream_reads_use_the_read_token test_error_messages_say_what_failed test_pins_differ_opens_one_pull_request test_base_is_the_release_of_the_dev_branch \
  test_base_moves_after_promotion test_no_ancestor_tag_fails test_pins_equal_does_nothing \
  test_second_run_is_idempotent test_existing_branch_with_same_pins_does_nothing \
  test_existing_branch_with_stale_pins_is_refreshed test_branch_moved_meanwhile_is_not_overwritten test_existing_branch_with_open_pull_request_is_left \
  test_open_pull_request_does_nothing test_dry_run_does_nothing test_base_release_override \
  test_invalid_base_release_is_rejected test_missing_app_tag_fails_without_partial_change \
  test_app_set_change_updates_gitmodules test_untrusted_upstream_data_is_validated \
  test_dev_branch_name_is_validated test_dev_branch_follows_the_line test_token_warning; do
  "$t"
done

echo
echo "passed: $PASSES, failed: $FAILS"
[ "$FAILS" -eq 0 ]
