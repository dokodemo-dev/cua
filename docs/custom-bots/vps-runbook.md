# VPS 配置手順（本番）

契約から受け入れまでの手順。ここまで実行すれば、あとは実際の VPS で順に流すだけになる。
対象は新規 VPS（KAGOYA 4GB 以上を想定）。Mac は GUI とローカル確認にだけ使う。

## 0. 前提

- 既存の WireGuard ネットワークに peer として加える（ハブは既存のもの）。
- 管理ポートは `wg0` からのみ許可し、公開するのは WireGuard の UDP だけ。
- サービスの状態は `/var/lib/cua-bots`。トークンは 0600 で、リポジトリには置かない。
- 本番の実行系は Go（`examples/cua-bots-service-go`）。

## 1. 契約と初期設定

| 手順 | 確認 |
| --- | --- |
| VPS を契約（KAGOYA 16GB 第一候補。試すだけなら 4GB の日額） | 管理画面で OS を Ubuntu 24.04 に |
| 非 root ユーザーを作り、公開鍵を置く | `ssh` で入れる |
| パスワード認証と root ログインを無効化 | `sshd -T` で `passwordauthentication no` |
| UFW を有効化（22 は `wg0` のみ、WireGuard の UDP だけ公開） | `ufw status verbose` |
| Docker を導入 | `docker run --rm hello-world` |
| イメージを取得 | `docker pull ghcr.io/trycua/linux:24.04` |

初期設定の詳細なチェックリストは `dokodemo-vps-access` スキルの
`references/vps-initial-setup-checklist.md` を使う。

## 2. WireGuard peer 追加

**`wg0.conf` を手で編集しない。** ハブの監視（wireguard-observer）は peer 台帳 `peer-inventory.json` と
照合しており、手動追加した peer は「未登録」として要確認になる。登録はハブ上の
`wireguard-peer-register` を使う。

```sh
# 新 VPS 側で鍵と PSK を作る
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo sh -c 'umask 077; wg genpsk > /etc/wireguard/preshared.key'
sudo chmod 600 /etc/wireguard/private.key /etc/wireguard/preshared.key
```

公開鍵と PSK をハブへ渡し、**root 所有 0600 のファイル**にしてから登録する
（`-public-key-file` は 0400/0600 以外を拒否する）。

```sh
# ハブ側
sudo install -o root -g root -m 0600 /tmp/cua-custom.pub /etc/wireguard/cua-custom.pub
sudo install -o root -g root -m 0600 /tmp/cua-custom.psk /etc/wireguard/cua-custom.psk
sudo /usr/local/sbin/wireguard-peer-register \
  -name cua-custom-vps -public-key-file /etc/wireguard/cua-custom.pub \
  -psk-file /etc/wireguard/cua-custom.psk
```

- 返ってきたクライアント設定（AllowedIPs / endpoint）を新 VPS 側の `wg0.conf` に入れる。
- 空きアドレスは登録時に決まる（`.7` に戻るとは限らない）。
- 旧版の register には `-public-key-file` / `-psk-file` が無い場合がある。
  `cd vps-agent && ansible-playbook hub.yml --tags wireguard_hub` で現行版を配ってから実行する。
- 手動で追加してしまった peer は、`wg0.conf` の該当 `[Peer]` を削除して
  `sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'` で外し、上記の登録で入れ直す。

### 2.1 再起動後も tunnel が戻ることを確かめる

`wg` で直接作った interface は再起動で消える。`[Interface]` に `Address` と `ListenPort`、
`[Peer]` に `Endpoint` と `PersistentKeepalive = 25` が入った `/etc/wireguard/wg0.conf`（0600）を作り、
`wg-quick@wg0` を enable しておく。

```sh
# 実行中の interface から設定を作り直す（秘密鍵を画面に出さない）
ADDR=$(ip -4 -o addr show wg0 | awk '{print $4}' | cut -d/ -f1)
sudo wg showconf wg0 | sudo awk -v a="$ADDR/24" '{print} /^\[Interface\]/ && !d {print "Address = " a; d=1}' \
  | sudo install -m 600 -o root -g root /dev/stdin /etc/wireguard/wg0.conf
sudo wg-quick strip wg0 >/dev/null && sudo systemctl enable wg-quick@wg0
```

- `ListenPort` を固定したら、公開側 address にその UDP ポートだけを許可する。
  fleet の他ホストと同じく、公開するのは WireGuard の UDP だけにする。
