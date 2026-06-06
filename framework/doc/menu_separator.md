---
unsafe: false
---

# menu_separator
メニュー内の項目を視覚的に区切る水平線。
Swing の `JSeparator`（`JPopupMenu.addSeparator()` で生成されるもの）相当。
クリック / hover / フォーカスはなく、純粋に装飾。

## 型定義
```zig
pub const MenuSeparator = struct {
    component: Component,
    allocator: std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };
};
```

state も外部 API もない。
描画スタイル（線の色 / 厚さ / padding）は theme から取る（v1 はハードコード、`## 描画` 参照）。

## MenuSeparator の生成
```zig
pub fn create(allocator: std.mem.Allocator) !*MenuSeparator;
```

allocator で MenuSeparator を確保して初期化する。
`component.min_size` を「上下 padding + 線の厚さ」に固定する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## MenuSeparator の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`MenuSeparator.vtable.destroy` として登録される。
追加で解放するリソースはないので、本体を free するだけ。

## レイアウト属性
* `min_size`: width=0, height=9（上記合計）
* `max_size`: width=inf, height=9（横は伸びる、縦は固定）
* `grow_x` / `grow_y`: 共に 0（popup 内 BoxLayout vertical で full width に揃う、cross-axis stretch）

## 利用例
File メニューで「設定系」と「Quit」を分ける典型。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const file = try Menu.create(allocator, "File", font, black);
try file.add(&(try MenuItem.create(allocator, "New", font, black)).component);
try file.add(&(try MenuItem.create(allocator, "Open", font, black)).component);
try file.add(&(try MenuItem.create(allocator, "Save", font, black)).component);
try file.addSeparator();   // ← Menu.addSeparator は MenuSeparator.create + add の shorthand
try file.add(&(try MenuItem.create(allocator, "Quit", font, black)).component);
```

直接生成して add する場合（共有 separator を作る理由は通常無いが、API としては可能）。

```zig
const sep = try MenuSeparator.create(allocator);
try popup_menu.add(&sep.component);
```

## 機能要望
* theme 化（色 / 厚さ / padding を Application 全体で切替）
* テキスト付き separator（"Recent files" のような見出し付き区切り、Swing にはない）
* 縦置き separator（MenuBar 内に置く Vertical 版、優先度低）
