---
unsafe: true
---

# secondary_loop
SecondaryLoop の設計判断とネスト・モーダルダイアログとの関連。

## なぜ tick コールバックを取るか
SecondaryLoop は awt 層のプリミティブとして「イベントを流す機構」だけを提供する。
再描画 / OS 同期 / dirty フラグ管理は framework 層の責務であり、それを awt 層から直接呼ぶと層が逆転する。

そのため SecondaryLoop は「イベント駆動でループを回す」だけを行い、ループ反復ごとに何をするかは `tick` コールバックで利用者（framework）に委ねる。
framework は `Application.tickOnce` のような関数を渡して、メインループと同じ per-iteration 処理を SecondaryLoop でも回す。

awt 層単体でも使える（モーダルダイアログの代わりに低レベル blocking UI を作る用途等）。
その場合は `tick = null` で初期化し、イベントだけ流して `exit()` 呼び出しを待つ。

## ネスト
SecondaryLoop は入れ子で使える。
モーダルダイアログの中から別のモーダルダイアログを開く、というケースに対応する。
各 SecondaryLoop が独立した `exit_requested` を持つので、外側は内側の終了を待ってから自分の `exit` を判定する。

## EventQueue との関係
SecondaryLoop の `tick` が EventQueue の `drain` を呼ぶ責務を負う（framework 側で実装する）。
これにより、SecondaryLoop 実行中も別スレッドからの `invokeLater` が消化される。
`event_queue.md` を参照。

## メインループとの違い
| | `Application.run()` | `SecondaryLoop.exec()` |
|---|---|---|
| 終了条件 | 全ウィンドウが閉じた | `exit()` が呼ばれた |
| 階層 | 最外殻、1 回だけ | 入れ子で複数回 |
| tick | 自分で処理一式を持つ | コールバック経由 |
| 戻り値 | `!void` | `i32`（exit code） |

「最後のウィンドウが閉じたら」終了するのは `Application.run()` のみ。
SecondaryLoop は明示的な `exit()` を待つ。

## モーダルダイアログでの想定利用フロー
将来 Dialog が追加された時の典型フロー:

1. `dialog.showModal()` が呼ばれる
2. Dialog 内部で SecondaryLoop を init
3. `loop.exec()` で blocking 開始
4. ダイアログ内の OK / Cancel ボタンのイベントハンドラから `loop.exit(result_code)` を呼ぶ
5. `exec()` が return、`showModal()` が結果を返す

呼び出し側コード：

```zig
const result = dialog.showModal();
if (result == .ok) { ... }
```

これによりモーダルダイアログの同期的な API がイベント駆動アーキテクチャの上に成立する。