- `systemd-socket-proxyd` の中継で入っている場合、`wg0` が落ちると管理経路も切れる。
  2 分間隔の watchdog（`wg0-watchdog.timer` → `wg0-recover`）を入れておくと、
  起動に失敗しても自動で戻る。
- 再起動は一度実際にかけて、VPN 経由で戻ることを確認する。戻らなければコンソールしか残らない。

**変更前に VNC／シリアルコンソールを確保する。** `wg show` で handshake を確認してから次へ進む。

## 3. ビルドと配置

ローカル（Mac）で Linux 向けバイナリを作る。

```sh
cd examples/cua-bots-service-go
GOOS=linux GOARCH=amd64 go build -o cua-bots-service ./cmd/cua-bots-service
GOOS=linux GOARCH=amd64 go build -o cua-bots-scheduler ./cmd/cua-bots-scheduler
```

`cua-bots-service`、`cua-bots-scheduler`、`scripts/` を VPS の 1 つのディレクトリへ置き、次を実行する。

```sh
cd /tmp/cua-bots-dist
sudo ./scripts/install-vps.sh --bind <新 VPS の WG アドレス> --port 7717          # 何をするか表示
sudo ./scripts/install-vps.sh --bind <新 VPS の WG アドレス> --port 7717 --apply   # 実行
```

- `/usr/local/bin` に 2 つのバイナリと `cua-bot-turn` を置く。
- `cua-bots` ユーザーと `/var/lib/cua-bots`（0700）を作る。
- `cua-bots-service.service` / `cua-bots-scheduler.service` を書いて有効化する。
- `--bind` が loopback 以外なら `--allow-remote` が unit に書き込まれる（トークンが境界）。

## 4. 資格情報

```sh
sudo -u cua-bots cua-bots-service --state /var/lib/cua-bots --seed-bots alpha,beta
sudo -u cua-bots cua-bots-service --state /var/lib/cua-bots --admin
sudo -u cua-bots cua-bots-service --state /var/lib/cua-bots --mint alpha
```

- `admin.token` はホスト専用（`manageRegistry`、どの Space にも属さない）。
- 各 Bot のトークンは `/var/lib/cua-bots/<bot>.token`（0600）。Bot へは URL とパスだけ渡す。
- ブラウザの「Bots」タブからも作成できる（`POST /v1/manage/bots`、管理者の資格情報が必要）。
  資格情報は作成時に一度だけ返り、`/var/lib/cua-bots/<bot>.token` にも書かれる。
  Bot 自身の資格情報では Bot を作れない（403）。
- Space は VPS 上に作る: `cua spaces create --on local --name bot-<id>`。
  トークンは `local:bot-<id>` のバインディングに対して発行する。
- **発行したトークンは状態ファイルにも保存される。** サービスを起動したまま CLI で発行した場合は
  再起動するか、管理 API（`POST /v1/manage/bots/<id>/token`）で発行する。どちらも
  `/var/lib/cua-bots/<bot>.token` を上書きしないので、返り値を自分で保存する。

## 4.2 Cua CLI と Space

Bot のターンは `cua` CLI が Space の中でハーネス（既定は Pi）を動かす。CLI は VPS 上でビルドする。

```sh
# ビルド（ソースはリポジトリの libs/cua。vendor ファイルが要る）
#   libs/images/sandbox-images.json  -> /images に置く
#   libs/cua-spacesd/VERSION          -> crates/cua-host/vendor/cua-spacesd-VERSION
sudo docker run --rm -v /tmp/cua-src:/src -w /src rust:1.97.1 \
  bash -c 'cargo build --release --locked -p cua-cli'
sudo install -m 0755 /tmp/cua-src/target/release/cua /usr/local/bin/cua
```

```sh
# Space を作り、サービス用の CUA_HOME に登録する
export CUA_HOME=/var/lib/cua-bots/.cua CUA_TELEMETRY=0 DO_NOT_TRACK=1
sudo -u cua-bots usermod -aG docker cua-bots   # 先に一度だけ
cua sb create linux --on local --kind container --name bot-alpha
cua spaces add local:bot-alpha --name bot-alpha
```

- `cua agent run <space> <harness> <prompt>` は **登録済みの Space** を要求する（未登録は `not found`）。
- ターンは `cua agent run --json` で run id を取り、次の配送は `cua agent send <space> <run> <prompt>` で同じセッションに送る。
- モデルは `--model` と `--base-url` で差し替えられる（OpenAI 互換）。鍵は `--env-from-host` で
  ホストの環境変数を名前だけ渡す。

