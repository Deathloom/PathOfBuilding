# Per-player builds repos: set-up (POE-Builds owner)

Files in this folder go into the **POE-Builds/access** repo (same paths). They replace
`.github/workflows/approve.yml` and add the access-request form and the migration workflow.

1. **Token**: create a fine-grained token, resource owner **POE-Builds**, Repository access **All repositories**,
   permissions **Administration: Read and write** + **Contents: Read and write**. Save it in
   POE-Builds/access → Settings → Secrets → Actions as **ORG_ADMIN_TOKEN**. (Master copy in Vaultwarden.)
2. **GitHub App**: POE-Builds → Settings → GitHub Apps → the sync app → Configure →
   Repository access **All repositories** (new builds-* repos are then covered automatically).
3. **Base permission**: POE-Builds → Settings → Member privileges → Base permissions **No permission**,
   and remove any team that gives Write/Read on poe-builds, otherwise everyone still sees everything there.
4. **Copy these files** into POE-Builds/access and add the label **builds-access**.
5. **Migrate**: Actions → Migrate to per-player repos → Run with `players` = each folder and its owner's GitHub
   login (e.g. `Deathloom=Deathloom,FriendFolder=friend-login`), dry run first, then untick.
   Each player then sets their PoB/Loot Goblin player folder to their GitHub name (required in per-player mode).
6. **Switch the apps**: PoB Sync... → Per-player repos = `builds-` (a later Loot Goblin release sets it for everyone).
7. When everyone has pulled from the new repos: empty `poe1/` in poe-builds (it stays as the problem-reports repo).
