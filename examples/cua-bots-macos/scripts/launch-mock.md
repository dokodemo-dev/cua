# GUIからローカルモックへ送受信する

## 概要

`launch-mock.sh`は一時HOMEとローカルSpaceを作り、Space内のloopbackモックに接続したCuaBotsを起動する。
実APIキーやMac側のPi設定は引き継がず、接続専用の合成値`test-key`を使う。
実モデルは呼び出さず、テレメトリとシステム通知は無効にする。
`launch-mock.ts`が準備、起動、終了処理を担当し、`.sh`は薄いラッパーとなる。

## 必要環境

- macOSとNode.js 24以降
- 起動済みのOrbStackまたはDocker（`/var/run/docker.sock`）
- ビルド済みの`libs/cua/target/release/cua`
- ビルド済みの`examples/cua-bots-macos/.build/debug/CuaBots`

ホストにパッケージをインストールする処理はない。
Space内ではSDK固定版のPi関連パッケージを導入するため、初回はパッケージレジストリへの通信が必要となる。
Linuxイメージが未キャッシュならイメージもダウンロードする。

## 使い方

既存の画面確認用CuaBotsを閉じ、`cua-custom/`から実行する。

```sh
bash cua/examples/cua-bots-macos/scripts/launch-mock.sh
```

出力した`Bot name to enter`の名前をGUIにそのまま入力する。
外観を選んだ後、`This Mac`と`Pi`を選び、モデルなどの追加設定はすべて空欄のまま`Create`を押す。
この名前で作成すると、事前準備したテスト用Spaceを再利用する。
別名のBotやCua Cloudは作成しない。

## 送受信の確認

作成後の初回応答に`GUI mock reply #1. No real model was called.`が含まれることを確認する。
その後、`hello`、`again`を順番に送信し、応答の番号が`#2`、`#3`と増えることを確認する。
応答は固定文であり、入力の内容を推論するものではない。

GUIを終了すると、この起動処理が作成した1つのSpaceだけを削除する。
起動したターミナルはGUIの終了まで開いておく。
ログインやホストアクセスの許可は行わない。

## オプション

| オプション | 動作 |
|---|---|
| 指定なし | Spaceの準備後にGUIを起動する |
| `--help` | ヘルプだけを表示する |

## 出力の見方

`[1/4]`から`[4/4]`が準備段階を示す。
`[4/4] GUI ready`が出たらGUIでBotを作成できる。
一時データの保存先は`Temporary data`に表示し、終了後も残す。
Space内のモックログは`/tmp/cua-bots-gui-mock.log`にあり、Space削除時に失われる。
入力文や認証ヘッダはモックログに記録しない。

## 想定ワークフロー

画面表示だけの確認には`launch-isolated.sh`を使い、送受信には本スクリプトを使う。
モック実装と隔離用環境変数の単体テストは次で実行する。

```sh
node --test cua/examples/cua-bots-macos/scripts/launch-mock.test.ts
```

## 既知の制約

OSのサンドボックスではないため、macOSのウインドウ設定やDocker自体は実ユーザーの環境を使う。
Spaceのネットワークを強制遮断するものでもない。
起動中は1つのSpaceが動作し、終了後もDockerのイメージキャッシュと一時HOMEは残る。
強制終了やSpace作成途中の中断では後片付けが完了しない場合がある。
削除に失敗した場合は表示されたSpace名と一時データの保存先を使い、そのSpaceだけを確認する。
本スクリプトの再実行では別の一時HOMEとSpaceを作り、前回の会話は復元しない。
