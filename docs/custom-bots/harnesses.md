# ハーネスとPi設定

## 選択と保存

Macの作成画面はSDKの `agentHarnesses()` を使う。
このForkのSDKは `claude-code`、`openai-codex`、`gemini-cli`、`google-antigravity`、`opencode`、`goose`、`pi`、`deepseek-harness`、`hermes`、`openclaw` を定義している。
初期選択は `pi` である。
既存BotのIDはそのまま保持する。
SDK一覧にない保存済みIDも編集画面で確認できるが、SDKが起動を受け付ける保証はない。

Bot別の設定は作成画面とプロファイルの「Agent settings」から編集する。
保存した設定はVolumeのidentityとアプリのstateへ記録される。
変更時は旧Runを止め、次のメッセージから新しいセッションを作る。
既存の会話、メモリ、成果物、Spaceは削除しない。
会話画面の過去履歴を新ハーネスへ全件投入する処理は追加していない。

## Pi設定の参照方式

設定の自動コピーではなく、実行先に事前配置した専用ディレクトリを参照する。
パスはMac側ではなくSpace内の絶対パスである。
空欄ならBotのguest home内に `.pi-agent` を設ける。
同一VM上でも別Botの設定を無条件に共有しない。

| 設定 | 起動時の扱い |
|---|---|
| Model | `SpaceAgentOptions.model` とPiの `defaultModel` |
| Pi provider | project settingsの `defaultProvider` |
| Guest Pi agent directory | `PI_CODING_AGENT_DIR` |
| Guest working directory | ACP sessionのcwdとBot homeの転送先 |
| Additional system prompt | cwdの `.pi/APPEND_SYSTEM.md` |
| Botの基本指示 | cwdの `AGENTS.md` |
| Skills | 参照先の `skills/` またはsettingsのskills |
| Extensions、カスタムツール | 参照先の `extensions/` またはsettingsのextensions |
| カスタムモデル | 参照先の `models.json` |

作業ディレクトリはBot専用にする。
アプリはそのディレクトリのinstructions、rules、memory、outputs、inboxを管理する。
Piのproject settingsはモデルとproviderの既定値を管理対象とし、既存のextensionsやskillsなどの他フィールドを保持する。
壊れたJSONは上書きせず起動エラーにする。

追加System Promptには管理用ヘッダーを付ける。
既存の未管理APPEND_SYSTEM.mdを空欄で上書きしない。
既存の未管理ファイルがある状態で追加promptを設定した場合は起動を拒否する。
promptをクリアすると、以前アプリが作成したファイルだけを削除し、参照先profileのpromptを再び利用できるようにする。

SkillsとExtensionsのファイル選択やアップロードUIは今回追加していない。
管理者が実行先へ配置したファイルをPiが読み込む設計である。
その配置や実際のExtension実行は今回検証していない。
認証ファイルやMacの `~/.pi/agent` をコピーする処理はない。

## モデルエンドポイント

従来の `CUA_BOTS_MODEL_URL`、`CUA_BOTS_MODEL`、`CUA_BOTS_MODEL_KEY_VARS` を維持する。
Bot別のmodelが指定されていれば、環境のmodelより優先する。
URLがなければモデル環境変数だけではなくハーネスの既定設定を使う従来の挙動を維持する。

PiのカスタムURLはSDKがRun内のpi-agent設定を生成する。
この場合のproviderは `cua` になる。
SDKのPi adapterはOpenAI Chat Completions形式だけを扱い、Anthropic wire formatは受け付けない。
カスタムURLやguestの `models.json` にはOpenAI Chat Completions互換endpointを指定する。

カスタムURLの鍵は `OPENAI_API_KEY` としてRunへ渡す。
`CUA_BOT_KEY_VARS` に書いた変数のうち先頭の値を、`cua-bot-turn` が `OPENAI_API_KEY` に写して `--env-from-host` する。
そのためDeepSeekやOpenRouterの鍵も、ホスト側ではそれぞれの名前で置いてよい。

### エンドポイントの追加ヘッダー

ゲートウェイが経路指定用のヘッダーを要求することがある（OpenCode Zen の
`x-opencode-session`）。Bot のエージェント設定の「追加ヘッダー」に `name=value` を
カンマ区切りで書くと、`cua agent run --header` として届き、`pi` と `deepseek-harness` の
モデル設定に書かれる。この 2 つ以外のハーネスは設定ファイルを cua が広げられないため、
ヘッダー付きの実行を拒否する。値は秘密ではない。鍵は `--env-from-host` のまま使う。

## DeepSeek Harness (dsh)

`deepseek-harness` はDeepSeekのdshをACPで動かす。
実体は `dsh --profile acp` で、stdioのACPサーバーとして起動する。
インストールはnpmの `@deepseek-ai/dsh` を固定バージョン（0.2.1-rc.2）で行い、Nodeを必要とする。

