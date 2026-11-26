#!/usr/bin/env bash
# Tests for ionos-app-pins.sh. The seam is the script run as a process against a stub `gh`
# that answers from canned JSON and records every call. Nothing here talks to GitHub.
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
BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ROOT_TREE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
APPS_TREE=cccccccccccccccccccccccccccccccccccccccc
AU_TREE=dddddddddddddddddddddddddddddddddddddddd

# --- stub gh ---------------------------------------------------------------
make_stub() {
  mkdir -p "$T/bin" "$T/fx" "$T/log"
  cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: only `gh api <endpoint> [--method M] [--input -] [-H h]`.
set -u
[ "${1:-}" = api ] || { echo "stub gh: unsupported: $*" >&2; exit 2; }
shift
method=GET endpoint="" input=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -H|--header) shift 2 ;;
    -*) echo "stub gh: unsupported flag $1" >&2; exit 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
n=$(( $(find "$STUB_DIR/log" -name 'call.*' | wc -l) + 1 ))
echo "$method $endpoint" >"$STUB_DIR/log/call.$n"
if [ -n "$input" ]; then cat >"$STUB_DIR/log/body.$n"; fi
key=$(printf '%s' "$endpoint" | tr -c 'A-Za-z0-9._-' '_')
if [ "$method" = GET ]; then
  if [ -f "$STUB_DIR/fx/$key" ]; then cat "$STUB_DIR/fx/$key"; exit 0; fi
  echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
case "$endpoint" in
  */git/blobs) echo '{"sha":"b10b"}' ;;
  */git/trees) echo '{"sha":"7ee"}' ;;
  */git/commits) echo '{"sha":"c0mm17"}' ;;
  */git/refs) echo '{"ref":"ok"}' ;;
  */pulls) echo '{"number":7,"html_url":"https://example.invalid/pull/7"}' ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$T/bin/gh"
}

fx() { # fx <endpoint> <content>   (content from stdin if "-")
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  if [ "$2" = - ]; then cat >"$T/fx/$key"; else printf '%s' "$2" >"$T/fx/$key"; fi
}

# Default scenario: line 33, newest final v33.0.10 (a v33.0.11rc1 prerelease and a draft are
# ignored). Config lists a_one, b_two (in upstream org), c_tree (in the fork's apps/), d_priv
# (private repo outside nextcloud/). Current pins: a_one old, b_two current.
scenario() {
  T=$(mktemp -d -p "$WORK")
  make_stub
  fx 'repos/nextcloud-releases/server/releases?per_page=100' \
    '[{"tag_name":"v33.0.11rc1","prerelease":true,"draft":false},{"tag_name":"v33.1.0","prerelease":false,"draft":true},{"tag_name":"v34.0.1","prerelease":false,"draft":false},{"tag_name":"v33.0.10","prerelease":false,"draft":false},{"tag_name":"v33.0.9","prerelease":false,"draft":false}]'
  fx 'repos/nextcloud-releases/server/contents/stable33.json' \
    '[{"id":"a_one","repo":"nextcloud/a_one"},{"id":"b_two","repo":"nextcloud/b_two"},{"id":"c_tree","repo":"nextcloud/c_tree"},{"id":"d_priv","repo":"nextcloud-gmbh/d_priv"}]'
  fx 'repos/ionos/nc/git/ref/heads/ionos-dev-v33' "{\"object\":{\"sha\":\"$BASE_SHA\"}}"
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
  fx 'repos/ionos/nc/pulls?state=open&head=ionos:app-pins/v33.0.10&base=ionos-dev-v33' '[]'
  tag_ref v33.0.10 a_one "$NEW1"
  tag_ref v33.0.10 b_two "$SAME"
}

tag_ref() { # tag_ref <tag> <app> <sha>
  fx "repos/nextcloud/$2/git/ref/tags/$1" "{\"object\":{\"type\":\"commit\",\"sha\":\"$3\"}}"
}

run_script() { # extra env as args; sets OUT and RC
  OUT=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" GH_TOKEN=x GITHUB_REPOSITORY=ionos/nc "$@" \
    bash "$SCRIPT" 2>&1)
  RC=$?
}

calls() { cat "$T"/log/call.* 2>/dev/null | sort; }
posts() { calls | grep -c '^POST ' || true; }
body_of() { # body_of <suffix>: body of the (single) POST whose endpoint ends with suffix
  local f
  f=$(grep -l "^POST .*$1\$" "$T"/log/call.* | head -1)
  cat "${f/call./body.}"
}

ok() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; [ -z "${2:-}" ] || echo "       $2"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi
}
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in output: $2" ;; esac; }

