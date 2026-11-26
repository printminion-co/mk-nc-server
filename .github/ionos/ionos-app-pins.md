# Upstream app pins (line 33)

The official Nextcloud release archive (`nextcloud-33.0.9.zip`) contains 53 apps in `apps/`.
Not all of them live in the server repository. This fork keeps the server's own `apps/`
directory untouched and adds the others as git submodules under `apps-upstream/`, pinned to
the commit upstream shipped.

This page is a snapshot for `v33.0.9`. The gitlinks in the tree are authoritative
(`git submodule status`); the helper described below changes only those, not this page.

## Bundled in the tree (`apps/`, 30 shipped apps plus `testing`)

These come with the server sources and need no pin:

`admin_audit`, `cloud_federation_api`, `comments`, `contactsinteraction`, `dashboard`, `dav`, `encryption`, `federatedfilesharing`, `federation`, `files`, `files_external`, `files_reminders`, `files_sharing`, `files_trashbin`, `files_versions`, `lookup_server_connector`, `oauth2`, `profile`, `provisioning_api`, `settings`, `sharebymail`, `systemtags`, `theming`, `twofactor_backupcodes`, `updatenotification`, `user_ldap`, `user_status`, `weather_status`, `webhook_listeners`, `workflowengine`

`testing` is in the tree but is not part of the release archive (it is a test fixture app).

## Separately hosted (`apps-upstream/`, 23 apps)

Upstream lists these in `stable33.json` of the repository `nextcloud-releases/server`
(23 entries); its release tooling fetches each from its own repository when it builds the
archive. 22 are submodules here:

| App | Repository | Pinned commit (tag `v33.0.9`) |
| --- | --- | --- |
| `activity` | `nextcloud/activity` | `6f4bc73cb1ef14a1637761496212309270546146` |
| `app_api` | `nextcloud/app_api` | `ae172e794bd0353dfafbb5bd937b7c47b1ce06f2` |
| `bruteforcesettings` | `nextcloud/bruteforcesettings` | `5f6f2bc0e0eb9141fcb269d139b6ba4f5b31195c` |
| `circles` | `nextcloud/circles` | `858950ccb3f9842a4d652e0dc8135bacea8f4582` |
| `files_downloadlimit` | `nextcloud/files_downloadlimit` | `18850af238687fcfd06a19356e9845b879eb2428` |
| `files_pdfviewer` | `nextcloud/files_pdfviewer` | `5ff0a99125ab2b7010d5c2f576299b94852de3e0` |
| `firstrunwizard` | `nextcloud/firstrunwizard` | `e774aff4d2865046576472e95fc3c8881f72ee33` |
| `logreader` | `nextcloud/logreader` | `4382e6a2d3d6256241da8b4f523a5d9a7c7eacc8` |
| `nextcloud_announcements` | `nextcloud/nextcloud_announcements` | `8fe77e1cf8f97015d205f1b4fe2ee041ab4f49ce` |
| `notifications` | `nextcloud/notifications` | `ad87ab52010666ce996f4741aa59744a4ffe686a` |
| `password_policy` | `nextcloud/password_policy` | `3437846bcd713275c49caeff57b356d237da0959` |
| `photos` | `nextcloud/photos` | `178d1ce025b8a5e4c0f1fec1a62132bc0db2d906` |
| `privacy` | `nextcloud/privacy` | `929300fa6adc1611ee6e6dc2a01222281c31f2f3` |
| `recommendations` | `nextcloud/recommendations` | `0def67bd97f4bab02a5cfa4b4030afc8524bd342` |
| `related_resources` | `nextcloud/related_resources` | `5fb328c8c7550ee1f43f44de9161b1ef214dfb71` |
| `serverinfo` | `nextcloud/serverinfo` | `cae33d6a22484ec897675a83b25801c4fff81d01` |
| `survey_client` | `nextcloud/survey_client` | `ca4001806036dbc2c28793a70f2fa852405699a6` |
| `suspicious_login` | `nextcloud/suspicious_login` | `15b421454a41c925bffa62efaa4eee2e1fee29ea` |
| `text` | `nextcloud/text` | `afc021faa7b96fee2aa0827e2becdd937edede07` |
| `twofactor_nextcloud_notification` | `nextcloud/twofactor_nextcloud_notification` | `bc3c8b0094253f3c78fadd51dcd950817645a230` |
| `twofactor_totp` | `nextcloud/twofactor_totp` | `f0dcf04e3bf99c001f899719bee6ad50d83c7392` |
| `viewer` | `nextcloud/viewer` | `1f3282140385b10a0340ed872dddd8ced88a6ef5` |

Not pinned: `support` is listed upstream with the repository `nextcloud-gmbh/support`, which is
not publicly readable (GitHub answers 404). The archive ships it (version 5.0.0 in
`apps/support/appinfo/info.xml`), but there is no public URL to use as a submodule and no
commit could be looked up. It is the one entry that is separately hosted but not pinned.
The helper skips any listed app whose repository is not under `nextcloud/`.

