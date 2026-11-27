#!/usr/bin/env bash
# Track upstream: keep the fork's mirrors current, propose a rebased candidate branch on a
# new upstream release, and switch off upstream's workflows. Run by ionos-sync.yml; every
# input comes from the environment so it can be run against local repositories.
#
#   GITHUB_REPOSITORY  owner/name of the fork                          (required)
#   GH_TOKEN           token for gh and for pushing                    (required unless FORK_URL is set)
#   UPSTREAM_URL       default https://github.com/nextcloud/server.git
#   FORK_URL           default https://github.com/$GITHUB_REPOSITORY.git
#   LINE               release line, default 33
#   DEV_BRANCH         default ionos-dev-v$LINE
#   MIRRORS            branches fast-forwarded from upstream, default "master stable$LINE"
#   UPSTREAM_TAG       optional: use this tag instead of the newest final tag of the line
#   DRY_RUN            "true": print what would be done, change nothing
#   HAS_SYNC_TOKEN     "true" when GH_TOKEN is the repository secret IONOS_SYNC_TOKEN (a token with the
#                      workflow scope); anything else means the default GITHUB_TOKEN, which cannot push
#                      workflow files (see ionos-sync.md)
# shellcheck disable=SC2317  # steps run through run_step "$@", which shellcheck cannot follow
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_PREFIX=ionos-sync
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
LINE="${LINE:-33}"
DEV_BRANCH="${DEV_BRANCH:-$(dev_branch_for_line "$LINE")}"
MIRRORS="${MIRRORS:-master stable${LINE}}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/nextcloud/server.git}"
FORK_URL="${FORK_URL:-https://github.com/${REPO}.git}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
DRY_RUN="${DRY_RUN:-false}"
HAS_SYNC_TOKEN="${HAS_SYNC_TOKEN:-false}"
CANDIDATE_PREFIX="candidate/${DEV_BRANCH}"
TAG_RE="$(final_tag_re "$LINE")"

FAILED=0
is_dry_run() { [ "$DRY_RUN" = true ]; }
would()      { log "[dry run] would: $*"; }

# Each step runs isolated in a subshell: a failure is reported and the other steps still run.
run_step() {
  local name="$1" rc
  shift
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then echo "::error::ionos-sync: step '${name}' failed (exit ${rc})"; FAILED=1; fi
}

# The credential git sends for pushes, in the form the extraheader carries it.
token_header_b64() { printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0; }

# Must run before the value is used anywhere: the log would otherwise show it in clear.
mask_token_header() {
  [ -n "${GH_TOKEN:-}" ] && echo "::add-mask::$(token_header_b64)"
  return 0
}

warn_without_sync_token() {
  [ "$HAS_SYNC_TOKEN" = true ] && return 0
  warn "IONOS_SYNC_TOKEN is not set, using the default GITHUB_TOKEN. GitHub refuses a push that creates or updates files under .github/workflows with that token, and our patch series contains workflow files: pushing a candidate branch will be refused. Store a token with the workflow scope as the repository secret IONOS_SYNC_TOKEN (see ionos-sync.md)."
}

# A code fence longer than any run of backticks in the paths, so that no path can close it.
fence_for() {
  local longest n
  longest="$(grep -o '`*' <<<"$1" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  n=$(( longest >= 3 ? longest + 1 : 3 ))
  printf '`%.0s' $(seq "$n")
}

