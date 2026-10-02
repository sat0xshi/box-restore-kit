#!/usr/bin/env bash
# snapshot.sh - record what was added to this box on top of the base image.
#
# Fast (seconds), no prompts, never reads secrets (credential files are only
# checked for existence). Safe to run any time, as often as you like.
# Results are MERGED (union) with the existing manifests, so running it right
# after a box update does not forget things that are not restored yet.
#
#   bash snapshot.sh                 # write manifests next to this script
#   bash snapshot.sh --prune         # drop entries that are no longer on this box
#   bash snapshot.sh --no-versions   # skip the CLI --version probes (faster)
#   bash snapshot.sh --out DIR       # manifest dir (default: <script dir>/manifests)
#   bash snapshot.sh --mirror DIR    # also copy the kit + manifests to DIR
#
# Env: BOX_RESTORE_MANIFESTS (=--out), BOX_RESTORE_MIRROR (=--mirror),
#      BOX_RESTORE_WORKSPACE (default /workspace), BOX_BASE_TIME (epoch override
#      for the "base image" cut-off; normally auto-detected).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${BOX_RESTORE_MANIFESTS:-$DIR/manifests}"
MIRROR="${BOX_RESTORE_MIRROR:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    --out=*) OUT="${1#--out=}" ;;
    --mirror) MIRROR="${2:?--mirror needs a directory}"; shift ;;
    --mirror=*) MIRROR="${1#--mirror=}" ;;
    --prune|--no-versions) ARGS+=("$1") ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "snapshot.sh needs python3" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
BR_DIR="$DIR" BR_OUT="$(cd "$OUT" && pwd)" BR_MIRROR="$MIRROR" exec python3 - "${ARGS[@]}" <<'PY'
import os, sys, re, glob, json, subprocess, shutil, time
from urllib.parse import urlparse

DIR = os.environ["BR_DIR"]; M = os.environ["BR_OUT"]; MIRROR = os.environ.get("BR_MIRROR", "")
HOME = os.path.expanduser("~")
WS = os.environ.get("BOX_RESTORE_WORKSPACE", "/workspace").rstrip("/") or "/workspace"
PRUNE = "--prune" in sys.argv; NOVER = "--no-versions" in sys.argv
NOW = time.strftime("%Y-%m-%d %H:%M:%S %Z")
# Files the box platform itself manages in /usr/local/bin (never user installs).
BOX_MANAGED = re.compile(r"^(sand-|box-|cursor[-_]agent|start-|supervise-|stop-window)")

def run(cmd, timeout=8):
    try: return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout
    except Exception: return ""

def read_tsv(name):
    p = os.path.join(M, name); d = {}
    if os.path.exists(p):
        for l in open(p, encoding="utf-8", errors="replace"):
            l = l.rstrip("\n")
            if not l or l.startswith("#"): continue
            k, *rest = l.split("\t"); d[k] = rest[0] if rest else ""
    return d

def write_tsv(name, cur, header, drop=(), keep_old=None):
    """Union-merge cur {key: value} with the existing file (unless --prune).
    drop: keys that must not survive from the old file (e.g. now known as base).
    keep_old(old_value, new_value) -> True keeps the old value for that key."""
    old = read_tsv(name); out = dict(cur)
    for k, v in old.items():
        if k in out:
            if keep_old and keep_old(v, out[k]): out[k] = v
        elif not PRUNE and k not in drop:
            out[k] = v
    with open(os.path.join(M, name), "w") as f:
        f.write(f"# {header}\n# updated {NOW}  (TAB separated)\n")
        for k in sorted(out): f.write(f"{k}\t{out[k]}\n")
    return out

def write_lines(name, lines, header):
    with open(os.path.join(M, name), "w") as f:
        f.write(f"# {header}\n# updated {NOW}\n")
        for l in lines: f.write(l + "\n")

counts = {}

