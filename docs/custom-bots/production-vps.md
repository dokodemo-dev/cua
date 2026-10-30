# 本番構成（VPS）

Cua Bots の本番は VPS に置く。Mac は開発とローカル確認にだけ使う。
この文書は、その前提での配置、必要スペック、移行手順、未決事項をまとめる。

## 役割の分け方

| 場所 | 役割 | 常駐 |
| --- | --- | --- |
| Mac | GUI（Tauri / SwiftUI）、開発、ローカル確認 | しない |
| VPS | サービス、スケジューラー、Space の実行（Docker） | する |
| WireGuard | Mac と VPS の経路。管理APIは wg0 だけで待ち受ける | — |

Mac 上で `launchctl` に登録しない。`launchd.md` の手順は、ローカル確認で常駐させたい場合の参考として残す。

## 必要スペック（実測ベース）

| 項目 | 値 | 根拠 |
| --- | --- | --- |
| Space 1つ | 2 vCPU / 4GB / 実質12GiB のディスク余裕 | `cua spaces create` の既定と、2026-10-23 の作成エラー（6.4GiB＋予備5GiB） |
| 同時 Space | 2〜3 | 用途次第 |
| サービス | 数十MB | `cua-bots-service` / `cua-bots-scheduler` |
| 目安 | **16GB / 6〜8 vCPU / 200GB 以上の NVMe** | 上記の合計 |

## VPS の候補（2026-10 調査）

詳しい比較は社内ナレッジ（`japan-vps-research` の 2026-10 データ）に置く。要点だけ:

| VPS | メモリ | CPU | ストレージ | 月額（1ヶ月） | 備考 |
| --- | --- | --- | --- | --- | --- |
| KAGOYA CLOUD VPS | 16GB | 8コア | 1TB NVMe | ¥7,810 | APIなし。ディスクが最も余る |
| WebARENA Indigo | 16GB | 6vCPU | 320GB SSD | ¥7,150 | REST APIあり。停止中も課金 |
| シンVPS | 16GB | 6コア | 100GB NVMe | ¥5,110 | 最低3ヶ月。ディスクが厳しい |
| さくらのVPS | 16GB | 8コア | 800GB SSD | ¥15,400 | 高いが請求・サポートが整う |

第一候補は **KAGOYA 16GB**。Space を3つ置いてもディスクが余り、8コアある。
自動化を優先するなら **WebARENA Indigo**（REST API）。

## 実装の分担（2026-10-23 決定）

本番は **Go 実装**（`examples/cua-bots-service-go`）、Swift 実装は**参照実装とローカル確認**として残す。

| 部品 | 本番（Linux VPS） | ローカル確認（Mac） |
| --- | --- | --- |
| 協調 API | `examples/cua-bots-service-go`（Go、単一バイナリ） | `examples/cua-bots-macos` の `cua-bots-service`（Swift） |
| 状態ファイル | 同じ JSON。`flock`＋原子的置換、0600 | 同じ |
| トークン | FNV-1a の digest。方式を揃えてあるので相互に読める | 同じ |
| スケジューラー | `cua-bots-scheduler`（Go、lease と slot 記録） | Swift 版 |
| Bot の実行 | `scripts/cua-bot-turn.sh` → `cua agent run` / `send --follow` | `cua-bots-run`（macOS の SDK をリンク） |
| Space の実行 | Docker（runc/gvisor）。**KVM 不要** | OrbStack |

Go を選んだ理由は、単一バイナリで systemd から起動でき、Swift の `Darwin` ソケット移植と
macOS 専用 dylib の制約を避けられるため。ドメインの規則は Swift 版と同じで、テストで固定している。

## 移行手順

1. サービス（Go）の用意 — **済**
   - `go build ./cmd/cua-bots-service` で単一バイナリ。
   - `--bind <wg0>` で VPN 待受、`--print-systemd-unit` で unit を出力。
   - 状態は Swift 版と同じ JSON（テストで相互変換を確認）。
2. VPS の初期設定
   - 非 root ユーザー、SSH 鍵、パスワード認証と root ログインの無効化。
   - WireGuard peer 追加、UFW は `wg0` からのみ許可。
   - Docker（または gvisor）を導入し、`ghcr.io/trycua/linux:24.04` を取得。
3. 認証と待受
   - サービスは `wg0` のアドレスで待ち受け、Mac からは VPN 経由で接続する。
   - トークンは Bot ごと、管理者は別。TLS は内部 CA か WireGuard 内の平文かを決める（**未決**）。
4. 常駐
   - systemd unit（`cua-bots-service.service` / `cua-bots-scheduler.service`）で `Restart=always`。
   - 状態ディレクトリは `/var/lib/cua-bots`、トークンは 0600。
5. 受け入れ
   - Space 作成 → Bot への委譲 → スケジューラーの実行 → Mac の GUI から接続、までを VPN 越しに確認する。
   - まずは 1 Bot で通し、通ってから 2〜3 Bot に増やす。

## 配置手順

VPS の契約から受け入れまでの手順は `vps-runbook.md` に固定した。配置スクリプトは
`examples/cua-bots-service-go/scripts/install-vps.sh`（既定は表示のみ、`--apply` で適用）。

## TLS の方針（2026-10-24 決定）

- **開始時は WireGuard 内の平文＋トークン**。経路は WG で暗号化され、UFW で `wg0` のみ許可。
- TLS は実装済み（TLS 1.2 以上）。次のいずれかで有効化する。
  1. WG の外から届く場所へ置く
  2. 同じホストに信頼できない tenant を載せる
  3. 監査・契約上、VPN 内でも TLS が必要
- loopback 以外を bind するには `--allow-remote` が必須（`0.0.0.0` の誤公開を防ぐ）。

## 未決事項

- VPS 上の Space を QEMU（KVM なし）にするか、Docker コンテナにするか（既定はコンテナ）。
- バックアップ（状態ファイル、成果物）の取得先。
- Bot 実行の実配線（`--exec-command` から `cua` CLI を呼ぶコマンド例の確定）。
- VPS の契約と初期設定（SSH / UFW / WireGuard / Docker）。
