# Cutting a release: the snapshot workflow (line 33)

`.github/workflows/ionos-snapshot.yml` freezes a state of the dev branch as a snapshot, names it with a release
number and starts the release build. The logic is in `.github/ionos/ionos-snapshot.sh` (shared names and the tag
annotation in `ionos-lib.sh`); the workflow only passes the environment. Test it with
`bash .github/ionos/ionos-snapshot.test.sh`: the script runs as a process against a throwaway bare repository and a stub
`gh`, and the tests look at the refs that are left in that repository. What the release build then does is in
`ionos-build.md` ("Release builds").

## What one run does

1. Checks every input with a regular expression (below) before it talks to GitHub.
2. Reads the tip of the source branch and, from `version.php` AT THAT COMMIT, the base release (`$OC_VersionString`, for
   example `33.0.9`). The line of the branch name must be the line of that version.
3. Refuses a used release number, before creating anything: the branch `rc/ncw-v<nn>-<n>` exists, OR any tag
   `ncw-v<nn>.<x>.<y>-<n>` of the line exists (any base release: the number restarts per line, not per base release; a
   lightweight tag counts too). `rc/ncw-v33-10` does not block 1 (the lookup is a prefix match that is compared exactly).
4. Creates the branch `rc/ncw-v33-<n>` AT the source tip (no new commit, so the signatures stay as they are) and the
   ANNOTATED tag `ncw-v33.0.9-<n>` on the same commit. Refs are created through the API and are never updated or deleted.
5. Starts the release build: `gh workflow run ionos-build.yml --ref rc/ncw-v33-<n> -f kind=release` (up to 3 attempts, 5 s apart).
   `workflow_dispatch` is the one event the default token may start. Nothing else is passed: the build reads release number,
   snapshot branch and scope from the tag annotation, so they cannot drift.

The tag annotation (the single place the scope lives; the build, the release notes and `version.json` copy it from there):

```
ncw-v33.0.9-1: snapshot of ionos-dev-v33 for the release build

release_nr: 1
line: 33
base_release: 33.0.9
source_branch: ionos-dev-v33
source_commit: <40 hex>
snapshot_branch: rc/ncw-v33-1
rehearsal: false
scope: <the scope text>
```

The tag is created through the API, so it is annotated but not signed (the commit it points at is the signed commit of
the dev branch).

## Inputs

| Input | Default | Rule |
|---|---|---|
| `release_nr` | | `^[1-9][0-9]{0,8}$`: a positive integer, no leading zeros. Restarts at 1 for each line. |
| `source_branch` | `ionos-dev-v33` | `^ionos-dev-v[0-9]{1,3}$`. Only dev branches can be frozen. |
| `scope` | | One line, 1 to 500 characters, no control characters (no newline, no tab), not starting or ending with a blank. It is text: it only travels as the `message` of the tag object through `env:` and is never part of a shell command or a URL; `$(...)`, backticks and quotes are stored as written. |
| `rehearsal` | false | `true` or `false`. See below. |
| `dry_run` | false | `true` or `false`. Runs steps 1 to 3 (so a used number still fails), prints the branch, the tag and the annotation, creates and starts nothing. |

Run it from the Actions tab (IONOS snapshot, Run workflow) or:

```
gh workflow run ionos-snapshot.yml -R printminion-co/mk-nc-server \
  -f release_nr=1 -f source_branch=ionos-dev-v33 -f scope='First release on base v33.0.9, flavor1' -f rehearsal=false
```

Like the other manual workflows it is listed only once the file is on the repository's default branch (the cutover setting).

## Rehearsal

`rehearsal=true` uses `rehearsal/ncw-v33-<n>` and the tag `rehearsal-v33.0.9-<n>` instead of `rc/...` and `ncw-v...`. The real
names are never used by a rehearsal, and the rulesets of `rc/*` and `ncw-v*` do not cover the rehearsal names, so everything a
rehearsal made can be deleted by hand. Downstream honors the prefix: the release build derives "rehearsal" from the branch
name (not from an input), and publishes a PRE-release titled `rehearsal-v33.0.9-<n> (rehearsal, not a release)` with a warning
on top. Duplicate detection works within the rehearsal names, so a second rehearsal needs another number, or the first one's
refs deleted. A rehearsal number does not use up the real number.

Delete a rehearsal by hand (release and tag, then the branch):

```
gh release delete rehearsal-v33.0.9-1 -R printminion-co/mk-nc-server --cleanup-tag --yes
gh api -X DELETE repos/printminion-co/mk-nc-server/git/refs/heads/rehearsal/ncw-v33-1
```

(Without a release page the tag goes with `gh api -X DELETE repos/printminion-co/mk-nc-server/git/refs/tags/rehearsal-v33.0.9-1`.)
Never use these commands on `rc/` or `ncw-v` names.

## Rebuild

A rebuild re-runs the release build of the SAME snapshot, for example after a flaky smoke test or a runner problem. Start it
on the snapshot branch, with kind release (Actions, IONOS build, Run workflow, branch `rc/ncw-v33-1`, kind release), or

```
gh workflow run ionos-build.yml -R printminion-co/mk-nc-server --ref rc/ncw-v33-1 -f kind=release
```

