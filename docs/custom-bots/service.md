# 実行サービスと協調の基盤

Botの実行、Spaceの所有権、認可、協調、スケジュールをGUIから分離するための基盤をまとめる。
この文書は、実装済みの範囲と未接続の範囲を区別して記録する。

## 位置づけ

Mac上で動く単一のサービスを正本とし、GUIとPi ExtensionはAPIクライアントにする。
サービスがBot、実行先、Spaceの所有権、メッセージ、委譲、成果物、スケジュールを保持し、SDKの呼び出しを直列化する。
GUIを終了してもスケジュールと実行は継続する。

現時点で実装したのは、この構成に必要な純粋なドメイン層、APIルーター、loopbackの待ち受け、Pi Extensionクライアント、GUI非依存で動くスケジューラー実行ファイルである。
TLS終端、VPN接続、実行先を選ぶUIはまだ接続していない。

## 所有権と信頼境界

`ExecutionRegistry` が実行先とSpaceの対応を持つ。

| 種別 | 削除 | 停止 | 複数Bot |
| --- | --- | --- | --- |
| アプリが作った専有Space | Botの削除時に削除 | Space全体を停止 | 不可 |
| 既存Space（`managedByApp: false`） | 削除しない | BotのRunだけ中断 | 可 |
| 共有Space（`mode: .shared`） | 削除しない | BotのRunだけ中断 | 可 |

既存Botは読み込み時に互換レコードへ移行する。
移行は冪等で、既存Spaceの削除権限を与えない。

共有Spaceには信頼グループがある。
同じグループのBotだけが同じSpaceに入れる。
別グループのBotは共有を拒否されるため、強い分離が必要なBotは専用Spaceへ分ける。
作業ディレクトリはBotごとに分け、前方一致で重なるパスを拒否する。

画面操作は最大300秒のleaseで排他する。
leaseを持たないBot、期限切れのlease、奪われたleaseでの解放は拒否する。

この境界はパスの字句検査であり、ファイルシステムのサンドボックスではない。
ゲスト側のアダプターはsymlinkの別名を別途拒否する必要がある。

## 接続状態

`ConnectionHealth` がprobeの結果と鮮度を管理する。

- 30秒を過ぎた成功は`online`ではなく`stale`として扱う。
- probeは5秒で期限切れにし、古いprobeの結果が新しい結果を上書きしない。
- 失敗は2の冪で最大60秒までバックオフし、5回で`exhausted`にする。
- 認証拒否は`unauthorized`として止め、自動再試行しない。

ネットワークI/Oは含まない。
probeの実装は実際のタイムアウトとキャンセルを別途持たせる。

## 認可

`AuthorizationPolicy` が操作ごとに能力を確認する。

- Spaceの読み取りは所属と信頼グループの一致を要求する。
- 画面操作は所属に加えて有効なleaseを要求する。
- 成果物の書き込みは自分の所有分だけ、読み取りは同じ信頼グループのメンバーまで許す。
- 委譲は明示した宛先、同じ信頼グループ、深さ3まで、期限30分までに制限する。
- 管理操作はloopbackからの要求だけを許す。

VPNへ参加していることは操作権限の代用にしない。
Botは自分のprincipalを申告できない。
API層が認証済みトランスポートからprincipalを導出する。

## APIルーター

`ServiceAPI` はメソッド、パス、接続元アドレス、認証ヘッダ、本文だけを受け取り、状態コードとJSONを返す。
待ち受けを持たないため、通信なしで認可と状態遷移を検証できる。

- 接続元がloopbackでなければ全要求を拒否する。
- `/v1/health` 以外は`Bearer`トークンを要求する。
- トークンはBotごとに発行し、ハッシュだけを保存する。失効と期限切れを扱う。
- トークンのBotとパスのBotが違えば拒否する。
- 委譲、メッセージ、成果物の状態コードは、認可の失敗を403、大きすぎる成果物を413、冪等キーの衝突を409、上限超過を429として返す。

## 待ち受けとクライアント

`ServiceServer` は127.0.0.1だけにbindし、HTTP/1.1の要求を`ServiceAPI`へ渡す。
接続元は`getpeername`で取得したアドレスを使うため、loopback以外からの要求はルーター側でも拒否される。

`cua-bots-service` は隔離した状態ディレクトリにSpaceとBotを用意し、Botごとのトークンを0600で書き出す。
トークンは標準出力へ出さず、ファイルのパスだけを表示する。

## 永続化

`ServiceStateStore` がレジストリ、トークンのハッシュ、協調の状態を1つのファイルへ保存する。
書き込みは一時ファイルを作ってから置き換え、`flock` で排他するため、途中で落ちても前の状態か新しい状態のどちらかが残る。
`ServiceAPI` は状態を変更した要求が成功したときだけ保存し、拒否された要求ではファイルへ触れない。
トークンの文字列は保存しない。失効はハッシュの記録として残るため、再起動後も拒否される。
トークンのファイルを失った場合は、ハッシュから元の文字列を復元できないので再発行が必要になる（`MISSING_TOKEN` を表示する）。

