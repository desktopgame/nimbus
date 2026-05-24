# checkbox
二状態 (ON / OFF) のチェックボックスウィジェット。
左側にチェック四角、 右側にラベルテキストを並べる。
クリック / Space キーで selected を反転し、 ActionListener を発火する。

## 型定義
```zig
pub const CheckBox = struct {
    component:  Component,
    model:      *ToggleButtonModel,
    owns_model: bool,
    text:       []const u8,
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    allocator:  std.mem.Allocator,
};
```

`ToggleButtonModel` を介して selected / pressed / rollover / enabled を管理する (詳細は `toggle_button_model.md`)。
`owns_model` が true なら `destroy` 時に model を deinit / free する。

## 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBox;

pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBox;
```

`create` は内部で `ToggleButtonModel` を新規生成して所有する。
`createWithModel` は呼び出し側の所有する model を共有する形 (例: 同じ状態を別 widget からも反映したいときに使う)。

ファクトリ:
```zig
const cb = try app.checkBox("Enable notifications");
```

`Application.checkBox(text)` は default font (14px) と黒色を注入する。

## テキストの取得 / 設定
```zig
pub fn getText(self: CheckBox) []const u8;
pub fn setText(self: *CheckBox, text: []const u8) !void;
```

`setText` はバッファを dup し直し、 `applyMetrics` 後に repaint する。

## 選択状態の取得 / 設定
```zig
pub fn isSelected(self: CheckBox) bool;
pub fn setSelected(self: *CheckBox, v: bool) void;
```

内部 model への薄いラッパー。
listener (`addChangeListener` / `addActionListener`) を仕込みたい場合は `getModel()` 経由で。

## Model の取得
```zig
pub fn getModel(self: CheckBox) *ToggleButtonModel;
```

`addChangeListener` / `addActionListener` / `setEnabled` 等を直接呼ぶときの入口。

---

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

## 機能要望
* フォーカスリング描画 (現状は rollover のみで keyboard focus が見えない)
* keyboard 操作の充実 (例: `Enter` でも toggle、 矢印キーでの「次の checkbox へ移動」)
* mnemonic (アクセラレータ文字) 対応 — `_` プレフィックスで下線つきの文字を作って Alt+<char> で toggle
* アイコン付きチェックボックス
