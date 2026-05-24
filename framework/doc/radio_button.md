# radio_button
丸い indicator + ラベルからなる二状態ウィジェット。
内部状態 (`ToggleButtonModel`) と入力ロジックは `CheckBox` と同じ。
違いは描画 (丸 + 内側ドット) と「クリックは toggle ではなく常に on にする」 挙動。

通常は `ButtonGroup` (詳細は `button_group.md`) と組み合わせて、 複数の RadioButton から 1 つだけ selected にする。

## 型定義
```zig
pub const RadioButton = struct {
    component:  Component,
    model:      *ToggleButtonModel,
    owns_model: bool,
    text:       []const u8,
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    allocator:  std.mem.Allocator,
};
```

## 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButton;

pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButton;
```

`create` は内部で `ToggleButtonModel` を新規生成 / 所有する。
`createWithModel` は呼び出し側の所有する model を共有する。

ファクトリ:
```zig
const rb = try app.radioButton("Small");
```

`Application.radioButton(text)` は default font (14px) と黒色を注入する。

## テキストの取得 / 設定
```zig
pub fn getText(self: RadioButton) []const u8;
pub fn setText(self: *RadioButton, text: []const u8) !void;
```

## 選択状態の取得 / 設定
```zig
pub fn isSelected(self: RadioButton) bool;
pub fn setSelected(self: *RadioButton, v: bool) void;
```

## Model の取得
```zig
pub fn getModel(self: RadioButton) *ToggleButtonModel;
```

ButtonGroup に登録するときや、 ActionListener を仕込むときの入口。

---

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

## 機能要望
* 矢印キーでのグループ内ナビゲーション (上下キーで前 / 次の radio へ移動 + 自動 selection)
* mnemonic 対応
* フォーカスリング描画