再発行は`--rotate <botID>`で行う。対象Botの既存トークンをすべて失効させてから新しい値を書き出し、状態ファイルにも反映する。

```sh
cua-bots-service --state <dir> --rotate alpha
```

再起動をまたいだ確認は次のとおり。

| 確認 | 結果 |
| --- | --- |
| 委譲の後にプロセスを強制終了して再起動 | 状態を復元し、同じ冪等キーで同じタスクIDを返す |
| 再起動後のメッセージ一覧 | 停止前のメッセージが残る |
| 失効させたトークンで再起動後に要求 | 401 |
| 拒否された要求（8MiB超の成果物など） | 保存済みの状態を変更しない |

Pi Extension（`examples/cua-bots-macos/extensions/cua-bots-service/`）は4つのツールを登録する。
クライアントはloopback以外のURLを構築時点で拒否し、トークンは呼び出しのたびにファイルから読む。

### ゲストからの到達

待ち受けは`127.0.0.1`のまま変えない。
OrbStackでは`host.docker.internal`がホストのloopbackへ中継されるため、Spaceの中からでも同じURLで届く。
2026-10-21に、実際のBotと同じ`bridge`ネットワークのコンテナから次を確認した。

| 確認 | 結果 |
| --- | --- |
| `host.docker.internal:<port>/v1/health` | 200 |
| 自分のトークンで`/v1/bots/<id>/messages` | 200 |
| 他Botのトークンで同じパス | 403 |
| トークン無し | 401 |
| 60回/分を超える連続要求 | 429 |

`ServiceServer`は`getpeername`で接続元を見るが、中継により127.0.0.1になるためloopback検査はそのまま通る。
つまり**LANへ公開されるわけではない**が、このMac上の任意のコンテナからは到達しうる。
防御はトークン、能力、Space所属、信頼グループで行う。

この前提は「loopback限定＝外部から届かない」を「このMac内のコンテナからは届く。認証はトークンで行う」へ読み替えるもので、利用者の承認を得ている。

### 資格情報の渡し方

`BotServiceAccess`は、APIのURL、トークンファイルのパス、Bot IDだけを持つ。
トークンの値はそのファイルにだけ置き、Botの設定や状態ファイルへは保存しない。
`HarnessLaunch`はこれらを環境変数`CUA_BOTS_API_URL`、`CUA_BOTS_TOKEN_FILE`、`CUA_BOTS_ID`としてプロセスへ渡す。
Pi Extensionは`CUA_BOTS_TOKEN_FILE`を呼び出しのたびに読む。

同じSpaceのBotは同一ユーザーで動くため、信頼グループ内では互いのトークンファイルを読める。
これは「共有Spaceは同じ信頼グループだけ」という既存の前提の内側であり、別グループのトークンはそのSpaceに入らない。

トークンの発行は`cua-bots-service`が行う。

| 操作 | 手段 |
| --- | --- |
| 発行 | 初回起動時に`<botID>.token`を0600で書き出す |
| 追加発行 | `--mint <botID>`（失効させない） |
| 再発行 | `--rotate <botID>`（既存をすべて失効） |
| 失効 | `--revoke <botID>` |
| ホストアプリからの発行 | `POST /v1/manage/bots/<botID>/token`（管理者資格情報が必要） |

管理者資格情報は初回起動時に`admin.token`として0600で書き出し、パスだけを表示する。
管理者の資格情報はSpaceに属さないBotにだけ発行し、`manageRegistry`能力を持つ。
Botの資格情報には`manageRegistry`を含めないため、Botが他のBotのトークンを発行することはできない。

状態ファイルも0600で保存する。

### ブローカー（BotのSpaceへ置く）

`HTTPCredentialBroker`が管理者資格情報で`POST /v1/manage/bots/<id>/token`を呼び、`CuaEngine`が受け取った値をBotの作業ディレクトリの`.cua-bots/credential`へ書き、`chmod 700`と`chmod 600`を適用する。
プロセスへはURLとファイルのパスだけを渡す。

有効にするには、アプリに次の環境変数を渡す。

| 変数 | 内容 |
| --- | --- |
| `CUA_BOTS_SERVICE_URL` | ホスト側の待ち受け（`http://127.0.0.1:<port>`） |
| `CUA_BOTS_ADMIN_FILE` | 管理者資格情報のファイル（`<state>/admin.token`） |
| `CUA_BOTS_SERVICE_ADVERTISE` | ゲストへ渡すURL。省略時は`CUA_BOTS_SERVICE_URL` |

