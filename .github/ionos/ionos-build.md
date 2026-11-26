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
release, checks the names in the `flavors` input, derives the line, and decides. A manual run always
builds. A scheduled run skips (logged, the run succeeds) only when the newest dev pre-release (highest
build number among published pre-releases whose tag is `dev-v<a>.<b>.<c>.<n>`) covered ALL flavors
(its body line `flavors_scope: all`) and its `server_commit` (`HEAD`) and `flavors_commit` (the `IONOS`
submodule entry) equal the current ones. The flavors commit fixes the set of flavors, so "all" then is
"all" now. A pre-release of a subset run (`flavors` input) or one without the line is never a baseline:
the scheduled run builds. `force` builds anyway.

Three jobs, so that third-party app code never meets a write token:

**`build`** (permissions `contents: read` only; timeout 120 minutes; concurrency group `ionos-build`,
no cancelling) runs everything that executes app code and ends by uploading the workflow artifact
`ionos-build` (archives, checksums, `flavors.txt`, `validated`, `scope`, `base-release`):

1. Check out the dev branch (depth 1) and only the submodules `3rdparty` and `IONOS` (depth 1).
2. Node from the server's `package.json` `engines`; `ionos-build-server.sh`: deletes the committed
   `dist/`, `npm ci && npm run build`, fails when `dist/` stays empty. This `npm ci` runs lifecycle
   scripts on purpose: the server's `postinstall` (`build/demi.sh ci`) installs the frontend builds. Composer
   is not run for the server (`3rdparty` is its vendor folder, as upstream).
3. Node 24 for the tool (it runs TypeScript natively); `npm ci --ignore-scripts` in `IONOS/tools`.
4. `ionos-build-select.sh`: `ncw resolve` for every flavor; the out-of-tree apps of a flavor are the
   entries of its ACTIVE app folders (read from the commit) whose mode is not `removed`. None is fine.
   It also writes `scope` (`all` when the selected flavors are every flavor of `IONOS/flavors`).
5. `ionos-build-apps.sh`: initialises only those submodules (depth 1) and builds each from source, by
   this rule. A script `.github/ionos/build-recipes/<app id>.sh` replaces the default for that app: it is
   run in the app folder with `APP` set (use `set -euo pipefail`), it owns what it deletes and builds, and
   no check is made on its result. Without a recipe the default recipe applies, and built files are never
   trusted:
   - committed files in `js/` or `css/`, no `package.json` build script and no recipe: the step FAILS
     naming the app (add a recipe, even a no-op one that states the files are sources);
   - `composer.json`: `vendor/` is deleted, `composer install --no-dev -a` runs and `vendor/autoload.php`
     must exist, else the step fails naming the app;
   - `package.json` with a `build` script: `js/` and `css/` are deleted, `npm ci --ignore-scripts && npm run
     build` runs, and `js/` or `css/` must contain files, else the step fails naming the app (an app that
     builds elsewhere needs a recipe);
   - `node_modules` is deleted afterwards.
   `--ignore-scripts` is used for the apps because most do not need lifecycle scripts (as for the tool itself); an app
   that needs a `postinstall` has to use a recipe. The server cannot use it (see 2). An app that keeps
   handwritten files in `js/` or `css/` also needs a recipe, because the default recipe deletes those dirs.
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
   the cache is a later ticket), then `ncw validate --artifact`, then `<zip>.sha256`. A failing flavor
   leaves no archive; the other flavors still run, all failures are reported at the end and the step fails.
   `$WORK/validated` is written only when every flavor passed.
8. Upload of the artifact (`actions/upload-artifact`), only reached when everything above passed.

**`publish`** (needs `plan` and `build`; permissions `contents: write`, `id-token: write`,
`attestations: write`; runs no npm, no composer and no app code: it checks out only `.github/ionos`):

1. Download the artifact (`actions/download-artifact`).
2. `ionos-build-publish.sh --check`: the gate. Refuses unless `validated` equals the flavor list, every
   flavor has an archive, every archive matches its checksum, the scope is `all` or `subset`, and the
   release for the tag does not exist yet. Nothing is attested before it passes.
3. `actions/attest-build-provenance` on the zips; the bundle is attached to the release as
   `ncw-build-<n>.attestation.jsonl`. Check with `gh attestation verify <zip> -R <repo>`.
4. `ionos-build-publish.sh`: runs the gate again, then one `gh release create` with the default token: tag
   `dev-v<base release>.<build number>` on the built commit (`--target <sha>`, for example
   `dev-v33.0.9.42`), `--prerelease`, title `Dev build <n> (v<base> base)`, assets every zip, its `.sha256`
   and the attestation bundle. The body has machine-readable lines (`server_commit:`, `flavors_commit:`,
   `build_number:`, `base_release:`, `flavors_scope:`, `flavors:`), the flavor list and a link to the run.
   An existing release for the tag (a re-run of a finished run keeps its number) fails and touches nothing.
5. `ionos-build-retain.sh`, a separate step: keeps the newest 14 dev pre-releases (`KEEP`, default 14) and
   deletes older ones with `gh release delete --cleanup-tag --yes`. Only published pre-releases whose tag is
   exactly `dev-v<a>.<b>.<c>.<n>` are considered; anything else is never touched. Deletions are logged.
   `DRY_RUN=true` only prints.

The default `GITHUB_TOKEN` is enough: the tag points at an existing commit and no workflow file is
pushed. All actions are GitHub's own and pinned to a commit SHA.

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
- `flavor1` takes five apps from the app folder `apps-flavor1/` (submodules, see `ionos-flavor-apps.md`); four of them
  have a recipe in `build-recipes/`. Recipes should use `$NPM` and `$COMPOSER` (set by the tests; unset means the plain commands)
  instead of plain `npm` and `composer`, so the tests can stub them.
- No cache (own ticket): server and apps are built on every run.
- The tool loads the whole tree: about 1.5 GB of memory and 35 s per flavor on the official tree.
