# ローカル確認で常駐させる（launchd手順）

**本番は VPS に置く（`production-vps.md`）。この文書は Mac でローカル確認するときの手順である。**
Mac を本番にはしない。`launchctl` への登録は、ローカルで常駐させたい場合だけ行う。

`cua-bots-service` と `cua-bots-scheduler` はGUIに依存しない実行ファイルである。
この文書は、それらをログイン時に常駐させるための手順を示す。

**このリポジトリの作業では登録を実行していない。** 登録は利用者の環境を変える操作なので、内容を確認したうえで利用者が行う。

## 前提

- 実行ファイルを安定した場所へ置く。ビルドディレクトリの`.build/debug/`は再ビルドで消えるため使わない。
- 状態ディレクトリを決める（例: `~/Library/Application Support/CuaBots/service`）。
- トークンは状態ディレクトリ内に0600で作られる。plistには含まれない。

## plistを生成する

各実行ファイルは自分の絶対パスを使ってplistを出力する。

```sh
cd examples/cua-bots-macos
swift build -c release --product cua-bots-service --product cua-bots-scheduler

mkdir -p "$HOME/Library/Application Support/CuaBots/service"
STATE="$HOME/Library/Application Support/CuaBots/service"

.build/release/cua-bots-service --state "$STATE" --print-launchd-plist \
  > /tmp/ai.cua.bots.service.plist

.build/release/cua-bots-scheduler --state "$STATE/scheduler" --owner cua-bots \
  --exec-command "$PWD/.build/release/cua-bots-run --volume <Volume>" --exec-timeout 600 \
  --print-launchd-plist \
  > /tmp/ai.cua.bots.scheduler.plist

plutil -lint /tmp/ai.cua.bots.service.plist /tmp/ai.cua.bots.scheduler.plist
plutil -p /tmp/ai.cua.bots.service.plist
```

生成物には次が入る。

| キー | 内容 |
| --- | --- |
| `Label` | `ai.cua.bots.service` / `ai.cua.bots.scheduler` |
| `ProgramArguments` | 実行ファイルの絶対パスと、生成時に指定した引数 |
| `RunAtLoad` / `KeepAlive` | どちらも`true` |
| `ThrottleInterval` | 10秒 |
| `StandardOutPath` / `StandardErrorPath` | 状態ディレクトリ内の`launchd.*.log` |
| `WorkingDirectory` | 指定した場合だけ |

トークン、認証ヘッダ、APIキーは含まれない。`--exec-command`に秘密値を直接書かないこと（環境変数経由で受け取る）。

## 登録する（利用者の操作）

```sh
mkdir -p "$HOME/Library/LaunchAgents"
cp /tmp/ai.cua.bots.service.plist "$HOME/Library/LaunchAgents/"
cp /tmp/ai.cua.bots.scheduler.plist "$HOME/Library/LaunchAgents/"

launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/ai.cua.bots.service.plist"
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/ai.cua.bots.scheduler.plist"
launchctl print gui/$(id -u)/ai.cua.bots.service | head -20
tail -f "$STATE/launchd.err.log"
```

停止と解除。

```sh
launchctl bootout gui/$(id -u)/ai.cua.bots.scheduler
launchctl bootout gui/$(id -u)/ai.cua.bots.service
rm "$HOME/Library/LaunchAgents/ai.cua.bots."*.plist
```

## 確認できること

- `KeepAlive`により、プロセスが落ちるとlaunchdが起動し直す。
- スケジューラーのleaseとスロット記録は状態ディレクトリに残るため、再起動しても同じスロットを二重に送らない。
- 結果が不明なスロットは`unconfirmed`になり、自動再送しない。
- GUIを終了しても、スケジューラーは`--exec-command`を実行し続ける。

## 既知の制約

- サービスは`127.0.0.1`だけで待ち受ける。OrbStackでは`host.docker.internal`がホストのloopbackへ中継されるため、Spaceの中からも届く（実測済み）。LANへは公開しない。
- ゲストへ渡すのはAPIのURLとトークンファイルのパスだけである。トークン値は状態ディレクトリ内の0600のファイルに置く。
- `--exec-command`の受け側は`cua-bots-run`を使う。実Spaceの起動・送信は`CuaEngine`経由で行う。
- 状態ファイルは単一ホスト向けの実装で、複数マシンでの共有は想定していない。
