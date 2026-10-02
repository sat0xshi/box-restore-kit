# Skill: Box Keeper - keep the box restorable across updates

The box is one shared Linux machine. A box **update** wipes `/usr`, `/etc`, `/opt`, `/var`
(apt packages, apt repos, everything in `/usr/local`), `~/.nvm` (node and every `npm -g`
CLI under it), `~/.npm`, `~/.cache`, project `node_modules/` and `.venv/`, running daemons
and logins stored under `/var` (e.g. Tailscale). It keeps `/workspace` and most of the home
directory (`~/.local`, `~/.config`, `~/.ssh`, CLI logins stored in home).

The kit (`snapshot.sh` + `restore.sh`) records what was added on top of the base image and
reinstalls only what is missing. Repo: `https://github.com/sat0xshi/box-restore-kit`
Location on the box: `KIT=/workspace/box-restore` (inside `/workspace`, so it survives).

## 1. Get the kit (only if `$KIT/snapshot.sh` is missing)
```bash
git clone https://github.com/sat0xshi/box-restore-kit /workspace/box-restore
# no git: mkdir -p /workspace/box-restore && cd /workspace/box-restore && for f in snapshot.sh restore.sh; do curl -fsSLO https://raw.githubusercontent.com/sat0xshi/box-restore-kit/main/$f; done
```
If the folder already exists, do not re-clone or overwrite it: it holds this box's
`manifests/` and local edits to `restore.sh`. To update the kit, `git -C /workspace/box-restore
pull` only when there are no local changes (otherwise tell the user and leave it).

## 2. When to snapshot
Run `bash /workspace/box-restore/snapshot.sh` (about 2 s, no prompts, never reads secrets,
merges with existing manifests; check it prints `snapshot OK`):
- right after you install, upgrade or remove anything: apt, npm -g, pip, uv tool, pipx,
  cargo, go, nvm/node, a project's `npm install` / venv;
- right before a box update (always, even if you think nothing changed).
Use `--prune` only when you deliberately removed something.

## 3. Hand-installed tools must be added by hand
The manifests only see package managers. Anything installed with a curl installer,
AppImage, tarball, downloaded `.deb`, `make install`, or a copied binary is invisible.
In the same turn, add one line to the `MANUAL INSTALLS` section of `$KIT/restore.sh`:
```bash
custom "<name>" "<check that succeeds when installed>" "<non-interactive install command>"
```
Then snapshot. Every file in `manifests/usr-local-bin-added.txt` needs such a line.
Never put tokens, passwords or license keys in it.

## 4. Before an update
1. Snapshot (section 2) and confirm `snapshot OK`.
2. Tell the user the snapshot is done and that **they** must start the update from the
   Grok Bot settings (an agent cannot), then message you when the box is back. Warn them
   not to use *Reset* instead (it rolls back to an older state and can lose recent work).
3. Mention which re-logins will be needed afterwards (e.g. Tailscale, if used).

## 5. After an update
```bash
bash /workspace/box-restore/restore.sh --dry-run          # preview
bash /workspace/box-restore/restore.sh --with-projects    # restore (about a minute)
bash /workspace/box-restore/restore.sh --dry-run          # should say "nothing to install"
```
Exit 0 = every action succeeded. On failure read `$KIT/restore.log`, fix the cause, rerun
(finished steps are skipped). Then tell the user briefly: actions run/failed, what was
rebuilt, each `WARN:` line (e.g. base-image packages the new image dropped - offer
`--include-base`) and each `MANUAL:` line they must do themselves.
If `NPM_CONFIG_PREFIX` is set, `nvm use` complains: call nvm-installed CLIs by full path
(`~/.nvm/versions/node/<ver>/bin/<cli>`) or `unset NPM_CONFIG_PREFIX; . ~/.nvm/nvm.sh`.

## 6. Re-logins are manual, and login links expire fast
`restore.sh` restarts daemons but cannot log in for the user. For a browser login
(e.g. `sudo tailscale up`), run the command in the background, read the URL from its
output and send it to the user **immediately**; such links can expire within seconds
to minutes. If it expired (Tailscale: `http 410: auth path not found`), start a fresh one:
```bash
sudo tailscale logout
sudo nohup tailscale up --force-reauth >/tmp/tailscale-up.log 2>&1 &
sleep 3; grep -o 'https://login.tailscale.com/[^ ]*' /tmp/tailscale-up.log
```
Confirm with `tailscale status`. A Tailscale re-login may register a new node (new name
suffix and IP): tell the user to update anything that used the old name/IP and remove the
old node in the admin console. Never use an auth key unless the user gave one for this.

## Never
- Never read, print, copy or store credential contents; the kit checks only existence.
- Never start an update or reset yourself.
- Never publish, commit or share `manifests/` or `restore.log` (they list this box's
  paths and packages).
- Never add secrets or interactive commands to `restore.sh`.