# --- tests -----------------------------------------------------------------
test_pins_differ_opens_one_pull_request() {
  echo "pins differ: one branch, one commit, one pull request, only pin paths"
  scenario
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "creates exactly one tree" "$(calls | grep -c '^POST .*/git/trees$')" 1
  assert_eq "creates exactly one commit" "$(calls | grep -c '^POST .*/git/commits$')" 1
  assert_eq "creates exactly one ref" "$(calls | grep -c '^POST .*/git/refs$')" 1
  assert_eq "creates exactly one pull request" "$(calls | grep -c '^POST .*/pulls$')" 1
  assert_eq "no other write call" "$(posts)" 4
  assert_eq "tree entries" "$(body_of /git/trees | jq -c '[.tree[]|[.path,.mode,.sha]]')" \
    "[[\"apps-upstream/a_one\",\"160000\",\"$NEW1\"]]"
  assert_eq "tree is based on the base commit's tree" "$(body_of /git/trees | jq -r .base_tree)" "$ROOT_TREE"
  assert_eq "commit parent is the base branch head" "$(body_of /git/commits | jq -c .parents)" "[\"$BASE_SHA\"]"
  assert_eq "commit message" "$(body_of /git/commits | jq -r .message)" "IONOS(apps): pin upstream's bundled apps for v33.0.10"
  assert_eq "branch name" "$(body_of /git/refs | jq -r .ref)" "refs/heads/app-pins/v33.0.10"
  assert_eq "pull request head and base" "$(body_of /pulls | jq -c '[.head,.base]')" '["app-pins/v33.0.10","ionos-dev-v33"]'
}

test_pins_equal_does_nothing() {
  echo "pins equal: no creation call"
  scenario
  tag_ref v33.0.10 a_one "$OLD1"
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "no write call" "$(posts)" 0
  assert_contains "says up to date" "$OUT" "already match"
}

test_existing_branch_does_nothing() {
  echo "existing branch: nothing"
  scenario
  fx 'repos/ionos/nc/git/ref/heads/app-pins/v33.0.10' '{"object":{"sha":"e"}}'
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "no write call" "$(posts)" 0
  assert_contains "mentions the branch" "$OUT" "app-pins/v33.0.10 already exists"
}

test_open_pull_request_does_nothing() {
  echo "open pull request for the branch: nothing"
  scenario
  fx 'repos/ionos/nc/pulls?state=open&head=ionos:app-pins/v33.0.10&base=ionos-dev-v33' '[{"number":5}]'
  run_script
  assert_eq "exit code" "$RC" 0
  assert_eq "no write call" "$(posts)" 0
  assert_contains "mentions the pull request" "$OUT" "pull request #5"
}

test_dry_run_does_nothing() {
  echo "dry run: nothing is created"
  scenario
  run_script DRY_RUN=true
  assert_eq "exit code" "$RC" 0
  assert_eq "no write call" "$(posts)" 0
  assert_contains "reports the planned change" "$OUT" "apps-upstream/a_one"
}

test_base_release_override() {
  echo "base_release override: uses that tag"
  scenario
  tag_ref v33.0.9 a_one "$OLD1"
  tag_ref v33.0.9 b_two "$NEW1"
  fx 'repos/ionos/nc/pulls?state=open&head=ionos:app-pins/v33.0.9&base=ionos-dev-v33' '[]'
  run_script BASE_RELEASE=v33.0.9
  assert_eq "exit code" "$RC" 0
  assert_eq "tree entries" "$(body_of /git/trees | jq -c '[.tree[]|[.path,.sha]]')" \
    "[[\"apps-upstream/b_two\",\"$NEW1\"]]"
  assert_eq "branch name" "$(body_of /git/refs | jq -r .ref)" "refs/heads/app-pins/v33.0.9"
}

test_invalid_base_release_is_rejected() {
  echo "invalid base_release: rejected, nothing created"
  scenario
  tag_ref v34.0.1 a_one "$NEW1"
  tag_ref v34.0.1 b_two "$NEW1"
  fx 'repos/ionos/nc/pulls?state=open&head=ionos:app-pins/v34.0.1&base=ionos-dev-v33' '[]'
  run_script 'BASE_RELEASE=v34.0.1'
  assert_eq "fails" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes
  assert_eq "no write call" "$(posts)" 0
}

test_missing_app_tag_fails_without_partial_change() {
  echo "listed public app without the release tag: fail, nothing created"
  scenario
  rm "$T/fx/repos_nextcloud_b_two_git_ref_tags_v33.0.10"
  run_script
  assert_eq "fails" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes
  assert_eq "no write call" "$(posts)" 0
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
  assert_eq "tree entries" "$(body_of /git/trees | jq -c '[.tree[]|[.path,.mode,.sha]]|sort')" \
    "[[\".gitmodules\",\"100644\",\"b10b\"],[\"apps-upstream/b_two\",\"160000\",null],[\"apps-upstream/e_new\",\"160000\",\"$NEW_E\"]]"
  local gm
  gm=$(body_of /git/blobs | jq -r .content)
  assert_contains ".gitmodules gets the new app" "$gm" '[submodule "apps-upstream/e_new"]'
  assert_contains ".gitmodules keeps the new app url" "$gm" 'url = https://github.com/nextcloud/e_new.git'
  assert_contains ".gitmodules keeps the 3rdparty entry" "$gm" '[submodule "3rdparty"]'
  assert_contains ".gitmodules keeps the IONOS entry" "$gm" 'branch = v33'
  case "$gm" in *b_two*) bad ".gitmodules drops the removed app" ;; *) ok ".gitmodules drops the removed app" ;; esac
}

for t in test_pins_differ_opens_one_pull_request test_pins_equal_does_nothing \
  test_existing_branch_does_nothing test_open_pull_request_does_nothing \
  test_dry_run_does_nothing test_base_release_override \
  test_invalid_base_release_is_rejected test_missing_app_tag_fails_without_partial_change \
  test_app_set_change_updates_gitmodules; do
  "$t"
done

echo
echo "passed: $PASSES, failed: $FAILS"
[ "$FAILS" -eq 0 ]