### 4.2.1 定期実行（routine）の登録

GUI はルーティンをメモリ上で編集する。VPS ではスケジュールがファイルなので、
`cua-bots-scheduler` に同じ操作を用意してある（すべてスケジューラーのロック内で書き換える）。

```sh
S="sudo -u cua-bots /usr/local/bin/cua-bots-scheduler --state /var/lib/cua-bots/scheduler --owner cua-bots"

$S --add-job alpha --job-title Daily --job-prompt "Summarize what changed since the last run." \
   --job-every 24h --job-delay 10m       # 登録（--job-every は 1m 以上）
$S --jobs                               # 一覧（id / bot / 間隔 / 次回 / 状態）
$S --pause-job <id>                     # 一時停止
$S --resume-job <id>                    # 再開
$S --remove-job <id>                    # 削除（その求人の未配送スロットも消える）
```

- `--job-delay` を省くと次のティックで即実行される。課金やクォータを使う前に、まず
  `--pause-job` で止めた状態から始めるほうが安全。
- 実行は `cua-bot-turn` が受け持つ。run は初回に作り、以降は同じセッションへ送る。
- ルーティンは `CUA_BOT_MODE=wait` で回し、終わったターンを `POST /v1/bots/<id>/chat/record`
  でサービスへ返す。ブラウザのチャットと同じ画面に並ぶ。
- そのため **claim の期限はターンの上限より長くする**（`--claim-timeout 20m`、
  `--exec-timeout 16m`）。2 分のままだと、長いターンの途中で別の claim が走り得る。

### 4.2.1b ブラウザでチャットする

サービスは `/ui` で画面を返す。Mac では `cua-bots-open` を実行すると、VPS の
管理者資格情報でログインリンクを作ってブラウザで開く（`~/.zshrc` の関数）。

**リンクは長期トークンを運ばない。** `cua-bots-open` はまず
`POST /v1/login/code`（管理者トークンで認証）で **60 秒・1 回限りのコード**を発行し、
`https://bots.dokodemo-dev.internal:7717/ui#c=<code>` を開く。ページはフラグメントを
読み次第 URL から消し、`POST /v1/login/exchange` でコードを **HttpOnly Cookie** と
交換する。以後の API 呼び出しは Cookie で認証され、JS はトークンを持たない。

- コードは推測できない乱数（32 バイト）で、交換時に原子的に消費する。期限切れ・使用済みは 401
- Cookie は `HttpOnly; SameSite=Strict; Path=/`（HTTPS では `Secure`）。JS から読めないため、
  XSS があってもトークンを持ち出せない（Cookie を使った操作は防げない）
- 画面のサインイン欄（手入力）も同じ交換 API を使う。値は保存しない
- 旧リンク（`#k=<トークン>`、`?login=<トークン>`）は**廃止した**。`?login=` は 410 を返し、
  `#k=` は交換しない（画面が「この形式のリンクは廃止されました」と出す）。
  実運用前だったため互換期間は設けていない
- 交換の試行は送信元アドレスごとに制限する
- iPhone は `POST /v1/login/device` にコードを送って**トークンを受け取り**、Keychain に
  保存する（Cookie を持てないアプリ向け。コードは同じく 1 回限り）
- Cookie で認証された**更新系**（POST/PUT/DELETE）は `Origin` が要求ホストと一致することを
  必須にした。Bearer（curl や iPhone）は対象外
**ブラウザからのポーリングは 2 秒間隔・タブが隠れている間は停止**。サーバーの制限は
600 リクエスト/分（60 だと画面が自分の上限に当たり、サインインしていないように見えた）。`/ui?logout=1` は両方を消す。設定タブは `GET /v1/session` で「種類（管理者 / Bot）・
有効期限・できること」を出す。鍵そのものは返さない。失効したリンクで開いた場合は
「このリンクはもう使えません」と出る。

ハブのアドレスは ssh config の `HostName`（tailnet 名）を使わず、7717 に応答した
WireGuard のピアを選ぶ。Tailscale が止まっていても届く。

- 管理操作（Bot の一覧・作成・資格情報の発行）は管理者の資格情報で行う。
- 管理者はどの Bot のチャットも操作できる（パスの Bot を対象にする）。Bot の
  資格情報は自分の Bot に閉じたまま。
- 「Bots」タブで Bot を作るときは、動かす Space を一覧から選ぶか、新しい Space を作る。
  一覧は `GET /v1/spaces`（`cua spaces ls --json --no-size` の結果）で返す。
