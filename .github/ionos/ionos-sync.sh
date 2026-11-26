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

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
LINE="${LINE:-33}"
DEV_BRANCH="${DEV_BRANCH:-ionos-dev-v${LINE}}"
MIRRORS="${MIRRORS:-master stable${LINE}}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/nextcloud/server.git}"
FORK_URL="${FORK_URL:-https://github.com/${REPO}.git}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
DRY_RUN="${DRY_RUN:-false}"
CANDIDATE_PREFIX="candidate/${DEV_BRANCH}"
TAG_RE="^v${LINE}\.[0-9]+\.[0-9]+$"   # final releases only: no beta/rc suffix

FAILED=0
log()  { echo "$*"; }
act()  { [ "$DRY_RUN" = true ] && { log "[dry run] would: $*"; return 1; }; return 0; }
fail() { echo "::error::$*"; FAILED=1; }

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
  if act "open issue \"${title}\""; then
    gh api -X POST "repos/${REPO}/issues" -f title="$title" -f body="$body" >/dev/null
    log "candidate: opened issue \"${title}\""
  fi
}

# ---------------------------------------------------------------- candidate
# The fork has about 7.6 GB of history, so never clone it in full. A blobless partial
# clone (commits and trees, file contents on demand) of only the refs we need is enough
# to find the base, rebase the series and push.
make_candidate() {
  local work tag base tip series cand
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
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
  tip="refs/remotes/fork/${DEV_BRANCH}"

  # base: the newest final release tag that is an ancestor of the dev branch
  base=""
  while read -r t; do
    if git -C "$work" merge-base --is-ancestor "refs/tags/$t" "$tip"; then base="$t"; break; fi
  done < <(git -C "$work" tag --list "v${LINE}.*" | grep -E "$TAG_RE" | sort -rV)
  [ -n "$base" ] || { fail "no release tag of line ${LINE} is an ancestor of ${DEV_BRANCH}"; return; }

  if [ -n "$UPSTREAM_TAG" ]; then
    [[ "$UPSTREAM_TAG" =~ $TAG_RE ]] || { fail "upstream_tag ${UPSTREAM_TAG} is not a final v${LINE}.x.y tag"; return; }
    git -C "$work" rev-parse -q --verify "refs/tags/$UPSTREAM_TAG" >/dev/null || { fail "tag ${UPSTREAM_TAG} not found upstream"; return; }
    tag="$UPSTREAM_TAG"
  else
    tag="$(git -C "$work" tag --list "v${LINE}.*" | grep -E "$TAG_RE" | sort -V | tail -n1)"
  fi
  if [ "$(printf '%s\n%s\n' "$base" "$tag" | sort -V | tail -n1)" = "$base" ]; then
    log "candidate: ${tag} is not newer than base ${base}; nothing to do"; return
  fi
  cand="${CANDIDATE_PREFIX}/${tag}"
  series="$(git -C "$work" rev-list --count "refs/tags/${base}..${tip}")"
  log "candidate: base ${base}, new release ${tag}, series of ${series} commit(s) -> ${cand}"

  # idempotent: a candidate branch or an open issue for this tag means it was handled already
  if [ -n "$(git -C "$work" ls-remote --heads fork "refs/heads/${cand}")" ]; then
    log "candidate: ${cand} already exists; nothing to do"; return
  fi
  if gh api --paginate "repos/${REPO}/issues?state=open&per_page=100" \
       | jq -r '.[] | select(.pull_request == null) | .title' \
       | grep -qxF "Rebase of ${DEV_BRANCH} onto ${tag} conflicts"; then
    log "candidate: an open issue for ${tag} already exists; nothing to do"; return
  fi

  git -C "$work" checkout -q -b rebase-work "$tip"
  if git -C "$work" -c user.name="ionos-sync" -c user.email="ionos-sync@users.noreply.github.com" \
       rebase -q --onto "refs/tags/${tag}" "refs/tags/${base}" >/dev/null 2>&1; then
    if act "push ${cand}"; then
      git -C "$work" push -q fork "HEAD:refs/heads/${cand}"
      log "candidate: pushed ${cand}"
    fi
  else
    local files
    files="$(git -C "$work" diff --name-only --diff-filter=U)"
    git -C "$work" rebase --abort >/dev/null 2>&1 || true
    log "candidate: rebase onto ${tag} conflicts in: $(echo "$files" | tr '\n' ' ')"
    open_conflict_issue "$tag" "$base" "$files"
  fi
}

# Upstream's workflow files stay untouched in the fork (deleting them would conflict on every
# rebase); instead every active workflow outside our ionos- prefix is disabled. Workflows that
# upstream adds later are caught by the next run.
disable_upstream_workflows() {
  local id path
  while IFS=$'\t' read -r id path; do
    if act "disable workflow ${path} (${id})"; then
      gh api -X PUT "repos/${REPO}/actions/workflows/${id}/disable" >/dev/null
      log "workflows: disabled ${path}"
    fi
  done < <(gh api --paginate "repos/${REPO}/actions/workflows?per_page=100" \
    | jq -r '.workflows[] | select(.state == "active")
             | select(.path | startswith(".github/workflows/ionos-") | not) | [.id, .path] | @tsv')
}

# Mirrors move only by fast-forward: GitHub's merge-upstream endpoint refuses (HTTP 409) when the
# branch has diverged. That is never forced; the run fails so that a person looks at it.
sync_mirrors() {
  local b out
  for b in $MIRRORS; do
    if act "sync mirror ${b} (fast-forward only)"; then
      if out="$(gh api -X POST "repos/${REPO}/merge-upstream" -f branch="$b" 2>&1)"; then
        log "mirror ${b}: $(echo "$out" | jq -r '.merge_type // .message' 2>/dev/null || echo "$out")"
      else
        fail "mirror ${b} could not be fast-forwarded from upstream (diverged?); not forced. ${out}"
      fi
    fi
  done
}

[ "$DRY_RUN" = true ] && log "dry run: nothing will be changed"
sync_mirrors
disable_upstream_workflows
make_candidate
exit "$FAILED"
