# 段階的な実装計画

## Phase 1の完了（2026-10-21）

Piの初期選択、SDKカタログの選択肢、Bot別設定の保存と編集、新設定でのRun作り直しを実装した。
以下の受け入れ条件を、実認証情報や実モデルを使わない隔離環境で確認した。

1. ビルド済みの`cua-spaces-ffi`と現行Swiftバインディングを使い、CuaBotsをリンクした。
2. 一時HOMEと専用のOrbStack SpaceでGUIを起動した。
3. SDK固定版Piとローカルモックで作成、送受信、同一Run継続、Space停止と再開後の送信を確認した。
4. ゲスト内だけにテスト用SkillとExtensionを置き、明示的なSkill展開、登録ツールの実行、実行マーカーを確認した。
5. SDK固定版Codex ACPを起動し、CLIでのSpace停止と再開、CuaEngineでの送受信、StoreとEngine再生成後の同一Run継続を確認した。
6. CuaBotsの実プロセスを終了して再起動し、設定、Space ID、Run IDの復元、応答の重複防止、同じRunへの追加送信を確認した。
7. 2つのBotが別々のSpaceを持つこと、同じBotだけが名前一致で再利用すること、片方のresetが他方へ影響しないことを確認した。

再起動復帰のため、受信cursor、応答途中のテキスト、処理中状態、タスク参照をRun IDとともに保存する。
SDKからの応答差分はStoreで蓄積し、処理済みページと状態をまとめて保存する。
SDKの汎用`reuse`は別名のSpaceも返すため無効にし、Botの正規Space IDが一致する場合だけ再利用する。

利用前の検証段階というユーザー判断により、cursorを保存していない旧版stateの自動移行は対象外とした。
今回形式で保存したstateの再起動復帰を検証対象とする。
検証証跡は`test-results.md`、追加テストの手順は`../../examples/cua-bots-macos/Tests/Fixtures/phase1/README.md`を参照する。

依存導入はユーザーの許可を得てゲスト内だけで行い、固定版の公開後7日経過とSDKの整合性検証を確認した。
Claude Code、実モデル、実認証情報、クラウドは使用していない。
Phase 2以降のうち、所有権、接続状態、認可、協調、スケジューラーのドメイン層を実装した。
HTTP API、Pi Extensionクライアント、VPN接続、実行先を選ぶUIは未接続である。
詳細と検証手順は`service.md`を参照する。

## Phase 2で分離する実行先

`ExecutionTarget`、`Bot.executionTargetID`、`SpaceBinding` を追加した。
既存Botは読み込み時に互換レコードへ移行し、既存Spaceの削除権限を与えない。
作成時のBotは専有Spaceとして登録し、既存Spaceは共有として登録する。

共有Spaceでは所有権と信頼グループを持たせる。
Botのresetで共有Spaceを削除しないこと、pauseが他のBotを止めないこと、画面操作のleaseが排他になることをCoreのテストで確認した。
共有は同じ信頼グループのBotだけに許し、別グループのBotは専用Spaceへ分ける。

既存Spaceを選ぶUIを追加した。作成画面でSpace一覧から選び、信頼グループと作業ディレクトリを指定する。
既存Spaceへ作るBotは、アプリが作ったSpaceではないため、削除も停止もしない。

`SharedSpaceAcceptanceTests` で実際のSpaceに2つのBotを入れ、片方の中断と停止がもう片方とSpaceに影響しないことを確認した。
画面操作のleaseは実操作と結び付いていないため、レジストリのテストまでの確認である。

## Phase 3で追加する接続管理

`ConnectionHealth` を追加した。
期限付きのprobe結果、失敗とオフラインの区別、上限付きバックオフ、認証拒否の停止を純粋な状態機械として実装し、テストで確認した。

`AuthorizationPolicy` を追加した。
Spaceの所属、信頼グループ、画面lease、成果物の所有、委譲の宛先と深さ、管理操作のloopback制限を操作ごとに確認する。

WireGuard接続、probeのネットワークI/O、鍵の管理、実VPN上の検証は未実施である。
実接続と本番常駐の登録は、別途の承認を得てから行う。

## Phase 4で追加する協調

`CollaborationService` を追加した。
明示した宛先への単発委譲、Space内メッセージ、成果物参照を扱い、次をテストで確認した。

- 冪等キーによる重複排除と、同じキーで内容が違う場合の拒否
- ルートタスクの経路に含まれるBotへの再委譲の拒否
- 深さ3、全体同時4件、Botごと1件の上限
- 親の期限を超えない子タスクの期限と、期限切れ結果の拒否
- 成果物の所有、8MiB上限、パスを含む名前の拒否