- 新しい Space を選ぶと、`--cua` の CLI が `cua sb create` と `cua spaces add` を実行して
  Space まで用意する（`--no-provision` で無効化、`--provision-timeout` で上限）。
  既存の Space を選んだ場合は作り直さない（`createSpace: false`）。
  進捗は `GET /v1/bots/<id>/space` が `pending` / `ready` / `failed` で返す。
- 成果物の一覧は `GET /v1/bots/<id>/artifacts`。その Bot と同じ Space の記録だけを返し、
  実体（バイト列）は Space の中に残る。登録は Bot のトークンによる `POST /v1/bots/<id>/artifacts`。
- ピン留めは `GET /v1/pins`、`PUT /v1/pins/<id>`、`DELETE /v1/pins/<id>`（管理者のみ）。
  `service-state.json` の `pins` に保存され、同じ資格情報で開いた端末で共有される。
  Swift 版が状態を書き戻すと `pins` は落ちる（実行状態ではないため許容）。
- Bot の作成は 1 つのダイアログ（名前 → 形と色 → 動かす Space）にまとめた。名前は
  1〜63 文字の半角小文字英数字と `.` `_` `-` だけで、画面側でも送信前に検査する。
  既存の Space を選んだときは、`trustGroup` を省略すればその Space の信頼グループを
  引き継ぐ（画面はグループを知らないため）。見た目は Mac アプリと同じ
  コアラで、`name` から色が決まる（`GET /v1/bots` の `avatars`、変更は
  `POST /v1/manage/bots/<id>/avatar` に `{color,eyes,ears}`）。
- レジストリ上の Space と実際に動く Space がずれたら、`POST /v1/manage/bots/<id>/space`
  で付け替える（画面では「見た目」の Space 選択）。ずれたままにすると、ターンが
  `Space ... is not registered` で落ちる。
- チャットの取得は、カーソルより前でも**直近2ターンと実行中のターンを必ず返す**。
  そうしないと、走っているターンの本文が伸びず、終わったことも画面に伝わらない。
- Bot は削除ではなく **アーカイブ** で片付ける（`POST /v1/manage/bots/<id>/archive`、
  戻すのは `.../unarchive`）。Space・ワークスペース・履歴はそのまま残り、一覧から外れ、
  資格情報は失効する。アーカイブ中の Bot を操作すると 409 を返す。
  削除は「Space をどうするか」を決める別の判断なので、まだ用意していない。
- アーカイブすると、その Bot のルーティンは**自動で止まる**（戻すと再開する。自分で止めた
  ものは止まったまま）。スケジューラーは `cua-bot-turn` を直接起動するので、トークンの
  失効だけでは止まらない。実装は `pausedByArchive` をジョブに付け、戻すときにそれだけを再開する。
- **作った Space には Pi のログインがまだ無い。** そのまま話しかけると
  `not signed in yet` で失敗する（`cua-bot-turn` が ACP の失敗を検出して即座に返す）。
  §4.3 の手順でその Space の中の Pi にログインしてから使う。ログイン済みの Space
  （例 `local:bot-alpha`）を選んで作れば、その場で会話できる。

- `POST /v1/bots/<id>/chat` に `{"prompt": "..."}` を送ると、サービスが
  `cua-bot-turn` を `CUA_BOT_MODE=wait` で起動し、ターンのログを流し込む。
- `GET /v1/bots/<id>/chat?after=<n>` が新しいターンを返す。画面は 1 秒間隔で見に行く。
- **1 Bot につき同時 1 ターン**。実行中に送ると 429 を返す。
- 画面は「チャット / Bots / ルーティン / 設定」のタブに分かれている。ルーティンは
  **Bot ごと**に持ち、画面から追加・停止・再開・削除できる（`POST /v1/bots/<id>/routines`、
  `POST .../routines/<job>/{pause,resume}`、`DELETE .../routines/<job>`）。
  書き込みはサービスがスケジューラーと同じ `scheduler.json` を同じ flock で更新する
  （`--scheduler-state` のディレクトリ）。CLI（`cua-bots-scheduler --add-job`）も併用できる。
- 間隔は 60 秒以上のみ受け付ける。`delaySec` で初回の時刻を決める。
- ターンは状態ファイルに保存する（直近 200 件/Bot）。サービス再起動で「実行中」だった
  ターンは failed として復元する。
