---
unsafe: false
---

# menu_item
クリック可能なメニュー項目（リーフ）。
Swing の `JMenuItem` 相当。
左に icon slot、中央にラベル、右にアクセラレータ表示（将来）の 3 カラム構成。
クリック完了で ActionListener が発火する。

## 型定義
```zig
pub const MenuItem = struct {
    component:  Component,
    text:       []const u8,
    icon:       ?awt.Image,           // null なら icon slot は空白（揃いは保つ）
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    model:      *ButtonModel,         // enabled / armed / rollover / action は ButtonModel 流用
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

## MenuItem の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*MenuItem;
```

allocator で MenuItem を確保し、内部 `ButtonModel` を生成して所有する（`owns_model = true`）。
`text` を dup して保持し、`font` / `color` を保持し、`component.min_size` を icon slot 幅 + テキスト寸法 + accel slot 幅 + padding から算出する。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## MenuItem の生成（外部 Model）
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*MenuItem;
```

利用者が事前に作った `ButtonModel` を借用する（`owns_model = false`）。
同じ Model を複数の MenuItem で共有することで「同期した enabled 状態を持つ複数項目」を作れる（`button.md` の共有 Model 例と同じ）。

## MenuItem の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`MenuItem.vtable.destroy` として登録される。
`uninstall` で model のリスナーを外し、text バッファを解放、`owns_model` が true なら model を deinit + 解放、最後に MenuItem 本体を free する。
`icon` の Image は所有していないので解放しない。

## テキストの取得 / 設定
```zig
pub fn getText(self: MenuItem) []const u8;
pub fn setText(self: *MenuItem, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` を再計算する。

## アイコンの取得 / 設定
```zig
pub fn getIcon(self: MenuItem) ?awt.Image;
pub fn setIcon(self: *MenuItem, icon: ?awt.Image) void;
```

`null` でアイコン無し。
Image の所有権は MenuItem に**移らない**（borrow）。利用者が外で寿命管理する。
アイコン領域の幅は親 Menu / PopupMenu 内で共通幅に揃うので、`null` でもテキスト位置は他項目と揃う。

## Model の取得
```zig
pub fn getModel(self: MenuItem) *ButtonModel;
```

利用者が `addActionListener` を直接呼ぶ場面で使う。

## プログラム的な起動
```zig
pub fn doClick(self: *MenuItem) void;
```

項目を起動する (`fireAction`。親 Menu の auto-dismiss リスナーが開いていれば閉じる)。
アクセラレータとメニューローカルニーモニックが共有する単一の入口。
`model.enabled == false` のときは no-op。

## アクセラレータの設定
```zig
pub fn setAccelerator(self: *MenuItem, stroke: ?keybinding.KeyStroke) void;
```

ウィンドウ全体で効くキー和音 (`KeyStroke.cmd(.s)` 等) を割り当てる。`null` で解除。
**保存のみ**で登録は行わない — 配送の最終段がメニューツリーを走査して照合するため、
メニューバーへの attach 順と無関係にいつ呼んでもよい。メニューが閉じていても発火する。
v1 ではアクセラレータ文字列の描画は行わない。

## ニーモニックの設定
```zig
pub fn setMnemonic(self: *MenuItem, ch: u8) void;
```

**メニューローカル**のニーモニック: 親メニューが開いている間だけ、修飾なしの
文字キー `ch` でこの項目を起動できる (Alt は不要。ウィンドウ全体の Alt+文字 走査の
対象にはならない)。ラベル中の該当文字に下線を引く。

## レイアウト属性
* `min_size`: icon_slot_width + テキスト寸法 + accel_slot_width + padding
* `max_size`: width=inf, height=min_size.height（縦には伸ばさない）
* `grow_x` / `grow_y`: 0（popup 内 BoxLayout vertical で full width に揃う、cross-axis stretch）

## 利用例
基本のクリック項目。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const open = try MenuItem.create(allocator, "Open", font, black);
open.setIcon(open_icon);
try open.getModel().addActionListener(AppContext, onOpen, &app_ctx);
try file_menu.add(&open.component);
```

disabled の制御。

```zig
const debug = try MenuItem.create(allocator, "Toggle Debug", font, black);
debug.getModel().setEnabled(false);
try menu.add(&debug.component);
// 後から有効化
debug.getModel().setEnabled(true);
```

共有 Model で 2 つの MenuItem の enabled 状態を同期。

```zig
const model = try allocator.create(ButtonModel);
model.* = ButtonModel.init(allocator);
defer { model.deinit(); allocator.destroy(model); }

const save_in_file = try MenuItem.createWithModel(allocator, model, "Save", font, black);
const save_in_ctx  = try MenuItem.createWithModel(allocator, model, "Save", font, black);
try file_menu.add(&save_in_file.component);
try context_menu.add(&save_in_ctx.component);
// model.setEnabled(false) で両方 disabled になる
```

## 機能要望
* アクセラレータの表示（`Ctrl+S` 等を右側 slot に描画）
* ニーモニック（テキスト内に下線、`Alt+x` で発火）
* tooltip
* テキスト + アイコン以外のカスタム描画（vtable.paint オーバライド経由で既に可能だが、専用 API が欲しい）
* HTML レンダリング（Swing が対応している、優先度低）
