# cua-bots-service 拡張

Botの中で動くPi Extensionから、同じMac上のCua Botsサービスへ委譲、メッセージ、成果物の登録を行う。
サービスはloopbackで待ち受け、BotごとのBearerトークンで認可する。

## 構成

| ファイル | 役割 |
| --- | --- |
| `client.ts` | サービスAPIのクライアント。Piに依存しない |
| `client.test.ts` | fetchを差し替えた単体テスト |
| `cli.ts` | 動作確認と他ハーネスからの薄いCLI |
| `index.ts` | Pi Extensionのエントリ。4つのツールを登録する |

## ツール

- `cua_bots_delegate`: 同じSpace・同じ信頼グループのBotへ単発の委譲を送る。冪等キーが必須。
- `cua_bots_messages`: 自分宛て、またはSpace宛てのメッセージを読む。
- `cua_bots_post_message`: Spaceへメモを投稿する。宛先を1つ指定できる。
- `cua_bots_artifact`: ファイル名、サイズ、SHA-256を登録する。ファイル自体は送らない。

## 環境変数

| 名前 | 内容 |
| --- | --- |
| `CUA_BOTS_API_URL` | `http://127.0.0.1:<port>` の形の待ち受け先。loopback以外は拒否する |
| `CUA_BOTS_TOKEN_FILE` | 自分のトークンを含むファイル。呼び出しのたびに読む |
| `CUA_BOTS_ID` | Bot ID。ツール引数の`botID`を省略したときに使う |

トークンはプロンプト、会話ログ、ツール結果へ出さない。
`cli.ts`もトークンをファイルから読み、標準出力へは出さない。

## 使い方

```sh
cd examples/cua-bots-macos
swift build --product cua-bots-service
DIR=$(mktemp -d)
.build/debug/cua-bots-service --state "$DIR"
```

別の端末で、表示されたポートとトークンファイルを指定する。

```sh
cd examples/cua-bots-macos/extensions/cua-bots-service
export CUA_BOTS_API_URL="http://127.0.0.1:<port>"
export CUA_BOTS_TOKEN_FILE="$DIR/alpha.token"
node cli.ts health
node cli.ts delegate --bot alpha --to beta --space local:shared \
  --prompt "Summarize" --key req-1 --deadline 60
```

同じ冪等キーで再実行すると、新しいタスクは作られず同じIDが返る。

## テスト

```sh
cd examples/cua-bots-macos/extensions/cua-bots-service
node --test client.test.ts
```

ネットワークを使わない。`fetch`を差し替え、ヘッダ、本文、状態コードの対応を確認する。

## 制約

- TLS終端とトークン配布は未実装である。待ち受けは127.0.0.1だけに限定している。
- サービスの状態はメモリ上にあり、再起動で委譲とメッセージは消える。永続化は未接続である。
- 委譲は単発のみで、グループ全員への自動応答は行わない。