- 資格情報の既定の有効期間は 30 日。`--rotate` / `--revoke` で入れ替える。
- ターンのログに保存する run は Space ごとに分ける（`<bot>.<space>.run`）。Space を
  作り直した場合、古い run は自動で捨てて新しく始める。

### 4.2.1c チャットに出るもの

ターンのログのうち、**エージェントの言葉だけ**をチャットへ流す。`cua-bot-turn` の目印
（`turn bot=…`、`[turn N ended]`）と Cua CLI の進捗（`[install]`、`[notice]`）は stderr へ
分け、失敗したときだけ stderr の最後の行を理由として画面に出す。

### 4.2.1c2 thinking の表示

エージェントの思考は `[thinking]` 行としてログに流れる。画面は**最後の `[thinking]` 行まで**を
「考えていること」、それ以降を回答として分ける（長い思考は印の無い行に折り返すため、
行単位ではなく位置で切る）。表示は折りたたみで、**既定で開くか閉じるかは設定タブ**で選ぶ
（`localStorage` の `cua.thinking.open`、このブラウザだけ）。見出しをクリックした結果は
そのターンでは設定より優先する。

### 4.2.1d サービスとスケジューラーは同じ版で動かす

`internal/domain` を共有しているので、片方だけ更新すると、古い側が知らないフィールド
（例: `pausedByArchive`）を書き戻しで落とす。`install-vps.sh` と手動配備のどちらでも
**2 つのバイナリを同時に**入れ替える。

### 4.2.2 画面をブラウザで見る

`cua sb view` のチケットは約 1 時間で切れるので、必要になるたび取り直す。
`cua-view-url [space] [host:port]` が、リレー経由の URL か、指定した host:port に
書き換えた URL を 1 行で返す。

- **平文の HTTP でリモートから開くと secure context にならず、WebCodecs が無効になる。**
  その状態では映像のコーデック交渉が成立せず `no acceptable codec` で止まる。
- 対策は `ssh -L 13280:<VPS_WG>:3280` でループバックへ引き、`http://127.0.0.1:13280/viewer/` を開くこと。
  Mac 側は `~/.zshrc` の `cua-view` 関数がこれを行う（`cua-view [space]`）。
- トンネルは張りっぱなしになる。閉じるボタンは無いので `pkill -f "L 13280"`。
- Space を作り直すとコンテナのホスト側ポートが変わる。`cua-view.service` は 1 つの
  アドレスしか持たないので、`cua-view-follow` が `docker ps` から現在のポートを引き、
  変わっていたときだけ unit を書き換えて再起動する（`cua-view-follow.timer` が 2 分ごと）。

### 4.3 モデル（ChatGPT プランで動かす）

ChatGPT のプランは API ではないので、API キーではなく **Space の中の Pi に OAuth でログイン**する。
`codex` CLI は要らない。

```sh
# ゲストのシェルで一度だけ
~/.cua/bin/pi      # /login → ChatGPT を選び、ブラウザで認証する
```

認証は `/home/cua/.pi/agent/auth.json`（0600）に入る。Mac 側の認証情報はコピーしない。

**`cua agent run ... --model` だけでは効かない。** ハーネスは `--base-url` を渡したときだけ
run 用のモデル設定を書くので、ChatGPT 認証で動かすときはゲストの既定モデルを設定する。

```json
{"defaultProvider": "openai-codex", "defaultModel": "gpt-6.1-sol"}
```

置き場所はゲストの `/home/cua/.pi/agent/settings.json`。`turn.env` には次だけ置けばよい（鍵は不要）。

```
CUA_BOTS_HARNESS=pi
CUA_BOT_MODEL=gpt-6.1-sol
```

- モデルを変えたら run を作り直す（`/var/lib/cua-bots/runs/<bot>.run` を消す）。
  既存 run は古いモデルのままターンを重ねる。
- `/login` の一覧に ChatGPT が出ない版の Pi では、Space 内の Pi を更新する
  （cua のインストーラ管理外になるので、更新した旨を記録しておく）。

スケジューラーからは `cua-bot-turn` を exec-command にし、環境は unit の drop-in で渡す。
**チャットのターンも同じ `turn.env` を読む**ので、`cua-bots-service` にも同じ drop-in を置く。
無いと、Bot ごとの設定を持たない Bot は全体既定を受け取れず、認証エラーで失敗する。

```ini
# /etc/systemd/system/cua-bots-scheduler.service.d/env.conf
[Service]
EnvironmentFile=/etc/cua-bots/turn.env
```

