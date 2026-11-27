# Tracking upstream (line 33)

`.github/workflows/ionos-sync.yml` keeps this fork in step with `nextcloud/server`. The logic is in
`.github/ionos/ionos-sync.sh` (shared helpers in `ionos-lib.sh`); the workflow only passes the
environment. Test it with `bash .github/ionos/ionos-sync.test.sh`: the script runs as a process
against throwaway local repositories and a stub `gh` that holds the state of a small fake GitHub,
and the tests check that state.

## What a run does

It runs daily (03:17 UTC) and on demand (`workflow_dispatch`, inputs `dry_run` and `upstream_tag`).
Three steps, each isolated: a failing step is reported with `::error::`, the other steps still run,
and the job fails at the end when any step failed.

1. **Mirrors.** `master` and `stable33` are fast-forwarded from upstream with GitHub's
   `merge-upstream` endpoint. That only fast-forwards: a diverged mirror (HTTP 409) is never forced,
   the run fails and a person looks at it. When upstream touches workflow files, this step may also
   need the token below.
2. **Disabling upstream's workflows.** Every active workflow whose file is under `.github/workflows/`
   and does not start with `ionos-` is disabled (upstream's files stay untouched, so they never
   conflict on a rebase; new ones are caught by the next run). Dynamic workflows (path outside
   `.github/workflows/`, such as `pages-build-deployment`) are skipped. A 4xx answer for one workflow
   is a warning, not a failure, and the others are still handled.
3. **Candidate.** When upstream has a final release tag newer than the base release of the dev
   branch, the patch series of `ionos-dev-v33` is rebased onto it and pushed as
   `candidate/ionos-dev-v33/<tag>`. Candidate commits are unsigned; the person who promotes the
   candidate re-signs them. The dev branch is never moved by this workflow.

The fork has about 7.6 GB of history, so the script never clones it fully: a blobless partial
clone of only the refs it needs.

## How the base release is determined

The base is the newest final `v33.x.y` tag (no beta or rc suffix) that is an ancestor of the tip of
`ionos-dev-v33`. The newest final tag upstream is the new release. If it is not newer than the base,
nothing happens. `upstream_tag` replaces "newest final tag" (it must itself be a final tag of the line).

## When a candidate conflicts

No branch is created. The run opens an issue "Rebase of ionos-dev-v33 onto `<tag>` conflicts" that
lists the conflicting files and the commands for rebasing by hand and pushing
`candidate/ionos-dev-v33/<tag>`. The file list is inside a code fence longer than any run of
backticks in a path, so no path can end it.

Idempotency: a run does nothing for a tag when the candidate branch exists or when an issue with that
title exists in any state, open or closed. Closing the issue or deleting the candidate branch after
the conflict was handled therefore does not make the next run open another issue. Deleting a
candidate that was never promoted (and for which no issue exists) makes the next run create it again.
A second run changes nothing.

## The secret `IONOS_SYNC_TOKEN`

GitHub does not let the default `GITHUB_TOKEN` create or update files under `.github/workflows`, and
our patch series, and so the candidate branches rebased from it, contain workflow files. The push of a
candidate (and possibly the mirror sync when upstream touches workflow files) is refused with the
default token. Both workflows therefore use the repository secret `IONOS_SYNC_TOKEN` and fall back to
the default token when it is missing, so dry runs still work:

```yaml
GH_TOKEN: ${{ secrets.IONOS_SYNC_TOKEN || github.token }}
HAS_SYNC_TOKEN: ${{ secrets.IONOS_SYNC_TOKEN != '' }}
```

The scripts read `HAS_SYNC_TOKEN`; when it is not `true` the log says that candidate pushes
containing workflow files will be refused and why. The script also masks the base64 form of the token
that git sends in its `extraheader` (`::add-mask::`) before using it.

Create the token as a fine-grained personal access token limited to this repository with read and
write access to Contents, Workflows, Pull requests, Issues and Actions, and store it under Settings,
Secrets and variables, Actions as `IONOS_SYNC_TOKEN`.

The token's lifetime does not matter for reading upstream: the `nextcloud` organization rejects
fine-grained tokens with a lifetime over 366 days (HTTP 403), so nothing sends this token to
`nextcloud/*` or `nextcloud-releases/*`. `ionos-sync.sh` calls no upstream API at all and fetches upstream's
public repository over git without credentials (the credential header is scoped to the fork's URL only);
its real runs worked for that reason. `ionos-app-pins.sh` reads upstream through the API with the default
token (see `ionos-app-pins.md`). Give the sync token a short expiry anyway and rotate it.

Pushes made with this token DO trigger workflows (pushes with the default token do not). The pins
pull request opened by `ionos-app-pins.yml` uses the same token so that the commit-lint workflow runs
on it.

## When it runs

Scheduled runs and manual runs need the workflow file on the default branch. Nothing runs until a
person switches the default branch to `ionos-dev-v33` (a separate settings step).

See also `ionos-app-pins.md` for the pins helper.
