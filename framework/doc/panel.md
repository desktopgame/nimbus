---
unsafe: false
---

# panel
背景色と境界線を持つコンテナー。
`Container` を embed した薄いラッパで、Container 自身が透明（描画なし）であるのに対し、Panel は背景塗りと縁取りを行う。
Swing の `JPanel` 相当。

## 型定義
```zig
pub const Border = struct {
    thickness: f32,
    color:     awt.Graphics.Color,
};

pub const Panel = struct {
    container:  Container,
    background: ?awt.Graphics.Color = null,    // null なら透明
    border:     ?Border             = null,    // null なら境界線なし

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,                  // 背景 + 境界線を描画してから子を再帰描画
        .processEvent = processEvent,           // Container と同じく子へ dispatch
        .destroy      = destroy,
    };

    // ... メソッド
};
```

`Border` は厚さと色だけを持つ単純な構造体。
角丸 / 破線 / 影などの装飾は将来追加する（機能要望参照）。

## パネルの生成
```zig
pub fn create(allocator: std.mem.Allocator) !*Panel;
```

allocator で `Panel` を確保し、内部の `Container` を初期化、vtable をセットして install まで実行する。
背景色と境界線は `null`（透明、線なし）で開始する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## パネルの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Panel.vtable.destroy` として登録される。
内部の Container を deinit（再帰的に children を解放）したのち、Panel 本体を allocator で free する。

## 背景色の取得
```zig
pub fn getBackground(self: Panel) ?awt.Graphics.Color;
```

`null` なら背景描画なし（透明）。

## 背景色の設定
```zig
pub fn setBackground(self: *Panel, color: ?awt.Graphics.Color) void;
```

`null` を渡すと透明（背景を描画しない）。
値が変わったら paint_dirty を立てる。

## 境界線の取得
```zig
pub fn getBorder(self: Panel) ?Border;
```

## 境界線の設定
```zig
pub fn setBorder(self: *Panel, border: ?Border) void;
```

`null` を渡すと境界線なし。
値が変わったら paint_dirty を立てる。
境界線の厚さは描画上の話で、子のレイアウト領域（content area）には影響しない（後述「境界線と子のレイアウト」参照）。

## Container へのアップキャスト
```zig
pub fn asContainer(self: *Panel) *Container;
```

`&self.container` を返すだけの helper。
LayoutManager や Container API を期待する場面で使う。

## 利用例
背景色だけ持つカード状の Panel。

```zig
const panel = try app.panel();
defer panel.component.vtable.destroy(&panel.component, app.allocator);

panel.setBackground(awt.Graphics.Color.rgb(0.95, 0.95, 0.95));
panel.component.setBounds(.{ .x = 20, .y = 20, .width = 300, .height = 200 });

try panel.container.add(&label.component);
try frame.window.add(&panel.component);
```

背景 + 境界線で「カード」を表現する。

```zig
panel.setBackground(awt.Graphics.Color.rgb(1, 1, 1));
panel.setBorder(.{
    .thickness = 1,
    .color     = awt.Graphics.Color.rgb(0.8, 0.8, 0.8),
});
```

LayoutManager と組み合わせる。

```zig
panel.container.setLayout(box_layout_vertical);
try panel.container.add(&header_label.component);
try panel.container.add(&body_label.component);
try panel.container.add(&footer_button.component);
```

## 機能要望
* 角丸境界線（`Border` に corner_radius を追加）
* 破線境界線
* グラデーション背景
* 影 / blur 装飾
* `BorderInsets` モデル（境界線が子のレイアウト領域を削る Swing 流のモード）
* `setOpaque(bool)` 相当（透明制御の明示的フラグ）