`turn.env`（0600）に入れるのは `CUA_TELEMETRY=0`、`HOME`、`CUA_HOME`、`PATH`、
`CUA_BOT_MODEL`、`CUA_BOT_BASE_URL`、`CUA_BOT_WIRE`、`CUA_BOT_KEY_VARS` と、その鍵。

ルーティンの配送にも Bot ごとの設定（と時間帯の切り替え）を効かせるには、
`CUA_BOTS_AGENT_URL` にサービス URL（`http://<hub の WG アドレス>:7717`）を置く。
`cua-bot-turn` が `GET /v1/bots/<id>/agent/env` を Bot のトークンで読み、その時刻に
適用される harness / model / baseURL / wire / 鍵の名前 / ヘッダーを受け取る。

`CUA_BOTS_SPACE` は **turn.env に置かない**。チャットのターンはサービスが Bot ごとの Space を
渡すが、ルーティンの配送はスケジューラーが渡さないため、全体に置くと全部のルーティンが同じ
Space で走る（2026-10-27 に実際に起きていた）。

### 4.3.0 API キーを画面から入れる

Web の「設定 → API キー」から、プロバイダの鍵を保存できる（管理者のみ）。
保存先は `/var/lib/cua-bots/keys.json`（0600、`cua-bots`）で、値は API から返さない
（一覧は名前と下 4 桁だけ）。

- `cua-bot-turn` が、その Bot の鍵の変数が環境に無いときこのファイルから読む。
  `turn.env` に値があればそちらが優先される。
- そのため鍵ごとに SSH で `turn.env` を編集する必要はない。既存の `turn.env` の値は
  そのまま動く。
- 鍵を消すと、次にその名前を使うターンから `turn.env` の値（無ければ失敗）になる。

### 4.3.1 Bot ごとのエージェント設定

Web の右パネル「エージェント」から、Bot ごとに harness / model / base URL / wire / 鍵の変数名を
保存できる（`GET` / `PUT /v1/bots/<id>/agent`、管理者のみ、`service-state.json` の `agents`）。
保存するとその Bot の run ファイルを消すので、次のターンは新しい設定で始まる。

- ChatGPT のサブスクは「Space のログイン」を選ぶ（harness `pi`、モデルは Space の既定）。
- DeepSeek は「DeepSeek」を選ぶ。中身は harness `pi`、`https://api.deepseek.com/v1`、
  wire `openai-chat`、`DEEPSEEK_API_KEY`。この鍵は `OPENAI_API_KEY` として Run に渡る。
- DeepSeek のモデルを Ollama Cloud で動かすなら「Ollama Cloud」を選ぶ（`pi`、
  `https://ollama.com/v1`、wire `openai-chat`、モデル `deepseek-v4.1-flash:1017`、
  `OLLAMA_API_KEY`）。
- OpenCode Zen の Go 枠で動かすなら「OpenCode Go」を選ぶ（`pi`、
  `https://opencode.ai/zen/go/v1`、wire `openai-chat`、モデル `deepseek-v4.1-flash`、
  `OPENCODE_API_KEY`、ヘッダー `x-opencode-session=cua-bots`）。このヘッダーが無いと
  400 `MissingSessionID` で拒否される。
- dsh で動かすなら「DeepSeek Harness」を選ぶ。中身は harness `deepseek-harness`、
  dsh 標準の DeepSeek 経路、`DEEPSEEK_API_KEY`。エンドポイントを指定する場合は
  «カスタム» で base URL と wire `openai-chat` を入れる。
- どちらのプリセットも、新しい `cua` CLI を配備してから使う（harness 一覧は CLI 側に埋め込まれている）。
- 鍵は `turn.env` に置き、画面には変数名だけを書く。
- harness と wire の対応は `cua agent harnesses` と `cua agent run --help` を正本にする。

## 4.5 TLS

VPN 内でも TLS を使う（2026-10-30 から有効）。経路は次のとおり。

```text
Mac/iPhone -> https://bots.dokodemo-dev.internal:7717
                  |  (CoreDNS がハブの WG アドレスを返す)
                  v
             ハブの WG アドレス:7717  (systemd-socket-proxyd の TCP 中継)
                  |  (TLS はそのまま通る)
                  v
             cua-vps の WG アドレス:7717  cua-bots-service が TLS 終端
```

- 証明書は VPN 専用 CA（`vpn-dokodemo-dev internal CA`）が発行する。この CA は
  `nameConstraints` で `.dokodemo-dev.internal` に限定しているため、IP SAN は発行できない。
  名前で接続する。
