---
unsafe: true
---

# grid_layout
子を行優先で `n_cols` 列のグリッドに並べる `LayoutManager`。
列幅はその列に入る子の自然幅の最大値で決まる **非一様列** グリッドで、Swing の等セル `GridLayout` とは別物。

## 型定義
```zig
pub const Options = struct {
    col_spacing: f32 = 0,   // 列間ギャップ (px)
    row_spacing: f32 = 0,   // 行間ギャップ (px)
};

pub const GridLayout = struct {
    base:        LayoutManager,   // 公開 LayoutManager は base (先頭フィールド必須)
    n_cols:      usize,           // 列数 (1 以上)
    col_spacing: f32,
    row_spacing: f32,
};
```

### レイアウト規則
子は追加順に行優先で `n_cols` 列ずつ埋める。最終行は埋まりきらなくてもよく、欠けたセルは飛ばす (ragged final row)。

- 列幅は「その列に入る子の `effectiveMinSize().width` の最大値」= 列の自然幅。行高は「その行に入る子の `effectiveMinSize().height` の最大値」。
- コンテナー幅が全列の自然幅合計 + `col_spacing` を上回った余剰は、**各列の grow** に比例して配る。列の grow はその列に入る子の `grow_x` の最大値。
- どの列も grow が 0 なら余剰は配らず、右側に余白として残る。1 つでも grow する列があれば余剰を吸う。
- セル内では子の `align_x` / `align_y` が配置を決める。`stretch` は列幅 / 行高いっぱいに広げる (子の `max_size` でクランプ)。
- `start` / `center` / `end` は子の最小サイズのまま、その列 / 行の枠内で端 / 中央 / 端へ寄せる。
- `GridLayout` 自身の最小サイズは、幅 = 全列の自然幅合計 + `col_spacing * (列数 - 1)`、高さ = 全行の行高合計 + `row_spacing * (行数 - 1)`。
- 最大サイズは、幅 = grow する列が 1 つでもあれば無限、無ければ最小幅と同じ。高さは最小高さと同じ。

## 関数定義

### 生成
```zig
pub fn create(allocator: std.mem.Allocator, n_cols: usize, opts: Options) !*LayoutManager;
```

`GridLayout` を `allocator` で確保し、内包する `base` (`*LayoutManager`) を返す。戻り値をそのまま `Container.setLayout` に渡せる。
確保したインスタンスは差し先の `Container` が所有し、`Container` の破棄・レイアウト差し替え時に解放される (`layout.md`「LayoutManager の所有」参照)。
`BoxLayout` と同じく `Application` のファクトリは設けず、この自由関数だけで生成する。

#### 事前条件
* 確保に使う `allocator` は差し先の `Container` の `allocator` と同一であること。
* 1 つの `Container` が専有し、複数の `Container` で共有しないこと (二重解放になる)。

#### 診断情報
`n_cols` が 0 のときは `error.InvalidColumnCount` を返す (確保もしない)。

---

## 利用例
ラベルと入力欄を 2 列に並べるフォーム。左の列はラベルの自然幅、右の列は入力欄が伸びる。

```zig
const form = try app.container();
form.setLayout(try nimbus.GridLayout.create(app.allocator, 2, .{ .col_spacing = 8, .row_spacing = 8 }));

const name_label = try app.label("Name:");
const name_field = try app.textField("");
name_field.component.setGrowX(1);     // 右の列 (入力欄) が余剰幅を吸う

try form.add(&name_label.component);  // row 0, col 0
try form.add(&name_field.component);  // row 0, col 1
// 以降、add した順に row 1, row 2... と 2 列ずつ埋まる
```

## 機能要望
* 列 / 行ごとの span (1 つのセルが複数列 / 行にまたがる)。
* 行方向の grow (現状の余剰配分は列方向のみ。高さは常に行高合計)。
* 等セルモード (Swing 相当の、全セル同幅・同高) の切り替え。
