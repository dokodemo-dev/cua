# Cuaの表示言語

Cua Bots、Cua SpacesのmacOS画面、共有Web UIが参照する日英の翻訳カタログを管理する。
初期対応は言語選択と主要画面に限り、未翻訳の文言は英語のまま表示する。

## 言語の選択

選択肢は「システムに従う」「日本語」「English」とする。
保存値はそれぞれ`system`、`ja`、`en`で、既存の設定がない場合は`system`を使う。
システムの最優先言語が日本語なら日本語にし、それ以外は英語にする。

- Cua Bots：アプリメニューのSettingsから選ぶ。
- Cua SpacesのmacOS従来画面：設定の一般から選ぶ。
- 共有Web UI：SettingsのGeneralにあるLanguageから選ぶ。

macOSの2アプリは`CUA_HOME/ui-language.json`を使い、`CUA_HOME`がなければ`~/.cua/ui-language.json`に保存する。
公式macOS版のWeb UIは既存の`settings.get`と`settings.choose`を通じて、従来画面と同じ値を読み書きする。
設定ファイルは原子的に更新し、保存に失敗した場合は直前の設定を維持してエラーを表示する。
Cua BotsとCua Spacesを同時に開いている場合、別プロセスで保存した値を自動監視する機能はないため、もう一方を再起動して反映する。

単体ブラウザーと、まだ言語フィールドを返さないElectronなどのホストでは、Web UI自身のlocalStorageに保存する。
Tauriのアダプターは既存のUIストレージを使う。
この段階で実動作を確認したのは単体ブラウザーとmacOSであり、TauriやElectronの実アプリ起動は確認していない。

## カタログ

正本は`Sources/CuaLocalization/Resources/en.json`と`ja.json`となる。
Swiftパッケージはこれをリソースとして含め、Web UIは同じJSONを直接importする。
独自の言語パック配布機構や外部の翻訳ライブラリは追加していない。
Rust SDKやモデル設定の型も変更しない。

カタログのキーは現在の英語文言を使う。
日英で同じキーを揃え、翻訳がない場合は英語、英語にもない場合はキー自体を表示する。
変数は`Create {name}`のような名前付きプレースホルダーにし、翻訳の前後で名前を変えない。
値は文字列として挿入し、HTMLとして解釈しない。
会話本文、ファイル名、ユーザーが付けた名前、APIの識別子、モデルへの指示は翻訳カタログへ流さない。

Swiftでの使用例：

```swift
Translator(preference: "ja").text("Create {name}", ["name": "demo"])
```

Web UIのコンポーネントでは`useI18n()`から`t`を取得する。
React以外のロジックには`i18n-core.ts`の純粋関数を使う。
Webの言語同期では、起動時にlocalStorageの古い値をネイティブ側へ書き戻さない。

## リソースの配置

配布するmacOSアプリでは`CuaLocalization_CuaLocalization.bundle`を`Contents/Resources`へ含める。
公式macOS版の既存ビルドスクリプトはSwiftPMのbundleをまとめてコピーするため、その処理を利用する。
`TranslationResources`はインストール先、実行ファイルの隣、テストbundleの隣から探し、ビルド機の絶対パスやSwiftPMの`Bundle.module`に依存しない。

## 検証

```sh
cd libs/cua-localization
swift test
```

Web UI側は、そのディレクトリでVitestを使う。

```sh
cd apps/cua-spaces-web
node node_modules/vitest/vitest.mjs run src/lib/i18n.test.ts src/lib/i18n-ui.test.tsx
```

Swiftテストは言語の保存、未対応値の拒否、フォールバック、置換、配布用リソースの探索を確認する。
Webテストはカタログのキーとプレースホルダーの一致、切り替え、ネイティブ設定の優先、保存失敗を確認する。
テストの保存先は一時ディレクトリであり、実際の言語設定ファイルは変更しない。

## この段階の対応範囲

Cua Botsではサイドバー、新規Bot作成、ハーネス設定の主要入力ラベル、言語設定を対応した。
公式macOS版は主要なサイドバー項目、設定タブ、一般設定の主要ラベル、言語設定を対応した。
Web UIはサイドバー、トップバー、設定タブ、設定見出し、言語設定を対応した。

詳細画面、承認文、動的な状態説明、通知、モデルのエラー本文には英語が残る。
複数形や数値の単位を扱うICU形式にはまだ対応していない。
カタログへの追加と画面側の明示的な参照を段階的に進める。
