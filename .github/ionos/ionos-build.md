# Build pipeline (line 33): dev and release builds

`.github/workflows/ionos-build.yml` builds the server and the out-of-tree apps from source, builds and
validates every flavor with the flavors tool, and publishes the archives: a dev build as one GitHub
pre-release, a release build (see "Release builds" below) as a GitHub release.
The logic is in `ionos-build-*.sh` (helpers in `ionos-lib.sh`); the workflow only passes the
environment. Test it with `bash .github/ionos/ionos-build.test.sh` (seconds: npm, composer and the tool
are stubs, `gh` is a stub with a list of releases).

## One workflow file, one build number

The build number is `github.run_number`, which GitHub counts per workflow file. The design wants one
counter shared by dev and release builds, so release builds are another `kind` of this same file (a second
workflow file would start a second counter). Input `kind` is `dev` (default) or `release`; a release build is
accepted only on a snapshot branch, see "Release builds". All flavors of a run share the build number. A scheduled run that is skipped (see below)
still uses a number, so numbers can have gaps; they always increase.

Triggers: `schedule` (05:07 UTC daily) and `workflow_dispatch` with inputs `kind` (default `dev`),
`flavors` (comma separated, default every folder of `IONOS/flavors`), `force`, `no_cache` (see "Cache" below) and `smoke_break` (see the smoke test below). Scheduled and manual
runs only exist once the file is on the default branch; a person switches that to the dev branch (a
separate settings ticket). A dev run must be on `ionos-dev-v<nn>`: the line is derived from the branch name.

## Jobs and steps

`plan` (read-only token, one commit, only `.github/ionos`): `ionos-build-plan.sh` checks the names in the
`flavors` input, derives the line, and decides; for `kind` release it does what "Release builds" says. A manual run always
builds. A scheduled run skips (logged, the run succeeds) only when the newest dev pre-release (highest
build number among published pre-releases whose tag is `dev-v<a>.<b>.<c>.<n>`) covered ALL flavors
(its body line `flavors_scope: all`) and its `server_commit` (`HEAD`) and `flavors_commit` (the `IONOS`
submodule entry) equal the current ones. The flavors commit fixes the set of flavors, so "all" then is
"all" now. A pre-release of a subset run (`flavors` input) or one without the line is never a baseline:
the scheduled run builds. `force` builds anyway.