A flavor that wants `support` must provide its own public fork of it and add that as a
submodule with a different name in an app folder of its own (not `apps-upstream/`, which
the helper owns and prunes), or go without the app.

## Rule used to pick the pin

1. Take the app list from `stable33.json` in `nextcloud-releases/server` (default branch).
   The file has 23 entries and was last changed on 2026-06-02, before the 33.0.9 release
   (2026-09-10), so the current content is the content used for 33.0.9.
2. Drop every app whose directory exists in this fork's `apps/` at the base branch.
3. For each remaining app, pin the commit the tag equal to the release tag (`v33.0.9`)
   points at in the app's own repository. Upstream's tag workflow (`release-tag.yml`) creates
   that tag in every listed repository, and its build workflow (`release-build.yml`) checks
   each app out at exactly that ref. All 22 tags are lightweight tags that point at a commit.
4. The list contains no branch names and no version ranges: each entry has only `id`, `repo`
   and optionally `composer_args`. The tag is derived from the release, not read from the file.

## Check against the official archive

The list of directories in `apps/` of `nextcloud-33.0.9.zip` (sha256 `fa8ec03b...e70`)
has 53 entries. Fork `apps/` (31) minus `testing` (30) plus the 23 listed apps gives the same
53. The set difference "in the zip, not in the fork's `apps/`" is exactly the 23 listed apps.
Only the directory names were compared; the contents of the apps and their versions were not,
except for `support`.

## Not verified

- The commit of `support`; it is not publicly readable.
- That the archive contents of each app equal the tagged commit (only names were compared).
  The archive build also vendors composer dependencies and applies `.nextcloudignore`, so a
  checkout of a pin is not byte-identical to the archive's app directory.
- Which `stable33.json` the 33.0.9 build used: the file's history shows only two commits
  (2026-05-31 and 2026-06-02), both before the release, and the release's metadata asset
  carries no app list.
- Tags are assumed immutable; upstream's `release-tag.yml` can delete and recreate them.

## The helper

`.github/workflows/ionos-app-pins.yml` runs weekly (Monday 04:17 UTC) and on demand
(`workflow_dispatch`, inputs `dry_run` and `base_release`). It checks out only
`.github/ionos/` (sparse, one commit) and runs `.github/ionos/ionos-app-pins.sh`, which uses
the API only and clones nothing. It shares `.github/ionos/ionos-lib.sh` with the sync script.

**Which release.** It pins for the base release of the dev branch, never for a newer upstream
release than the server code. The base is found the way `ionos-sync.sh` does it: the newest final
`v<line>.x.y` tag of `nextcloud/server` that is an ancestor of the tip of `ionos-dev-v<line>`. Through
the API: for the final tags of the line, newest first, take the tag's commit (annotated tags are
dereferenced) and call `compare/<tag commit>...<tip commit>` on the fork; `ahead` or `identical`
means the tag is an ancestor, and the first such tag is the base. (The tip is passed as its commit
id, read from the branch first, so no branch name ends up in the compare URL.) The `base_release`
input overrides this. So the helper proposes pins when the base of the dev branch changes (after a
candidate was promoted) or when upstream's app list for that release differs from the pins.

**What it does.** It works out the pins as above and, when they differ from the pins on
`ionos-dev-v33`, creates the branch `app-pins/<tag>` with one commit on top of the dev branch tip and
opens one pull request into `ionos-dev-v33`. The commit contains only the gitlinks under
`apps-upstream/`; `.gitmodules` changes only when the set of apps changes (new sections appended,
removed ones dropped).

**Existing branch or pull request.** An open pull request for the branch is never touched. When the
branch `app-pins/<tag>` exists and its pins equal the new ones, nothing happens. When it exists with
other pins (upstream's app list changed in between) it is replaced by a new commit through the API
with a force update, and a pull request is opened if none is open. The API has no compare-and-swap,
so the helper re-reads the branch just before moving it and stops when somebody pushed to it
meanwhile (a best-effort lease).

**Input from upstream is untrusted.** App ids must match `^[a-z0-9_]+$` and repositories
`^nextcloud/[A-Za-z0-9._-]+$` before they reach an API URL or the `url` of a `.gitmodules` section;
anything else stops the run. Branch names and refs are passed as query parameters, not concatenated
into URLs.

**The token.** The helper opens its pull request with the repository secret `IONOS_SYNC_TOKEN`, see
`ionos-sync.md` for what the token is and how to create it. Pull requests opened with the default
`GITHUB_TOKEN` do not trigger workflows, so the commit-lint check would not run on them; without the
secret the workflow falls back to the default token and the log says so. The default token also
needs the repository setting "Allow GitHub Actions to create and approve pull requests" to open a
pull request at all; a personal access token does not.

**When it runs.** Scheduled runs and manual runs need the workflow file on the default branch,
which a person switches to the dev branch later (a separate settings step). Until then nothing runs.

Test it with `bash .github/ionos/ionos-app-pins.test.sh`: the script runs as a process against a
stub `gh` that behaves like a small stateful GitHub, and the tests check the state it holds
afterwards.
