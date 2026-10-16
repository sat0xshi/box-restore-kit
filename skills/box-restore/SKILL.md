---
name: box-restore
description: Snapshot the tools installed on a shared Linux agent box and reinstall only what is missing after a box update wipes system directories. Use before an update, after an update, or when installed CLIs, apt packages or daemons have disappeared.
---

# Box Restore

A box update can wipe system locations (`/usr`, `/etc`, `/opt`, `/var`, `~/.nvm`, `~/.npm`,
`~/.cache`, project `node_modules/` and `.venv/`) while keeping `/workspace` and most of the
home directory. This kit records what was added on top of the base image and restores it.

## Get the kit (only if it is not there yet)
```bash
git clone https://github.com/sat0xshi/box-restore-kit /workspace/box-restore
```
If `/workspace/box-restore` already exists, do not re-clone or overwrite it: it holds this
box's `manifests/`. Update with `git -C /workspace/box-restore pull` only when it has no local changes.

## Take a snapshot (before an update, and after installing anything new)
```bash
bash /workspace/box-restore/snapshot.sh
```
Non-interactive, takes a few seconds, and only checks that credential files exist; it never
reads secrets. Expect `snapshot OK` and review `manifests/counts.txt`.

For tools installed by hand into `/usr/local/bin` or similar, add a `custom` entry so
`restore.sh` can reinstall them. Never put tokens, passwords or license keys there.

## Restore (after an update)
```bash
bash /workspace/box-restore/restore.sh --dry-run   # preview
bash /workspace/box-restore/restore.sh             # reinstall what is missing
```
Useful flags: `--with-projects` (reinstall project dependencies), `--latest` (latest instead of
recorded versions), `--no-services` (do not start daemons), `--manifests DIR`.

Restore is idempotent. At the end it prints `MANUAL:` lines for logins that must be redone by
the user (for example a VPN daemon login). Run such login commands in the background, give
the user the URL right away (these links can expire quickly), and never handle their
credentials yourself.

## Rules
- Never add secrets or interactive commands to the restore script or manifests.
- Re-run `snapshot.sh` after any successful restore or new install.
