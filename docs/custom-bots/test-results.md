# 検証結果

## 環境と境界

macOS arm64、Swift 6.3.3、XcodeのDeveloper環境で検証した。
実APIキー、OAuth、実モデル、Cua Cloud、VPN、Keyvaultは使っていない。
OrbStack上に隔離Spaceを作り、Cua CLI、CuaEngine、GUIのテストで承認済みの `test-key` placeholderだけを使った。
応答はSpace内loopbackのOpenAI Chatモックが返した。
Cua CLI、オプトインのCuaEngine試験、GUI試験では `CUA_TELEMETRY=0` と `CUA_TELEMETRY_FORBID_NETWORK=1` を指定し、Usage Telemetryの無効化を公式CLIで確認した。
通常のSwiftテストでは実行フラグがなく、Cua Engineは起動しない。
Cargo.lock依存、検疫条件を満たしたprotobuf、Cua Linux imageとSDK固定ハーネス依存を取得した。MacのPi設定や認証ファイルはコピーしていない。

## 実行結果

| 検証 | 結果 |
|---|---|
| 変更前の `scripts/test.sh --skip-update` | 失敗。既存Keyvaultコードが現行SDKにないsite、label、accountを参照 |
| 新規設定切り替えテストの先行実行 | configureとdisconnectが未実装でコンパイル失敗することを確認 |
| `scripts/test.sh --core-only` | 成功。29テスト、10スイート |
| `cargo build --locked --offline --release -p cua-spaces-ffi -p cua-cli -p cua-mock-llm` | 未完了。Cargoキャッシュに `pbjson` がなく、オフライン解決で停止 |
| Homebrew `protobuf` 36.2 | 成功。公開日2026-09-17で7日間の検疫を満たし、`protoc 36.2` を確認 |
| `cargo build --locked --release -p cua-spaces-ffi -p cua-cli -p cua-mock-llm` | 成功 |
| `stage-library.sh` | 成功。SDK dylibをSwift packageへ配置し、arm64 Mach-Oとinstall nameを確認 |
| `cargo build --locked --release -p cua-mock-llm` | 成功 |
| ホスト上の `cua-mock-llm` health確認 | 成功。127.0.0.1の `/health` が応答 |
| OrbStack Docker EngineとCua Linux Space image | 成功。`orbstack` context上に約3.03 GBのimageを取得 |
| 隔離Spaceの後始末 | 成功。CLIとCuaEngineの試験Run・Spaceを削除。Cua Linux imageはキャッシュに保持 |
| Cua SDK Pi + Anthropic wire | 起動前に拒否。Pi adapterはOpenAI Chat Completions形式のみを受け付け、インストールは始まらなかった |
| Cua CLI経由のPi実行 | 成功。Pi 0.87.1、pi-acp 0.0.33を起動し、Space内loopbackのOpenAI Chatモックから期待した応答を取得 |
| PiのSDK固定依存 | 成功。Node 24.21.0、ACP SDK 1.5.0、mcp-remote 0.14.3、Pi 0.87.1、pi-acp 0.0.33を導入。各版は公開後7日以上経過し、SDKのchecksum/integrity検証を通過。Piの更新通知は表示されたが、版は変えていない |
| 同一Runへのfollow-upとSpace suspend/resume後の再送信 | 成功。3ターンの終了とモック応答をログで確認 |
| Cua Usage Telemetry | `CUA_TELEMETRY=0` が有効で、`CUA_TELEMETRY_FORBID_NETWORK=1` も指定 |
| `scripts/test.sh`（通常経路） | 成功。30テスト、11スイート（29成功、オプトイン1件skip）。CuaBots実行ファイルのリンクも成功 |
| オプトインの`CuaBotsCuaIntegrationTests` | 成功。CuaEngine経由でPiを起動し、suspend/resume後の同一Runで2回目のモック応答を確認。SDKの更新通知が応答に付くため、応答本文の完全一致ではなくモック文の存在を検証 |
| Cua BotsのGUI起動と送受信 | 成功。一時HOMEで起動し、Cua DriverのAX操作でBot作成、`hello`、`again`の送信を実施。画面上のモック応答`#1`から`#3`と、モック受信3件を確認 |
| GUIモック起動スクリプト | 成功。Nodeの2単体テスト、strict型検査、Oxlint、シェル構文検査を通過。初回のsandboxのみの作成では認証エラーになったため、`spaces create`で登録する方式に修正 |
| `swift build --target CuaBots` | 成功。SDKアダプターとMac UIを含めてコンパイル |
| 新規scratch領域での同ターゲットビルド | 成功。既存ビルドキャッシュなしでコンパイル |
| `xcrun swift-format lint`（新規Swiftファイル） | 成功 |
| `xcrun swift-format lint`（既存 `AppModel.swift`） | 終了コード0。既存のインデント警告は残る |
| Swift compiler warning | `AppModel.reset` の未使用 `map` 警告を明示的なoptional bindingへ変更して解消 |
| `bash -n scripts/test.sh` | 成功 |
| `git diff --check` | 成功 |

