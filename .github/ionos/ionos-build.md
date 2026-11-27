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
`flavors` (comma separated, default every folder of `IONOS/flavors`), `force` and `smoke_break` (see the smoke test below). Scheduled and manual
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
   `*.map.license`; remove `config/config.php`, `data/` and empty folders. A symbolic link to a regular file
   inside the tree (for example the `*.js.license` links of built apps) is replaced by a copy of the file, as zip does
   for the official archive; any other symbolic link (broken, to a folder, or pointing outside the tree) fails the step.
7. `ionos-build-package.sh`: per flavor, a pins file `{app: {commit, describe}}` for the flavor's built
   submodule apps (`git submodule status` must show the pinned commit; `describe` is `git describe --tags
   --always` after a blobless unshallow fetch), then `ncw build --kind dev --build-number <run number>
   --line <nn> --server-commit <HEAD> --flavors-commit <IONOS sha> --app-pins <file>` (no `--cache-keys`:
   the cache is a later ticket), then `ncw validate --artifact`, then `<zip>.sha256`. A failing flavor
   leaves no archive; the other flavors still run, all failures are reported at the end and the step fails.
   `$WORK/validated` is written only when every flavor passed.
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
5. The deployment's next step, `ionos-smoke-appconfig.sh`: `${VAR}` placeholders of `app-config.json` are filled from the
   environment (a missing one fails), then `occ config:import`; each entry of `app-config-special.json` is set with
   `occ config:app:set --value ... [--type] [--lazy] [--sensitive]`.
6. `php -S 127.0.0.1:<port> -t <tree>` (4 workers, no router: the probes use `index.php`, `remote.php` and `ocs/v2.php`
   paths), then `ionos-smoke-probes.sh`: `status.php`, login page, OCS capabilities (basic auth, `OCS-APIRequest`), WebDAV
   PROPFIND, PUT and GET with a content compare, a session through the login form (cookie jar, request token and an
   `Origin` header, which Nextcloud requires) and with it the files page, admin settings and admin overview. All probes run;
   each failure is named.
7. `php cron.php` and `occ files:scan --all`.
8. `occ app:list --output=json_pretty` against the resolved flavor (`ionos-smoke-apps.sh`): `always` and `default` apps
   enabled, `available` apps present and disabled, `removed` apps absent, and an app the flavor does not list is an error.
   Each problem names the app and the mode. How `default` apps get enabled: nothing extra is done. `occ maintenance:install`
   itself installs and enables every app listed in `alwaysEnabled` or `defaultEnabled` of `core/shipped.json`, in any app
   folder, including added apps that are not in `shippedApps` (the spec says `default` means "enabled at install"). The smoke
   test deliberately runs no `occ app:enable`: it would hide a wrong `shipped.json`.
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
`install.log`, `appconfig.log`, `php-server.log` (web server access and error log), `probes.log` and `probes/` (every
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

If the smoke test passes with a break, the run fails with "did not catch the break" (so a gate that proves nothing is a
failure too). Scheduled runs have no such input and always use `none`; the tamper step also only runs for `workflow_dispatch`.
Combine with `flavors` to keep the proof short. A run with a break must show: smoke failed, publish skipped, no release.

### What the first runs on dev-v33.0.9.5 showed

Run on the published archive `ncw-flavor1-v33.0.9.5.zip` (server commit 9538551), the smoke test FAILS at the install, so
the gate does what it is for. Two real defects, both found by reading the install output:

- `calendar` and `contacts` have no `vendor/autoload.php` (their `composer/autoload.php` requires it), because the app
  build skips composer when `composer.json` has no runtime packages. `occ maintenance:install` dies with "Failed opening
  required .../vendor/autoload.php". Composer must run for these apps (the autoloader is needed even without packages).
- `groupfolders` is `default` in flavor1, so `occ maintenance:install` installs it, and its migration needs a service
  that the app registers when it is loaded (`IUserMappingManager`, bound in `Application::register`); the install dies with
  "Could not resolve OCA\GroupFolders\ACL\UserMapping\IUserMappingManager". `occ app:enable groupfolders` on an installed
  instance works. So a fresh install cannot enable groupfolders at install time; until that is decided in the flavors
  repository (for example mode `available` plus an explicit enable step in the deployment), the smoke test of flavor1 stays red.

With those two repaired in a local copy (vendor folders added, groupfolders `available` in a copy of the flavors folder) the
smoke test passes on the real archive, and the three `smoke_break` modes each fail it.

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
| calendar, groupfolders, notes, tasks | composer requires only php or the bin plugin; tracked handwritten `css/` | no recipe any more: composer is skipped without runtime packages, tracked files are never deleted |
| files_downloadlimit, related_resources | tracked `css/public.css` is a build input; related_resources commits its built `js/` | tracked files are never deleted; the rebuild rewrites changed files, which is what the marker check sees |

`engines` warnings (EBADENGINE, for example Node ^22 in some apps) are warnings only; no app broke on Node 24.
What a local run cannot show: the runner's PHP is also 8.3, but its Composer version may differ.

## Tokens

The `plan` and `publish` jobs only use the default `GITHUB_TOKEN` and only call this repository's API. The
build never uses the sync token and never reads `nextcloud/*` through the API, so the `nextcloud`
organization's rule against fine-grained tokens with a lifetime over 366 days does not touch it (see
`ionos-app-pins.md`). Submodules are fetched over git without credentials.

## Open items

- The design says an app recipe override is a `build:` entry in the flavor manifest. The tool does not
  parse it yet, so `.github/ionos/build-recipes/<app>.sh` is the interim place.
- `flavor1` takes five apps from the app folder `apps-flavor1/` (submodules, see `ionos-flavor-apps.md`); four of them
  have a recipe in `build-recipes/`. Recipes should use `$NPM` and `$COMPOSER` (set by the tests; unset means the plain commands)
  instead of plain `npm` and `composer`, so the tests can stub them.
- No cache (own ticket): server and apps are built on every run.
- The tool loads the whole tree: about 1.5 GB of memory and 35 s per flavor on the official tree.
