# cua-bots-service-go

Bot の協調 API を提供する Go 実装。**本番の VPS で動かすのはこちら**で、
`examples/cua-bots-macos` の Swift 実装は参照実装兼ローカル確認用として残す。

## なぜ Go か

- 本番は Linux VPS。Swift 版は `Darwin` のソケットと `flock` を直接使うため移植が要り、
  `cua-bots-run` は macOS の `libcua_sdk.dylib` をリンクしていて Linux では動かない。
- Go は単一バイナリで配布でき、systemd から起動する常駐に余計なランタイムが要らない。
- ドメインの規則（所有権、信頼グループ、委譲の上限、冪等性）は Swift 版と同じ形のまま
  移植し、テストで固定している。状態ファイルの JSON も共通で、Swift 版と読み書きできる。

## 構成

| パス | 内容 |
| --- | --- |
| `internal/domain` | レジストリ（所有権・信頼グループ・画面lease）、認可、トークン、協調（委譲・メッセージ・成果物） |
| `internal/api` | HTTP ルーター、Bearer 認証、本文上限、レート制限、管理用の発行 |
| `internal/store` | 状態の保存（`flock`＋原子的置換、0600） |
| `cmd/cua-bots-service` | 起動、`--mint` / `--rotate` / `--revoke` / `--admin` / `--print-systemd-unit` |
| `cmd/cua-bots-scheduler` | スケジュール実行（lease、slot 単位の配送記録、`--exec-command`） |

## 使い方

```sh
go build ./cmd/cua-bots-service
./cua-bots-service --state /var/lib/cua-bots --bind 127.0.0.1
```

VPS では WireGuard のアドレスで待ち受ける。

```sh
./cua-bots-service --state /var/lib/cua-bots --bind <wg0 のアドレス> --port 7717
```

- `--bind` が loopback 以外なら `--allow-remote` を付ける（付け忘れると起動しない）。
  接続元の loopback 検査は外れ、トークンが境界になる。
- `--tls-cert` / `--tls-key` を渡すと HTTPS になる（TLS 1.2 以上）。
- `--allow-remote` で TLS 未設定のときは、起動時に警告を1行出す（ホスト内の平文が見えるため）。
  共有ホストや VPN 外への公開では TLS を付ける。
- 起動時に `api-url` を状態ディレクトリへ 0600 で書き出す。Bot はこの URL と
  自分のトークンファイルだけを知る。

### 資格情報

```sh
./cua-bots-service --state DIR --seed-bots alpha,beta   # 動作確認用の Space と Bot
./cua-bots-service --state DIR --admin                  # 管理者トークン（host のみ）
./cua-bots-service --state DIR --mint alpha             # Bot トークン（失効させない）
./cua-bots-service --state DIR --rotate alpha           # 既存を全失効して再発行
./cua-bots-service --state DIR --revoke alpha           # 失効のみ
```

トークンの値は状態ファイルに残らない（FNV-1a の digest のみ）。`admin` は
`manageRegistry` を持ち、どの Space にも属さない。Bot のトークンは
`manageRegistry` を持たず、Space に属するため、管理者の発行は通らない。

## ブラウザ画面（`/ui`）

サービスは `/ui` でブラウザ画面を出す。`cua-bots-open` が作ったリンクを開くと
サインインした状態で立ち上がる。認証は資格情報そのものではなく、このブラウザから
操作してよいかを示す鍵で、リンクの期限が切れたら同じコマンドを実行し直す。

画面は Grok Bot のデスクトップ版に寄せた構成にしている。

- 左は Bot の一覧。上に検索と「＋」、ピン留めした Bot の大きなアイコン、
  Space ごとのセクション、アーカイブ、最下部にアカウント。ピン留めは右パネルから
  切り替え、サービスに保存する（同じ資格情報で開いた端末で共有）。
- 中央は会話。回答は吹き出しではなく Markdown の本文で、コードブロックにはコピー、
  メッセージにはコピーと再送が付く。上部のピルから右パネルを開く。
- 右パネルは「詳細 / ライブラリ / コンピューター」。詳細に状態と動かす場所（読み取り
  専用）、ルーティン、管理操作をまとめた。ルーティンの追加は「＋ 追加」からダイアログで行う。
- 右パネルの「エージェント」で、Bot ごとにハーネス・モデル・エンドポイント・通信形式・鍵の
  変数名を設定できる（管理者のみ、`GET` / `PUT /v1/bots/<id>/agent`）。変更は次のターンから。
  鍵の値は VPS の `turn.env` に置き、画面には変数名だけを書く。
- ライブラリは、Bot と同じ Space の成果物（名前・所有者・サイズ・日時・sha256）を新しい順に
  並べる。`GET /v1/bots/<id>/artifacts` の記録で、実体は Space の `outputs` / `inbox` にある。見た目は「見た目を変える」からダイアログで
  編集する。動かす場所は作成時に決まり、画面からは変えない（API と CLI では引き続き
  付け替えられる）。