初回の通常Swiftテストでは29件が成功し、オプトインのSpace統合テスト1件は実行フラグ未設定でskipした。CuaBots実行ファイルもリンクした。
オプトインテストでは、CuaEngineがSpaceを作り、Piの2回目の応答まで同じRunで処理する経路を確認した。
追加のGUI試験では、アプリUIからPiを起動し、初回応答と2回の追加送信を確認した。
アプリ再起動後のRun復帰は初回試験では未確認だったが、2026-10-21の追加試験で確認した。

既存のKeyvault参照は現行SDKのdomain、appDisplay、kindへ修正した。
これによりMac UI全体のコンパイルを確認できたが、保存済みsign-inの動作自体は未検証である。

## 追加テストで確認した契約

- 新規Botの既定ハーネスがPiになる。
- 既存の4種類と未知のハーネスIDがJSONで往復し、新規runtimeがない旧identityも読める。
- SDKカタログを採用し、重複IDを除去し、不正JSONでは互換候補へ戻る。
- Bot別runtimeを保存し、Storeを再生成して復元できる。
- guest pathの相対指定、親参照、NULを拒否する。
- Piのモデル、provider、profile参照、追加promptが起動設定へ入る。
- 同一設定の通常メッセージでは同じRunを使う。
- 実行中の設定変更を拒否する。
- 旧Runの停止失敗時は設定とRunを維持する。
- 停止成功後はSpaceを削除せず、次のメッセージでCodexの新Runを開始する。
- カスタムendpointと明示profileの衝突を拒否する。
- Piのproject設定を更新してもExtensionsとSkillsの既存参照を保持する。

Storeの統合テストは `ScriptedEngine` を使う。別のオプトインテストではCua SDKを使う`CuaEngine`とPiの実行経路を確認した。
2026-10-21の追加試験では実Extensionのツール実行とCodex ACPの実起動も、ローカルモックに対して確認した。

## 再実行

リポジトリルートから実行する。

```sh
cd examples/cua-bots-macos
scripts/test.sh --core-only
swift build --target CuaBots
```

CuaEngineのSpace統合テストは、OrbStackまたはDockerが動き、`OPENAI_API_KEY`にテスト専用placeholder（`test-`で始まる値）が設定されている場合だけ実行する。キーは隔離Space内のloopbackモックに限って渡す。

```sh
CUA_BOTS_RUN_CUA_INTEGRATION=1 CUA_TELEMETRY=0 CUA_TELEMETRY_FORBID_NETWORK=1 \
  scripts/test.sh --filter CuaEngineIntegrationTests
```

Core-only経路は一時パッケージを作り、CoreとUIと既存テストを参照して検証する。
SDKをstubへ差し替えて本番アプリを起動する仕組みではない。
テストの永続化先は一時ディレクトリであり、ユーザーのBotデータを使わない。

通常テストとアプリのリンクには、`cua-spaces-ffi` をrelease buildし、`libs/spaces-app-swift/scripts/stage-library.sh` でネイティブSDKを配置する。
Cargo.lock依存の取得、protobufの導入、隔離Space上でのSDK固定ハーネス導入はユーザーの許可を得て実施した。
CuaのPi adapterはOpenAI Chat Completions形式を使う。Anthropic wire形式のendpointは拒否される。

GUI送受信の再実行には、`examples/cua-bots-macos/scripts/launch-mock.sh`を使う。
手順と終了時の後始末は、同じディレクトリの`launch-mock.md`に記載した。
GUI試験の初回失敗分はアプリ終了後にSpaceを削除した。
成功分はユーザーが引き続き操作できるようGUIを開いたままとし、そのGUIの終了時にSpaceを削除する。
一時HOMEとイメージキャッシュは残す。

