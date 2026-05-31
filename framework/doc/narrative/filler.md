---
unsafe: false
---

# filler
Filler 専用型を作らない理由とボックスレイアウト内での挙動・既知のパターン。

## なぜ専用型を作らないか
Filler に必要な性質は次の 3 つだけ。

* 描画しない（透明）
* 最小サイズ 0（誰にも邪魔されない）
* 余白があれば食う（`grow` が non-zero）

これらは既に `Panel` が満たせる：

| 性質 | Panel での実現 |
|---|---|
| 描画しない | `background = null`, `border = null`（デフォルト） |
| 最小サイズ 0 | `component.min_size = (0, 0)`（Container のデフォルト） |
| 余白を食う | `component.grow_x = 1; component.grow_y = 1`（setter で設定） |

専用 `Filler` 型を作っても Panel と同じデータ構造になる。
別型にする理由は意味的な区別だけで、それはファクトリの名前（`app.filler()`）で表現すれば足りる。

子を持たない Panel として残るぶんの「children リスト + Container の vtable」のオーバーヘッドはあるが、実用上問題ない。

## ボックスレイアウト内での挙動
水平ボックスに Filler を 1 個入れた場合：

* Filler の `grow_x = 1` が「主軸の余白を食う」と解釈される
* 他の子はすべて `grow = 0`（デフォルト）なので、`min` サイズで配置される
* 残った余白はすべて Filler が吸収する

これにより「左寄せの右に余白」「右寄せの左に余白」「中央寄せの両側」などのパターンが Filler を置く位置で表現できる。

垂直ボックスでも同様（`grow_y` 側が効く）。
`app.filler()` は両軸 grow=1 で返すので、ボックスの方向に応じて自動的に主軸方向が選ばれる。

## 既知のパターン
| 配置したいもの | Filler の使い方 |
|---|---|
| 右寄せ | `[Filler, content...]` |
| 左寄せ | `[content..., Filler]`（既定の左寄せ + 末尾に明示の Filler。grow なしのデフォルト挙動と同じ結果） |
| 中央寄せ | `[Filler, content..., Filler]` |
| 両端寄せ（justify-between） | `[a, Filler, b]` |
| 等間隔（justify-around） | `[Filler, a, Filler, b, Filler]` |

これは Swing `Box.createGlue()` のパターンそのもの。

## Filler 自身の bounds
Filler の sizing は他の Panel と同じく LayoutManager 任せ。
BoxLayout が `grow_x = 1` を見て主軸方向に伸ばし、交差軸はコンテナーいっぱい（または max まで）に広がる。

クリック等のイベントは透明な Panel として子へ dispatch されるが、Filler に子はいないので何も起きない。
マウスホバー検出に使いたい場合は通常の Panel を使う方が筋がいい。

## 固定サイズの「余白」が欲しい場合
Swing の `Box.createRigidArea(Dimension)` 相当の「決まった大きさの空白」が欲しい場合は、Filler ではなく次のいずれかで対処する。

* `Panel` を `min_size = max_size = (w, h)` で作る（伸縮しない）
* `grow = 0` の Filler（事実上 Panel と同じ）
* 専用の `Spacer(w, h)` ファクトリ — 機能要望参照
