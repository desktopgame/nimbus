---
unsafe: false
---

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

## プログラム的な起動
```zig
pub fn doClick(self: *RadioButton) void;
```

選択 (冪等。グループが前の選択を落とす) + `fireAction`。Space (フォーカス時) が
共有する単一の入口。`enabled == false` のときは no-op。

## フォーカスとキー操作
RadioButton は focusable (Tab トラバーサルの対象)。disabled の間は `FocusQuery` により
Tab がスキップする。フォーカス中は Space で `doClick`、フォーカスリング (枠線) を描画する。

## 機能要望
* 矢印キーでのグループ内ナビゲーション (上下キーで前 / 次の radio へ移動 + 自動 selection)
* mnemonic 対応
* フォーカスリング描画