## Phase 1の追加受け入れ検証（2026-10-21）

| 検証 | 結果 |
|---|---|
| 再起動の先行回帰テスト | 修正前に応答の重複、cursorの消失、処理中状態の消失を再現 |
| Coreテスト | 32件成功。途中の応答差分と処理中状態の復元、reset後の同名Bot再作成時のcursor初期化を含む |
| PiのResource検証 | ゲスト内Skillを明示展開し、Extensionの`phase1_probe`実行結果とマーカーファイルを確認 |
| PreparedAcceptanceTests | PiとCodexをCuaEngine経由で実起動。StoreとEngine再生成後もruntimeと同じRun IDを保持し、追加のモック応答を確認 |
| BotごとのSpace所有 | 2つのBotで異なるSpace ID、同じBotだけの再利用、片方のreset後も他方が応答することを確認。作成した2つのSpaceは削除 |
| 最新CuaEngineのPi停止と再開 | 専用Spaceで最初の応答、suspend/resume、同一Runの2回目のモック応答を確認。試験Spaceを削除 |
| Codex CLI | `codex-acp 1.13.1`を実起動。最初の応答とSpace停止と再開後の2ターン目を同じRunで確認 |
| CuaBots実GUIのプロセス再起動 | テスト用バイナリを一時HOMEで起動して送信。終了後に同じデータで再起動し、設定、Space ID、Run ID、受信cursorを維持。最初の応答は1件のまま、追加送信の応答も1件 |

SDK固定版の公開日時はnpmのtimeメタデータで確認した。
Pi 0.87.1は2026-09-22、pi-acp 0.0.33は2026-07-30、codex-acp 1.13.1は2026-09-23公開であり、いずれも検証日より7日以上前である。
SDKはダウンロード時にNodeのSHA-256とnpmパッケージのSHA-512 integrityを検証した。

追加検証のモックはホストの`127.0.0.1:18789`だけで待ち受け、OrbStackゲストから`host.docker.internal`経由で接続した。
実認証情報、実モデル、クラウドは使っていない。
Pi 0.87.1の専用プロファイルでは、認証変数参照に`$OPENAI_API_KEY`が必要だった。
変数名だけの文字列はリテラルとして送られ、ローカルモックが401を返したため修正した。
プロジェクト内の実行コードは信頼が必要なため、テスト専用のゲスト内プロファイルにだけ`defaultProjectTrust: always`を指定した。
ホストのPi設定や認証情報は転送していない。
テスト用GUIとモックサーバーは終了し、準備した検証用Spaceは削除した。
既存のCuaBotsプロセスと`bot-bot`コンテナーは停止も変更もしていない。
一時データとイメージキャッシュは残す。

再実行用fixtureと条件は`../../examples/cua-bots-macos/Tests/Fixtures/phase1/README.md`を参照する。

## Phase 2〜5のドメイン層（2026-10-21）

Coreのテストは`bash examples/cua-bots-macos/scripts/test.sh --core-only`で実行した。
最終実行は68テスト・19スイートが成功した（終了コード0）。
Pi Extensionクライアントは`node --test client.test.ts`で4テストが成功した。

