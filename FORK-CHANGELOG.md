# Fork changelog

Changes in this fork compared with [Path of Building Community](https://github.com/PathOfBuildingCommunity/PathOfBuilding). Upstream's own changes are in `CHANGELOG.md` / `changelog.txt`. Those files are left as upstream has them.

**How to maintain:** every PR adds a line under **Unreleased**. Once the fork has its own releases (the `master` release branch), rename **Unreleased** to the release version and date, and start a new empty section.

## [Unreleased]

### Added
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