モデルとエンドポイントは `$DSH_HOME/profiles/acp/cordis.patch.yml` に書く。
カスタムエンドポイントではprovider `cua` を `llm-pi-ai` に足し、`acp` の既定モデルをそのproviderに向ける。
エンドポイントが無い場合はdsh標準の `deepseek-official` を使い、`DEEPSEEK_API_KEY` を読む。

Runには次の環境変数を渡す。

| 変数 | 値 | 理由 |
|---|---|---|
| `DSH_HOME` | Runの `dsh-home` またはBot homeの `dsh` | セッションと設定をRun / Botごとに分ける |
| `DSH_PERMISSION_MODE` | `danger-full-access` | dshのサンドボックスを重ねない。境界はSpace |
| `DSH_TELEMETRY_MODE` | `DISABLED` | セッションを外部へ送らない |

制約は次のとおり。

- dshはACPのmodeを持たない。`mode_kinds` は効かず、モデルは起動時の設定で決まる。
- ACPで使えるMCPはHTTPだけである。stdioのMCPサーバーは起動しない。
- cuaのスキルは配置しない。dsh側のskillsを使う。
- dshはdeveloper previewで互換性を壊す。インストーラの版を上げるときは、ACPの疎通とツール実行をやり直す。
明示したPi agent directoryとカスタムURLの同時指定は、片方を黙って無視せずエラーにする。
profileのmodels.jsonを使う場合はグローバルのカスタムURLを指定しない。

キーの変数名は可能な限りSDKメタデータから取得する。
値は従来のSDK経路でRunへ渡され、BotRuntimeには保存しない。
開発中にはキーを取得せず、実ハーネスや外部モデルも呼び出していない。

## ACPでの制約

SDK固定版はPi 0.87.1、pi-acp 0.0.33である。
pi-acpの対応commit `1bfcb394088ed879db8fd936b570bb626017f878` のソースで、Piが `--mode rpc --no-themes` により起動され、環境変数を継承することを確認した。
Extensionsを無効化するフラグは付いていない。
SkillsもPi側が読み込む。

ただし、TUI専用の表示や操作がBot画面へそのまま表示されるわけではない。
Extensionが追加したslash commandもアダプターのREADMEでは未対応とされている。
対話入力が必要なExtensionや独自Pi 1.3.0だけの機能の互換性は、実行先の版で個別に検証する必要がある。

このSDKのPi連携はACPのMCPサーバー指定を利用しない。
Cua DriverはCLIを利用するか、実行先のPi Extensionから呼ぶ必要がある。
今回Driver用Extensionを新規実装しておらず、Piによる画面操作の完了条件は未達である。

設定が同じ場合は同じRun IDでfollow-upを送る。
アプリはRun IDを保存し、SDK runnerとpi-acpはそれぞれのセッション情報を保持する。
Cua CLI経由ではPiの起動、ローカルモックへの送信、同一Runへのfollow-up、Spaceのsuspend/resume後の再送信まで確認した。Cua Botsアプリ本体からの起動や再接続は未確認である。

## URL

画面の状態はアドレスに出る。戻る・進む・再読み込み・ブックマークが効く。

| URL | 画面 |
|---|---|
| `/ui` | 起動直後。保存した Bot（無ければ先頭）を選び、`/ui/<bot>` に置き換える |
| `/ui/<bot>` | その Bot の会話 |
| `/ui/<bot>/<tab>` | 右パネルを開く（`details` / `library` / `computer`） |
| `/ui/settings/<section>` | 設定ダイアログ（`general` / `access` / `spaces` / `keys` / `chat` / `screen`） |

- 設定を開くと履歴が1つ進む。セクションの切り替えは置き換えなので、戻ると設定が閉じて元の画面になる。
- `settings` は Bot の id としても使える。同じ名前の Bot がある場合は Bot を優先する。
- ログイン用のリンク（`login` クエリ付き）は、サインイン後もそのパスを開く。
- サーバーは `/ui` 配下のパスをすべて同じページとして返す（アセットを除く）。

## 左メニューの並び替え

左メニューの「並び」で Bot 一覧の見せ方を選べる。選択はブラウザに保存される。

| 選択 | 見せ方 |
|---|---|
| 動かす場所 | Space ごとに見出しを付け、その中は名前順 |
| 名前順 | 見出し無しで名前順 |
| 最後に動いた順 | 見出し無しで、最後にターンを始めた順（無い Bot は名前順で末尾） |

「最後に動いた順」はサーバーが `GET /v1/bots` の `activity`（Bot ごとの最新ターン開始時刻）で
返す。ターンを持たない Bot は含まれない。既存の会話履歴はサービスが持つ直近のターンだけなので、
サービスを入れ替える前の履歴は順位に効かない。

## 時間帯による切り替え（オフピーク）

DeepSeek V4.1 Flash は Ollama Cloud と OpenCode Go の両方が提供している。
どちらも混雑時間だけ単価が倍で、その時間帯は重ならない。