`ServiceAPI` としてトランスポート非依存のルーターとBearerトークン管理を追加した。
loopback以外の拒否、Botとトークンの不一致拒否、委譲・メッセージ・成果物の状態コード、他グループへの委譲拒否をテストで確認した。
`ServiceServer` として127.0.0.1限定のHTTP待ち受けを追加し、`cua-bots-service` で隔離起動できるようにした。
`examples/cua-bots-macos/extensions/cua-bots-service/` にPi Extensionとクライアント、CLIを追加した。
Nodeのクライアントから実際のソケット越しに委譲、メッセージ、成果物を往復させ、同じ冪等キーの再送、他グループへの委譲拒否、別Botトークンの拒否を確認した。
TLS終端とトークン配布は未実装である。
グループ発言への全Bot自動応答は実装しない。

## Phase 5で分離するスケジューラー

`SchedulerState` と `cua-bots-scheduler` を追加した。
UIプロセス外で動く実行ファイルが、スロット単位の配送記録とleaseでジョブを実行する。

隔離したディレクトリで次を確認した。

1. スロットごとに1回だけ配送され、再起動後も配送済みスロットを再送しない。
2. claim直後のクラッシュは`unconfirmed`になり、自動再送しない。
3. leaseの有効期限切れ後は別プロセスが引き継ぎ、二重配送しない。

`--exec-command` で配送ごとに実コマンドを実行できるようにした。
終了コード0だけを成功として記録し、失敗とタイムアウトは`failed`にして自動再送しない。
`EngineScheduledExecutor` は`BotEngine`へ配送を渡し、Runが無ければ開始、あれば新しいターンを送る。

サービス側は`ServiceStateStore`でレジストリ、トークンのハッシュ、協調の状態を保存する。
プロセスを強制終了して再起動しても、同じ冪等キーが同じタスクIDを返し、メッセージと失効が維持されることを確認した。

Botの起動時には、管理者APIで発行した資格情報をBotの作業ディレクトリへ書き、700/600にしたうえでURLとパスだけを渡す。
実際のSpaceで、Space内から`host.docker.internal`経由でAPIへ到達できることまで確認した。

`flock`による排他とファイル保存は単一ホストでの検証用である。
スケジューラーから`CuaEngine`を直接組み立てるCLIと常駐登録は未接続であり、UIの終了後も実行できると本番環境で断言するのは常駐登録の検証後とする。

## 本番の置き場所（2026-10-23 決定）

Mac は開発とローカル確認に使い、本番は VPS に置く。
当初の「Mac常駐を本番とする」前提は取り下げた。

- サービスとスケジューラーは VPS の systemd で常駐する。
- Space は VPS 上の Docker（runc）で動かす。KVM は不要。
- GUI は Mac に残し、WireGuard 越しに VPS のサービスへ接続する。
- 本番の協調 API は **Go 実装**（`examples/cua-bots-service-go`）にする。Swift 版は参照実装とローカル確認用に残す。
  - Go 実装は、レジストリ、認可、トークン、協調を Swift 版と同じ規則で持ち、状態 JSON も共通（テストで相互変換を確認）。
  - スケジューラーと Bot の実行は次の段階。VPS では `cua` CLI を `--exec-command` から呼ぶ。
- VPS の候補と必要スペック、移行手順、未決事項は `production-vps.md` に置く。

## 今回の変更履歴

- 既存のKeyvault参照を現行SDKの `domain`、`appDisplay`、`kind` へ修正した。
- Pi対応のハーネスモデル、Bot別runtime、純粋な起動設定層を追加した。
- 作成UIとプロファイルの編集UIを更新した。
- Runのみを停止するBotEngine APIと安全な設定切り替えを追加した。
- SDKのネイティブライブラリがなくてもCore/UIを検証できる `scripts/test.sh --core-only` を追加した。
- アーキテクチャ、設定、ネットワーク、協調、テストの文書を追加した。
- 実行先の所有権、信頼グループ、画面lease、接続状態、認可、協調、スケジューラーのドメイン層を追加した。
- GUI非依存のスケジューラー実行ファイルを追加した。

## ブラウザ画面の作り直し（2026-10-27）

`examples/cua-bots-service-go` の `/ui` を、Grok Bot のデスクトップ版に寄せた構成へ
作り直した。対象は Go 実装のブラウザ画面で、macOS アプリの SwiftUI 画面は変更していない。

- 構成は左の Bot 一覧、中央の会話、右の Bot パネル。上部タブを廃止し、検索・新規作成・
  設定・接続情報はモーダルとサイドバーへ移した。Bot のまとまりは利用者が作るセクションでは
  なく、Bot が動く Space をそのまま使う。
- 会話は等幅のプレーンテキストをやめ、見出し・箇条書き・コードブロック・リンクを描く。
  メッセージにはコピーと再送、上部のピルから右パネルを開ける。
- テーマはシステム設定に追従する。ライトは Grok Bot の白より明度を落とし、暖色寄りの
  グレーを土台にした。
- アバターは Cua のコアラを維持し、色・目・耳を新規作成ダイアログのグリッドに載せた。