# ---------- base-image cut-off ----------
# Anything whose inode change time (ctime) is newer than CUT was added after the
# base image was laid down. Base image files keep the image build time as ctime.
CUT, CUT_SRC = 0.0, "none"
if os.environ.get("BOX_BASE_TIME", "").strip():
    try: CUT, CUT_SRC = float(os.environ["BOX_BASE_TIME"]), "BOX_BASE_TIME"
    except ValueError: pass
if not CUT:
    try:
        w = int(run("stat -c %W /").strip() or 0)   # birth time of the root fs = box (re)creation
        if w > 0: CUT, CUT_SRC = float(w), "rootfs-birth"
    except ValueError: pass
hist = ""
for f in sorted(glob.glob("/var/log/apt/history.log*")):
    try:
        if f.endswith(".gz"):
            import gzip; hist += gzip.open(f, "rt", errors="replace").read() + "\n"
        elif not f.endswith((".xz", ".bz2")): hist += open(f, errors="replace").read() + "\n"
    except Exception: pass
blocks = [b for b in re.split(r"\n\s*\n", hist) if "Start-Date:" in b]
def listfile(p):
    for c in (f"/var/lib/dpkg/info/{p}.list", *glob.glob(f"/var/lib/dpkg/info/{p}:*.list")):
        if os.path.exists(c): return c
    return ""
def pkgs_of(line):
    return re.findall(r"([^\s,()]+?)(?::[\w-]+)? \(([^)]*)\)", line)
if not CUT:  # fallback: newest apt step of the image build (blocks without Requested-By)
    sig = []
    for b in blocks:
        if "Requested-By:" in b: continue
        m = re.search(r"^Install: (.*)$", b, re.M)
        for n, _ in pkgs_of(m.group(1) if m else ""):
            lf = listfile(n)
            if lf: sig.append(os.stat(lf).st_ctime)
    for f in glob.glob("/usr/local/bin/*"):
        if BOX_MANAGED.match(os.path.basename(f)):
            st = os.lstat(f)
            if st.st_ctime_ns % 1_000_000_000 == 0: sig.append(st.st_ctime)
    if sig: CUT, CUT_SRC = max(sig) + 1, "image-build-signals"
def is_user(path):
    try: st = os.lstat(path)
    except OSError: return False
    if CUT: return st.st_ctime > CUT
    return st.st_ctime_ns % 1_000_000_000 != 0   # layer files carry whole-second times

# ---------- apt ----------
installed = {}
for l in run("dpkg-query -W -f='${Package}\\t${Version}\\t${db:Status-Status}\\n'", 20).splitlines():
    p = l.split("\t")
    if len(p) == 3 and p[2] == "installed": installed[p[0]] = p[1]
manual = set(run("apt-mark showmanual", 20).split())
added, upgraded = {}, set()
for b in blocks:
    if "Requested-By:" not in b: continue
    m = re.search(r"^Install: (.*)$", b, re.M)
    for n, info in pkgs_of(m.group(1) if m else ""):
        if "automatic" not in info and n in installed and n in manual: added[n] = installed[n]
    u = re.search(r"^Upgrade: (.*)$", b, re.M)
    upgraded |= {n for n, _ in pkgs_of(u.group(1) if u else "")}
for n in manual:   # dpkg -i / installs whose apt history is gone
    if n in installed and n not in upgraded and is_user(listfile(n) or "/nonexistent"):
        added.setdefault(n, installed[n])
base_apt = {n: installed[n] for n in manual if n in installed and n not in added}
r = write_tsv("apt-added.txt", added, "apt packages added after the base image (restore.sh installs missing ones)",
              drop=set(base_apt))
counts["apt"] = len(r)
write_tsv("apt-base.txt", base_apt, "apt packages that came with the base image (reference; restore.sh --include-base)",
          drop=set(r))