| 対象 | 確認したこと |
| --- | --- |
| 所有権 | 既存Spaceの移行が冪等で削除権限を与えないこと、共有SpaceのresetがSpaceを削除せずRunだけを止めること、専有Spaceは空になったときだけ削除すること |
| 信頼グループ | 別グループのBotの共有拒否、旧レコードが既定グループとして読めること |
| 接続状態 | 30秒を超えた成功がstaleになること、古いprobe結果が新しい結果を上書きしないこと、5回で打ち切ること、認証拒否を再試行しないこと |
| 認可 | 非メンバーの拒否、leaseなしの画面操作拒否、Botをまたぐ成果物書き込みの拒否、別グループへの委譲拒否、loopback以外の管理操作拒否 |
| 協調 | 冪等キーの再送、経路に含まれるBotへの再委譲拒否、深さ4の拒否、全体4件とBotごと1件の上限、期限切れ結果の拒否、成果物名と8MiB上限の拒否 |
| 待ち受け | 127.0.0.1へのbind、TCP往復でのhealth 200、トークン欠落401、トークン付き200、委譲201と冪等再送200、停止後の解放 |
| Pi Extensionクライアント | loopback以外の拒否、Bearerヘッダ、本文と冪等キーの送信、409の状態保持、Bot IDのエンコード、タイムアウトsignal |
| APIルーター | loopback以外の拒否、トークン欠落・失効・別Botトークンの拒否、委譲の冪等な再送と409、他グループへの委譲拒否、成果物の413と400、メッセージの受信範囲 |
| launchd plist | 生成したplistが`plutil -lint`を通ること、`ProgramArguments`が絶対パスと引数になること、`&`のエスケープ、トークンや認証情報を含まないこと、不正なラベル・相対パス・負の間隔の拒否 |
| 永続化 | 委譲・メッセージ・成果物の再起動後の復元、同一冪等キーでの同一タスクID、失効トークンの再起動後の拒否、拒否された要求で状態が変わらないこと |
| スケジューラーの実行 | 成功のみ`delivered`、0以外の終了は`failed`で再実行なし、`--exec-timeout`超過は`failed`で子プロセスが残らないこと、`EngineScheduledExecutor`の初回startと2回目以降send、停止中Botの拒否 |
| スケジューラー | 同じスロットの二重claim防止、再起動後の再送防止、lease引き継ぎ時の`unconfirmed`化、明示再送だけが1回だけ通ること |

`cua-bots-service` とNodeクライアントの往復も、隔離した状態ディレクトリで確認した。

`SharedSpaceAcceptanceTests` は実際のOrbStack Spaceで、2つのBotを同じSpaceに入れて確認した（2026-10-21、95.8秒、`DO_NOT_TRACK=1` `CUA_TELEMETRY=0`）。

| 確認 | 結果 |
| --- | --- |
| 同じSpaceに2つのBotを作成 | 別々のRun ID、別々のホーム（`/home/cua/bots/<id>`） |
| 片方のRunを中断 | もう片方は同じSpaceで応答を継続 |
| 片方のRunを停止 | Spaceは稼働したまま、もう片方も応答を継続 |

| 確認 | 結果 |
| --- | --- |
| health | `{"status":"ok"}` |
| 同じ冪等キーでの委譲2回 | 同じタスクID、201の後に200 |
| 受信側のメッセージ | `alpha`からの委譲が`beta`にだけ見える |
| 8MiB超の成果物 | `413 artifactTooLarge` |
| 別信頼グループへの委譲 | `403 unauthorized` |
| 別Botのトークン | `403 token is for another bot` |

スケジューラー実行ファイルは`.build/debug/cua-bots-scheduler`を直接起動して確認した。
すべて`/tmp`配下の隔離ディレクトリを使い、実モデル、実認証、VPN、クラウドには接続していない。

| 確認 | 結果 |
| --- | --- |
| 単独プロセスで1秒間隔のジョブを5回配送 | `delivered=5 duplicate_keys=0` |
| 再起動後の継続 | 配送済みスロットの再送なし、追加スロットは1回だけ |
| claim直後の強制終了と再起動 | `UNCONFIRMED ... (not resent)`、配送0件のまま、claim数0 |
| 2プロセス同時起動 | leaseを持つ側のみ配送、待機側は`LEASE_BUSY`、重複キー0 |
| スケジューラー→実行ファイル | `cua-bots-run --dry-run`を`--exec-command`に指定し、別プロセスへBot ID・プロンプト・試行回数が渡り、3回とも`DELIVERED`で重複なし |
| `--exec-command` の成功 | スロットごとに1回だけ実行、`DONE delivered=2 failed=0` |
| `--exec-command` の失敗 | `exit 7`で`failed`、次のtickでも再実行なし |
| `--exec-timeout 1` と `sleep 30` | 約2秒で`failed error=timedOut`、残存プロセス0 |
| サービスを強制終了して再起動 | `RESTORED tasks=1`、同じ冪等キーで同じタスクID、メッセージも残存 |
| ゲストからの到達 | Botと同じ`bridge`ネットワークのコンテナから、`host.docker.internal`経由でhealth 200、自分のトークンで200、他Botのトークンで403、無認証401 |
| レート制限と本文上限 | 連続要求で59回200の後に429、64KiB超は413（単体テスト）、拒否の記録にトークン値を含まない |
| BotのSpaceへの配布 | 実際のSpaceで、管理者APIから発行した資格情報が`.cua-bots/credential`へ入り、ディレクトリ700・ファイル600になり、Space内から`host.docker.internal`経由で200、無認証は401（9.4秒、`DO_NOT_TRACK=1` `CUA_TELEMETRY=0`） |
| 管理者による発行 | 管理者トークンで`POST /v1/manage/bots/beta/token`が201、返った値で`/v1/bots/beta/messages`が200、Botのトークンで同じ操作は403、存在しないBotは404、管理者トークン無しは401（単体） |
| 状態ファイルの権限 | `service-state.json`が0600 |
| トークンの再発行 | 旧トークンが401、新トークンが通り、再起動後も同じ（`TokenStore.revokeAll`は対象Botだけを失効） |
| launchd plistの生成 | `cua-bots-service`と`cua-bots-scheduler`の両方で`plutil -lint`がOK、`token`を含まない |

