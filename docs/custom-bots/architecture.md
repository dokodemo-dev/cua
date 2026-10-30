# Cua Botsカスタマイズの構成

## 調査対象

対象は親ディレクトリではなく、この `cua/` リポジトリである。
調査開始時のHEADは `44f47953a422d87593a7ba9a48020799f22e2548`、ブランチは `main`、作業ツリーに既存差分はなかった。
`AGENTS.md`、`CLAUDE.md`、ルートREADME、両BotアプリのREADME、開発ガイド、テストガイド、ライセンスを参照した。

実装対象は `apps/cua-spaces-*` ではなく、`examples/cua-bots-macos/` である。
`libs/cuabot` は別の旧パッケージであり、変更していない。

## アプリとSDKの依存関係

```text
CuaBots (Mac SwiftUI)
  CuaBotsCore: Bot、設定、会話、ルール、Volume、BotStore
  CuaBotsUI: 共通SwiftUI部品
  CuaBotsCua: BotEngineのSDK実装、RoutineClock、RemoteBridge、Keyvault
    Cua → libs/cua/swift → CuaSDK → cua_sdkFFI
    CuaSpaces → libs/spaces-sdk-swift
    CuaSpacesFFI / CuaSpacesStreaming → libs/spaces-app-swift

iPhone: examples/cua-bots-ios
  Mac側パッケージのCore/UIを再利用
  CuaBotsRemote → spacesdへ直接接続、またはRelay
  Macが書いたsnapshotを読み、outboxへ操作要求を書く
```

Mac側がBotの作成と実行を担当する。
iPhone版は独立したBot実行ホストではない。
Swiftパッケージはローカルパス依存だが、実行と通常テストのリンクにはRustでビルドしたSpaces exportの配置が必要になる。

## 起動とハーネス

SDKの正本は `libs/cua/crates/cua-agents/src/harness.rs` である。
`agentHarnesses()` はSDKの `HarnessInfo` 一覧をJSONで返す。
新しいUIはその一覧を使い、Piを初期値にする。
一覧取得に失敗した場合だけ、従来の4種類とPiを候補にする。
保存形式は従来どおり文字列IDなので、未知のIDも読み込み時に捨てない。

起動は `CuaEngine.start` → `Space.agentStart` → `cua-spaces` の `start_options` → `cua-agents` → `acp-runner.mjs` である。
Piの場合は `pi-acp` が `pi --mode rpc --no-themes` を起動する。
SDKはPi 0.87.1とpi-acp 0.0.33を固定している。
このMacの独自Pi 1.3.0をリモートへ配置したわけではない。

追加した `HarnessLaunch` はSDKに依存しない起動設定層である。
Pi固有の環境変数と設定ファイル生成をここに置き、SDKの生成バインディングやRustコードは変更しない。

## 保存と移行

| データ | 既存の保存先 |
|---|---|
| Bot設定 | Volumeの `agents/<id>/identity/` とアプリの `state.json` |
| 会話、承認、通知、Run ID | アプリの `state.json` |
| メモリ | `agents/<id>/memory/MEMORY.md` |
| 成果物、受信ファイル | `agents/<id>/outputs/`、`inbox/` |
| ルール | `rules.yaml` とidentity内のJSON |
| タスク | `VolumeLayout.tasks` のJSON |
| Routineの時計と発火履歴 | `RoutineStore` の `routines.json` |

新規フィールド `Bot.runtime` はoptionalであり、既存Botではnilとなる。
既存のハーネスIDは変更しない。
モデル未指定なら従来の環境変数によるモデル指定、またはハーネス既定値にフォールバックする。
不明なハーネスを別のハーネスへ黙って置換せず、SDKからの起動エラーとして扱う。

設定変更時は動作中のターンを拒否し、旧Runを停止する。
停止失敗時は旧設定とRun IDを保持する。
成功時はRun IDとポーリングカーソルをクリアし、Spaceと会話を残す。
次のメッセージが新しいRunを開始する。
変更がない通常のメッセージは従来のRunを継続する。

## SpaceとVMの制約

現行アプリはBotごとに `bot-<id>` というSpaceを作成する。
SDKは同一sandboxに複数のAgent Runを持てるが、Botアプリのpause、reset、画面操作は専用Spaceを前提にしている。
複数Botを同じSpaceに割り当てるだけでは、あるBotのresetが他のBotのSpaceも削除する。
共有化に先立ち、実行先VM、Spaceの所有権、Agent Runを別のレコードに分離する必要がある。

WireGuard経由の接続候補はSDKの直接接続と `Spaces.add` である。
VPN自体をSDKから構築する必要はない。
接続先の登録、Bot単位の認可、画面操作の排他制御は未実装である。

## ライセンス

正本はルートの `LICENSE.md` と `legal/LICENSING.md` である。
ユーザー指定のルート `LICENSING.md` URLは404だった。
SDKとCua DriverはMITだが、両Botサンプル、Spaces export、streaming、spacesdはFSL-1.1-MITである。
BotサンプルのLICENSEは社内利用をPermitted Purposeに明記している。
競合する商用サービスとして他者へ提供する場合は別の検討が必要になる。
既存の著作権表示とLICENSEを保持し、新規BotソースにもFSLの識別子を付けた。

Piとpi-acpはSDKが依存する既存コンポーネントであり、新規ライブラリは追加していない。
pi-acpのnpmメタデータはMITを示す。
Swift側には新規の外部パッケージを追加していない。
Webアプリの依存許諾一覧は `legal/THIRD_PARTY_NOTICES.md` にあるが、今回そのアプリは利用も変更もしていない。
推移的依存すべての新規法務監査は実施していない。

## 公式資料と差異

- https://cua.ai/docs/spaces/examples/cua-bots
- https://cua.ai/docs/cua-sdk/guides/coding-agent-options
- https://cua.ai/docs/cua-sdk/reference/agents
- https://github.com/svkozak/pi-acp

coding-agent-optionsはrun-a-coding-agentへリダイレクトされた。
API名や保存経路の判断は、このForkのソースを優先した。
公式Botページの「追加したコンピューター」選択説明に対して、このForkの作成UIはlocal/cloudの2択だった。
SDKにはCua Cloud終了の記載もあり、残存するcloud選択肢の利用可能性は確認していない。

## 実装の境界

Phase 1の設定、UI、起動オプション、隔離テストを実装した。
ネイティブライブラリ不足により実アプリのリンクと実通信検証は未完了である。
Phase 2以降は設計上の要件を文書化した段階であり、利用可能な機能として扱わない。
