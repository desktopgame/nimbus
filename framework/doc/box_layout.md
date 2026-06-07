---
unsafe: false
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

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
    };

    // ... メソッド
};
```

利用者は `BoxLayout` 自体を直接インスタンス化せず、シングルトンを返すヘルパで使う（後述）。

## 水平ボックスレイアウトの取得
```zig
pub fn horizontal() *LayoutManager;
```

水平方向に子を並べるシングルトン `BoxLayout` への `*LayoutManager` を返す。
`Container.setLayout` に渡せる。

## 垂直ボックスレイアウトの取得
```zig
pub fn vertical() *LayoutManager;
```

垂直方向に子を並べるシングルトン `BoxLayout` への `*LayoutManager` を返す。

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

## 機能要望
* 主軸方向の justify-content 相当（space-between / space-around / center 等を Filler なしで指定）
* 子の間に固定ギャップを入れるオプション（`spacing: f32`）
* min が container を超えた場合の挙動（現状は overflow、将来 clip / scroll の選択肢）
* CSS flexbox 流の再分配ループ（max にぶつかった余りを残りの growable な子に再配分）