Four jobs, so that third-party app code never meets a write token:

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
4a. `actions/cache/restore` restores the app build cache folder (skipped for `no_cache`), see "Cache" below.
5. `ionos-build-apps.sh`: initialises only those submodules (depth 1) and builds each from source, unless the cache holds a
   verified build of it under the same key (see "Cache"), by this rule. A script `.github/ionos/build-recipes/<app id>.sh` replaces the default for that app: it is
   run in the app folder with `APP` set (use `set -euo pipefail`), it owns what it deletes and builds, and
   no check is made on its result. Without a recipe the default recipe applies, and built files are never
   trusted:
   - committed files in `js/` or `css/`, no `package.json` build script and no recipe: the step FAILS
     naming the app (add a recipe, even a no-op one that states the files are sources);
   - `composer.json` (always, even when it requires only php, extensions or the bin plugin: the app's `composer/autoload.php` requires `vendor/autoload.php`): untracked `vendor/` files are deleted, `composer install --no-dev -a --no-scripts` runs and `vendor/autoload.php`
     must exist, else the step fails naming the app;
   - `package.json` with a `build` script: untracked `js/` and `css/` files are deleted, `npm ci && npm run
     build` runs, and `js/` or `css/` must contain files, else the step fails naming the app (an app that
     builds elsewhere needs a recipe);
   - `node_modules` is deleted afterwards.
   `npm ci` runs lifecycle scripts for the apps (vue-demi's `postinstall` is needed by text, viewer and photos; see the table
   at the end). Tracked files are never deleted, so handwritten files in `js/` or `css/` survive, but an app with committed
   `js/` or `css/` and no build script needs a recipe.
6. `ionos-build-assemble.sh`: a CLEAN tree in `$WORK/tree` (the tool loads it all into memory), done as
   upstream's release build does (`nextcloud-releases/server`, `.github/scripts`): copy without `.git`,
   `node_modules`, `IONOS`; `3rdparty` without `.git .github .gitignore README.md`; remove what the root
   `.nextcloudignore` lists (`git ls-files -cio --exclude-from`, gitignore semantics) and what each built
   app's own `.nextcloudignore` lists (keeping `composer.json/lock`, `package.json/-lock.json`); drop
   `*.map.license`; remove `config/config.php`, `data/` and empty folders. A symbolic link to a regular file
   inside the tree (for example the `*.js.license` links of built apps) is replaced by a copy of the file, as zip does
   for the official archive; any other symbolic link (broken, to a folder, or pointing outside the tree) fails the step.
7. `ionos-build-package.sh`: per flavor, a pins file `{app: {commit, describe}}` for the flavor's built
   submodule apps (`git submodule status` must show the pinned commit; `describe` is `git describe --tags
   --always` after a blobless unshallow fetch), then `ncw build --kind dev --build-number <run number>
   --line <nn> --server-commit <HEAD> --flavors-commit <IONOS sha> --app-pins <file> --cache-keys <file>` (the key and
   checksum of each of the flavor's USED app builds, see "Cache"), then `ncw validate --artifact`, then `<zip>.sha256`. A failing flavor
   leaves no archive; the other flavors still run, all failures are reported at the end and the step fails.
   `$WORK/validated` is written only when every flavor passed.
7a. `actions/cache/save` (in the file right after step 5; only when `ionos-build-apps.sh` asked for it), see "Cache".
8. Upload of the artifact (`actions/upload-artifact`), only reached when everything above passed.

**`smoke`** (needs `plan` and `build`; permissions `contents: read` only): see "Fresh-install smoke test" below.

**`publish`** (needs `plan`, `build` and `smoke`; permissions `contents: write`, `id-token: write`,
`attestations: write`; runs no npm, no composer and no app code: it checks out only `.github/ionos`):

1. Download the artifact (`actions/download-artifact`).
2. `ionos-build-publish.sh --check`: the gate. Refuses unless `validated` equals the flavor list, every
   flavor has an archive, every archive matches its checksum, the scope is `all` or `subset`, and the
   release for the tag does not exist yet. Nothing is attested before it passes.
3. `actions/attest-build-provenance` on the zips; the bundle is attached to the release as
   `ncw-build-<n>.attestation.jsonl`. Check with `gh attestation verify <zip> -R <repo>`.
4. `ionos-build-publish.sh`: (dev builds; for release builds see below) runs the gate again, then one `gh release create` with the default token: tag
   `dev-v<base release>.<build number>` on the built commit (`--target <sha>`, for example
   `dev-v33.0.9.42`), `--prerelease`, title `Dev build <n> (v<base> base)`, assets every zip, its `.sha256`
   and the attestation bundle. The body has machine-readable lines (`server_commit:`, `flavors_commit:`,
   `build_number:`, `base_release:`, `flavors_scope:`, `flavors:`), the flavor list and a link to the run.
   An existing release for the tag (a re-run of a finished run keeps its number) fails and touches nothing.
5. `ionos-build-retain.sh`, a separate step, only for dev builds (`if: needs.plan.outputs.kind == 'dev'`): keeps the newest 14 dev pre-releases (`KEEP`, default 14) and
   deletes older ones with `gh release delete --cleanup-tag --yes`. Only published pre-releases whose tag is
   exactly `dev-v<a>.<b>.<c>.<n>` are considered; anything else is never touched. Deletions are logged.
   `DRY_RUN=true` only prints.

The default `GITHUB_TOKEN` is enough: the tag points at an existing commit and no workflow file is
pushed. All actions are GitHub's own and pinned to a commit SHA.

## Release builds

A release build is the same workflow file with `kind` release, started by `ionos-snapshot.yml` right after it
created the snapshot (`gh workflow run ionos-build.yml --ref rc/ncw-v<nn>-<n> -f kind=release`; a
`workflow_dispatch` is allowed with the default token) or by a person for a REBUILD of the same snapshot
(Actions, Run workflow, branch `rc/ncw-v33-1`, kind release; or the same `gh` command). How to cut a release: `ionos-snapshot.md`.

**Where it may run.** `ionos-build-plan.sh` accepts `kind` release only for a manual run on a BRANCH named
`rc/ncw-v<nn>-<n>` (a rehearsal: `rehearsal/ncw-v<nn>-<n>`), with an empty `flavors` input and no `force`; any other
ref (the dev branch, a tag, a candidate) is refused, and `kind` dev is refused on a snapshot branch. The rehearsal flag is
derived from the ref prefix and is not an input.

**Where the facts come from.** The plan job reads the ANNOTATED tag of the snapshot (`read_snapshot_tag` in `ionos-lib.sh`,
through the API: `git/matching-refs/tags/ncw-v<nn>.` filtered to `ncw-v<nn>.<x>.<y>-<n>`, then `git/tags/<sha>`). It refuses unless
exactly one such tag exists, it is annotated (a lightweight tag cannot carry the scope), it points at the commit the run built,
and its annotation agrees with the branch name (release number, line, snapshot branch, rehearsal flag; the tag name carries the
annotation's base release). From the annotation it takes release number, snapshot branch, base release, scope, source branch
and source commit, and hands them to the other jobs as job outputs (which reach scripts only through `env:`). The scope is
therefore never an input of the build and cannot drift from the tag. A tag cannot be moved or deleted once the settings
wizard's ruleset is on, so every rebuild reads the same annotation.

**Build.** `ionos-build-package.sh` runs `ncw build --kind release --snapshot-branch <branch> --release-number <n> --scope <text>`, which
puts kind, snapshot branch, release number and scope into `version.json` (spec 04). It first checks that the base release of
the built tree is the one in the tag name. A release build never skips because nothing changed and prunes nothing. The build
number is the run number, as for dev builds. The smoke job runs unchanged and blocks publishing.
A release build uses the app build cache like a dev build (a release rebuilt from the same snapshot reuses the same trees); `version.json`
records the key and checksum of every used app build (`cached_builds`), reused or fresh. `no_cache` makes it fully clean (see "Cache").

**Publish** (`ionos-build-release.sh`, sourced by `ionos-build-publish.sh` when `KIND=release`; the gate before it is the same):

- A GitHub release on the EXISTING snapshot tag: `gh release create <tag> --verify-tag --latest=false` (no `--target`, so the
  tag is never created and a missing tag is an error), not a pre-release, title = the tag name (`ncw-v33.0.9-1`). `--latest=false` is
  deliberate: which release is live is a decision of the deployment, not of GitHub's "latest" badge.
- Body: the scope (quoted), release number, line and base release, snapshot branch and tag with the source branch and commit,
  the table of EVERY archive of the release (flavor, file with download link, build number, sha256; newest build first), how to
  verify (`sha256sum -c`, `gh attestation verify <archive> -R <repo>`), then machine-readable lines (`release_nr`,
  `base_release`, `snapshot_branch`, `snapshot_tag`, `source_*`, `server_commit`, `flavors_commit`, `scope`, `latest_build_number`).
- Assets: every zip, its `.sha256` and the attestation bundle `ncw-build-<n>.attestation.jsonl`.
- A rebuild (a new run on the same branch, a new run number): the release exists, so the new assets are attached with
  `gh release upload` WITHOUT `--clobber` and the body is rewritten with `gh release edit`. The table is rebuilt from the
  `.sha256` assets of the release (downloaded) plus the new ones, not from the old body, so no row is lost. Before anything
  is attached the build number must be strictly larger than every build number already attached (archives, checksums and
  attestation bundles count), else the run fails: assets are never replaced or deleted, and a re-run of a finished run (same
  number) is refused. If the upload fails the body is not touched; if only the body update fails, the assets are attached
  and the error says so (edit the notes by hand; the next rebuild rewrites the table anyway). `ionos-build-publish.sh --check`
  (before the attestation) applies the same rule.
- A rehearsal (`rehearsal/` branch) publishes a PRE-release titled "... (rehearsal, not a release)" with a warning on top, so it can
  never be taken for the production channel. Everything else is the same code path.

Dev behavior is unchanged (dev tags, pre-release, retention).

## Fresh-install smoke test

Job `smoke` sits between `build` and `publish`; `publish` needs it, so any failure of the smoke test means nothing
is attested or published. It checks out only `.github/ionos` and `IONOS` (the pinned flavors repository), sets up Node 24 and
runs `npm ci --ignore-scripts` in `IONOS/tools` (as `build` does), downloads the `ionos-build` artifact and runs
`ionos-smoke-run.sh`. No third-party action is used; PHP, `unzip`, `zip`, `curl` and `jq` come from the runner image.
The logic is in `ionos-smoke-*.sh`, tested by `bash .github/ionos/ionos-smoke.test.sh` (a mock server, stubs and
fixtures; no Nextcloud tree, no network).

For every archive in `out/`:

1. `ncw resolve --flavors IONOS --flavor <name>` gives the RESOLVED flavor (the name comes from the archive name and
   must equal `version.json`'s `flavor`). There is no per-flavor test code: every expectation comes from it.
2. The archive is unpacked into a fresh empty folder (it is untrusted: paths are passed as arguments, and the only
   code run from the tree is `php occ`, `php cron.php` and the web server serving it).
3. Variables the flavor declares (`env:` of the resolved output): a required one gets the test value
   `smoke-test-value-<name>`, an optional one its declared default.
4. `php occ maintenance:install --database sqlite` with a test admin, as the deployment contract says.
5. The deployment's next step: `bash ncw-configure.sh`, the script the flavors tool generated into the archive (run in
   the tree with `PHP` set; it fills the `${VAR}` placeholders of `app-config.json` from the environment, runs
   `occ config:import`, sets `app-config-special.json` with `occ config:app:set`, and enables the apps of the flavor's
   `enable_after_install` with `occ app:enable`). An archive without the script fails before the install. The smoke
   test has no configuration code of its own.
6. `php -S 127.0.0.1:<port> -t <tree>` (4 workers, no router: the probes use `index.php`, `remote.php` and `ocs/v2.php`
   paths), then `ionos-smoke-probes.sh`: `status.php`, login page, OCS capabilities (basic auth, `OCS-APIRequest`), WebDAV
   PROPFIND, PUT and GET with a content compare, a session through the login form (cookie jar, request token and an
   `Origin` header, which Nextcloud requires) and with it the files page, admin settings and admin overview. All probes run;
   each failure is named.
7. `php cron.php` and `occ files:scan --all`.
8. `occ app:list --output=json_pretty` against the resolved flavor (`ionos-smoke-apps.sh`): `always` and `default` apps
   enabled, `available` apps present and disabled, except the ones in `enable_after_install` (listed by `ncw resolve`),
   which must be enabled, `removed` apps absent, and an app the flavor does not list is an error. Each problem names the
   app and the mode. How apps get enabled: `occ maintenance:install` itself installs and enables every app listed in
   `alwaysEnabled` or `defaultEnabled` of `core/shipped.json`, in any app folder, including added apps that are not in
   `shippedApps`. An app the installer cannot enable (groupfolders: its migration needs the app loaded) is `available`
   and listed in `enable_after_install`, and `ncw-configure.sh` enables it. The smoke test runs no `occ app:enable`
   itself: it would hide a wrong `shipped.json`.
9. `data/nextcloud.log` (`ionos-smoke-logs.sh`): fails on every entry at level 3 (error) or higher whose message does not match
   `ionos-smoke-log-allowlist.txt`, on a line that is not JSON, and ALWAYS on a `Disabled incompatible app` line (at any
   level, whatever the allow-list says).

The run needs these PHP extensions and says which is missing before it installs: ctype, curl, dom, fileinfo, filter, gd,
hash, iconv, libxml, mbstring, openssl, pdo_sqlite, posix, session, SimpleXML, XMLReader, XMLWriter, zip, zlib. The
`ubuntu-latest` image (24.04) has PHP 8.3.6 from the Ubuntu packages, installed with php-curl, gd, mbstring, sqlite3, xml, zip, intl, gmp,
bcmath, apcu and others (`images/ubuntu/scripts/build/install-php.sh` of `actions/runner-images`); it also has `unzip`, `zip`,
`curl` and `jq`.

### The allow-list

`ionos-smoke-log-allowlist.txt` has one extended regular expression (`grep -E`) per line, matched against the log
message; blank lines and `#` lines are ignored. EVERY entry needs a comment above it that names the message, where it
comes from and why it is harmless. A blank entry or an invalid expression fails the check. Keep it short; it starts empty
(a clean fresh install logs nothing at error level). Add an entry only after reading the entry in the kept log.

### Reading the logs

The artifact `ionos-smoke-logs` of the run (kept 14 days, also after a failure) has one folder per flavor: `resolved.yaml`,
`install.log`, `configure.log`, `php-server.log` (web server access and error log), `probes.log` and `probes/` (every
answer), `cron.log`, `scan.log`, `app-list.json`, `apps.log`, `nextcloud.log` (the JSON lines) and `logs.log` (the verdict).
Start with the `::error::` lines of the job; they name the app or the log entry. Open `nextcloud.log` with
`jq -r 'select(.level >= 3) | [.level, .app, .message] | @tsv'`.

### Proving the gate (`smoke_break`)

A manual run of `IONOS build` with input `smoke_break` set to one of these tampers with the archives the smoke job downloaded
(`ionos-smoke-break.sh`; the publish job downloads its own untouched copy), and the smoke test must fail, which skips `publish`:

| Value | What it does | Expected message |
| --- | --- | --- |
| `missing-app` | deletes the folder of one app that a fresh install enables (the last `defaultEnabled` app that has a folder) | `app '<id>' has mode default but is not in the app list` |
| `extra-app` | adds a valid app folder `apps/ionos_smoke_extra` | `app 'ionos_smoke_extra' is disabled but is not in the resolved flavor` |
| `wrong-mode` | takes one `defaultEnabled` app out of `core/shipped.json` | `app '<id>' has mode default and must be enabled ... but it is disabled` |
| `skip-enable` | empties the `ENABLE_APPS` list of the archive's `ncw-configure.sh` (needs a flavor with `enable_after_install`) | `app '<id>' has mode available and is listed in enable_after_install: it must be enabled ...` |

If the smoke test passes with a break, the run fails with "did not catch the break" (so a gate that proves nothing is a
failure too). Scheduled runs have no such input and always use `none`; the tamper step also only runs for `workflow_dispatch`.
Combine with `flavors` to keep the proof short. A run with a break must show: smoke failed, publish skipped, no release.

### What the first runs on dev-v33.0.9.5 showed

Run on the published archive `ncw-flavor1-v33.0.9.5.zip` (server commit 9538551), the smoke test failed at the install, so
the gate did what it is for. Two real defects were found by reading the install output:

- `calendar` and `contacts` had no `vendor/autoload.php` (their `composer/autoload.php` requires it), because the app
  build skipped composer when `composer.json` had no runtime packages. Fixed: composer now always runs (see the default recipe).
- `groupfolders` was `default` in flavor1, so `occ maintenance:install` installed it, and its migration needs a service
  that the app registers when it is loaded (`IUserMappingManager`, bound in `Application::register`); the install died with
  "Could not resolve OCA\\GroupFolders\\ACL\\UserMapping\\IUserMappingManager". `occ app:enable groupfolders` on an installed
  instance works. Decision: groupfolders is `available` plus `enable_after_install: [groupfolders]` in the flavor, and
  `ncw-configure.sh` enables it. This needs the flavors commits that add the field and the script (pin bump).

## Cache

Built apps are kept in the GitHub Actions cache; the server build is not cached (accepted). The key is portable:
it is a sha256 of facts about the build and nothing about the runner, so moving the cache to JFrog later changes
no key and no artifact. Code: `ionos-cache-lib.sh` (key, checksum, folder key), `ionos-build-apps.sh` (reuse and
store), `ionos-cache-check*.sh` (the weekly job).

**Layout.** ONE folder (`$RUNNER_TEMP/ionos-app-cache`), because `actions/cache` takes one key and one path per
step and the steps of a workflow are static:

```
<cache>/<app id>/tree         the built app folder without .git (every recipe deletes node_modules)
<cache>/<app id>/meta.json    key, checksum, app_commit, node, php, composer, recipe_hash
```

**Per-app key.** `sha256` over a fixed text: the key rules version, the app id, the app's commit (the gitlink of the
checked-out commit, `git rev-parse HEAD:<path>`), the sha256 of the recipe in effect, the Node version (`node --version`),
the PHP version (`PHP_VERSION`) and the Composer MAJOR version. The recipe in effect is the file
`build-recipes/<app id>.sh` when there is one, else `ionos-build-default-recipe.sh` (the default recipe and the
version of its rules, `RECIPE_RULES_VERSION`; any edit of that file, even a comment, gives every default-recipe app a new key
once). The npm version is not in the key (it follows Node). A key never contains a run id, a path or a runner name.

**Checksum.** `sha256` over the sorted list of every file of the app tree with the sha256 of its content, plus every
symbolic link with its target (links are never followed), as paths relative to the app folder. Left out: the top-level
`.git`, and timestamps, owners, modes and empty folders (they are not content). Nothing else is ignored (see the
reproducibility measurement below for why no pattern is needed).

**Restore and reuse (`build` job).** `actions/cache/restore` (skipped for `no_cache`) restores the newest folder by the
prefix `ionos-app-build-v1-` (`restore-keys`; the `key` of the step matches nothing on purpose). `ionos-build-apps.sh` always
initialises the app's submodule (the assembly and the pins need the git checkout), computes the key, and reuses the app only when
the cache holds an entry with EXACTLY that key and the tree still has the checksum of its `meta.json`; then the tree is copied over the
app folder (`rsync --delete`, never `.git`). Everything else is built by the recipe, and the entry is replaced. Reasons for a rebuild are
logged (`<app>: not reused: ...`: not in the cache, other key, no or unreadable `meta.json`, no tree, a tree that does not match its checksum).
A restored cache is untrusted input like any build output: it only supplies app trees, which the assembly and the flavors tool's static checks
then treat like freshly built ones, nothing in it is ever executed, links and odd entries are not followed, and a mismatch means rebuild.
The checksum detects damage and stale or mixed content; it is not a signature, so what protects the cache is who may write it: only this
workflow's `build` job (dev branch, snapshot branch, scheduled and manual runs; no pull request), and GitHub scopes a cache to its branch.

**Save.** `ionos-build-apps.sh` writes `cache_save=true` and `cache_key` to the step output when an app was built or an entry dropped
(an app that is no pinned app of any `apps-*` folder any more; an app that is pinned but not part of this run, for instance with the
`flavors` input, stays). The step `actions/cache/save` runs only then, under `ionos-app-build-v1-<sha256 of the sorted "<app> <key>" lines>`.
An already existing key is fine: the action only logs that it could not reserve it, and the step is `continue-on-error`, so a failed save never
fails a build. A run that reused everything saves nothing. Caches are immutable, so a damaged entry is not repaired by saving under the same
key: it is rebuilt in every run until an app key changes; delete the cache in the Actions UI to start clean.

**`version.json`.** `ionos-build-apps.sh` writes `$WORK/app-builds.json` (`{"<app>": {"key", "checksum"}}` of every USED build, reused or built
fresh), and `ionos-build-package.sh` passes each flavor's apps from it as `ncw build --cache-keys <file>`; they end up in `cached_builds`.
An app of the flavor without a recorded build fails the flavor. Release builds use the cache like dev builds, and say so the same way.

**`no_cache`** (manual runs only, boolean, default false): the restore step is skipped, nothing in the folder is read or reused, every app is built, and
NOTHING IS SAVED (a clean run must not replace what other runs use; an equal key could not be overwritten anyway). The used keys and checksums are
still recorded in `cached_builds`. Use it for a fully clean release build or to see whether the cache drifted.

**Weekly job** (`ionos-app-cache-check.yml`, Mondays 03:23 UTC and manual): job `check` (`contents: read`) restores the same folder, then
`ionos-cache-check.sh` takes every pinned app of every `apps-*` folder (not only what a flavor selects), skips the ones that are not in the cache or are
cached under another key (other commit, recipe, Node or PHP: nothing to compare, nothing is rebuilt for them), rebuilds the rest WITHOUT the cache with
the same script (`ionos-build-apps.sh`, `NO_CACHE=true`) and compares each rebuilt checksum with the cached one of the same key. It never writes the cache.
For every app whose checksum differs (known or not) it also lists WHICH FILES differ between the restored cache tree and the tree just rebuilt: at most 30 paths per app, marked `changed`, `only in cache` or `only in rebuild`, with both sizes, using the checksum's normalization (ignored patterns do not show; `cache_tree_diff` in `ionos-cache-lib.sh`). The list is in the job log, the summary and the issue body or comment (cut at 50000 bytes). It writes `report.md` (also in the job summary) and the output `mismatch`. If nothing was compared (empty cache, or all keys changed) it warns. A build
failure fails the job. Job `report` (`contents: read`, `issues: write`, runs no app code, only the report as a workflow artifact) runs
`ionos-cache-check-issue.sh` only on a mismatch: ONE issue titled `IONOS app cache check: rebuilt apps differ from the cache`; when an open issue
with that title exists a comment is added instead, so reruns do not spam. No mismatch: no issue. The cache lives on the branch the build runs on,
so the weekly job sees the cache of the default branch (see the note in the workflows).

### Reproducibility of the app builds (measured)

Before the weekly comparison was built, all 27 pinned apps (22 of `apps-upstream/`, 5 of `apps-flavor1/`, the pins of commit
99c442a) were built twice, in new folders, from shallow clones of the pinned commits, with the real `ionos-build-apps.sh`, real npm and
composer, Node 24.21, PHP 8.3.6, Composer 2.7.1, 4 apps at a time, and the checksum of each tree was compared. Result with the plain checksum
(every file): 24 of 27 apps identical, 3 different. With the two documented ignore patterns (`CACHE_CHECKSUM_IGNORE` in `ionos-cache-lib.sh`): 26
identical, 1 different.

| App | What differs between two builds | Handling |
| --- | --- | --- |
| app_api | only `js/app_api-adminSettings.js.map` (the `mappings` string); the js is identical | `*.map` is ignored by the checksum (source maps are debugging aids, never loaded by the server) |
| text | `webpack-stats.json` at the app root (untracked build report, shipped): `builtAt` is the build time, the asset order differs | the root `webpack-stats.json` is ignored by the checksum |
| calendar | `js/calendar-contacts-menu.js` and `js/calendar-reference.js` (and so their maps): webpack/terser names identifiers differently (`e3` against `e9`) | cannot be normalized: listed in `ionos-cache-check-known.txt`. Measured on 5 builds: 5 different checksums. The weekly job still compares it, but a difference is only reported as "known to differ" and opens no issue |
| text (on the runner) | 39 files in the weekly run on GitHub (node v24.22.3, php 8.5.4): the content-hashed chunk names of the vite/rollup build change (`js/Editor-DJgbMEjd.chunk.mjs` against `js/Editor-BdXZ3brt.chunk.mjs`, a 7 byte difference in the main editor chunk, css chunks even swap the parent name: `css/MarkdownContentEditor-Bbu87U1y.chunk.css` against `css/RichTextReader-Bbu87U1y.chunk.css`) and other files reference the hashed names | cannot be normalized by an ignore pattern: listed in `ionos-cache-check-known.txt`. Locally two builds were identical once `webpack-stats.json` is ignored (the row above), so it depends on toolchain or timing and differs on the runner. Measured by the weekly run, reported as "known to differ", no issue |
| related_resources | no difference, but the build FAILED without a recipe: it commits its built `js/`, webpack does not rewrite an unchanged file, so the default recipe's "the build wrote a new file" check failed | new recipe `build-recipes/related_resources.sh` (deletes the committed built `js/` first, which also drops stale chunk names); 3 builds with it: identical |

Everything else (23 apps) is bit-reproducible, also the apps with `*.map.license` links. Not part of the checksum, because they are not content: timestamps, owners,
modes and empty folders. A cached app that was built on another day therefore has the same checksum as a rebuild, which is what makes the weekly
comparison meaningful. One pass takes about 10 minutes at 4 apps in parallel; the built trees together are about 730 MB uncompressed (calendar and
password_policy about 115 MB each), so the cache folder is large: GitHub evicts a cache after 7 days without a hit, the weekly job keeps it alive.

## Differences from upstream's release build

- Not signed (no code signing, no GPG), no metadata file, no tar.bz2.
- Upstream installs the minimum PHP of the server (8.2) with a third-party setup action so that composer's
  generated platform check is identical to a release; here PHP and Composer come from the runner image
  (no third-party action).
- Upstream adds the web updater, `example-files` (`core/skeleton`) and the docs; here the tool drops the
  updater, and the skeleton and docs stay as in the fork.
- Upstream's central `dev-files.txt` list is not applied; the tool's dev file strip and `validate` cover
  `.git*`, `node_modules`, app tests and the like.

## Apps that need attention (local build of all 27 pinned apps, Node 24, PHP 8.3, Composer 2.7)

All 22 apps of `apps-upstream/` and the 5 of `apps-flavor1/` were built from their pins with the real
`ionos-build-apps.sh`, real npm and composer, 4 at a time. Only these needed something:

| App | Problem | Handling |
| --- | --- | --- |
| serverinfo, survey_client | handwritten tracked `js/` and `css/`, no `package.json`, no runtime packages | no-op recipe (`build-recipes/<app>.sh`) |
| text, viewer, photos, privacy, files_pdfviewer, recommendations | `npm ci --ignore-scripts` breaks the build (vue-demi's postinstall) | default recipe runs `npm ci` with scripts |
| password_policy | composer `post-install-cmd` runs `composer bin all install` (dev tooling) and fails | composer runs with `--no-scripts` |
| calendar, groupfolders, notes, tasks | composer requires only php or the bin plugin; tracked handwritten `css/` | no recipe: composer runs with `--no-scripts` (the autoloader is needed even without packages), tracked files are never deleted |
| files_downloadlimit | tracked `css/public.css` is a build input | tracked files are never deleted |
| related_resources | commits its built `js/` (partly stale); a faithful rebuild rewrites nothing, so the default recipe's marker check fails (found by the reproducibility measurement above) | recipe `build-recipes/related_resources.sh` |

`engines` warnings (EBADENGINE, for example Node ^22 in some apps) are warnings only; no app broke on Node 24.
What a local run cannot show: the runner's PHP is also 8.3, but its Composer version may differ.

## Tokens

The `plan` and `publish` jobs only use the default `GITHUB_TOKEN` and only call this repository's API (a release build's plan
job reads refs and tag objects with it; the snapshot workflow, not this one, uses `IONOS_SYNC_TOKEN`). The
build never uses the sync token and never reads `nextcloud/*` through the API, so the `nextcloud`
organization's rule against fine-grained tokens with a lifetime over 366 days does not touch it (see
`ionos-app-pins.md`). Submodules are fetched over git without credentials.

## Open items

- The design says an app recipe override is a `build:` entry in the flavor manifest. The tool does not
  parse it yet, so `.github/ionos/build-recipes/<app>.sh` is the interim place.
- `flavor1` takes five apps from the app folder `apps-flavor1/` (submodules, see `ionos-flavor-apps.md`); four of them
  have a recipe in `build-recipes/`. Recipes should use `$NPM` and `$COMPOSER` (set by the tests; unset means the plain commands)
  instead of plain `npm` and `composer`, so the tests can stub them.
- The server build is not cached (accepted). The cache of the apps is the Actions cache for now; moving it to JFrog later changes
  no key and no artifact (see "Cache").
- The tool loads the whole tree: about 1.5 GB of memory and 35 s per flavor on the official tree.