# extra apt repositories + their public keyrings (never URLs with credentials, never auth.conf)
sd = os.path.join(M, "apt-sources"); os.makedirs(sd, exist_ok=True)
for f in glob.glob("/etc/apt/sources.list.d/*"):
    b = os.path.basename(f)
    if not b.endswith((".list", ".sources")) or b.startswith("debian") or not is_user(f): continue
    try: t = open(f).read()
    except Exception: continue
    if re.search(r"://[^/\s]*@", t) or re.search(r"(?i)token|password|auth", t): continue
    open(os.path.join(sd, b), "w").write(t)
    for k in re.findall(r"(?:signed-by=|Signed-By:\s*)(/\S+?)(?:\]|\s|$)", t):
        if os.path.isfile(k) and k.endswith((".gpg", ".asc")):
            shutil.copy2(k, os.path.join(sd, os.path.basename(k)))

# ---------- nvm / npm ----------
def pkgs_in(nm):
    out = {}
    for pj in glob.glob(os.path.join(nm, "*/package.json")) + glob.glob(os.path.join(nm, "@*/*/package.json")):
        try: j = json.load(open(pj))
        except Exception: continue
        n = j.get("name"); v = j.get("version", "")
        if n and n not in ("npm", "corepack"): out[n] = v
    return out
nvm = os.environ.get("NVM_DIR") or os.path.join(HOME, ".nvm")
nvm_ver = ""
try: nvm_ver = json.load(open(os.path.join(nvm, "package.json"))).get("version", "")
except Exception: pass
vers = {os.path.basename(v): "" for v in glob.glob(os.path.join(nvm, "versions/node/v*"))}
alias = ""
try: alias = open(os.path.join(nvm, "alias/default")).read().strip()
except Exception: pass
active = run("node --version").strip()
def vkey(v): return [int(x) if x.isdigit() else 0 for x in v.lstrip("v").split(".")]
if active not in vers and re.match(r"^v?\d", alias):
    a = alias if alias.startswith("v") else "v" + alias
    cand = sorted((v for v in vers if v == a or v.startswith(a + ".")), key=vkey)
    active = cand[-1] if cand else active
if active in vers: vers[active] = "active"
if nvm_ver: vers["nvm"] = nvm_ver
r = write_tsv("nvm-versions.txt", vers, "nvm itself (row 'nvm') and node versions ('active' = default)",
              keep_old=lambda o, n: o == "active" and n == "")
counts["node"] = len([k for k in r if k != "nvm"])
ng = 0
for v in sorted(k for k in r if k != "nvm"):
    cur = pkgs_in(os.path.join(nvm, "versions/node", v, "lib/node_modules"))
    ng += len(write_tsv(f"npm-global-{v}.txt", cur, f"npm -g under nvm node {v} (wiped by update)"))
ng += len(write_tsv("npm-global-user.txt", pkgs_in(os.path.join(HOME, ".local/lib/node_modules")),
                    "npm -g with prefix ~/.local (NPM_CONFIG_PREFIX); normally survives an update"))
sysnm = "/usr/local/lib/node_modules"
allsys = pkgs_in(sysnm) if os.path.isdir(sysnm) else {}
def npm_user(n): return is_user(os.path.join(sysnm, n))
cur = {n: v for n, v in allsys.items() if npm_user(n)}
base = {n: v for n, v in allsys.items() if n not in cur}
r = write_tsv("npm-global-system.txt", cur, "npm -g in /usr/local added after the base image", drop=set(base))
write_tsv("npm-global-system-base.txt", base, "npm -g in /usr/local from the base image (reference)", drop=set(r))
counts["npm-g"] = ng + len(r)

# ---------- python ----------
def distinfo(sp, only=None):
    out = {}
    for d in glob.glob(os.path.join(sp, "*.dist-info")):
        m = re.match(r"(.+?)-([^-]+)\.dist-info$", os.path.basename(d))
        if m and (only is None or only(d)): out[m.group(1).replace("_", "-").replace(".", "-").lower()] = m.group(2)
    return out