- テーマはシステム設定に追従する。ライトは白ではなく、明度を落とした暖色寄りの
  グレー（`#e8e6e1`）を土台にしている。

### 画面のソースとビルド

HTML と CSS は `internal/api/ui/` に置き、埋め込みの `app.js` は
`ui/src/*.ts` から作る。`app.js` はコミットする（VPS と `go test` に Node を要らなくするため）。

```sh
cd ui
aube install
aube run check   # 型検査・バンドルの差分・lint・整形
```

`aube run check` が落ちるときは `aube run build` で `app.js` を作り直す。

### ローカルで見る

Space を作らずに画面だけ確認できる。

```sh
go build -o /tmp/cua-bots ./cmd/cua-bots-service
/tmp/cua-bots --state /tmp/cua-demo --seed-bots alpha,beta,gamma --space local:demo
/tmp/cua-bots --state /tmp/cua-demo --admin   # 管理者トークンを作る
/tmp/cua-bots --state /tmp/cua-demo --port 8099 --no-provision \
  --turn-command /path/to/turn-script
```

`/ui#k=<管理者トークン>` を開くと入れる（資格情報はフラグメントに置くので、query と
違ってサーバーのログやブラウザの履歴に残らない。`/ui?login=` も互換のため受け付ける）。`--turn-command` は標準出力を1行ずつ
ターンへ流すので、`echo` するだけのスクリプトでも会話の表示を確認できる。

### まだ無いもの

承認キュー、会話の横断検索、添付、実行中の停止はサーバ API が無いため画面にも無い。
コンピューターのタブは `cua-view` の案内を出すだけ。

## API

Swift 版と同じ経路・状態コード。

| メソッド | パス | 認証 |
| --- | --- | --- |
| GET | `/v1/health` | 不要 |
| GET | `/v1/bots/{id}/messages` | その Bot のトークン |
| POST | `/v1/bots/{id}/messages` | 同上 |
| POST | `/v1/bots/{id}/delegate` | 同上 |
| POST | `/v1/bots/{id}/artifacts` | 同上 |
| POST | `/v1/manage/bots/{id}/token` | 管理者トークン |

失敗は 400 / 401 / 403 / 404 / 409 / 413 / 429 で返す。本文は 64KiB、要求は
トークンごとに 60 回/分。

## テスト

```sh
go test ./...
```

- `domain`: 信頼グループの拒否、専有Spaceの削除権、workspace の重なり、画面lease、
  冪等な委譲、ループと深さ、同時実行、期限、成果物の上限、メッセージの到達範囲
- `api`: health、トークン欠落・別Botの拒否、委譲の 201→200、管理者の発行と Bot の拒否、
  413、429、loopback 以外の拒否
- `store`: 再起動後のトークンと状態、0600、Swift 版の JSON を読めること

## スケジューラー

```sh
./cua-bots-scheduler --state /var/lib/cua-bots/scheduler --owner cua-bots \
  --exec-command 'cua spaces ... ' --interval 1s --lease 30s
```

- lease を持つプロセスだけが slot を claim する。別プロセスが持っていれば `LEASE_BUSY`。
- 配送キーは `<jobID>@<UTC>`。同じ slot は一度しか claim されない。
- 結果が不明な slot（クラッシュ、期限切れ claim）は `UNCONFIRMED` として残し、**自動では再送しない**。
  人間が `Acknowledge(key, resend)` を選んだときだけ、同じ slot を1回だけ再実行する。
- `--exec-command` の終了コード0だけを配送成功として記録する。失敗は `failed`。
- 不明な slot は人間が決める。`--unconfirmed` で一覧、`--ack <key> --resend` で1回だけ再実行、
  `--ack <key> --give-up` で打ち切る。

## Bot への配送（`--exec-command`）

`scripts/cua-bot-turn.sh` が本番の `--exec-command`。スケジューラーが渡す
`CUA_BOTS_*` を Cua CLI に変換する。

```sh
CUA_BOTS_BOT_ID=alpha CUA_BOTS_PROMPT="Summarize" \
  CUA_BOTS_SPACE=local:bot-alpha ./scripts/cua-bot-turn.sh
```

- 初回は `cua agent run --json` で run を作り、id を `CUA_BOTS_RUN_DIR` に覚える。2回目以降は
  `cua agent send --follow` で同じ run に送る（セッションが続く）。
- `CUA_BOT_MODE=accept`（既定）はキュー投入で成功、`wait` はターン終了まで待つ。
- `CUA_BOT_MODEL` / `CUA_BOT_BASE_URL` / `CUA_BOT_KEY_VARS` は初回 run に渡す。
- 契約テスト: `bash scripts/cua-bot-turn.test.sh`（12チェック）。

`cua agent create` / `tell`（persistent agents）は Cua Spaces 拡張が必要で、素の CLI では
`host capability missing` で失敗するため使っていない。

## 未実装

- Bot の実行そのもの（VPS では `cua` CLI を `--exec-command` から呼ぶ）。
- TLS 終端。VPN 内の平文＋トークンで始め、必要なら内部 CA を足す。