It gets a new run number, so its archives have a new build number in their names. They are attached to the SAME release, the
archive table of the page is rebuilt, the earlier assets stay, and a build number that is not strictly larger than the ones
already attached is refused. Do NOT re-run the snapshot workflow: the number is used. "Re-run jobs" on a finished run keeps
its run number and is refused at publish time.

A rebuild uses the snapshot's own pipeline and tooling (the code of `rc/ncw-v33-1`), not the dev branch's.

## When something fails half way

Nothing is ever deleted or rolled back; the run says what exists.

- **Inputs, used number, unreadable source:** nothing was created. Fix the input and run again.
- **The branch was created, the tag was not:** the number is spent (the branch exists). The error names the branch. Use a new
  release number; the half-made branch is harmless (a release build refuses a snapshot branch without its tag). An admin can remove it by hand if
  needed (disable the ruleset `ncw-snapshot-branches` for a moment, delete the branch, enable it again).
- **Branch and tag exist, the release build could not be started:** the snapshot stays and the run fails with the command that
  restarts the build (`gh workflow run ionos-build.yml --ref rc/ncw-v33-<n> -f kind=release`, or the Actions page). Do not run the snapshot
  workflow again for that number.
- **The release build fails (plan, build, smoke):** nothing is published; read the logs (`ionos-build.md`), then rebuild.
- **The publish fails after some assets were attached:** the body is updated only after all assets are attached. If the assets
  are on the release but the notes are not, the run says so; the next rebuild rewrites the table.

## What is protected (never rewritten)

- Signed commits are required on `rc/*` (ruleset `ncw-signed-commits`), so the snapshot branch can only point at signed
  history. It points at the source tip without a new commit.
- `rc/*` branches and `ncw-v*` tags cannot be force-pushed or deleted (rulesets `ncw-snapshot-branches` and
  `ncw-snapshot-tags`, check and apply step 9 of `tools/fork-settings/wizard.sh` in the flavors repository). Creating them stays
  allowed. A mistaken snapshot is superseded by a new release number.
- The script itself only ever creates refs, and the release build only ever adds assets.

## The token

The workflow uses the repository secret `IONOS_SYNC_TOKEN` (ADR 0007, fine-grained personal access token with the `workflow` scope; see
`ionos-sync.md`) and falls back to the default token with a warning in the log. Permissions of the job: `contents: write` (create refs
with the default token) and `actions: write` (start the build with the default token). The token that creates the refs and starts the build
is the same. With the sync token, the pushes it makes start other workflows too; no ionos workflow listens to `push` or `create`, and
upstream's workflows are disabled. Whether the default token may create a ref whose history contains workflow files can only be seen on GitHub;
that is why the sync token is the supported one. The expiry of that token is a real risk: a run with an expired token fails at the first
API call and nothing is created.

## Runbook for the first release, `ncw-v33-1` (human ticket)

Preconditions (check them, do not assume): the workflow files of the fork are on the default branch (cutover); the secret
`IONOS_SYNC_TOKEN` exists; `tools/fork-settings/wizard.sh --check --live-line 33` has no TODO, including step 9; the last dev build
(`dev-v33.0.9.<n>`) of the tip of `ionos-dev-v33` is green and its flavors pin is the intended one (the snapshot freezes the
server, the pipeline, the app pins and the flavors).

1. **Dry run.** IONOS snapshot with `release_nr` 1, `scope` set, `dry_run` true. The log must show `rc/ncw-v33-1`, `ncw-v33.0.9-1` and the annotation.
2. **Rehearsal.** Same with `rehearsal` true (and `dry_run` false). Check: branch `rehearsal/ncw-v33-1` and tag `rehearsal-v33.0.9-1` exist, a run of
   IONOS build on that branch (kind release) starts by itself, the plan job log shows scope and release number read from the tag, the
   smoke job passes, a pre-release `rehearsal-v33.0.9-1` appears with the scope, the table of every flavor and the attestation bundle.
   `gh attestation verify <zip> -R printminion-co/mk-nc-server` passes. `unzip -p <zip> version.json` shows kind `release`, snapshot
   branch `rehearsal/ncw-v33-1`, release number 1 and the scope.
3. **Rehearse the duplicate.** Run the same rehearsal again: it must fail ("already used") and change nothing.
4. **Rehearse a rebuild.** Start IONOS build on `rehearsal/ncw-v33-1`, kind release: the same release gets new assets with a higher build
   number, the table lists old and new archives, nothing was replaced.
5. **Delete the rehearsal** (commands above).
6. **The real one.** IONOS snapshot, `release_nr` 1, the agreed `scope`, `rehearsal` false. Wait for the release build. The release
   `ncw-v33.0.9-1` must not be marked pre-release and not "latest", must show the scope and one archive per flavor with sha256,
   and its `.sha256` files and `ncw-build-<n>.attestation.jsonl` must be attached. Verify one archive as the page says.
7. **Never rewrite.** Do not try to delete the real tag to prove the rule: if the rulesets were missing it would work. Read the
   rulesets instead (`wizard.sh --check`, step 9 PASS).
8. Hand the archives and the release link to the staging rehearsal (spec 07, layer 4).
