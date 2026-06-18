---
unsafe: true
---

# box_layout
水平または垂直に子を並べる `LayoutManager`。
分配アルゴリズムは `{REPO_ROOT}/doc/internal/layout-design.md`「子の分配アルゴリズム」の 1-pass clamp を採用する。
Swing の `BoxLayout` / CSS flexbox の単純化版に相当する。
hint は使わない（常に null）。

## 型定義
```zig
pub const Orientation = enum { horizontal, vertical };

pub const BoxLayout = struct {
    base:        LayoutManager,
    orientation: Orientation,
    spacing:     f32 = 0,           // 主軸方向の子間ギャップ

    // シングルトン用（spacing = 0、無確保）。Container は解放しない。
    pub const singleton_vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
        .deinit         = null,
    };

    // spaced 変種用（確保インスタンス）。Container が deinit で解放する。
    pub const spaced_vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
        .deinit         = deinit,
    };

    // ... メソッド
};
```

`spacing` は主軸方向に隣り合う子の間へ入れる固定の隙間。
子が `n` 個なら隙間は `n - 1` 箇所できる（両端には入らない）。交差軸には影響しない。

`doLayout` / `computeMinSize` / `computeMaxSize` の中身は 2 つの vtable で共通であり、所有モデルだけが異なる。
`deinit` の有無が `layout.md`「LayoutManager の所有」の discriminator（Container が解放するか否か）なので、
解放されてはならない const シングルトンと、Container が解放すべき確保インスタンスとで vtable を分ける。

利用者は `BoxLayout` 自体を直接インスタンス化せず、後述のヘルパで使う。
`spacing = 0`（隙間なし）は確保不要の const シングルトン（`singleton_vtable`）で提供し、
`spacing > 0` のときだけインスタンス（`spaced_vtable`）を確保する。

## 水平ボックスレイアウトの取得
```zig
pub fn horizontal() *LayoutManager;
```

水平方向に子を並べる（`spacing = 0`）シングルトン `BoxLayout` への `*LayoutManager` を返す。
この `base.vtable` は `singleton_vtable`（`deinit = null`）を指す。
`Container.setLayout` に渡せる。確保しないため解放不要で、複数の Container で共有してよい。

## 垂直ボックスレイアウトの取得
```zig
pub fn vertical() *LayoutManager;
```

垂直方向に子を並べる（`spacing = 0`）シングルトン `BoxLayout` への `*LayoutManager` を返す。
`horizontal` と同じく `base.vtable` は `singleton_vtable` を指す。

## ギャップ付き水平ボックスレイアウトの生成
```zig
pub fn horizontalSpaced(allocator: std.mem.Allocator, spacing: f32) !*LayoutManager;
```

主軸方向に `spacing` の隙間を入れる水平 `BoxLayout` を `allocator` で確保し、`*LayoutManager` を返す。
確保したインスタンスの `base.vtable` は `spaced_vtable`（`deinit` 非 null）を指す。
解放は差した `Container` が肩代わりする（`deinit` フック経由。`layout.md`「LayoutManager の所有」参照）。
1 つの Container が専有し、複数の Container で共有してはならない（二重解放になる）。
確保に使う `allocator` は差し先の `Container` の `allocator` と同一でなければならない。

### 失敗時の保証
確保に失敗した場合は `error.OutOfMemory` を返し、後片付けは不要。

## ギャップ付き垂直ボックスレイアウトの生成
```zig
pub fn verticalSpaced(allocator: std.mem.Allocator, spacing: f32) !*LayoutManager;
```

`horizontalSpaced` の垂直版。確保したインスタンスの `base.vtable` は同じく `spaced_vtable` を指す。

## ギャップ付きレイアウトの解放
```zig
fn deinit(self: *LayoutManager, allocator: std.mem.Allocator) void;
```

`spaced_vtable` の `deinit` として登録される。
`self` を内包する `BoxLayout` を `allocator` で free する。
`horizontalSpaced` / `verticalSpaced` が確保したインスタンスにのみ使われ、差した `Container` の破棄・差し替え時に Container が呼ぶ。
`singleton_vtable`（`deinit = null`）のシングルトンに対しては呼ばれない。
利用者が直接呼ぶことは無い。

## 利用例
水平ボックスでラベルを並べる。

```zig
const wrapper = try app.container();
wrapper.setLayout(BoxLayout.horizontal());

const a = try app.label("A");
const b = try app.label("B");
const c = try app.label("C");
try wrapper.add(&a.component);
try wrapper.add(&b.component);
try wrapper.add(&c.component);

wrapper.component.setBounds(.{ .x = 0, .y = 0, .width = 600, .height = 32 });
// a, b, c は左から順に min_width 分ずつ配置。grow=0 なので余白は右端に残る
```

垂直ボックスで grow を使って中央のコンテンツを伸ばす。

```zig
const wrapper = try app.container();
wrapper.setLayout(BoxLayout.vertical());

const header = try app.label("Header");
const body   = try app.label("Body");
body.component.setGrowY(1);                    // 余白を body が食う
const footer = try app.label("Footer");

try wrapper.add(&header.component);
try wrapper.add(&body.component);
try wrapper.add(&footer.component);
```

Filler を使った右寄せ。

```zig
const toolbar = try app.container();
toolbar.setLayout(BoxLayout.horizontal());

try toolbar.add(&app.filler().component);      // 左に伸縮スペース
try toolbar.add(&save_button.component);
try toolbar.add(&cancel_button.component);
// → save と cancel が右端に寄る
```

Filler を両端に置いた中央寄せ。

```zig
const center = try app.container();
center.setLayout(BoxLayout.horizontal());

try center.add(&app.filler().component);
try center.add(&content.component);
try center.add(&app.filler().component);
// → content が中央に来る
```

水平ボックスで子を垂直中央に揃える例（背の高い行に短いボタンを置く場合など）。

```zig
const row = try app.container();
row.setLayout(BoxLayout.horizontal());
row.component.setBounds(.{ .x = 0, .y = 0, .width = 600, .height = 80 });

const btn = try app.button("OK");
btn.component.setAlignY(.center);    // 80px 行の中で min 高さで垂直中央
try row.add(&btn.component);
```

ネスト（vertical の中に horizontal）。

```zig
const root = try app.container();
root.setLayout(BoxLayout.vertical());

const toolbar = try app.container();
toolbar.setLayout(BoxLayout.horizontal());
try toolbar.add(&btn_a.component);
try toolbar.add(&btn_b.component);

const status = try app.label("Ready");

try root.add(&toolbar.component);
try root.add(&body.component);
try root.add(&status.component);
```

ギャップ付きのツールバー。ボタンの間に 8px の隙間を空ける。

```zig
const toolbar = try app.container();
toolbar.setLayout(try BoxLayout.horizontalSpaced(app.allocator, 8));
try toolbar.add(&btn_a.component);   // [a] 8px [b] 8px [c]
try toolbar.add(&btn_b.component);
try toolbar.add(&btn_c.component);
// toolbar を破棄すれば spaced レイアウトも自動で解放される
```

## 機能要望
* 主軸方向の justify-content 相当（space-between / space-around / center 等を Filler なしで指定）
* min が container を超えた場合の挙動（現状は overflow、将来 clip / scroll の選択肢）
* CSS flexbox 流の再分配ループ（max にぶつかった余りを残りの growable な子に再配分）