launchdへの登録（`launchctl bootstrap`）は行っていない。plistの生成と構文検証までを確認した。

## Cua Spaces macOSスナップショット（2026-10-22）

設定画面のスナップショット5件を更新した。
原因は、表示言語の行が増えたことと、テストが開発者のシステム言語（日本語）を拾っていたことである。

- テスト用モデルは`ui-language.json`を一時ディレクトリに置き、表示言語を英語に固定するようにした。
- そのうえで`settings`、`settingsKeyvault`、`settingsAutoConnectOff`、`settingsLoginItemApproval`、`settingsStorage`を`SNAPSHOT_RECORD=1`で録り直した。
- 録り直しで差分のなかった`drive-page`と`notifications-page`は復元し、再比較で成功することを確認した。

`swift test`は546テスト・61スイートが成功した（終了コード0）。

## 未確認と未実装

Phase 1の受け入れ条件は2026-10-21に確認を終えた。
対象は新規作成または今回形式で保存したBotであり、受信cursorのない旧版stateの自動移行はユーザー判断で対象外とした。
Pi用Cua Driverブリッジの独自実装は含まない。
SkillとExtensionの検証ではテスト専用ツールだけを実行し、実際のコンピューター操作ツールは実行していない。

Phase 2以降のうち、所有権、信頼グループ、接続状態、認可、協調、スケジューラーのドメイン層はCoreのテストで確認した。
一方で次は未確認または未実装である。

- 実行先を選ぶUI、既存Spaceを選ぶUI
- 画面操作のleaseは実機の画面操作と結び付いていないため、複数Botでの実操作としては未確認である。レジストリの獲得、奪取、期限切れ、解放拒否はテストで確認した。
- 既存Spaceを選ぶUIは追加してビルドを確認したが、実Spaceを並べたGUI操作の目視確認は未実施である。
- 既存Spaceへの作成は、実SDKのSpace一覧取得と組み合わせたGUI操作までは未確認である。
- ハーネス非依存のHTTP APIと、Pi Extensionからの呼び出し
- WireGuard接続、health probeのネットワークI/O、鍵の管理
- スケジューラーの実SDK呼び出し、トランザクションのある保存先、本番の常駐登録

そのためVMや共有Spaceを選べる状態、VPN経由で接続できる状態、Piから委譲できる状態、本番でGUI終了後も実行されると断言できる状態としては報告しない。

## 振り返り

SDKのAPIとサンプルが同じFork内でも一致していなかった。
今後も型の正本を現行バインディングに置き、ネイティブリンク、ソースのコンパイル、純粋なCoreテスト、実アプリ検証を別々に記録する。
この区別を維持するため、Core-onlyテスト経路と関連文書をリポジトリへ残した。
共有Spaceへの単純なID割り当てはreset時の誤削除につながるため、所有権モデルを先に実装する方針とした。

GUIの事前準備はsandboxだけでなく、SDKのSpaceレジストリにも登録する必要がある。
`sb create`の後にGUIで同名Spaceを作ると、再利用ではなく新規作成へ進み、既存sandboxの接続情報と食い違った。
モック用ランチャーは`spaces create`と`spaces delete`を対にして、この手順を残した。