up = {}
for sp in glob.glob(os.path.join(HOME, ".local/lib/python3*/site-packages")): up.update(distinfo(sp))
counts["pip-user"] = len(write_tsv("pip.txt", up, "pip install --user (~/.local, normally survives)"))
sysall, syscur = {}, {}
for d in glob.glob("/usr/local/lib/python3*/dist-packages") + glob.glob("/usr/local/lib/python3*/site-packages"):
    sysall.update(distinfo(d)); syscur.update(distinfo(d, is_user))
sysbase = {n: v for n, v in sysall.items() if n not in syscur}
r = write_tsv("pip-system.txt", syscur, "sudo pip into /usr/local added after the base image", drop=set(sysbase))
write_tsv("pip-system-base.txt", sysbase, "pip packages in /usr/local from the base image (reference)", drop=set(r))
counts["pip-system"] = len(r)
uvt = {}
for l in run("uv tool list 2>/dev/null").splitlines():
    m = re.match(r"^(\S+) v(\S+)", l)
    if m: uvt[m.group(1)] = m.group(2)
counts["uv-tool"] = len(write_tsv("uv-tools.txt", uvt, "uv tool install"))
px = {}
if shutil.which("pipx"):
    try:
        for n, d in json.loads(run("pipx list --json") or "{}").get("venvs", {}).items():
            px[n] = d.get("metadata", {}).get("main_package", {}).get("package_version", "")
    except Exception: pass
counts["pipx"] = len(write_tsv("pipx.txt", px, "pipx install"))

# ---------- cargo / go ----------
cb = {}
for l in run("cargo install --list 2>/dev/null").splitlines():
    m = re.match(r"^(\S+) v(\S+?):?$", l)
    if m: cb[m.group(1)] = m.group(2)
counts["cargo"] = len(write_tsv("cargo-bins.txt", cb, "cargo install"))
gb = {}
for b in glob.glob(os.path.join(HOME, "go/bin/*")):
    mod = ""
    for l in run(f"go version -m '{b}' 2>/dev/null").splitlines():
        p = l.split()
        if len(p) >= 2 and p[0] == "path": mod = p[1]
        if len(p) >= 3 and p[0] == "mod": mod = f"{mod}@{p[2]}"; break
    gb[os.path.basename(b)] = mod
counts["go"] = len(write_tsv("go-bins.txt", gb, "go install (value = module@version)"))

# ---------- bin dirs (reference: things installed by curl/AppImage/tarball) ----------
def listing(d, only_new=False):
    out = []
    for f in sorted(glob.glob(os.path.join(d, "*"))):
        b = os.path.basename(f)
        if only_new and (BOX_MANAGED.match(b) or not is_user(f)): continue
        st = os.lstat(f)
        tgt = (" -> " + os.readlink(f)) if os.path.islink(f) else ""
        out.append(f"{b}{tgt}\t{time.strftime('%Y-%m-%d', time.localtime(st.st_mtime))}")
    return out
write_lines("local-bin.txt", listing(os.path.join(HOME, ".local/bin")), "~/.local/bin (survives an update)")
ulb = listing("/usr/local/bin", True)
write_lines("usr-local-bin-added.txt", ulb,
            "/usr/local/bin entries added after the base image (WIPED by update; add their installers to restore.sh MANUAL INSTALLS)")
counts["usr-local-bin"] = len(ulb)

# ---------- workspace projects (node_modules / .venv are wiped by update) ----------
LOCKS = ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb")
SKIP = {"node_modules", ".git", ".cache", ".next", ".nuxt", "dist", "build", "target", "__pycache__",
        ".playwright-mcp", ".venv", "venv"}
