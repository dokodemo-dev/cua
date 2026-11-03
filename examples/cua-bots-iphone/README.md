# Cua Bots（iPhone）

VPS の `cua-bots-service` を iPhone から操作するクライアント。
Mac アプリの相棒である `examples/cua-bots-ios` とは別物で、Cua SDK も Rust も使わない。
HTTP API だけを叩くので、実機ビルドに必要なのは署名だけになる。

## 必要なもの

- Xcode 16 以上（iOS 18 SDK）と `xcodegen`
- iPhone がサービスと同じ WireGuard VPN に入っていること
- 実機に入れる場合は Apple ID のチーム（無料の個人チームでも可。7日で期限切れ、同時3アプリまで）

## ビルド

```sh
xcodegen generate
xcodebuild -project CuaBotsPhone.xcodeproj -scheme CuaBotsPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

実機はチームを渡す。`DEVICE_UDID` は `xcrun devicectl list devices` で調べる。

```sh
xcodebuild -project CuaBotsPhone.xcodeproj -scheme CuaBotsPhone \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> build
xcrun devicectl device install app --device <DEVICE_UDID> \
  build/Build/Products/Debug-iphoneos/CuaBotsPhone.app
```

初回は端末の「設定 > プライバシーとセキュリティ > デベロッパーモード」を有効にし、
インストール後に「設定 > 一般 > VPN とデバイス管理」で開発元を信頼する。

## サインイン

`cua-bots-open` が作るリンク（`https://bots.dokodemo-dev.internal:7717/ui#c=...`）を貼るか、
`cuabots-service://?url=...&token=...` を開く。接続先と資格情報を分けて入れることもできる。
資格情報は Keychain に保存し、サインアウトで消す。

サービスは TLS で待ち受けるので、端末側に 2 つ用意が要る。

- VPN 専用 CA（`vpn-dns-ca.crt`）をプロファイルで信頼する
- WireGuard の設定で DNS にハブの WG アドレスを指定し、`bots.dokodemo-dev.internal` を
  引けるようにする（ハブの CoreDNS は内部名だけ権威応答し、他は NextDNS へ転送する）

## できること

- Bot の一覧、ピン留め、アーカイブの表示
- Bot の作成（管理者のみ）。名前・色・動かす Space を選び、新しい Space は準備完了まで見届ける
- チャット（2秒ポーリング、Markdown、思考の折りたたみ、送信）
- ルーティンの一覧・追加・停止/再開・削除
- 成果物の一覧（名前・所有者・サイズ・日時・sha256）
- テーマ（システム / ライト / ダーク）

## まだ無いもの

- 承認、画面ストリーム（`cua-view` 相当）
- プッシュ通知（開いている間だけ更新する）
- アバターはコアラの絵ではなく、色と頭文字の丸で表す

## アイコン

`design/AppIcon.svg` が原本で、コアラの形は Web UI の `ui/src/avatar.ts` と同じもの。
PNG（1024px、アルファなし）は `App/Assets.xcassets/AppIcon.appiconset/` に置く。
形を変えたときは SVG を書き換えて 1024px を書き出し直す。

```sh
node design/make-icon-svg.mjs ../cua-bots-service-go/ui/src/avatar.ts design/AppIcon.svg
```

## テスト

```sh
swift test
```

API クライアントの URL・ヘッダ・デコード・401 の扱いと、ターン出力の分解を確認する。

## 注意

- サービスは VPN 内の HTTP（IP 直指定）なので、ATS の例外（`NSAllowsArbitraryLoads`）を入れている。
  TLS 終端と DNS 名を用意できたら、この例外は外す。
- 署名のチーム ID と Bundle ID（`dev.dokodemo.cuabots`）は各自の環境に合わせる。
  別のアプリと衝突する場合は `project.yml` の `PRODUCT_BUNDLE_IDENTIFIER` を変える。