- サーバー鍵は cua-vps で生成し、外へ出さない。CSR だけを管理端末へ渡して署名する。
  CA 秘密鍵は Passman にあり、VPS へ置かない。
- 証明書と鍵は `/var/lib/cua-bots/tls/`（鍵 0600、`cua-bots`）。systemd の drop-in で
  `--tls-cert` / `--tls-key` を渡す。`/etc/cua-bots` は 0700 root なので、サービス
  ユーザーが読める場所に置く必要がある。
- UI の応答には CSP（`default-src 'self'`、インラインスクリプト不可）、
  `X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY`、
  `Referrer-Policy: no-referrer` を付ける。ログインページのインラインスクリプトだけ
  は nonce で許可する。
- 証明書の有効期間は 365 日。更新は 4.5.1 の手順で行う。

### 4.5.1 証明書の更新

```sh
# cua-vps: 鍵と CSR（鍵は現地生成。既存があれば作り直さない）
sudo install -d -o cua-bots -g cua-bots -m 0750 /etc/cua-bots/tls
sudo openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout /etc/cua-bots/tls/server.key -out /etc/cua-bots/tls/server.csr \
  -subj "/CN=bots.dokodemo-dev.internal/O=dokodemo-dev"
sudo chown cua-bots:cua-bots /etc/cua-bots/tls/server.key /etc/cua-bots/tls/server.csr
sudo chmod 0640 /etc/cua-bots/tls/server.key
```

```sh
# 管理端末: CSR に署名（CA 鍵は Passman から実行時だけ取り出す）
cat > server.ext <<'EXT'
[v3_req]
subjectAltName = DNS:bots.dokodemo-dev.internal
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EXT
openssl x509 -req -in server.csr -CA vpn-dns-ca.crt -CAkey <ca-key> \
  -CAcreateserial -out server.crt -days 365 -sha256 \
  -extfile server.ext -extensions v3_req
openssl verify -purpose sslserver -verify_hostname bots.dokodemo-dev.internal \
  -CAfile vpn-dns-ca.crt server.crt
```

署名した `server.crt` だけを cua-vps の `/etc/cua-bots/tls/` へ置き、サービスを再起動する。

### 4.5.2 クライアント

- Mac: VPN CA（`vpn-dns-ca.crt`）を Keychain の「システム」へ信頼登録する。ブラウザと
  `curl` はこれで通る。Node.js は OS のストアを見ないので `NODE_EXTRA_CA_CERTS` を使う。
- iPhone: VPN CA をプロファイルで信頼し、WireGuard の設定で DNS にハブの WG アドレスを
  指定する。ハブの CoreDNS は `.dokodemo-dev.internal` を権威応答し、それ以外は NextDNS へ
  転送するので外部名も引ける。アプリは `https://bots.dokodemo-dev.internal:7717` を使う。
- `cua-bots-open` はワンタイムコードを発行し、
  `https://bots.dokodemo-dev.internal:7717/ui#c=<code>` を開く。

## 4.8 バックアップ

`cua-bots-backup.timer`（毎日 03:30、±5 分）が `/var/lib/cua-bots` と
`/etc/cua-bots/turn.env` を `/var/backups/cua-bots/` へ tar で残す（root 0600、
14 世代）。`runs/` は一時状態なので含めない。

```sh
sudo systemctl list-timers cua-bots-backup.timer
sudo ls -l /var/backups/cua-bots | tail -3
sudo /usr/local/libexec/cua-bots-backup   # 手動で 1 回
```

中身は Bot 定義、トークン、`keys.json`、ルーティン、TLS の鍵を含む。復元するときは
サービスとスケジューラーを止め、`/` からの相対パスを保ったまま展開する。

```sh
sudo systemctl stop cua-bots-scheduler cua-bots-service
sudo tar xzf /var/backups/cua-bots/cua-bots-<stamp>.tar.gz -C /
sudo systemctl start cua-bots-scheduler cua-bots-service
```

cua-vps はハブの CoreDNS を使わないため、`/etc/hosts` に
`<cua-vps の WG アドレス> bots.dokodemo-dev.internal` を置いてある。
これが無いと、ルーティンの設定取得（`CUA_BOTS_AGENT_URL`）と
`curl` の確認が名前解決で失敗する。

## 5. Mac から届かせる（ハブ中継）

ハブは `ip_forward=0` でピア間転送をしないため、Mac から VPS の WG アドレスへ直接は届かない。
ハブにユーザー空間の中継を置き、Mac（`<MAC_WG>`）だけに許可する。転送は無効のままでよい。