Ollama Cloud では `deepseek-v4.1-flash:1017`（1017 ビルド）を指定する。
OpenCode Go は同じビルドをタグ無しの `deepseek-v4.1-flash` で公開している。

| プロバイダ | ピーク（UTC） | ピーク（JST） |
|---|---|---|
| Ollama Cloud | 月〜金 12:00〜18:00 | 月〜金 21:00〜24:00、火〜土 00:00〜03:00 |
| OpenCode Go（DeepSeek） | 月〜金 01:00〜04:00、06:00〜10:00 | 月〜金 10:00〜13:00、15:00〜19:00 |

Ollama Cloud の割引時間外は OpenCode Go が割引時間なので、次の 3 行で 1 日中
割引単価のまま動かせる。

```text
mon-fri 21:00-24:00 opencode
tue-sat 00:00-03:00 opencode
* ollama
```

Web の「エージェント設定」の「時間帯で切り替え」にこの形式で書き、
プリセット「オフピーク自動」を押すと同じ内容が入る。書いた順に判定し、
最初に当てはまった行のプリセットで動く。当てはまる行が無ければ、上の
エージェント設定（harness / model / baseURL / wire / 鍵 / ヘッダー）を使う。

- 判定はサーバーの `Asia/Tokyo` で行う。時刻は `HH:MM`、`24:00` は終端として使える。
  開始が終了より遅い行は日をまたぐ。
- ターンの開始時に決まる。ターンが切り替え時刻をまたいでも途中では変わらない。
- チャットのターンはサービスが、ルーティンの配送は `cua-bot-turn` が
  `GET /v1/bots/<id>/agent/env` で同じ判定を受け取る（`CUA_BOTS_AGENT_URL` を
  `turn.env` に置く）。サービスに届かないときは `turn.env` の値で走る。
- パネルには「いま: OpenCode Go（03:00まで）」のように、適用中のプリセットと
  次の切り替え時刻が出る。

## 設定を変えたときに Run を作り直す

Run は開始時の設定（モデル・エンドポイント・鍵の変数名・ヘッダー）を引きずる。
`cua-bot-turn` は Run の横に `*.settings` を持ち、設定が変わっていれば新しい Run を始める。
これが無いと、`turn.env` の既定を変えても既存の Run は古いモデルのまま認証に失敗し続ける
（2026-10-28 に実際に起きた）。

そのとき何を使ったかは `/var/lib/cua-bots/runs/turn-settings.log` に 1 行ずつ残る
（鍵は変数名だけ）。直近 200 行を保つ。

## 検証記録（2026-10-27）

`deepseek-harness` はVPSの `local:bot-alpha` で次を確認した。

- `cua agent ensure local:bot-alpha deepseek-harness` がnpmの固定tarballを検証して導入する。
- `cua agent run` がACPでdshを起動し、OpenAI Chat Completions互換のローカルモックへ送信して返答を受け取る。
- dshのbashツールがSpace内でコマンドを実行する（`DSH_PERMISSION_MODE=danger-full-access`）。
- `cua-bot-turn` 経由でも同じターンが成功し、`CUA_BOT_KEY_VARS` の鍵が `OPENAI_API_KEY` として渡る。

実プロバイダでも確認した（2026-10-27、`turn.env` の鍵を使用）。

| プロバイダ | harness | モデル | 結果 |
|---|---|---|---|
| Ollama Cloud (`https://ollama.com/v1`) | `pi` | `deepseek-v4.1-flash` | bashツール実行と返答まで成功 |
| Ollama Cloud | `deepseek-harness` | `deepseek-v4.1-flash` | 同上 |
| OpenCode Zen Go (`https://opencode.ai/zen/go/v1`) | `pi` | `mimo-v2.6-flash` | ヘッダー `x-opencode-session` 付きで成功 |

OpenCode Zen Goはこのヘッダーが無いと 400 `MissingSessionID` を返す。
`CUA_BOT_HEADERS` に `name=value` を `;` 区切りで入れると `--header` として届く。

## Space の確認（設定 → Space）

設定の「Space」で、ホスト上の Space と、そこを使っている Bot を一覧できる（読み取り専用）。

- 行を開くと、その Space を使う Bot が並ぶ。
- cua の一覧に無い Space（削除済み、または未登録）は「cua 未登録」と表示する。
  その Space を使う Bot はターンが失敗するので、作り直すか `--space` で移す。
- 「接続コマンドを表示」で `cua sb shell <space>` を選択済みのダイアログに出す。Space の
  ログインが無いときの次の一手になる。VPN 内は平文 HTTP で `navigator.clipboard` が
  使えないため、コピーはダイアログのボタン（execCommand で代替）か ⌘C で行う。
- 準備に失敗した Space（`failed`）は状態を表示する。
- 作成・移動は CLI のまま。UI からは壊さない。
