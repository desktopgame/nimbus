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

---

## なぜ Container と分けるのか
Container は「子を持つ」という最小機能のみで、自身は透明である方が再利用しやすい。
背景色や境界線が必要な場面では Panel を使う。
役割を分けることで：

* Container を Window や Frame のルートとして使う時に「透明である」前提を壊さない
* Panel は「背景塗り + 境界線 + 子を持つ」をひとまとめにした便利型

利用者が「子をグルーピングしたいだけ、背景は不要」なら Container を直接使う。
「視覚的なグルーピング（カードや枠）を作りたい」なら Panel を使う。

## 描画順序
`vtable.paint` は以下の順で描画する。

1. 背景色（non-null の場合）— Panel の bounds 全体を塗る
2. 子コンポーネント（Container の paint と同じ、`getBounds()` でクリップして再帰）
3. 境界線（non-null の場合）— Panel の bounds の縁を描く

境界線を最後に描くのは「子のはみ出しを境界線で隠す」ためではなく、「子の描画と独立してフレームとして見える」ようにするため。
将来 angle rect の角丸境界線などを入れた時にも順序を変えなくて済む。

## 境界線と子のレイアウト
境界線の厚さは Panel のクライアント領域（content area = 子が配置できる領域）には**影響しない**。
LayoutManager は Panel 全体の bounds を基準に子を配置する。
境界線は子の上に重なって描画される可能性がある。

これは設計判断の一つで、Swing の `JPanel + EmptyBorder` のように「境界線が content insets を取る」モデルとは異なる。
nimbus が後者を採るなら `Border` に inset 計算ロジックを足し、LayoutManager 側で content area を縮めて扱う必要があり、設計が一気に重くなる。
v1 は単純さを優先して「境界線は装飾、レイアウトには影響しない」と割り切る。
子が境界線と重ならないようにしたい場合は、利用者が手動で内側に余白を取るか、`Border.thickness` 相当の inner padding を含む LayoutManager を使う。

## 子の追加 / 削除
内部の `Container` のメソッドを直接使う（委譲メソッドは生やさない）。

```zig
try panel.container.add(&child.component);
panel.container.setLayout(box_layout);
```

`component.md`「派生型から Component メソッドへのアクセス」と同じ方針。

## install / uninstall
Panel 固有の install / uninstall は基本 no-op。
内部の Container はすでに `create` 時に install 済み。

---

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