proj, wsroots = {}, set()
vdir = os.path.join(M, "venvs"); os.makedirs(vdir, exist_ok=True)
kit = os.path.realpath(DIR)
def freeze(vp):
    lines = []
    for s in glob.glob(os.path.join(vp, "lib/python3*/site-packages")):
        for d in glob.glob(os.path.join(s, "*.dist-info")):
            m = re.match(r"(.+?)-([^-]+)\.dist-info$", os.path.basename(d))
            if not m: continue
            n = m.group(1).replace("_", "-").lower()
            if n in ("pip", "setuptools", "wheel"): continue
            line = f"{n}=={m.group(2)}"
            try:
                du = json.load(open(os.path.join(d, "direct_url.json")))
                u = du.get("url", "")
                if du.get("dir_info", {}).get("editable") and u.startswith("file://"): line = "-e " + urlparse(u).path
                elif "vcs_info" in du:
                    if "@" in urlparse(u).netloc: continue           # never record credentials
                    line = f"{n} @ {du['vcs_info'].get('vcs', 'git')}+{u}@{du['vcs_info'].get('commit_id', '')}"
                elif "dir_info" in du or u.startswith("file://"): continue
            except Exception: pass
            lines.append(line)
    return sorted(set(lines))
if os.path.isdir(WS):
    for root, dirs, files in os.walk(WS):
        rel = root[len(WS):]
        if os.path.realpath(root) == kit or os.path.basename(root).startswith("box-restore"):
            dirs[:] = []; continue
        for v in (".venv", "venv"):
            vp = os.path.join(root, v)
            if os.path.isfile(os.path.join(vp, "pyvenv.cfg")):
                pyv = ""
                try: pyv = re.search(r"^version(?:_info)?\s*=\s*(\S+)", open(os.path.join(vp, "pyvenv.cfg")).read(), re.M).group(1)
                except Exception: pass
                req = next((x for x in ("uv.lock", "requirements.txt", "pyproject.toml") if x in files), "none")
                fz = freeze(vp)
                if fz: open(os.path.join(vdir, vp.replace("/", "%") + ".txt"), "w").write("".join(l + "\n" for l in fz))
                proj[vp] = f"venv:python{pyv or '?'}:{req}"
        if "package.json" in files:
            lock = next((x for x in LOCKS if x in files), "")
            had = os.path.isdir(os.path.join(root, "node_modules"))
            if had or lock:
                proj[root] = f"node:{lock or 'nolock'}:{'installed' if had else 'lock-only'}"
                try:
                    if json.load(open(os.path.join(root, "package.json"))).get("workspaces"): wsroots.add(root)
                except Exception: pass
        dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")] if rel.count("/") < 4 else []
for p in list(proj):   # members of an npm/yarn/pnpm workspace are installed by the root
    if proj[p].startswith("node:") and any(p != w and p.startswith(w + "/") for w in wsroots): del proj[p]
r = write_tsv("workspace-projects.txt", proj,
              f"projects under {WS} whose node_modules/.venv must be rebuilt (restore.sh --with-projects)",
              keep_old=lambda o, n: o.endswith(":installed") and n.endswith(":lock-only"))
counts["projects"] = len(r)

# ---------- services / desktop apps ----------
svc = sorted({l.strip() for l in run("ps -eo args").splitlines()
              if re.match(r"^(sudo )?(\S*/)?(tailscaled|ollama|cloudflared|sshd|dockerd|containerd|redis-server|postgres|mysqld|nginx|caddy)\b", l.strip())})
names = sorted({re.sub(r"^(sudo )?(\S*/)?", "", l).split()[0] for l in svc})
write_lines("services.txt", ["[daemons]"] + names + ["[user systemd units]"] +
            sorted(os.path.basename(u) for u in glob.glob(os.path.join(HOME, ".config/systemd/user/*"))) +
            ["[crontab]"] + [l for l in run("crontab -l 2>/dev/null").splitlines() if l.strip() and not l.startswith("#")],
            "background services seen at snapshot time (daemon names only, no arguments)")
