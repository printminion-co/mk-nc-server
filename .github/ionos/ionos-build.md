# Dev build pipeline (line 33)

`.github/workflows/ionos-build.yml` builds the server and the out-of-tree apps from source, builds and
validates every flavor with the flavors tool, and publishes the archives as one GitHub pre-release.
The logic is in `ionos-build-*.sh` (helpers in `ionos-lib.sh`); the workflow only passes the
environment. Test it with `bash .github/ionos/ionos-build.test.sh` (seconds: npm, composer and the tool
are stubs, `gh` is a stub with a list of releases).

## One workflow file, one build number

The build number is `github.run_number`, which GitHub counts per workflow file. The design wants one
counter shared by dev and release builds, so release builds will be another `kind` of this same file.
Input `kind` accepts `release` but the run fails at once with a message: release builds arrive with the
snapshot ticket. All flavors of a run share the build number. A scheduled run that is skipped (see below)
still uses a number, so numbers can have gaps; they always increase.

Triggers: `schedule` (05:07 UTC daily) and `workflow_dispatch` with inputs `kind` (default `dev`),
`flavors` (comma separated, default every folder of `IONOS/flavors`) and `force`. Scheduled and manual
runs only exist once the file is on the default branch; a person switches that to the dev branch (a
separate settings ticket). The run must be on `ionos-dev-v<nn>`: the line is derived from the branch name.

## Jobs and steps

`plan` (read-only token, one commit, only `.github/ionos`): `ionos-build-plan.sh` rejects `kind`
release, derives the line, and decides. A manual run always builds. A scheduled run skips (logged, the run
succeeds) when the server commit (`HEAD`) and the flavors commit (the `IONOS` submodule entry) are the
same as the ones recorded in the newest dev pre-release. The newest is the one with the highest build
number among published pre-releases whose tag is `dev-v<a>.<b>.<c>.<n>`. `force` builds anyway.

`build` (only if `plan` says so; permissions `contents: write`, `id-token: write`,
`attestations: write`; `plan` has only `contents: read`; timeout 120 minutes; concurrency group
`ionos-build`, no cancelling):

1. Check out the dev branch (depth 1) and only the submodules `3rdparty` and `IONOS` (depth 1).
2. Node from the server's `package.json` `engines`; `ionos-build-server.sh`: deletes the committed
   `dist/`, `npm ci && npm run build`, fails when `dist/` stays empty. Composer is not run for the server
   (`3rdparty` is its vendor folder, as upstream).
3. Node 24 for the tool (it runs TypeScript natively); `npm ci --ignore-scripts` in `IONOS/tools`.
4. `ionos-build-select.sh`: `ncw resolve` for every flavor; the out-of-tree apps of a flavor are the
   entries of its ACTIVE app folders (read from the commit) whose mode is not `removed`. None is fine.
5. `ionos-build-apps.sh`: initialises only those submodules (depth 1) and builds each from source.
   Default recipe: `composer install --no-dev -a` when `composer.json` exists, then `npm ci && npm run build`
   when `package.json` has a `build` script, then `node_modules` is deleted. A script
   `.github/ionos/build-recipes/<app id>.sh` replaces the default for that app (run in the app folder,
   `APP` set; use `set -euo pipefail`).
6. `ionos-build-assemble.sh`: a CLEAN tree in `$WORK/tree` (the tool loads it all into memory), done as
   upstream's release build does (`nextcloud-releases/server`, `.github/scripts`): copy without `.git`,
   `node_modules`, `IONOS`; `3rdparty` without `.git .github .gitignore README.md`; remove what the root
   `.nextcloudignore` lists (`git ls-files -cio --exclude-from`, gitignore semantics) and what each built
   app's own `.nextcloudignore` lists (keeping `composer.json/lock`, `package.json/-lock.json`); drop
   `*.map.license`; remove `config/config.php`, `data/` and empty folders. A symbolic link left in the tree
   fails the step (the official archive has none).
7. `ionos-build-package.sh`: per flavor, a pins file `{app: {commit, describe}}` for the flavor's built
   submodule apps (`git submodule status` must show the pinned commit; `describe` is `git describe --tags
   --always` after a blobless unshallow fetch), then `ncw build --kind dev --build-number <run number>
   --line <nn> --server-commit <HEAD> --flavors-commit <IONOS sha> --app-pins <file>` (no `--cache-keys`:
   the cache is a later ticket), then `ncw validate --artifact`, then `<zip>.sha256`. The first failure
   stops the run, before anything is published. The step writes `$WORK/validated` only when every flavor
   passed; the publish script refuses to run without it.
8. `actions/attest-build-provenance` on the zips; the bundle is attached to the release as
   `ncw-build-<n>.attestation.jsonl`. Check with `gh attestation verify <zip> -R <repo>`.
9. `ionos-build-publish.sh`: one `gh release create` with the default token: tag
   `dev-v<base release>.<build number>` on the built commit (`--target <sha>`, for example
   `dev-v33.0.9.42`), `--prerelease`, title `Dev build <n> (v<base> base)`, assets every zip, its `.sha256`
   and the attestation bundle. The body has machine-readable lines (`server_commit:`, `flavors_commit:`,
   `build_number:`, `base_release:`), the flavor list and a link to the run. An existing release for the tag
   (a re-run of a finished run keeps its number) fails the step and touches nothing.
10. `ionos-build-retain.sh`: keeps the newest 14 dev pre-releases (`KEEP`, default 14) and deletes older
    ones with `gh release delete --cleanup-tag --yes`. Only published pre-releases whose tag is exactly
    `dev-v<a>.<b>.<c>.<n>` are considered; anything else is never touched. Deletions are logged. `DRY_RUN=true`
    only prints.

The default `GITHUB_TOKEN` is enough: the tag points at an existing commit and no workflow file is
pushed. All third-party actions are GitHub's own and pinned to a commit SHA.

## Differences from upstream's release build

- Not signed (no code signing, no GPG), no metadata file, no tar.bz2.
- Upstream installs the minimum PHP of the server (8.2) with a third-party setup action so that composer's
  generated platform check is identical to a release; here PHP and Composer come from the runner image
  (no third-party action).
- Upstream adds the web updater, `example-files` (`core/skeleton`) and the docs; here the tool drops the
  updater, and the skeleton and docs stay as in the fork.
- Upstream's central `dev-files.txt` list is not applied; the tool's dev file strip and `validate` cover
  `.git*`, `node_modules`, app tests and the like.

## Open items

- The design says an app recipe override is a `build:` entry in the flavor manifest. The tool does not
  parse it yet, so `.github/ionos/build-recipes/<app>.sh` is the interim place.
- The example flavor `flavor1` makes `demo` an `always` app of `apps-flavor1/`, a folder this fork does not
  have; `validate` fails with "app demo is missing" until the folder (or a real app) exists.
- No cache (own ticket): server and apps are built on every run.
- The tool loads the whole tree: about 1.5 GB of memory and 35 s per flavor on the official tree.
