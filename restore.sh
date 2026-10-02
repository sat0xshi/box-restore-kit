#!/usr/bin/env bash
# restore.sh - after a box update, reinstall ONLY what is missing, from manifests/.
# Idempotent (run it as often as you like), no prompts, never touches secrets.
#
#   bash restore.sh --dry-run          # show what would be installed (no changes)
#   bash restore.sh                    # apt, nvm+node, npm -g, pip/uv/pipx, cargo/go,
#                                      # MANUAL INSTALLS section, services
#   bash restore.sh --with-projects    # also rebuild node_modules/.venv under /workspace
# Options:
#   --with-projects  rebuild projects that had node_modules/.venv at snapshot time
#   --all-projects   also projects that only had a lockfile (implies --with-projects)
#   --include-bak    with projects: include *.bak* / *backup* directories
#   --include-base   also reinstall base-image packages missing from the new image
#   --latest         install latest versions instead of the recorded ones
#   --no-services    do not start daemons (tailscaled)
#   --manifests DIR  manifest dir (default: <script dir>/manifests; env BOX_RESTORE_MANIFESTS)
# Log: <script dir>/restore.log (env BOX_RESTORE_LOG); lock: /tmp/box-restore.lock (env BOX_RESTORE_LOCK)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="${BOX_RESTORE_MANIFESTS:-$DIR/manifests}"
LOG="${BOX_RESTORE_LOG:-$DIR/restore.log}"
DRY=0 WITH_PROJECTS=0 ALL_PROJECTS=0 INCLUDE_BAK=0 INCLUDE_BASE=0 LATEST=0 SERVICES=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --with-projects) WITH_PROJECTS=1 ;;
    --all-projects) WITH_PROJECTS=1; ALL_PROJECTS=1 ;;
    --include-bak) INCLUDE_BAK=1 ;;
    --include-base) INCLUDE_BASE=1 ;;
    --latest) LATEST=1 ;;
    --no-services) SERVICES=0 ;;
    --manifests) M="${2:?--manifests needs a directory}"; shift ;;
    --manifests=*) M="${1#--manifests=}" ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