desk = []
d = os.path.join(HOME, ".local/share/applications")
if os.path.isdir(d): desk += ["[~/.local/share/applications]"] + sorted(os.listdir(d))
d = os.path.join(HOME, "Applications")
if os.path.isdir(d): desk += ["[~/Applications]"] + sorted(os.listdir(d))
desk += ["[/usr/share/applications added]"] + sorted(os.path.basename(f) for f in glob.glob("/usr/share/applications/*.desktop") if is_user(f))
desk += ["[snap]"] + run("snap list 2>/dev/null").splitlines()[1:] + ["[flatpak]"] + run("flatpak list --app --columns=application,version 2>/dev/null").splitlines()
write_lines("desktop-apps.txt", desk, "GUI apps / .desktop files / AppImages")

# ---------- CLI versions (key = command name) ----------
if not NOVER:
    clis = ["codex", "claude", "gemini", "grok", "gh", "git", "tailscale", "ssh", "node", "npm", "pnpm", "bun", "deno",
            "python3", "uv", "pipx", "go", "cargo", "rustc", "docker", "ollama", "cloudflared", "wrangler", "ffmpeg",
            "pdftotext", "jq", "rg", "tmux", "google-chrome", "shellcheck"]
    extra = os.environ.get("NVM_DIR", os.path.join(HOME, ".nvm"))
    out = []
    for n in clis:
        flag = "-V" if n in ("ssh", "tmux") else ("-v" if n == "pdftotext" else ("version" if n in ("go", "tailscale") else "--version"))
        v = run(f"PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$(ls -d {extra}/versions/node/*/bin 2>/dev/null | tr '\\n' ':')$PATH\"; "
                f"command -v {n} >/dev/null && {{ {n} {flag} 2>&1 </dev/null | head -1; }}", 6).strip()
        out.append(f"{n}\t{v or '(not found)'}")
    write_lines("cli-versions.txt", out, "main CLIs at snapshot time (restore.sh warns if one goes missing)")

# ---------- credential locations: existence only, contents are never read ----------
paths = ["~/.codex/auth.json", "~/.claude/.credentials.json", "~/.claude.json", "~/.gemini", "~/.grok",
         "~/.config/gh/hosts.yml", "~/.config/.wrangler", "~/.gitconfig", "~/.git-credentials", "~/.npmrc",
         "~/.netrc", "~/.ssh/config", "~/.ssh/id_ed25519", "~/.ssh/id_rsa", "~/.aws/config",
         "~/.config/gcloud", "~/.docker/config.json", "/var/lib/tailscale/tailscaled.state"]
out = []
for p in paths:
    q = os.path.expanduser(p); ex = os.path.exists(q)
    if not ex and q.startswith("/var/"):
        try: ex = subprocess.run(["sudo", "-n", "test", "-e", q], capture_output=True, timeout=5).returncode == 0
        except Exception: ex = False
    keep = "kept" if q.startswith((HOME, WS)) else "WIPED-by-update"
    out.append(f"{'YES' if ex else 'no'}\t{p}\t{keep}")
write_lines("credential-paths.txt", out, "credential/config locations (existence only; values are never read or stored)")

# ---------- summary (+ optional mirror) ----------
write_lines("counts.txt", [f"{k}\t{v}" for k, v in counts.items()] +
            [f"base-cut\t{time.strftime('%Y-%m-%d %H:%M:%S %Z', time.localtime(CUT)) if CUT else '-'} ({CUT_SRC})"], "counts")
if MIRROR:
    mm = os.path.realpath(os.path.expanduser(MIRROR))
    if mm != os.path.realpath(DIR):
        os.makedirs(mm, exist_ok=True)
        shutil.rmtree(os.path.join(mm, "manifests"), ignore_errors=True)
        shutil.copytree(M, os.path.join(mm, "manifests"))
        for f in ("snapshot.sh", "restore.sh", "README.md", "SKILL_BODY.md", "SKILL_GETTING_STARTED.md", "LICENSE"):
            if os.path.isfile(os.path.join(DIR, f)): shutil.copy2(os.path.join(DIR, f), os.path.join(mm, f))
print("snapshot OK -> " + M + "  (" + ", ".join(f"{k}:{v}" for k, v in counts.items()) + f"; base cut-off: {CUT_SRC})")
PY