画面のソースは `ui/` の TypeScript に移し、esbuild で `internal/api/ui/app.js` を作る。
`app.js` はコミットし、`aube run check` で型検査、バンドルの差分、oxlint、oxfmt を確認する。
Go のビルドとテストは Node を要求しない。`/ui/app.css` と `/ui/app.js` は ETag 付きで配信する。

確認したこと:

- `go test ./...` が通る。`/ui` がスタイルシートとバンドルを参照し、両方が配信されることを
  テストで固定した。
- ローカルに `--no-provision` で起動し、`--seed-bots` と `--admin` で作った状態に対して
  ダーク、ライト、モバイル幅、検索、設定、新規作成、右パネルを実画面で確認した。

左メニュー上部の大きなアイコンは「ピン留め」に変え、右パネルから切り替える。保存は
サービス側（`GET /v1/pins`、`PUT` / `DELETE /v1/pins/<id>`、管理者のみ）で、同じ資格情報で
開いた端末に共有される。`service-state.json` の `pins` は Go 版だけが持つ項目なので、
Swift 版が状態を書き戻すと落ちる（UI の好みであり、実行状態ではない）。
見た目の編集とルーティンの追加は右パネルからダイアログへ移し、動かす場所は
作成時に決めた値の表示だけにした（付け替えは API / CLI の操作として残す）。

作成ダイアログは名前の規則（1〜63 文字、半角小文字英数字と `.` `_` `-`）を送信前に検査し、
失敗はダイアログの中に出す（背面のトーストではモーダルに隠れるため）。既存の Space へ
作るときは `trustGroup` を省略し、その Space の信頼グループを引き継ぐ。

Bot ごとのエージェント設定を追加した。Web の右パネルから harness / model / base URL / wire /
鍵の変数名を保存し（`GET` / `PUT /v1/bots/<id>/agent`、管理者のみ）、`service-state.json` の
`agents` に持つ。保存時にその Bot の run を消し、次のターンから新しい設定で始める。
鍵の値は `turn.env` に残し、画面には変数名だけを置く。ChatGPT のサブスクは「Space のログイン」、
DeepSeek は `pi` + `https://api.deepseek.com/v1` + `openai-chat` のプリセットで扱う。
DeepSeek Harness（dsh）は `deepseek-harness` を追加し、dsh 標準の DeepSeek 経路と
カスタムエンドポイントの両方を選べるようにした。

成果物の一覧は `GET /v1/bots/<id>/artifacts` を追加し、ライブラリタブが同じ Space の
記録（名前・所有者・サイズ・日時・sha256）を新しい順に出す。実体は Space の
`outputs` / `inbox` にあり、画面は索引だけを扱う。

### iPhone クライアント（2026-10-27）

`examples/cua-bots-iphone` に、`cua-bots-service` を直接叩く iPhone アプリを追加した。
upstream の `examples/cua-bots-ios`（Mac アプリの相棒）は残している。

- Cua SDK、Rust、XCFramework を使わない。HTTP クライアントと SwiftUI だけで、
  チャット、ルーティン、成果物、ピン留め、テーマを扱う。
- これで iOS ビルドの障害だった `CuaSpacesFFI` の iOS スライスが不要になり、
  実機ビルドは署名だけになる。
- 接続は VPN 内の HTTP。IP 直指定のため ATS の例外を入れている（TLS 化したら外す）。
- 2 秒ポーリング、Markdown の簡易描画、認証情報は Keychain。アプリアイコンは Web UI と
  同じコアラの幾何から SVG を起こし、1024px・アルファなしで書き出した。
- Bot の作成にも対応した（管理者のみ）。名前の規則は画面側でも検査し、色と Space を選び、
  新しい Space は `GET /v1/bots/<id>/space` で準備完了まで追う。
- Simulator（iPhone 17 Pro）でビルドと主要画面を確認し、実機向けビルドも通した。
  実機へのインストールは端末のデベロッパーモードと開発元の信頼が要る。

残り（サーバ API が要るため今回は入れていない）:

- 承認キュー、会話の横断検索、添付、実行中の停止。
- ライブラリとコンピューターのタブは、それぞれ空状態と `cua-view` の案内を出すだけ。
- 会話の更新は引き続き 2 秒のポーリング。SSE 化はサーバ側の追加になる。

### TODO（2026-10-28 時点で未着手）

- **Space ごとのハーネス版と更新チェック**: Space 内の `node` / `pi` / `dsh` の実版と
  `libs/cua/crates/cua-agents/installables.json` の固定版を比べ、設定 → Space に
  「更新あり」を出す。`cua sb exec` を 1 回呼ぶので 60 秒キャッシュと手動更新を付ける。
  dsh は developer preview なので、通知だけで自動更新はしない。
- **監視の拡張**: いまは死活と証明書だけ。ターン失敗率やキュー滞留を見るならメトリクスが要る。
- **承認キューの UI**: 実行中の承認要求を画面から許可・拒否する。
- **ターンの停止**: 実行中のターンを中断する（CLI の run 停止を API 経由で）。