open_conflict_issue() {
  local tag="$1" base="$2" files="$3" title body fence
  title="Rebase of ${DEV_BRANCH} onto ${tag} conflicts"
  fence="$(fence_for "$files")"
  body="$(cat <<BODY
Upstream released \`${tag}\`. Rebasing the patch series of \`${DEV_BRANCH}\` (the commits after \`${base}\`) onto it conflicts, so no candidate branch \`${CANDIDATE_PREFIX}/${tag}\` was created.

Conflicting files:

${fence}
${files}
${fence}

Rebase by hand:

\`\`\`sh
git fetch upstream tag ${tag}
git fetch origin ${DEV_BRANCH}
git switch -c ${CANDIDATE_PREFIX}/${tag} origin/${DEV_BRANCH}
git rebase --onto ${tag} ${base}
# resolve the conflicts, git add the files, git rebase --continue
git push origin ${CANDIDATE_PREFIX}/${tag}
\`\`\`

Then promote the candidate as described in the branch workflow: tag the old state \`pre-rebase/${DEV_BRANCH}/${tag}\`, re-sign the commits and reset \`${DEV_BRANCH}\`.
BODY
)"
  if is_dry_run; then
    would "open issue \"${title}\""
  else
    gh api -X POST "repos/${REPO}/issues" -f title="$title" -f body="$body" >/dev/null
    log "candidate: opened issue \"${title}\""
  fi
}

# ---------------------------------------------------------------- candidate
# The fork has about 7.6 GB of history, so never clone it in full. A blobless partial
# clone (commits and trees, file contents on demand) of only the refs we need is enough
# to find the base, rebase the series and push.

# candidate_setup <work>: an empty repository with the upstream and fork remotes and the refs we need.
candidate_setup() {
  local work="$1"
  git init -q "$work"
  git -C "$work" remote add upstream "$UPSTREAM_URL"
  git -C "$work" remote add fork "$FORK_URL"
  if [ -n "${GH_TOKEN:-}" ] && [[ "$FORK_URL" == https://github.com/* ]]; then
    git -C "$work" config "http.https://github.com/.extraheader" "AUTHORIZATION: basic $(token_header_b64)"
  fi
  git -C "$work" config commit.gpgsign false   # candidate commits stay unsigned; the promoter re-signs
  git -C "$work" fetch -q --filter=blob:none upstream "+refs/tags/v${LINE}.*:refs/tags/v${LINE}.*"
  git -C "$work" fetch -q --filter=blob:none fork "+refs/heads/${DEV_BRANCH}:refs/remotes/fork/${DEV_BRANCH}"
}

# find_base <work> <tip>: the newest final release tag that is an ancestor of the dev branch.
find_base() {
  local work="$1" tip="$2" t
  while read -r t; do
    if git -C "$work" merge-base --is-ancestor "refs/tags/$t" "$tip"; then echo "$t"; return 0; fi
  done < <(git -C "$work" tag --list "v${LINE}.*" | final_tags_newest_first "$LINE")
  return 1
}

# choose_tag <work>: the release to rebase onto: the override, or the newest final tag.
choose_tag() {
  local work="$1"
  if [ -n "$UPSTREAM_TAG" ]; then
    [[ "$UPSTREAM_TAG" =~ $TAG_RE ]] || die "upstream_tag ${UPSTREAM_TAG} is not a final v${LINE}.x.y tag"
    git -C "$work" rev-parse -q --verify "refs/tags/$UPSTREAM_TAG" >/dev/null || die "tag ${UPSTREAM_TAG} not found upstream"
    echo "$UPSTREAM_TAG"
  else
    git -C "$work" tag --list "v${LINE}.*" | newest_final_tag "$LINE"
  fi
}

# already_handled <work> <cand> <tag>: true when a candidate branch or an issue for the tag exists.
already_handled() {
  local work="$1" cand="$2" tag="$3" titles
  if [ -n "$(git -C "$work" ls-remote --heads fork "refs/heads/${cand}")" ]; then
    log "candidate: ${cand} already exists; nothing to do"; return 0
  fi
  # all states: a closed issue also counts (see ionos-sync.md)
  titles="$(gh_paginate '.[] | select(.pull_request == null) | .title' -X GET "repos/${REPO}/issues" -f state=all -f per_page=100)"
  if grep -qxF "Rebase of ${DEV_BRANCH} onto ${tag} conflicts" <<<"$titles"; then
    log "candidate: an issue for ${tag} already exists (any state); nothing to do"; return 0
  fi
  return 1
}

# rebase_series <work> <tip> <base> <tag>: rebase the series onto the tag; on conflict abort
# and leave the conflicting paths in $CONFLICT_FILES.
rebase_series() {
  local work="$1" tip="$2" base="$3" tag="$4"
  git -C "$work" checkout -q -b rebase-work "$tip"
  if git -C "$work" -c user.name="ionos-sync" -c user.email="ionos-sync@users.noreply.github.com" \
       rebase -q --onto "refs/tags/${tag}" "refs/tags/${base}" >/dev/null 2>&1; then
    return 0
  fi
  CONFLICT_FILES="$(git -C "$work" diff --name-only -z --diff-filter=U | tr '\0' '\n')"
  git -C "$work" rebase --abort >/dev/null 2>&1 || true
  return 1
}

publish_candidate() {
  local work="$1" cand="$2"
  if is_dry_run; then
    would "push ${cand}"
  else
    if ! git -C "$work" push -q fork "HEAD:refs/heads/${cand}"; then
      [ "$HAS_SYNC_TOKEN" = true ] || warn "the push was probably refused because the default token cannot push workflow files; set the secret IONOS_SYNC_TOKEN"
      die "candidate: pushing ${cand} failed"
    fi
    log "candidate: pushed ${cand}"
  fi
}

make_candidate() {
  local work tag base tip cand
  # A step runs in a subshell, so this EXIT trap fires when the step ends, also when it dies.
  work="$(mktemp -d)"
  CANDIDATE_WORK="$work"
  trap 'rm -rf "$CANDIDATE_WORK"' EXIT
  candidate_setup "$work"
  tip="refs/remotes/fork/${DEV_BRANCH}"

  base="$(find_base "$work" "$tip")" || die "no release tag of line ${LINE} is an ancestor of ${DEV_BRANCH}"
  tag="$(choose_tag "$work")"
  [ -n "$tag" ] || die "no final release tag of line ${LINE} found upstream"
  if [ "$(printf '%s\n%s\n' "$base" "$tag" | sort -V | tail -n1)" = "$base" ]; then
    log "candidate: ${tag} is not newer than base ${base}; nothing to do"; return
  fi
  cand="${CANDIDATE_PREFIX}/${tag}"
  log "candidate: base ${base}, new release ${tag}, series of $(git -C "$work" rev-list --count "refs/tags/${base}..${tip}") commit(s) -> ${cand}"

  already_handled "$work" "$cand" "$tag" && return
  if rebase_series "$work" "$tip" "$base" "$tag"; then
    publish_candidate "$work" "$cand"
  else
    log "candidate: rebase onto ${tag} conflicts in: $(echo "$CONFLICT_FILES" | tr '\n' ' ')"
    open_conflict_issue "$tag" "$base" "$CONFLICT_FILES"
  fi
}

# Upstream's workflow files stay untouched in the fork (deleting them would conflict on every
# rebase); instead every active workflow outside our ionos- prefix is disabled. Workflows that
# upstream adds later are caught by the next run.
disable_upstream_workflows() {
  local id path list err failed=0
  # only real workflow files: dynamic workflows (for example pages-build-deployment) have a
  # path outside .github/workflows/ and cannot be disabled this way
  list="$(gh_paginate '.workflows[] | select(.state == "active")
             | select(.path | startswith(".github/workflows/"))
             | select(.path | startswith(".github/workflows/ionos-") | not) | [.id, .path] | @tsv' \
             "repos/${REPO}/actions/workflows?per_page=100")"
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    if is_dry_run; then
      would "disable workflow ${path} (${id})"
    elif err="$(gh api -X PUT "repos/${REPO}/actions/workflows/${id}/disable" 2>&1 >/dev/null)"; then
      log "workflows: disabled ${path}"
    elif [[ "$err" == *"HTTP 4"* ]]; then
      warn "workflow ${path} (${id}) could not be disabled, continuing: ${err}"
    else
      echo "::error::ionos-sync: disabling workflow ${path} (${id}) failed: ${err}"; failed=1
    fi
  done <<<"$list"
  return "$failed"
}

# Mirrors move only by fast-forward: GitHub's merge-upstream endpoint refuses (HTTP 409) when the
# branch has diverged. That is never forced; the run fails so that a person looks at it.
sync_mirrors() {
  local b out failed=0
  for b in $MIRRORS; do
    if is_dry_run; then
      would "sync mirror ${b} (fast-forward only)"
    elif out="$(gh api -X POST "repos/${REPO}/merge-upstream" -f branch="$b" 2>&1)"; then
      log "mirror ${b}: $(echo "$out" | jq -r '.merge_type // .message' 2>/dev/null || echo "$out")"
    else
      echo "::error::ionos-sync: mirror ${b} could not be fast-forwarded from upstream (diverged?); not forced. ${out}"; failed=1
    fi
  done
  return "$failed"
}

mask_token_header
is_dry_run && log "dry run: nothing will be changed"
warn_without_sync_token
run_step mirrors sync_mirrors
run_step workflows disable_upstream_workflows
run_step candidate make_candidate
exit "$FAILED"
