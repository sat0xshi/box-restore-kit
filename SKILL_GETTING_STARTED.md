# Skill: Box Keeper - getting started (first run)

Use this once, when Box Keeper is first set up on a box (or when `/workspace/box-restore/snapshot.sh`
does not exist yet).

1. Fetch the kit into `/workspace/box-restore` (skip if it already exists - never overwrite it):
   ```bash
   git clone https://github.com/sat0xshi/box-restore-kit /workspace/box-restore
   # no git: mkdir -p /workspace/box-restore && cd /workspace/box-restore && for f in snapshot.sh restore.sh; do curl -fsSLO https://raw.githubusercontent.com/sat0xshi/box-restore-kit/main/$f; done
   ```
2. Take the first snapshot and check it prints `snapshot OK`:
   ```bash
   bash /workspace/box-restore/snapshot.sh
   ```
3. Look at what was captured (counts line, plus `manifests/counts.txt`,
   `manifests/usr-local-bin-added.txt`, `manifests/workspace-projects.txt`,
   `manifests/services.txt`).
4. Tell the user in a few lines:
   - what was captured: apt packages, node versions, npm -g / pip / uv / pipx / cargo / go
     tools, projects whose `node_modules`/`.venv` will be rebuilt, daemons seen;
   - anything the kit cannot restore automatically: files listed in
     `usr-local-bin-added.txt` and any tool they installed with curl, an AppImage or a
     tarball - offer to add a `custom` line for each to the `MANUAL INSTALLS` section of
     `restore.sh`;
   - that logins such as Tailscale must be redone by hand after an update, with a link
     that has to be opened right away;
   - the routine from now on: you snapshot after every install and before every update;
     after an update, they ask you to restore.
5. Never print credential contents, and never publish or share `manifests/`.