管理者資格情報はloopbackのURLにしか送らない（`HTTPCredentialBroker`が構築時に拒否する）。

`--mint <botID>`は、アプリを使わずに同じことを手で行う場合の逃げ道である。

### 制限

- 本文は64KiBまで。超える要求は413。
- トークンごとに60要求/分。超える要求は429。
- 拒否は`onDenied`へ状態コードとパスだけを渡す。トークン値は渡さない。

TLS終端は未実装である。

## 協調

`CollaborationService` がメッセージ、単発委譲、成果物参照を扱う。

- 委譲は冪等キーで重複を排除し、同じキーで内容が違えば拒否する。
- ルートタスクの経路に含まれるBotへは再委譲できない。
- 同時実行は全体4件、Botごと1件までとする。
- 子タスクの期限は親の期限を超えない。
- 期限切れのタスクは`expired`にし、遅れて届いた結果は拒否する。
- 成果物は1件8MiBまでで、パス区切りや`..`を含む名前を拒否する。
- メッセージは現在のSpaceメンバーだけが受信する。

グループ全員への自動応答は実装しない。

## スケジューラー

`SchedulerState` がスロット単位の配送記録を持つ。

- 1つのスロットは1回だけclaimでき、配送キーは`<jobID>@<ISO8601>`である。
- leaseを持つプロセスだけがclaimできる。leaseの有効期限が切れると別プロセスが引き継ぐ。
- 引き継ぎ時、結果が不明なclaimは`unconfirmed`にして自動再送しない。
- 人間が明示的に再送を選んだ場合だけ、同じスロットを1回だけ再びclaimする。
- 一時停止したジョブはclaimしない。

`cua-bots-scheduler` はこの状態をファイルへ保存し、`flock`で排他して読み書きする実行ファイルである。
GUIにもSDKにも依存しない。

```
.build/debug/cua-bots-scheduler --state /tmp/sched --owner svc-a \
  --interval 0.2 --lease 5 --seed-bot alpha Digest "Summarize" 60 \
  --exec-command 'my-bot-runner "$CUA_BOTS_BOT_ID" "$CUA_BOTS_PROMPT"' \
  --exec-timeout 600
```

`--exec-command` を付けると、配送ごとに `/bin/sh -c` でコマンドを実行する。
環境変数 `CUA_BOTS_DELIVERY_KEY`、`CUA_BOTS_BOT_ID`、`CUA_BOTS_TITLE`、`CUA_BOTS_PROMPT`、`CUA_BOTS_ATTEMPT` を渡すため、受け側でも同じキーで冪等にできる。
終了コード0だけを配送成功として記録し、失敗とタイムアウトは `failed` にして自動再送しない。
タイムアウト時は子プロセスを終了させる。
`--exec-command` を付けない場合は配送を `delivered.log` へ記録するだけで、`NO_EXEC_COMMAND` を表示する。

claimはロックの内側、実行はロックの外側、結果の記録は再びロックの内側で行う。
そのため2つのプロセスが同時に走っても、同じスロットを二重に実行しない。

`ScheduledDeliveryRunner` は同じ規則をプロセス内で適用するライブラリ版である。
`EngineScheduledExecutor` は `BotEngine` へ配送を渡し、Runが無ければ開始、あれば新しいターンを送る。
停止中のBotや存在しないBotは失敗として記録する。

### 実行ファイル `cua-bots-run`

スケジューラーの`--exec-command`に渡す実行ファイルである。
スケジューラーが設定した環境変数から配送を組み立て、`CuaEngine`で実際のRunを開始または継続する。

```
cua-bots-run --volume <Volumeのルート> [--data <データ>] [--state <state>] \
  [--spaces <spaces>] [--teleport <teleport>] [--dry-run]
```

| 終了コード | 意味 |
| --- | --- |
| 0 | 開始または送信を受け付けた（`--dry-run`は計画の表示のみ） |
| 1 | エンジンが失敗した（Runの失敗として記録される） |
| 2 | 引数または環境変数が不正 |
| 3 | 配送を拒否した（存在しないBot、停止中のBot） |

`--dry-run`はエンジンを起動せず、受け取ったBot ID、試行回数、プロンプト、identityの有無を表示する。

ファイル保存は単一ホストでの検証用であり、本番の状態管理にはトランザクションのある保存先を使う。

## 検証

`scripts/test.sh --core-only` で、所有権、信頼グループ、接続状態、認可、協調、スケジューラーのテストを実行する。

```sh
bash examples/cua-bots-macos/scripts/test.sh --core-only
```

スケジューラーの外部プロセス動作は、隔離したディレクトリで次を確認する。

