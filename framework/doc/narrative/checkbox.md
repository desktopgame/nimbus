---
unsafe: true
---

# checkbox
CheckBox のレイアウト・描画順序・イベント処理。

## レイアウト
* 横方向: `BOX_SIZE (16) + BOX_GAP (6) + text_width + PADDING_X * 2`
* 縦方向: `max(BOX_SIZE, text_height) + PADDING_Y * 2`
* `max_size.height` は min と同じ (1 行ウィジェット)。 横は `inf` で grow_x = 0 (固定幅、 利用者が `setGrowX(1)` で拡張可)

## 描画
順序:
1. チェック四角の背景 (`enabled == false` → 灰、 `selected` → 青、 そうでなければ白)
2. 四角の枠 (`rollover` 中は青、 通常は灰)
3. selected のとき、 四角内に白色チェックマーク (短い斜線 + 長い斜線、 短い長方形を並べて近似)
4. ラベル (`enabled == false` で薄い灰、 そうでなければ `color`)

フォーカスリングは v1 では描かない (機能要望)。

## イベント処理
| 入力 | 動作 |
|---|---|
| マウス left press (内側) | `pressed` / `armed` セット、 `requestCapture` でドラッグを掴む、 `requestFocus` でフォーカス取得 |
| マウス left release (armed のまま内側) | toggle → ActionListener 発火 |
| マウス move | drag 中なら `armed` を内外で更新、 `rollover` も追従 |
| Space キー press (focus がこの widget のとき) | toggle → ActionListener 発火 |

`enabled == false` のときは入力を全て無視する。
