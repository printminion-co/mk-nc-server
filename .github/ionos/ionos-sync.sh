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
CANDIDATE_PREFIX="candidate/${DEV_BRANCH}"
TAG_RE="$(final_tag_re "$LINE")"

FAILED=0
is_dry_run() { [ "$DRY_RUN" = true ]; }
would()      { log "[dry run] would: $*"; }
fail()       { echo "::error::$*"; FAILED=1; }

open_conflict_issue() {
  local tag="$1" base="$2" files="$3" title body
  title="Rebase of ${DEV_BRANCH} onto ${tag} conflicts"
  # shellcheck disable=SC2016  # the backticks in the sed script are literal markdown
  body="$(cat <<BODY
Upstream released \`${tag}\`. Rebasing the patch series of \`${DEV_BRANCH}\` (the commits after \`${base}\`) onto it conflicts, so no candidate branch \`${CANDIDATE_PREFIX}/${tag}\` was created.

Conflicting files:

$(echo "$files" | sed 's/^/- `/; s/$/`/')

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
    git -C "$work" config "http.https://github.com/.extraheader" \
      "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
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
    [[ "$UPSTREAM_TAG" =~ $TAG_RE ]] || { fail "upstream_tag ${UPSTREAM_TAG} is not a final v${LINE}.x.y tag"; return 1; }
    git -C "$work" rev-parse -q --verify "refs/tags/$UPSTREAM_TAG" >/dev/null || { fail "tag ${UPSTREAM_TAG} not found upstream"; return 1; }
    echo "$UPSTREAM_TAG"
  else
    git -C "$work" tag --list "v${LINE}.*" | newest_final_tag "$LINE"
  fi
}

# already_handled <work> <cand> <tag>: true when a candidate branch or an issue for the tag exists.
already_handled() {
  local work="$1" cand="$2" tag="$3"
  if [ -n "$(git -C "$work" ls-remote --heads fork "refs/heads/${cand}")" ]; then
    log "candidate: ${cand} already exists; nothing to do"; return 0
  fi
  if gh_paginate '.[] | select(.pull_request == null) | .title' "repos/${REPO}/issues?state=open&per_page=100" \
       | grep -qxF "Rebase of ${DEV_BRANCH} onto ${tag} conflicts"; then
    log "candidate: an open issue for ${tag} already exists; nothing to do"; return 0
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
  CONFLICT_FILES="$(git -C "$work" diff --name-only --diff-filter=U)"
  git -C "$work" rebase --abort >/dev/null 2>&1 || true
  return 1
}

publish_candidate() {
  local work="$1" cand="$2"
  if is_dry_run; then
    would "push ${cand}"
  else
    git -C "$work" push -q fork "HEAD:refs/heads/${cand}"
    log "candidate: pushed ${cand}"
  fi
}

make_candidate() {
  local work tag base tip cand
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  candidate_setup "$work"
  tip="refs/remotes/fork/${DEV_BRANCH}"

  base="$(find_base "$work" "$tip")" || { fail "no release tag of line ${LINE} is an ancestor of ${DEV_BRANCH}"; return; }
  tag="$(choose_tag "$work")" || return
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
  local id path
  while IFS=$'\t' read -r id path; do
    if is_dry_run; then
      would "disable workflow ${path} (${id})"
    else
      gh api -X PUT "repos/${REPO}/actions/workflows/${id}/disable" >/dev/null
      log "workflows: disabled ${path}"
    fi
  done < <(gh_paginate '.workflows[] | select(.state == "active")
             | select(.path | startswith(".github/workflows/ionos-") | not) | [.id, .path] | @tsv' \
             "repos/${REPO}/actions/workflows?per_page=100")
}

# Mirrors move only by fast-forward: GitHub's merge-upstream endpoint refuses (HTTP 409) when the
# branch has diverged. That is never forced; the run fails so that a person looks at it.
sync_mirrors() {
  local b out
  for b in $MIRRORS; do
    if is_dry_run; then
      would "sync mirror ${b} (fast-forward only)"
    elif out="$(gh api -X POST "repos/${REPO}/merge-upstream" -f branch="$b" 2>&1)"; then
      log "mirror ${b}: $(echo "$out" | jq -r '.merge_type // .message' 2>/dev/null || echo "$out")"
    else
      fail "mirror ${b} could not be fast-forwarded from upstream (diverged?); not forced. ${out}"
    fi
  done
}

is_dry_run && log "dry run: nothing will be changed"
sync_mirrors
disable_upstream_workflows
make_candidate
exit "$FAILED"
