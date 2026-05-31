---
unsafe: false
---

# radio_button
RadioButton のレイアウト・描画・イベント処理・ButtonGroup との連携。

## レイアウト
* 横方向: `CIRCLE_SIZE (16) + CIRCLE_GAP (6) + text_width + PADDING_X * 2`
* 縦方向: `max(CIRCLE_SIZE, text_height) + PADDING_Y * 2`
* `grow_x = 0` (固定幅、 利用者が `setGrowX(1)` で拡張可)

## 描画
1. 円の塗り (`enabled == false` → 灰、 通常 → 白)
2. 円の枠 (`rollover` 中は青、 通常は灰)
3. selected のとき、 円内に小さな塗りつぶし円 (青、 disabled なら灰)
4. ラベル (`enabled == false` で薄い灰、 そうでなければ `color`)

## イベント処理
| 入力 | 動作 |
|---|---|
| マウス left press (内側) | `pressed` / `armed` セット、 capture、 `requestFocus` |
| マウス left release (armed のまま内側) | **常に `selected = true`**、 ActionListener 発火 (CheckBox との違い) |
| Space キー press (focus 時) | 同上 |

`selected` を反転 (`!selected`) するのではなく、 必ず true にするのが radio の流儀。
ButtonGroup と組み合わせると、 他の radio が自動で false になる。

`enabled == false` のときは入力を全て無視する。

## ButtonGroup と組み合わせる
詳細は `button_group.md`:
```zig
const group = try app.buttonGroup();
defer { group.deinit(); allocator.destroy(group); }

try group.add(rb1.getModel());
try group.add(rb2.getModel());
try group.add(rb3.getModel());
```

これで「rb1 を選んだら rb2, rb3 が自動で off」 が成立する。

**寿命の注意**: ButtonGroup は各 model の ChangeListener にハンドルを持つので、 「group.deinit() を model (= radio) の destroy より前」 に呼ぶ必要がある。
example の `defer` 順序がそうなっていることを確認 (LIFO により、 group の defer を後に書くと先に実行される)。
