---
unsafe: true
---

# panel
背景色・境界線・余白（padding）を持つコンテナー。
Container 自身が透明（描画なし）であるのに対し、Panel は背景塗り・縁取りを行い、内側に余白を確保できる装飾型。
Swing の `JPanel` 相当。

## 型定義
```zig
pub const Border = struct {
    thickness: f32,
    color:     awt.Graphics.Color,
};

pub const Panel = struct {
    container:  Container,                     // 外側: 背景 + 境界線を描く。layout は PaddingLayout、子は content 1 個のみ
    content:    *Container,                    // 利用者がレイアウト・子を載せる内側コンテナー
    padding:    Insets              = .{},     // content の周囲に確保する余白（境界線の厚さに加算される）
    background: ?awt.Graphics.Color = null,    // null なら透明
    border:     ?Border             = null,    // null なら境界線なし

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,                  // 背景 → content → 境界線 の順で描画
        .processEvent = processEvent,           // Container と同じく子へ dispatch
        .destroy      = destroy,
    };

    // ... メソッド
};
```

`Border` は厚さと色だけを持つ単純な構造体。
角丸 / 破線 / 影などの装飾は将来追加する（機能要望参照）。

`Insets` は `PaddingLayout` モジュールの型（`padding_layout.md` 参照）。

Panel は内側に余白を実現するために `PaddingLayout` を合成する。
外側 `container` の layout は `PaddingLayout` 固定で、その唯一の子が `content` である。
`PaddingLayout` に渡す各辺の inset は `border.thickness + padding.<edge>`（境界線の厚さと利用者指定の余白の和）。
これにより inset のロジックを Panel 内で二重に持たず、`PaddingLayout` 1 箇所に集約する。
利用者が子・レイアウトを操作する先は常に `content`（`asContainer()` が返す）であり、外側 `container` の layout は触らない。

## パネルの生成
```zig
pub fn create(allocator: std.mem.Allocator) !*Panel;
```

`allocator` で `Panel` を確保し、外側 `Container` を初期化、内側 `content` を `Container.create` で確保する。
外側の layout に `PaddingLayout`（初期 inset は全辺 0）を差し、`content` を外側の唯一の子として追加し、両者の vtable / install まで実行する。
背景色・境界線は `null`、`padding` は全辺 0 で開始する。
`content` のデフォルト layout は `BorderLayout`（従来の Panel と同じく追加設定なしでシェルが組める）。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリ（Panel 本体・`content`・`PaddingLayout`）はすべて関数内で解放される。

## パネルの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Panel.vtable.destroy` として登録される。
外側 Container を deinit すると、その子 `content`（さらに再帰的にその children）と、外側に差した `PaddingLayout`（`deinit` フック経由）が解放される。
そのあと Panel 本体を `allocator` で free する。
`content` や `PaddingLayout` を Panel が個別に解放する必要はない（外側 Container の破棄に含まれる）。

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
境界線の厚さが変わると content の inset も変わるため、合成 `PaddingLayout` の inset を
`border.thickness + padding.<edge>` で再計算して差し替え、`markLayoutDirty` を立てる（再レイアウト + 再描画）。
従来とは異なり、境界線は content のレイアウト領域を内側へ削る（content は境界線の内側に収まる）。

## 余白の取得
```zig
pub fn getPadding(self: Panel) Insets;
```

現在の `padding` を返す。

## 余白の設定
```zig
pub fn setPadding(self: *Panel, padding: Insets) void;
```

`padding` を差し替える。
合成 `PaddingLayout` の inset を `border.thickness + padding.<edge>` で再計算して差し替え、`markLayoutDirty` を立てる。

## Component へのアップキャスト
```zig
pub fn asComponent(self: *Panel) *Component;
```

外側 `container` の `Component`（`&self.container.component`）を返す。
Panel を親へ追加する・`setBounds` する・grow を設定するなど、Panel を 1 つのコンポーネントとして扱う場面で使う。
これが背景・境界線を描く描画ハンドルである。

## Container へのアップキャスト
```zig
pub fn asContainer(self: *Panel) *Container;
```

内側の `content`（`self.content`）を返す。
子の追加（`add`）やレイアウトの差し替え（`setLayout`）はこの content に対して行う。
外側 `container` の layout は `PaddingLayout` 固定なので、利用者がそこへ `setLayout` してはならない（inset が壊れる）。

## 利用例
背景色だけ持つカード状の Panel。
追加・`setBounds` はハンドル（`asComponent()`）に、子の追加は content（`asContainer()`）に行う。

```zig
const panel = try app.panel();
defer panel.asComponent().vtable.destroy(panel.asComponent(), app.allocator);

panel.setBackground(awt.Graphics.Color.rgb(0.95, 0.95, 0.95));
panel.asComponent().setBounds(.{ .x = 20, .y = 20, .width = 300, .height = 200 });

try panel.asContainer().add(&label.component);
try frame.window.add(panel.asComponent());
```

背景 + 境界線 + 内側余白で「カード」を表現する。
境界線と余白のぶんだけ content が内側に寄り、子が縁に張り付かない。

```zig
panel.setBackground(awt.Graphics.Color.rgb(1, 1, 1));
panel.setBorder(.{
    .thickness = 1,
    .color     = awt.Graphics.Color.rgb(0.8, 0.8, 0.8),
});
panel.setPadding(Insets.all(12));   // content は境界線 1px + 余白 12px の内側に配置される
```

content に LayoutManager を組み合わせる。

```zig
panel.asContainer().setLayout(box_layout_vertical);
try panel.asContainer().add(&header_label.component);
try panel.asContainer().add(&body_label.component);
try panel.asContainer().add(&footer_button.component);
```

## 機能要望
* 角丸境界線（`Border` に corner_radius を追加）
* 破線境界線
* グラデーション背景
* 影 / blur 装飾
* `setOpaque(bool)` 相当（透明制御の明示的フラグ）
