# VMとWireGuard接続の設計

## 現在の機能

Botアプリはlocal/cloudのplacementとSpace IDを持つ。
localはホストMacを直接操作する指定ではなく、SDKがMac上で作るSpaceを意味する。
VM登録、VMの選択UI、VPNのhealth表示はまだ追加していない。
WireGuard鍵の作成、OSのネットワーク設定変更、実サーバーへの接続も行っていない。

SDKにはURLとtokenによる `Spaces.add`、sandboxのdirect接続、`Cua.spacesd` がある。
事前構築済みWireGuardネットワークの内部アドレスからこれらを使う方式なら、有料リレーを必須にしない構成を作れる。
その接続が実VMで動作することは今回検証していない。

## 次に追加するデータ

**ExecutionTarget** は既存の実行ホストを表す。
ID、表示名、OS、VPN内部アドレス、接続方式、資格情報への参照、health確認時刻、取得できたリソース情報を持つ。
Bot一覧はBotの `execution_target_id` から求め、重複して保存しない。

**SpaceBinding** は実行先上のSpaceを表す。
Space ID、実行先ID、専有または共有の区分、アプリが作成したかどうか、削除権限を持つ。
BotとAgent Runを別に参照し、既存VMへの割り当てを新規VMの作成と混同しない。

同じVMに複数Spaceを置く構成を先に実装する。
同じSpaceで複数Botを動かす場合は、resetの所有権、pauseの影響、作業ディレクトリの分離、画面操作の排他leaseを先に実装する。

## 通信と認可

WireGuardは通信経路の暗号化と到達性だけを担当する。
管理APIは別途Bot IDと資格情報を照合し、メッセージ送信先、委任先、成果物読取の権限を確認する。
VPN内部アドレスが送信元というだけでBotの操作を許可しない。

管理APIのlisten範囲とfirewallはVPN内部へ限定する。
平文HTTPを許す範囲、内部CAのTLSを使うか、資格情報をKeychainへ置くかは実環境の登録前に確定する。
秘密値は通常のBot JSON、Git、ログに入れず、設定は資格情報への参照のみを保存する。
SDKのSpace tokenはSpace単位の権限になり得るため、共有SpaceのBotへそのまま配布しない。

## 再接続と検証

health結果は確認時刻とともに保存し、期限切れをonline扱いしない。
ポーリングはキャンセル可能にし、接続タイムアウトと上限付きバックオフを使う。
VPN再接続後はSpaceとRunの存在を再確認してから復帰する。

ローカルのfake serverで認証失敗、期限切れ、接続切断、復帰、他Botへの拒否をテストする。
実VPNでの確認は接続先と許可範囲についてユーザーの承認を得てから行う。
