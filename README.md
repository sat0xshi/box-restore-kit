# box-restore-kit

Survive a Grok Bot box update without losing your installed tools.
Grok Bot の box を「アップデート」しても、入れたツールを数分で元に戻すためのキットです。

Author: sat0xshi · License: MIT

[English](#english) · [日本語](#日本語)

---

## English

### What it is
Two scripts and a folder of plain-text manifests:

| File | Purpose |
|---|---|
| `snapshot.sh` | Records everything you added on top of the base image into `manifests/` (apt, extra apt repos/keys, nvm + node versions, `npm -g`, pip/uv/pipx, cargo/go, `/usr/local/bin` additions, `/workspace` projects, daemons, CLI versions, credential *locations*). Takes ~2 s. |
| `restore.sh` | After an update, reinstalls **only what is missing**, from the manifests. Idempotent. |
| `SKILL_BODY.md` | A recipe you can paste into an agent skill / memory so the agent keeps the manifests current and drives the restore. |
| `SKILL_GETTING_STARTED.md` | Short first-run skill: fetch the kit, take the first snapshot, report what was captured. |

Both scripts are non-interactive, never read or write secrets (credential files are only checked for *existence*), and are safe to run any number of times.

### What survives an update and what is wiped

| Survives | Wiped (must be rebuilt) |
|---|---|
| `/workspace` (except the items on the right) | `/usr`, `/etc`, `/opt`, `/var` → apt packages, apt repos, everything in `/usr/local`, `sudo pip`, `sudo npm -g` |
| Most of `/home/box`: `~/.local` (pip `--user`, `npm -g` with prefix `~/.local`, native installers such as Claude Code), `~/.config`, `~/.ssh`, `~/.codex`, `~/.claude*`, `~/Applications` | `~/.nvm` (node **and every `npm -g` CLI installed under it**, e.g. Codex CLI), `~/.npm`, `~/.cache` |
| Logins stored under home (Codex, Claude Code, gh, …) | `node_modules/` and `.venv/` in your projects |
| | Tailscale login (`/var/lib/tailscale`) and running daemons |

The kit itself lives in `/workspace`, so it survives too.

### Install (one line)
```bash
git clone https://github.com/<OWNER>/box-restore-kit /workspace/box-restore && bash /workspace/box-restore/snapshot.sh
```
Without git (raw files):
```bash
mkdir -p /workspace/box-restore && cd /workspace/box-restore && for f in snapshot.sh restore.sh; do curl -fsSLO https://raw.githubusercontent.com/<OWNER>/box-restore-kit/main/$f; done && bash snapshot.sh
```
Any folder under `/workspace` works; the commands below assume `/workspace/box-restore/`. Manifests are written to `manifests/` inside it (git-ignored — never publish them).

### The flow
1. **Before the update** – take a fresh snapshot:
   `bash /workspace/box-restore/snapshot.sh`
2. **Update** – *you* press the update button for the computer in Grok Bot settings ("Update Grok Bot's Computer"). An agent cannot do this for you. (Do not confuse it with *Reset*, which rolls the box back to a snapshot and can lose recent work.)
3. **After the update** – restore:
   ```bash
   bash /workspace/box-restore/restore.sh --dry-run          # preview
   bash /workspace/box-restore/restore.sh --with-projects    # do it
   ```
   A typical run (apt + repo key, nvm + node, `npm -g`, tailscaled, a few `npm ci`, venvs) finishes in about a minute.
4. **Manual re-logins** – the summary prints `MANUAL:` lines. Usually only Tailscale needs a new login (`sudo tailscale up`); home-based logins (Codex, Claude Code) normally survive.

### Options
`snapshot.sh`: `--prune` (forget entries no longer on the box), `--no-versions` (skip CLI version probes), `--out DIR` (manifest dir; default `manifests/` next to the script, env `BOX_RESTORE_MANIFESTS`), `--mirror DIR` (also copy kit + manifests to DIR).

`restore.sh`: `--dry-run`, `--with-projects`, `--all-projects` (also projects that only had a lockfile), `--include-bak` (also `*.bak*` / `*backup*` dirs), `--include-base` (also reinstall base-image packages that the new image dropped), `--latest` (latest versions instead of recorded ones), `--no-services` (don't start tailscaled), `--manifests DIR`.

Env: `BOX_RESTORE_WORKSPACE` (default `/workspace`), `BOX_RESTORE_LOG`, `BOX_RESTORE_LOCK`, `BOX_BASE_TIME` (epoch override for the base-image cut-off).

### How "added by you" is detected
Base-image files keep the image build time as their inode change time; anything you install afterwards is newer than the box's root-filesystem creation time (`stat -c %W /`). Items older than that cut-off (for example the ~30 Python packages a base image may ship in `/usr/local`) are recorded as *base* (`*-base.txt`, reference only) and are **not** reinstalled unless you pass `--include-base`. Manifests are union-merged, so a snapshot taken right after an update (before restoring) never forgets anything; use `--prune` to drop stale entries deliberately.

Projects are found automatically: every directory under `/workspace` (depth ≤ 4) with a `package.json` plus `node_modules` or a lockfile, and every `.venv`/`venv` (with `requirements.txt` / `pyproject.toml` / `uv.lock` noted). Venv package lists are saved in `manifests/venvs/` and replayed on rebuild.

### Things installed by hand (curl installers, AppImages, tarballs)
The manifests only see package managers. If you install something any other way, **add one line to the `MANUAL INSTALLS` section of `restore.sh`** right away:
```bash
custom "<name>" "<check that succeeds when installed>" "<non-interactive install command>"
# e.g.
custom "ollama" "command -v ollama" "curl -fsSL https://ollama.com/install.sh | sh"
custom "MyApp AppImage" "[ -x \"\$HOME/Applications/MyApp.AppImage\" ]" \
  "mkdir -p ~/Applications && curl -fsSL -o ~/Applications/MyApp.AppImage https://example.com/MyApp.AppImage && chmod +x ~/Applications/MyApp.AppImage"
```
Things under `/home/box` (e.g. `~/.local/bin`, `~/Applications`) survive anyway; entries matter most for anything in `/usr`, `/opt`, `/etc`, `/var`. `manifests/usr-local-bin-added.txt` lists `/usr/local/bin` files you added — each of them needs a `custom` line. `restore.sh` also warns when a CLI that existed at snapshot time is still missing after the restore.

### Troubleshooting
**Tailscale: login link expires / `http 410: auth path not found`**
The URL from `sudo tailscale up` can expire within seconds. Start a fresh login in the background and open the new link immediately:
```bash
sudo tailscale logout
sudo nohup tailscale up --force-reauth >/tmp/tailscale-up.log 2>&1 &
sleep 3; cat /tmp/tailscale-up.log     # open the https://login.tailscale.com/... URL right away
tailscale status                       # verify
```
The re-login registers a **new node** (its name gets a `-1` suffix and it gets a new `100.x` IP). Update anything that used the old name/IP, and remove the old node in the Tailscale admin console.

**nvm complains about `NPM_CONFIG_PREFIX`**
If your shell sets `NPM_CONFIG_PREFIX` (e.g. to `~/.local`), `nvm use` refuses to work. `restore.sh` already runs nvm with that variable unset and installs `npm -g` packages with an explicit `--prefix`. In your own shell, either call nvm-installed CLIs by full path (`~/.nvm/versions/node/<ver>/bin/codex`) or run `unset NPM_CONFIG_PREFIX; . ~/.nvm/nvm.sh` first.

**"another restore.sh is running"** – another agent is restoring right now (lock `/tmp/box-restore.lock`). Wait and retry.

**A step failed** – details are in `restore.log` next to the script. Fix the cause and simply rerun; finished steps are skipped.

---

## 日本語

### これは何か
スクリプト 2 本と、テキストのマニフェスト一式です。

| ファイル | 役割 |
|---|---|
| `snapshot.sh` | ベースイメージに**後から追加したもの**を `manifests/` に記録（apt・追加リポジトリと公開鍵・nvm と node・`npm -g`・pip/uv/pipx・cargo/go・`/usr/local/bin` の追加分・`/workspace` のプロジェクト・常駐プロセス・CLI のバージョン・認証ファイルの「場所」）。約 2 秒。 |
| `restore.sh` | アップデート後、マニフェストを見て**足りないものだけ**を再インストール。何度実行しても安全。 |
| `SKILL_BODY.md` | エージェントのスキル/メモリに貼る手順書。記録の更新と復元をエージェントに任せられます。 |
| `SKILL_GETTING_STARTED.md` | 初回用の短いスキル: キット取得 → 最初のスナップショット → 記録内容の報告。 |

どちらも確認プロンプトなし。秘密情報は読み書きしません（認証ファイルは「存在するか」だけ確認）。

### アップデートで残るもの・消えるもの

| 残る | 消える（作り直しが必要） |
|---|---|
| `/workspace`（右の除外以外） | `/usr` `/etc` `/opt` `/var` → apt パッケージ、apt リポジトリ設定、`/usr/local` の全部、`sudo pip`、`sudo npm -g` |
| `/home/box` の大部分: `~/.local`（pip `--user`、prefix `~/.local` の `npm -g`、Claude Code などのネイティブインストーラ）、`~/.config`、`~/.ssh`、`~/.codex`、`~/.claude*`、`~/Applications` | `~/.nvm`（node 本体と、その下の `npm -g` CLI 全部。例: Codex CLI）、`~/.npm`、`~/.cache` |
| home に保存されたログイン（Codex、Claude Code、gh など） | 各プロジェクトの `node_modules/` と `.venv/` |
| | Tailscale のログイン状態（`/var/lib/tailscale`）と常駐プロセス |

キット自体は `/workspace` に置くので残ります。

### 導入（1 行）
```bash
git clone https://github.com/<OWNER>/box-restore-kit /workspace/box-restore && bash /workspace/box-restore/snapshot.sh
```
git を使わない場合（raw ファイル）:
```bash
mkdir -p /workspace/box-restore && cd /workspace/box-restore && for f in snapshot.sh restore.sh; do curl -fsSLO https://raw.githubusercontent.com/<OWNER>/box-restore-kit/main/$f; done && bash snapshot.sh
```
`/workspace` の下ならどこでも動きます（以下は `/workspace/box-restore/` 前提）。記録は中の `manifests/` に保存されます（.gitignore 済み。公開しないこと）。

### 流れ
1. **アップデート前** — 最新のスナップショットを取る:
   `bash /workspace/box-restore/snapshot.sh`
2. **アップデート** — Grok Bot の設定画面でコンピューターの更新ボタン（"Update Grok Bot's Computer"）を**ユーザー自身が**押します。エージェントには押せません。（「Reset」は別物で、スナップショットに巻き戻して最近の作業を失うことがあるので使わない。）
3. **アップデート後** — 復元:
   ```bash
   bash /workspace/box-restore/restore.sh --dry-run          # 確認だけ
   bash /workspace/box-restore/restore.sh --with-projects    # 実行
   ```
   apt＋リポジトリ鍵、nvm＋node、`npm -g`、tailscaled 起動、数件の `npm ci`、venv 再作成で、だいたい 1 分ほどです。
4. **手動の再ログイン** — 最後に `MANUAL:` 行が出ます。通常は Tailscale（`sudo tailscale up`）だけ。Codex や Claude Code のログインは home に残るので普通は不要です。

### オプション
`snapshot.sh`: `--prune`（box に無くなった項目を記録から消す）、`--no-versions`（CLI のバージョン取得を省略）、`--out DIR`（マニフェストの出力先。既定はスクリプト横の `manifests/`、環境変数 `BOX_RESTORE_MANIFESTS`）、`--mirror DIR`（キットとマニフェストを DIR にもコピー）。

`restore.sh`: `--dry-run`、`--with-projects`、`--all-projects`（lockfile だけで未インストールだったプロジェクトも）、`--include-bak`（`*.bak*` / `*backup*` も対象）、`--include-base`（新イメージから消えたベースイメージ由来のパッケージも入れる）、`--latest`（記録バージョンではなく最新）、`--no-services`（tailscaled を起動しない）、`--manifests DIR`。

環境変数: `BOX_RESTORE_WORKSPACE`（既定 `/workspace`）、`BOX_RESTORE_LOG`、`BOX_RESTORE_LOCK`、`BOX_BASE_TIME`（ベースイメージ判定の基準時刻を epoch で上書き）。

### 「自分で追加したもの」の判定方法
ベースイメージのファイルは inode の変更時刻がイメージ作成時のままで、後から入れたものは box のルートファイルシステム作成時刻（`stat -c %W /`）より新しくなります。基準より古いもの（例: ベースイメージが `/usr/local` に同梱する 30 個前後の Python パッケージ）は *base* として `*-base.txt` に参考記録し、`--include-base` を付けない限り再インストールしません。マニフェストは和集合でマージするので、アップデート直後（復元前）に snapshot を実行しても記録は消えません。不要な項目を消すときは `--prune`。

プロジェクトは自動検出します: `/workspace` 以下（深さ 4 まで）で `package.json` と `node_modules` または lockfile があるディレクトリ、および `.venv` / `venv`（`requirements.txt` / `pyproject.toml` / `uv.lock` の有無も記録）。venv のパッケージ一覧は `manifests/venvs/` に保存し、再作成時に使います。

### 手で入れたもの（curl インストーラ・AppImage・tarball）
マニフェストが見えるのはパッケージマネージャ経由のものだけです。それ以外の方法で入れたら、**すぐに `restore.sh` の `MANUAL INSTALLS` セクションに 1 行追加**してください。
```bash
custom "<名前>" "<入っていれば成功する確認コマンド>" "<確認なしで入るインストールコマンド>"
# 例
custom "ollama" "command -v ollama" "curl -fsSL https://ollama.com/install.sh | sh"
```
`/home/box` 以下（`~/.local/bin`、`~/Applications` など）はもともと残るので、特に必要なのは `/usr` `/opt` `/etc` `/var` に入るものです。`manifests/usr-local-bin-added.txt` に載っている `/usr/local/bin` の追加ファイルは、すべて `custom` 行が必要です。復元後もスナップショット時にあった CLI が見つからない場合、`restore.sh` が WARN を出します。

### トラブルシューティング
**Tailscale: ログインリンクがすぐ切れる / `http 410: auth path not found`**
`sudo tailscale up` の URL は数十秒で期限切れになることがあります。バックグラウンドで新しいログインを開始し、出たリンクをすぐ開いてください。
```bash
sudo tailscale logout
sudo nohup tailscale up --force-reauth >/tmp/tailscale-up.log 2>&1 &
sleep 3; cat /tmp/tailscale-up.log     # https://login.tailscale.com/... をすぐ開く
tailscale status                       # 確認
```
再ログインすると**新しいノード**として登録されます（名前に `-1` が付き、`100.x` の IP も変わる）。古い名前や IP を使っていた設定を直し、古いノードは Tailscale の管理画面で削除してください。

**nvm が `NPM_CONFIG_PREFIX` について文句を言う**
シェルで `NPM_CONFIG_PREFIX`（例: `~/.local`）が設定されていると `nvm use` が動きません。`restore.sh` は nvm をこの変数なしで実行し、`npm -g` は `--prefix` を明示して入れるので問題ありません。自分のシェルでは、nvm で入れた CLI をフルパスで呼ぶ（`~/.nvm/versions/node/<ver>/bin/codex`）か、先に `unset NPM_CONFIG_PREFIX; . ~/.nvm/nvm.sh` を実行してください。

**"another restore.sh is running"** — 別のエージェントが復元中です（ロック `/tmp/box-restore.lock`）。少し待って再実行。

**途中で失敗した** — 詳細はスクリプト横の `restore.log`。原因を直して再実行すれば、終わった手順は飛ばされます。