```sh
# ハブ側（HUB_WG はハブの wg0 アドレス、VPS_WG は VPS の wg0 アドレス）
sudo tee /etc/systemd/system/cua-relay-ssh.socket >/dev/null <<'EOF'
[Unit]
Description=Cua Bots relay: SSH (socket)
[Socket]
ListenStream=<HUB_WG>:2222
NoDelay=true
[Install]
WantedBy=sockets.target
EOF
sudo tee /etc/systemd/system/cua-relay-ssh.service >/dev/null <<'EOF'
[Unit]
Description=Cua Bots relay: SSH
Requires=cua-relay-ssh.socket
After=cua-relay-ssh.socket
[Service]
ExecStart=/lib/systemd/systemd-socket-proxyd <VPS_WG>:22
EOF
# API も同じ形で 7717 -> <VPS_WG>:7717

# socket は wg0 のアドレスができないと bind に失敗する。
# socket に After=wg-quick@wg0.service を足すだけだと sockets.target と basic.target の間で
# 循環になり、systemd が起動ジョブを削除して inactive のまま残る（2026-10-26 実測）。
# DefaultDependencies=no で既定の順序を外し、wg-quick の完了後に bind させる。
for u in cua-relay-api cua-relay-ssh cua-relay-view; do
  sudo mkdir -p "/etc/systemd/system/${u}.socket.d"
  sudo tee "/etc/systemd/system/${u}.socket.d/10-wg0-ordering.conf" >/dev/null <<'EOF'
[Unit]
DefaultDependencies=no
After=sysinit.target wg-quick@wg0.service
Wants=wg-quick@wg0.service
Before=shutdown.target
Conflicts=shutdown.target
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable --now cua-relay-ssh.socket cua-relay-api.socket
sudo ufw allow in on wg0 from <MAC_WG> to <HUB_WG> port 2222 proto tcp comment 'Cua Bots relay: SSH'
sudo ufw allow in on wg0 from <MAC_WG> to <HUB_WG> port 7717 proto tcp comment 'Cua Bots relay: API'
```

Mac からはハブのアドレスに対して使う。

```sh
ssh -p 2222 ubuntu@<HUB_WG>              # VPS へ
curl http://<HUB_WG>:7717/v1/health      # API
```

## 6. 受け入れ

| 確認 | 期待 |
| --- | --- |
| `systemctl status cua-bots-service cua-bots-scheduler` | 両方 active |
| `ss -ltn` | 7717 が WG アドレスにだけ bind（`0.0.0.0` でない） |
| `cat /var/lib/cua-bots/api-url` | `http://<VPS_WG>:7717` |
| ハブ経由 `curl http://<HUB_WG>:7717/v1/health` | `{"status":"ok"}` |
| 公開 IP の 22 と 7717 | 閉じている（timeout） |
| 中継経由の `ssh -p 2222` | ログインできる |
| 認証なしで `/v1/bots/alpha/messages` | 401 |
| 自分のトークン | 200 |
| 他 Bot のトークン | 403 |
| `cua-bots-scheduler --unconfirmed` | 何も出ない（正常時） |
| スケジューラーのログ | `CLAIM` → `DELIVERED`、同じキーの重複なし |
| `cua agent logs <space> <run>` | 依頼した内容への返答が残る（run が turn を重ねる） |
| ビューア（SSH トンネル `127.0.0.1:13280` → `<VPS_WG>:3280`） | Space の画面がブラウザで開く、映像コーデックも動く |
| GUI（Mac）から Space を開く | 既存の手順どおり |

## 7. 切り戻し

```sh
sudo systemctl disable --now cua-bots-scheduler cua-bots-service
sudo rm /etc/systemd/system/cua-bots-{service,scheduler}.service
sudo systemctl daemon-reload
```

状態は `/var/lib/cua-bots` に残る。作り直すときは同じディレクトリを渡せばトークンも維持される。

## 7. 既知の制約

- `cua agent create` / `tell`（persistent agents）は Cua Spaces の拡張が必要で、素の CLI では使えない。
  そのため `cua-bot-turn` は `cua agent run` / `send --follow`（通常の sandbox run）を使う。
- `cua-bot-turn` の `accept` モードは「ターンをキューに入れた」時点で成功とする。
  ターンの完了まで待つなら `CUA_BOT_MODE=wait` にする（`--exec-timeout` の範囲で）。
- TLS 終端は未実装。VPN 内の平文＋トークンで始める。