1. ジョブを登録し、スロットごとに1回だけ配送される。
2. プロセスを強制終了して再起動しても、配送済みスロットを再送しない。
3. claim直後にクラッシュしたスロットは`unconfirmed`になり、再送しない。
4. 2つのプロセスを同時に起動すると、leaseを持つ側だけが配送する。
5. `--exec-command` が0以外で終了したスロットは`failed`になり、次のtickでも再実行しない。
6. `--exec-timeout` を超えたコマンドは`failed`になり、子プロセスも残らない。

## 常駐の準備

`cua-bots-service --print-launchd-plist` と `cua-bots-scheduler --print-launchd-plist` は、自分自身の絶対パスを使ってlaunchdのジョブを出力する。
出力はplist XMLで、`RunAtLoad`、`KeepAlive`、`ThrottleInterval`、ログのパスを含む。
トークンや認証ヘッダは含めない。

生成と構文検証までは確認済みで、登録（`launchctl bootstrap`）は行っていない。
手順と解除方法は`launchd.md`を参照する。

## TLSの信頼ストア（2026-10-22）

2026-10のeMudhra中間CA侵害では、AppleのストアとMozillaの同梱リストが該当ルートを不信頼にした。
このMacでも`/etc/ssl/cert.pem`は126件・対象0件、システムのanchor 158件に対象なしを確認した。

一方、アプリが使うTauri側には2つの経路がある。

| 経路 | ルート |
| --- | --- |
| `reqwest`（既定のAPI・更新確認） | `rustls-tls-native-roots` のためOSのストア準拠 |
| `cua-spacesd-client`（gRPC） | 同梱の `webpki-roots` ＋ native |
| `cua-mesh`（relay の wss） | 同梱の `webpki-roots` のみ |

`webpki-roots 1.0.9` には emSign のルートが残っており、そのままではOSの不信頼設定を迂回して侵害されたCAを信頼していた。
そこで両クレートの `root_store()` で、件名に `emSign ECC Root CA - G3` と `AAA Certificate Services` を含むルートを除外する。
この2件は、Appleの束とMozillaの同梱リストが実際に外したものに合わせている。emSignの他のルート（C3、C1、G1）は今回の不信頼の対象ではないため残す。
`cua-spacesd-client` はnative側にも同じ除外を適用する（古いtrust設定や`SSL_CERT_FILE`が指す束で復活しうるため、実測で確認した）。

この確認は更新のたびに必要になる。`~/.pi/agent/scripts/tls-trust-audit.ts` が、システムの束・環境変数の束・Cargoの同梱リスト・ここのフィルタ配列をまとめて監査する。
launchdに毎日実行として登録でき、要対応のときだけ通知する（登録は利用者が行う）。

検証:

| 確認 | 結果 |
| --- | --- |
| `node ~/.pi/agent/scripts/tls-trust-audit.ts --repo .` | `status: clean`（システムの束126件に対象なし、フィルタ配列は対象を列挙） |
| `cargo test -p cua-spacesd-client --lib` | 43テスト成功 |
| `cargo test -p cua-mesh --lib` | 26テスト成功 |
| 追加したテスト | 除外対象が実際に存在し、除外後の件数が一致し、ISRG Root X1は残り、生成したストアに除外対象が残らないこと |
| `cargo clippy -p cua-spacesd-client -p cua-mesh --lib -- -D warnings` | 警告なし |

同梱リストが更新されれば、この除外は不要になる。

## リリース確認（2026-10-23）

Mac は本番ではなく、開発とローカル確認に使う。本番は VPS（`production-vps.md`）。

| 項目 | 状態 | 確認方法 |
| --- | --- | --- |
| Web UIの本番ビルド | 済 | `aube run build`（core wasm＋tsc＋vite） |
| Tauriのリリースビルド | 済 | `cargo build --release --manifest-path src-tauri/Cargo.toml` |
| リリースバイナリの単独起動 | 済 | Viteを止めて起動し、同梱`dist`で画面が出ること |
| 設定画面ほかUIの日本語 | 済 | リリースバイナリのウィンドウを単体キャプチャ |
| TLSの信頼ストア監査 | 済 | `node ~/.pi/agent/scripts/tls-trust-audit.ts --repo <cua>` |
| Mac常駐（launchd） | 対象外 | 本番はVPS。ローカル確認で常駐させるときだけ`launchd.md` |
| VPSへの配置 | 未着手 | `production-vps.md` の移行手順 |
| push | **未**（明示依頼待ち） | `git push` |

リリースビルドは`devUrl`を使わず`dist`を同梱する。デバッグビルドでViteを止めると真っ白になるのは仕様で、リリースビルドでは起きない。

## 未接続の範囲

- TLS終端（待ち受けはloopbackのままで、ゲストは`host.docker.internal`経由で到達する）

- Pi Extensionからの委譲・メッセージ・成果物の呼び出し
- 実行先を選ぶUIと、既存Spaceを選ぶUI
- WireGuard接続、health probeの実装、鍵の管理

- 本番の常駐登録（plistの生成までは実装済み）
