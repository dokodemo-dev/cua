# ハーネスとPi設定

## 選択と保存

Macの作成画面はSDKの `agentHarnesses()` を使う。
このForkのSDKは `claude-code`、`openai-codex`、`gemini-cli`、`google-antigravity`、`opencode`、`goose`、`pi`、`hermes`、`openclaw` を定義している。
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
