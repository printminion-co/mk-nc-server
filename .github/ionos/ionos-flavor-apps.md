# Apps of flavor1 from source (line 33)

`flavor1` (flavors repository, branch `v33`) adds five apps to the official set. They are not part of the
Nextcloud 33.0.9 archive, they are versioned independently of the server, and each is a git submodule in the
app folder `apps-flavor1/` (an app folder of its own: `apps-upstream/` belongs to the pins helper, see
`ionos-app-pins.md`, which prunes it). The flavor activates the folder with `app_dirs: [apps-upstream, apps-flavor1]`
and gives each app the mode `default`. The build pipeline finds them as entries of an active app folder (see
`ionos-build.md`), builds them from source and ships them.

## Pins

| App | Repository | Tag | Pinned commit | `<nextcloud>` in `appinfo/info.xml` |
| --- | --- | --- | --- | --- |
| `contacts` | `nextcloud/contacts` | `v8.10.0` | `a3a1abc4ebeb71a007e2b09345de973a04720ef3` | min 33, max 36 |
| `calendar` | `nextcloud/calendar` | `v6.6.6` | `f25a30b29f93a9be6f161a2791ef89a463e8b444` | min 32, max 35 |
| `tasks` | `nextcloud/tasks` | `v0.18.1` | `0326c958b3cbf3ca1c8bb2be5539800e3506fd09` | min 31, max 35 |
| `groupfolders` | `nextcloud/groupfolders` | `v21.0.16` | `52eb441b7410abbe06bd5b2d77d7c32cfbcc15e9` | min 33, max 33 |
| `notes` | `nextcloud/notes` | `v6.1.1` | `8394754a00590c1de486c7514855653066bce667` | min 33, max 36 |

Chosen on 2026-11-26. `calendar` v6.7.0 (min 34) and `groupfolders` v22 and later (min 34) need a newer server,
so the pins are the newest tags that accept 33. `groupfolders` v21.0.16 is the last line for Nextcloud 33.

## Rule

For each app take the newest tag that is a release (a plain `vX.Y.Z`, no `-rc`, `-beta`, `-alpha` suffix, and a
published release where the repository publishes releases) whose `appinfo/info.xml` has
`<nextcloud min-version=".." max-version="..">` with `min <= 33 <= max`, read at the tag itself. These apps have no
`stable33` branch and no tag equal to the server release, so the pin is a tag, never a branch. Pin the commit the tag
points at (annotated tags are dereferenced). The submodule URL is https, like the others, so CI can clone it.

`ncw check-compat` (run by `build` and `validate`) checks the same bounds against the server version of the tree, and
`ncw validate` checks that the app set of the artifact equals the flavor's apps, so a pin that does not accept 33 or
an app missing from the artifact fails the build.

## Build recipes

The default recipe (`ionos-build-apps.sh`) deletes `js/`, `css/` and `vendor/`, runs `composer install --no-dev -a`
when there is a `composer.json` and `npm ci --ignore-scripts && npm run build` when `package.json` has a `build`
script. Read from the sources at the pinned commits:

- `contacts`: no recipe. `composer.json` requires only php, no committed `js/` or `css/`, `build` is `vite build`.
- `calendar`: `build-recipes/calendar.sh`. `composer.json` has a `post-install-cmd` that runs `composer bin all
  install` (dev tools), so composer runs with `--no-scripts`. Build is `rspack build`.
- `groupfolders`: `build-recipes/groupfolders.sh`. Only the composer-bin plugin is required (no runtime packages), the
  `post-install-cmd` would install dev tools, so composer is not run, as in the app's own `krankerl.toml`.
- `tasks`: `build-recipes/tasks.sh`. `css/tasks-icon.css` is a committed handwritten file the default recipe would
  delete; built css is removed with git and tracked css restored.
- `notes`: `build-recipes/notes.sh`. `css/global.css` and `css/notes.css` are handwritten (the default would delete
  them); `composer.json` has only dev packages.

None of the apps has a `postinstall`, `prepare` or `preinstall` script in its `package.json`, so
`npm ci --ignore-scripts` is enough. The full builds were not run when the recipes were written; they are covered by
stubs in `ionos-build.test.sh` (scenario `recipes`). Check the first real run of the pipeline.

## Update by hand

No automation does this. For one app:

1. List the tags (`gh api repos/nextcloud/<app>/tags --paginate --jq '.[].name'`), take the candidates newest first and
   read `gh api repos/nextcloud/<app>/contents/appinfo/info.xml?ref=<tag> --jq .content | base64 -d`; apply the rule
   above.
2. Check what the new version needs: `package.json` scripts, `composer.json` scripts, committed `js/` and `css/`;
   adapt or add `build-recipes/<app>.sh` and its test.
3. Move the pin: `git update-index --cacheinfo 160000,<commit>,apps-flavor1/<app>` (or `git -C apps-flavor1/<app>
   fetch --depth 1 origin tag <tag>` and checkout in a full clone, then `git add apps-flavor1/<app>`).
4. Update the table above and commit as `IONOS(apps): <subject>`, signed.

A new app is added the same way: a section appended to `.gitmodules` (`path = apps-flavor1/<app>`, https `url`, no
`branch`), the gitlink, a row here, and a mode in the flavor.
