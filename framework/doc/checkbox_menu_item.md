---
unsafe: true
---

# checkbox_menu_item
チェック状態を持つメニュー項目。
Swing の `JCheckBoxMenuItem` 相当。
クリックで checked 状態がトグルし、ActionListener が発火する。
icon スロットにチェックマーク（チェック時のみ）を描画する。

`MenuItem` と多くを共有するが、icon スロットの使い方とトグル挙動が違うので別型にする。

## 型定義
```zig
pub const CheckBoxMenuItem = struct {
    component:  Component,
    text:       []const u8,
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    model:      *ToggleButtonModel,   // selected = checked 状態
    owns_model: bool,
    allocator:  std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };
};
```

`ToggleButtonModel.selected: bool` を checked 状態として使う（`toggle_button_model.md`）。
通常の `MenuItem` と違って `icon` フィールドは持たない（icon スロットをチェックマークが占有するため、追加アイコンを置く余地はない）。

## CheckBoxMenuItem の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem;
```

`allocator` で CheckBoxMenuItem を確保し、内部 ButtonModel を生成して所有する（`owns_model = true`）。
初期状態は checked = false（`model.selected = false`）。
`text` を dup して保持し、`font` / `color` を保持し、`component.min_size` を icon スロット幅 + テキスト寸法 + accel スロット幅 + padding から算出する。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## CheckBoxMenuItem の生成（外部 Model）
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem;
```

利用者が事前に作った `ButtonModel` を借用する。
同じ Model を複数の CheckBoxMenuItem で共有することで「同期した checked 状態を持つ複数項目」を作れる
（例: メニューと toolbar 両方に「Show Grid」チェックを置く）。

## CheckBoxMenuItem の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`CheckBoxMenuItem.vtable.destroy` として登録される。
`uninstall` で `model` のリスナーを外し、text バッファを解放、`owns_model` が true なら `model` を deinit + 解放、最後に CheckBoxMenuItem 本体を free する。

## テキストの取得 / 設定
```zig
pub fn getText(self: CheckBoxMenuItem) []const u8;
pub fn setText(self: *CheckBoxMenuItem, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` を再計算する。

## checked 状態の取得 / 設定
```zig
pub fn isChecked(self: CheckBoxMenuItem) bool;
pub fn setChecked(self: *CheckBoxMenuItem, v: bool) void;
```

`model.selected` の getter / setter。
`setChecked` は値変化時に ChangeListener を発火する。
ActionListener は発火しない（プログラム由来の変更とユーザクリックを区別するため）。

## Model の取得
```zig
pub fn getModel(self: CheckBoxMenuItem) *ToggleButtonModel;
```

ActionListener の登録や enabled の制御に使う。

## プログラム的な起動
```zig
pub fn doClick(self: *CheckBoxMenuItem) void;
```

トグル + `fireAction` (親 Menu の auto-dismiss リスナーが開いていれば閉じる)。
メニューローカルニーモニックの入口。`enabled == false` のときは no-op。

## レイアウト属性
`MenuItem` と同じ。

## 利用例
表示オプションのトグル。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const show_grid = try CheckBoxMenuItem.create(allocator, "Show Grid", font, black);
try show_grid.getModel().addActionListener(EditorCtx, onToggleGrid, &editor_ctx);
try view_menu.add(&show_grid.component);

// プログラム側から初期状態を反映
show_grid.setChecked(editor.show_grid);
```

メニューと toolbar の両方に同じ「Show Grid」チェック（同期状態）。

```zig
const grid_model = try allocator.create(ToggleButtonModel);
grid_model.* = ToggleButtonModel.init(allocator);
defer { grid_model.deinit(); allocator.destroy(grid_model); }

const grid_menu = try CheckBoxMenuItem.createWithModel(allocator, grid_model, "Show Grid", font, black);
const grid_btn  = try ToggleButton.createWithModel(allocator, grid_model, grid_icon); // 将来
try view_menu.add(&grid_menu.component);
try toolbar.add(&grid_btn.component);
```

## 機能要望
* チェックマークの描画スタイル切替（チェック / ラジオ円 / カスタム）
* アイコンも持てる variant（チェックマークと並べる）— 現状は不可
* indeterminate state（3 状態チェック、Swing にもない機能）