LOCK="${BOX_RESTORE_LOCK:-/tmp/box-restore.lock}"
exec 9>"$LOCK"; flock -n 9 || { echo "another restore.sh is running (lock: $LOCK)" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; TODO=0; FAIL=0; MANUAL=(); WARN=()
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
act(){ # act "description" "command"
  TODO=$((TODO+1))
  if [ "$DRY" = 1 ]; then log "[dry-run] would: $1"; return 0; fi
  log "RUN : $1"
  # 9>&- : never let children (e.g. daemons started here) inherit the lock fd
  if bash -c "$2" >>"$LOG" 2>&1 9>&-; then log "OK  : $1"; else log "FAIL: $1 (see $LOG)"; FAIL=$((FAIL+1)); fi
}
entries(){ if [ -f "$M/$1" ]; then grep -v '^#' "$M/$1" | grep -v '^[[:space:]]*$'; fi; return 0; }
pkgver(){ if [ "$LATEST" = 1 ] || [ -z "$2" ]; then echo "$1"; else echo "$1$3$2"; fi; }
apt_ok(){ [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]; }
inlist(){ local x=$1; shift; local e; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }
had_cli(){ entries cli-versions.txt | awk -F'\t' -v c="$1" '$1==c && $2!="(not found)"{f=1} END{exit !f}'; }
nvm_run(){ printf 'env -u NPM_CONFIG_PREFIX -u npm_config_prefix bash -c %q' ". \"$NVM_DIR/nvm.sh\" && $1"; }
log "===== restore.sh start (dry-run=$DRY with-projects=$WITH_PROJECTS manifests=$M) ====="
[ -d "$M" ] || { log "no manifests at $M - run snapshot.sh before the update"; exit 1; }

# ---------- 1. apt ----------
missing=()
while IFS=$'\t' read -r p _; do apt_ok "$p" || missing+=("$p"); done < <(entries apt-added.txt)
# safety net: tools restore.sh itself needs, and recorded CLIs that the new image dropped
declare -A CMDPKG=([curl]=curl [python3]=python3 [git]=git [jq]=jq [rg]=ripgrep [ffmpeg]=ffmpeg
  [pdftotext]=poppler-utils [gh]=gh [ssh]=openssh-client [tmux]=tmux [go]=golang-go [cargo]=cargo
  [tailscale]=tailscale [shellcheck]=shellcheck)
for c in "${!CMDPKG[@]}"; do
  command -v "$c" >/dev/null 2>&1 && continue
  { [ "$c" = curl ] || [ "$c" = python3 ] || had_cli "$c"; } || continue
  inlist "${CMDPKG[$c]}" "${missing[@]}" || missing+=("${CMDPKG[$c]}")
done
base_missing=()
while IFS=$'\t' read -r p _; do apt_ok "$p" || inlist "$p" "${missing[@]}" || base_missing+=("$p"); done < <(entries apt-base.txt)
if [ ${#base_missing[@]} -gt 0 ]; then
  if [ "$INCLUDE_BASE" = 1 ]; then missing+=("${base_missing[@]}")
  else WARN+=("base-image apt packages not in this image: ${base_missing[*]} (add --include-base to install)"); fi
fi
TS_SCRIPT=0
if inlist tailscale "${missing[@]}" && [ ! -e "$M/apt-sources/tailscale.list" ] && ! ls /etc/apt/sources.list.d/tailscale* >/dev/null 2>&1; then
  TS_SCRIPT=1; rest=(); for p in "${missing[@]}"; do [ "$p" = tailscale ] || rest+=("$p"); done; missing=("${rest[@]}")
fi
if [ ${#missing[@]} -gt 0 ]; then
  for f in "$M"/apt-sources/*; do   # extra repos + public keys, only if absent
    [ -e "$f" ] || continue; b=$(basename "$f")
    case "$b" in *.list|*.sources) dst=/etc/apt/sources.list.d/$b ;; *) dst=/usr/share/keyrings/$b ;; esac
    [ -e "$dst" ] || act "apt repo/key: $dst" "sudo -n install -m 0644 '$f' '$dst'"
  done
  act "apt install: ${missing[*]}" "sudo -n apt-get update -qq && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ${missing[*]}"
fi
[ "$TS_SCRIPT" = 1 ] && act "tailscale (official install script)" "curl -fsSL https://tailscale.com/install.sh | sudo -n sh"

# ---------- 2. nvm / node ----------
NVM_JUST=0
nvmv=$(entries nvm-versions.txt | awk -F'\t' '$1=="nvm"{print $2}'); nvmv=${nvmv:-0.40.1}
if [ ! -s "$NVM_DIR/nvm.sh" ] && [ -n "$(entries nvm-versions.txt | awk -F'\t' '$1~/^v/')" ]; then
  act "nvm v$nvmv (does not edit ~/.bashrc)" \
      "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v$nvmv/install.sh | env -u NPM_CONFIG_PREFIX PROFILE=/dev/null NVM_DIR='$NVM_DIR' bash"
  NVM_JUST=1
fi
ACTIVE=$(entries nvm-versions.txt | awk -F'\t' '$2=="active"{print $1; exit}')
while IFS=$'\t' read -r v _; do
  [[ "$v" == v* ]] || continue
  [ -x "$NVM_DIR/versions/node/$v/bin/node" ] && continue
  act "node $v (nvm install)" "$(nvm_run "nvm install $v")"; NVM_JUST=1
done < <(entries nvm-versions.txt)
if [ -n "$ACTIVE" ] && [ "$NVM_JUST" = 1 ] && [ "$(cat "$NVM_DIR/alias/default" 2>/dev/null)" != "$ACTIVE" ]; then
  act "nvm alias default $ACTIVE" "$(nvm_run "nvm alias default $ACTIVE")"
fi

# ---------- 3. npm -g ----------
npm_restore(){ # manifest prefix nodebin [sudo]
  local mf=$1 prefix=$2 bin=$3 su=${4:-} n v spec
  while IFS=$'\t' read -r n v; do
    [ -f "$prefix/lib/node_modules/$n/package.json" ] && continue
    spec=$(pkgver "$n" "$v" "@")
    act "npm -g $spec (prefix=$prefix)" "export PATH='$bin':\$PATH; $su env -u NPM_CONFIG_PREFIX PATH=\"\$PATH\" npm install -g --no-fund --no-audit --prefix '$prefix' '$spec'"
  done < <(entries "$mf")
}
for f in "$M"/npm-global-v*.txt; do
  [ -e "$f" ] || continue; v=$(basename "$f" .txt); v=${v#npm-global-}
  npm_restore "$(basename "$f")" "$NVM_DIR/versions/node/$v" "$NVM_DIR/versions/node/$v/bin"
done
NODEBIN="$NVM_DIR/versions/node/${ACTIVE:-none}/bin"
if [ ! -x "$NODEBIN/node" ] && [ "$DRY" = 0 ] || [ -z "$ACTIVE" ]; then NODEBIN=$(dirname "$(command -v node || echo /usr/bin/node)"); fi
npm_restore npm-global-user.txt "$HOME/.local" "$NODEBIN"
npm_restore npm-global-system.txt /usr/local /usr/bin "sudo -n"
[ "$INCLUDE_BASE" = 1 ] && npm_restore npm-global-system-base.txt /usr/local /usr/bin "sudo -n"

# ---------- 4. python (pip / uv / pipx) ----------
norm(){ tr 'A-Z_.' 'a-z--'; }
have_user=$(python3 -m pip list --user --format=freeze 2>/dev/null | cut -d= -f1 | norm)
while IFS=$'\t' read -r n v; do
  grep -qx "$(echo "$n" | norm)" <<<"$have_user" && continue
  s=$(pkgver "$n" "$v" "==")
  act "pip --user $s" "python3 -m pip install --user --break-system-packages -q '$s' || python3 -m pip install --user --break-system-packages -q '$n'"
done < <(entries pip.txt)
have_sys=$(find /usr/local/lib/python3*/dist-packages /usr/local/lib/python3*/site-packages -maxdepth 1 -name '*.dist-info' -printf '%f\n' 2>/dev/null | sed -E 's/-[^-]+\.dist-info$//' | norm)
pipsys(){ while IFS=$'\t' read -r n v; do
  grep -qx "$(echo "$n" | norm)" <<<"$have_sys" && continue
  s=$(pkgver "$n" "$v" "==")
  act "sudo pip $s" "sudo -n python3 -m pip install --break-system-packages -q '$s' || sudo -n python3 -m pip install --break-system-packages -q '$n'"
done < <(entries "$1"); }
pipsys pip-system.txt
[ "$INCLUDE_BASE" = 1 ] && pipsys pip-system-base.txt
if [ -n "$(entries uv-tools.txt)" ]; then
  command -v uv >/dev/null || [ -x "$HOME/.local/bin/uv" ] || act "uv (official installer, ~/.local/bin)" "curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh"
  have_uv=$(PATH="$HOME/.local/bin:$PATH" uv tool list 2>/dev/null | awk '/^[^ -]/{print $1}')
  while IFS=$'\t' read -r n v; do
    grep -qx "$n" <<<"$have_uv" || act "uv tool install $n" "PATH=\"\$HOME/.local/bin:\$PATH\" uv tool install '$(pkgver "$n" "$v" "==")'"
  done < <(entries uv-tools.txt)
fi
if [ -n "$(entries pipx.txt)" ]; then
  command -v pipx >/dev/null || apt_ok pipx || act "apt install pipx" "sudo -n apt-get install -y -qq pipx"
  have_px=$(pipx list --short 2>/dev/null | awk '{print $1}')
  while IFS=$'\t' read -r n v; do grep -qx "$n" <<<"$have_px" || act "pipx install $n" "pipx install '$(pkgver "$n" "$v" "==")'"; done < <(entries pipx.txt)
fi

# ---------- 5. cargo / go ----------
while IFS=$'\t' read -r n v; do
  [ -x "$HOME/.cargo/bin/$n" ] || act "cargo install $n" "cargo install '$n' ${v:+$( [ "$LATEST" = 1 ] || echo "--version $v")}"
done < <(entries cargo-bins.txt)
while IFS=$'\t' read -r n mod; do
  [ -x "$HOME/go/bin/$n" ] || [ -z "$mod" ] || { [ "$LATEST" = 1 ] && mod="${mod%@*}@latest"; act "go install $mod" "go install '$mod'"; }
done < <(entries go-bins.txt)

# ---------- 6. MANUAL INSTALLS (curl installers, AppImages, tarballs) ----------
# Anything installed WITHOUT apt/npm/pip/uv/pipx/cargo/go/nvm is invisible to the
# manifests. Add one line per tool here, right after you install it:
#   custom "<name>" "<check: succeeds when installed>" "<install command, non-interactive>"
# Files under /home/box (~/.local, ~/Applications) survive an update, so only
# things in /usr, /opt, /etc, /var (or ~/.nvm, ~/.cache) really need an entry.
custom(){ bash -c "$2" >/dev/null 2>&1 9>&- || act "$1" "$3"; }
# Claude Code (native installer, lives in ~/.local - only reinstalled if it vanished)
# shellcheck disable=SC2016  # expanded later by bash -c
had_cli claude && custom "Claude Code (native installer)" \
  '[ -x "$HOME/.local/bin/claude" ] && "$HOME/.local/bin/claude" --version' \
  "curl -fsSL https://claude.ai/install.sh | bash"
# --- examples (uncomment / adapt) ---
# custom "cloudflared" "command -v cloudflared" \
#   "curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && sudo -n apt-get install -y /tmp/cf.deb"
# custom "ollama" "command -v ollama" "curl -fsSL https://ollama.com/install.sh | sh"
# custom "MyApp AppImage" "[ -x \"\$HOME/Applications/MyApp.AppImage\" ]" \
#   "mkdir -p ~/Applications && curl -fsSL -o ~/Applications/MyApp.AppImage https://example.com/MyApp.AppImage && chmod +x ~/Applications/MyApp.AppImage"
# custom "tool in /usr/local/bin" "[ -x /usr/local/bin/mytool ]" \
#   "curl -fsSL https://example.com/mytool.tar.gz | sudo -n tar -xz -C /usr/local/bin mytool"
# ---------- end of MANUAL INSTALLS ----------

# ---------- 7. services ----------
had_daemon(){ entries services.txt | grep -qx "$1"; }
if [ "$SERVICES" = 1 ] && { had_daemon tailscaled || entries apt-added.txt | grep -q '^tailscale[[:space:]]'; }; then
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    if [ "$(ps -o comm= -p 1 2>/dev/null)" = systemd ]; then
      act "start tailscaled (systemd)" "sudo -n systemctl enable --now tailscaled"
    else
      act "start tailscaled (state in /var/lib/tailscale)" \
        "sudo -n mkdir -p /var/lib/tailscale /var/run/tailscale && (sudo -n nohup tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/tmp/tailscaled.log 2>&1 &) && sleep 3"
    fi
  fi
fi
while read -r d; do
  [ "$d" = tailscaled ] && continue
  pgrep -x "$d" >/dev/null 2>&1 || WARN+=("daemon '$d' was running at snapshot time but is not now - start it by hand")
done < <(entries services.txt | sed -n '/^\[daemons\]/,/^\[/p' | grep -v '^\[')

# ---------- 8. /workspace projects (node_modules / .venv are wiped) ----------
proj_skip=0; lock_skip=0
node_for(){ # pick node bin dir: .nvmrc if that version is installed, else the default
  local p=$1 want d
  want=""; [ -f "$p/.nvmrc" ] && want=$(tr -d '[:space:]' < "$p/.nvmrc"); want=${want#v}
  if [ -n "$want" ]; then
    d=$(find "$NVM_DIR/versions/node" -maxdepth 1 -name "v$want*" 2>/dev/null | sort -V | tail -1)
    [ -n "$d" ] && [ -x "$d/bin/node" ] && { echo "$d/bin"; return; }
  fi
  echo "$NODEBIN"
}
while IFS=$'\t' read -r p kind; do
  case "$p" in *.bak*|*backup*) [ "$INCLUDE_BAK" = 1 ] || continue ;; esac
  case "$kind" in
    node:*)
      [ -f "$p/package.json" ] || continue; [ -d "$p/node_modules" ] && continue
      grep -Eq '"(dev|optional|peer)?[dD]ependencies"' "$p/package.json" || continue   # nothing to install
      lock=$(echo "$kind" | cut -d: -f2); state=$(echo "$kind" | cut -d: -f3)
      case "$lock" in
        package-lock.json) cmd="npm ci --no-fund --no-audit" ;;
        pnpm-lock.yaml) cmd="{ command -v pnpm >/dev/null && pnpm install --frozen-lockfile || corepack pnpm install --frozen-lockfile; }" ;;
        yarn.lock) cmd="{ command -v yarn >/dev/null && yarn install --frozen-lockfile || corepack yarn install; }" ;;
        bun.lock|bun.lockb) cmd="bun install --frozen-lockfile" ;;
        *) cmd="npm install --no-fund --no-audit" ;;
      esac
      if [ "$state" = lock-only ] && [ "$ALL_PROJECTS" = 0 ]; then lock_skip=$((lock_skip+1)); continue; fi
      if [ "$WITH_PROJECTS" = 1 ]; then act "$p: ${cmd%% --*}" "export PATH='$(node_for "$p")':\$PATH; cd '$p' && $cmd"
      else proj_skip=$((proj_skip+1)); log "skip (needs --with-projects): $p"; fi ;;
    venv:*)
      proj=${p%/*}; [ -d "$proj" ] || continue
      [ -x "$p/bin/python" ] && "$p/bin/python" -c 'import sys' >/dev/null 2>&1 && continue
      req="$M/venvs/$(echo "$p" | tr '/' '%').txt"
      if [ "$p" = "$proj/.venv" ] && [ -f "$proj/uv.lock" ] && command -v uv >/dev/null; then
        cmd="cd '$proj' && uv sync --frozen"
      else
        cmd="python3 -m venv --clear '$p' && '$p/bin/pip' install -q --upgrade pip >/dev/null 2>&1; "
        if [ -s "$req" ]; then cmd+="'$p/bin/pip' install -q -r '$req' || sed -E 's/==.*//' '$req' | '$p/bin/pip' install -q -r /dev/stdin"
        elif [ -f "$proj/requirements.txt" ]; then cmd+="'$p/bin/pip' install -q -r '$proj/requirements.txt'"
        else cmd+="true"; fi
      fi
      if [ "$WITH_PROJECTS" = 1 ]; then act "rebuild venv: $p" "$cmd"
      else proj_skip=$((proj_skip+1)); log "skip (needs --with-projects): venv $p"; fi ;;
  esac
done < <(entries workspace-projects.txt)

# ---------- 9. re-logins (existence checks only, contents never read) ----------
hint(){ case "$1" in
  *codex*) echo "codex login --device-auth" ;; *claude*) echo "run 'claude' and use /login" ;;
  *gh/hosts.yml) echo "gh auth login" ;; *gemini*) echo "run 'gemini' and sign in" ;;
  *.ssh/*) echo "restore your SSH key/config" ;; *) echo "log in again / restore this file" ;; esac; }
while IFS=$'\t' read -r yes path _; do
  [ "$yes" = YES ] || continue
  case "$path" in *tailscale*) continue ;; esac
  q="${path/#\~/$HOME}"; [ -e "$q" ] && continue
  MANUAL+=("missing $path -> $(hint "$path")")
done < <(entries credential-paths.txt)
TS_TIP="if the login URL expires (control log: 'register request: http 410: auth path not found'): sudo tailscale logout; sudo nohup tailscale up --force-reauth >/tmp/tailscale-up.log 2>&1 & then open the URL in /tmp/tailscale-up.log IMMEDIATELY. Re-login creates a NEW node (name gets a -1 suffix, new 100.x IP); remove the old node in the Tailscale admin console."
if command -v tailscale >/dev/null 2>&1 && pgrep -x tailscaled >/dev/null 2>&1; then
  st=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)
  [ "$st" = Running ] || MANUAL+=("Tailscale (BackendState=${st:-unknown}): sudo tailscale up ; $TS_TIP")
elif { had_daemon tailscaled || entries apt-added.txt | grep -q '^tailscale[[:space:]]'; } && [ "$DRY" = 0 ]; then
  MANUAL+=("Tailscale: tailscaled is not running; start it, then sudo tailscale up ; $TS_TIP")
fi

# ---------- summary ----------
log "----- summary -----"
for w in "${WARN[@]}"; do log "WARN: $w"; done
[ "$proj_skip" -gt 0 ] && log "INFO: $proj_skip project(s) not rebuilt (add --with-projects)"
[ "$lock_skip" -gt 0 ] && log "INFO: $lock_skip lock-only project(s) skipped (never installed at snapshot time; add --all-projects)"
if [ -n "${NPM_CONFIG_PREFIX:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
  log "INFO: NPM_CONFIG_PREFIX is set, so 'nvm use' complains. Call nvm-installed CLIs by full path ($NVM_DIR/versions/node/<ver>/bin/<cli>) or run: unset NPM_CONFIG_PREFIX; . $NVM_DIR/nvm.sh"
fi
for m in "${MANUAL[@]}"; do log "MANUAL: $m"; done
if [ "$DRY" = 0 ]; then   # CLIs that existed at snapshot time but are still missing
  P="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$NVM_DIR/versions/node/${ACTIVE:-none}/bin:$PATH"
  while IFS=$'\t' read -r c v; do
    [ "$v" = "(not found)" ] && continue
    PATH="$P" command -v "$c" >/dev/null 2>&1 || log "WARN: '$c' existed at snapshot time but is missing (installed by hand? add it to MANUAL INSTALLS)"
  done < <(entries cli-versions.txt)
fi
if [ "$TODO" = 0 ]; then log "nothing to install - everything is present"
elif [ "$DRY" = 1 ]; then log "dry-run: $TODO action(s) would run"
else
  log "done: $TODO action(s), $FAIL failed"
  [ -f "$DIR/snapshot.sh" ] && bash "$DIR/snapshot.sh" --no-versions --out "$M" >>"$LOG" 2>&1 9>&-
fi
[ "$FAIL" = 0 ]
