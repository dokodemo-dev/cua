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

通常のSwiftテストでは29件が成功し、オプトインのSpace統合テスト1件は実行フラグ未設定でskipした。CuaBots実行ファイルもリンクした。
オプトインテストでは、CuaEngineがSpaceを作り、Piの2回目の応答まで同じRunで処理する経路を確認した。
追加のGUI試験では、アプリUIからPiを起動し、初回応答と2回の追加送信を確認した。
アプリ再起動後のRun復帰は未確認である。

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
実Extensionのツール実行、Codexの実起動は確認していない。

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

## 未確認と未実装

Phase 1は受け入れ条件の一部が未達である。
SDKを使うCua CLI経由のPi起動、送受信、同一Runへのfollow-up、Space suspend/resume後の再送信は確認した。
Cua Botsアプリ本体からのPi起動とモック送受信も確認した。
アプリ再起動後のRun復帰、実Extensionのツール実行、Codexの実起動は未確認である。
Pi用Cua Driverブリッジも追加していない。
SDKの`reuse`は名前ではなく配置先と利用可能なサービスでSpaceを選ぶため、複数BotのSpace分離も追加対応が必要となる。
今回のGUI試験は一時HOME内に1つのSpaceだけを登録して行った。

Phase 2以降のVM選択、WireGuard接続管理、Bot単位認可、協調API、グループチャット、成果物転送、UI外の常駐スケジューラーは未実装である。
そのためVMや共有Spaceを選べる状態としては報告しない。

## 振り返り

SDKのAPIとサンプルが同じFork内でも一致していなかった。
今後も型の正本を現行バインディングに置き、ネイティブリンク、ソースのコンパイル、純粋なCoreテスト、実アプリ検証を別々に記録する。
この区別を維持するため、Core-onlyテスト経路と関連文書をリポジトリへ残した。
共有Spaceへの単純なID割り当てはreset時の誤削除につながるため、所有権モデルを先に実装する方針とした。

GUIの事前準備はsandboxだけでなく、SDKのSpaceレジストリにも登録する必要がある。
`sb create`の後にGUIで同名Spaceを作ると、再利用ではなく新規作成へ進み、既存sandboxの接続情報と食い違った。
モック用ランチャーは`spaces create`と`spaces delete`を対にして、この手順を残した。
