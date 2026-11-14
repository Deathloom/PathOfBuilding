# Fork changelog

Changes in this fork compared with [Path of Building Community](https://github.com/PathOfBuildingCommunity/PathOfBuilding). Upstream's own changes are in `CHANGELOG.md` / `changelog.txt`. Those files are left as upstream has them.

**How to maintain:** every PR adds a line under **Unreleased**. Once the fork has its own releases (the `master` release branch), rename **Unreleased** to the release version and date, and start a new empty section.

## [Unreleased]

### Added (CI)
- **Loot Goblin smoke test** (`tools/smoke/smoke.py`, workflow *Loot Goblin smoke test*): runs every headless command the overlay uses (load, info, impact, gear, loadouts, gems, tree, treeMap) against PoB's test builds on Windows, for each PR into dev, each push to dev, and each weekly upstream release branch. Catches upstream changes that break the overlay without a merge conflict.

### Added
- **Tree map for Loot Goblin** (headless `treeMap` command): the whole passive tree as PoB lays it out (node positions, groups, links, names, stats) per tree version, plus the nodes the selected loadout and the live character allocate (masteries with their effect). Layout is skipped when the overlay already has that tree version.

### Security
- **Build sync: safe file names only** (security review part 3): Pull now refuses repo paths that could leave the builds folder or misbehave on Windows (backslashes, `:`, `..`, device names like `CON`/`NUL`, trailing dots/spaces, control characters), anything other than `.xml`/`.txt`, paths deeper than 6 folders and files over 10 MB. The worker re-checks the file name and blob sha before writing. Requests are https-only (also after redirects, max 3), downloads are capped at 10 MB, and PoB's "skip SSL check" option is no longer applied to requests that carry the GitHub sign-in. Owner / repo / branch typed in Sync... are validated before they go into API URLs. The build-impact server refuses build files over 32 MB (friends' builds are other people's data).

### Added
- **Per-player builds repos** (opt-in): Sync... → *Per-player repos* = `builds-`. Push goes to your own private repo `<owner>/builds-<player>`; Pull reads every `builds-*` repo you've been given access to, and from each only that player's folder (a repo can't write into anyone else's folder). Empty = one shared repo, as before. SyncServer `configure` takes `repoPrefix`. Set-up for the POE-Builds org (access-request form, `/approve` workflow that grants read access, own repo created on join, migration workflow) in `tools/poe-builds-access/`.
- **Self-update for Loot Goblin's copy** (#19): with `src\bundled.cfg` and an installed-style `src\manifest.xml` (branch + platform, written by Loot Goblin's download) PoB's own updater runs against the fork's `master` branch. New workflow **Release PoB (master)** regenerates `manifest.xml` and sets `master` to the released branch plus that commit. `HeadlessWrapper.lua` is now in the manifest (ImpactServer needs it); SyncServer finds `manifest.xml` in `src` too.
- `SyncServer.lua` `report` command: Loot Goblin's problem reports become issues in the builds repo (label `auto-report`, one issue per problem, repeats as comments), sent with the user's own GitHub sign-in (#18).
- **Headless build sync for Loot Goblin** (`src\SyncServer.lua`): sign in with GitHub, Pull / Push / Sync now and player folder from the overlay, sharing PoB's sign-in and `BuildSync.json` (#17).
- Tree tab data for Loot Goblin (#11).
- **Bundled mode** for the copy shipped inside Loot Goblin (`src\bundled.cfg`): no PoB updater, settings in `Documents\Loot Goblin\PathOfBuilding`, builds in `Documents\Loot Goblin\Builds` (#14).
- Updater points at this fork (`manifest.xml`, `update_manifest.py`) (#1).
- **Push / Pull builds** to POE-Builds/poe-builds via the GitHub API. Conflicts are kept as "(GitHub copy)". The token is stored in Windows Credential Manager (#2, #3).
- **Headless impact server** for Loot Goblin: item impact on the build (#4); comparison with the live character's items, tree, gems and level (#5); build gear in game text format (#6); loadouts, loadout switching and gems (#7); gems by gear piece (#9, #10).
- **Sign in with GitHub** (device flow, POE-Builds GitHub App), **auto sync** (pull on start, push after save), **Sync now**, and a first-run "Share builds with your group?" prompt (#8).

### Fixed
- Build sync re-reads `BuildSync.json` before each Pull/Push, records the build save path in it, and no longer signs out when another app (Loot Goblin) already renewed the shared GitHub sign-in (#17).
- Pull no longer makes a "(GitHub copy)" of builds that were only edited locally (#8).
- Gems by gear piece: a card for every gear piece; body armour no longer matched to a swap-weapon group (#10).
