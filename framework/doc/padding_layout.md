---
unsafe: true
---

# padding_layout
単一の子の周囲に余白（inset）を確保するデコレータ型 `LayoutManager` と、余白量を表す `Insets`。
任意の `Container` に差すと、その子を `Insets` ぶん内側に寄せて配置する。
Flutter の `Padding` 相当。nimbus には余白を表すフィールドが Component に無いため、余白はこのレイアウトで表現する。

## 型定義
```zig
pub const Insets = struct {
    left:   f32 = 0,
    top:    f32 = 0,
    right:  f32 = 0,
    bottom: f32 = 0,

    pub const zero: Insets = .{};

    pub fn all(v: f32) Insets;                          // 4 辺すべて v
    pub fn symmetric(horizontal: f32, vertical: f32) Insets; // left=right=h, top=bottom=v
    pub fn horizontalTotal(self: Insets) f32;           // left + right
    pub fn verticalTotal(self: Insets) f32;             // top + bottom
};

pub const PaddingLayout = struct {
    base:   LayoutManager,
    insets: Insets,

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
        .deinit         = deinit,           // インスタンス確保するため non-null
    };

    // ... メソッド
};
```

`Insets` は 4 辺を名前付き `f32` で持つ。デフォルト 0 なので必要な辺だけ書けばよい。
辺を名前で持つため Swing の `(top, left, bottom, right)` のような順序の取り違えが起きない。

`PaddingLayout` は `insets` を保持するためシングルトンにできない。
インスタンスごとに `allocator` で確保し、解放は差した `Container` が肩代わりする（後述「LayoutManager の所有」/ `layout.md` 参照）。

## レイアウトの生成
```zig
pub fn create(allocator: std.mem.Allocator, insets: Insets) !*LayoutManager;
```

`allocator` で `PaddingLayout` を確保し、`insets` をセットして内部の `base`（`LayoutManager`）へのポインタを返す。
戻り値は `Container.setLayout` にそのまま渡せる。

確保に使う `allocator` は、差し先の `Container` の `allocator` と同一でなければならない。
解放時に `Container` が自身の `allocator` で `deinit` を呼ぶため（「LayoutManager の所有」参照）。

### 失敗時の保証
確保に失敗した場合は `error.OutOfMemory` を返し、関数内で確保したメモリは無い（NULL 相当、後片付け不要）。

## レイアウトの解放
```zig
fn deinit(self: *LayoutManager, allocator: std.mem.Allocator) void;
```

`PaddingLayout.vtable.deinit` として登録される。
`self` を内包する `PaddingLayout` を `allocator` で free する。
利用者が直接呼ぶことは無い。差し先の `Container` の破棄時（または `setLayout` での差し替え時）に `Container` が呼ぶ。

## 余白の取得
```zig
pub fn getInsets(self: *const LayoutManager) Insets;
```

`self` を内包する `PaddingLayout` の現在の `insets` を返す。

## 余白の設定
```zig
pub fn setInsets(self: *LayoutManager, insets: Insets) void;
```

`insets` を差し替える。
このメソッド自身は再レイアウトを起こさない（`LayoutManager` は自身が差された `Container` を知らないため）。
呼び出し側が差し先の `Container` の `component.markLayoutDirty()` を撃つ必要がある。

## 子の bounds を決定する
```zig
doLayout: *const fn (*LayoutManager, *Container) void;
```

`container` の最初の子を `(insets.left, insets.top)` に置き、サイズ `(W - left - right, H - top - bottom)` を割り当てる（`W` / `H` は `container` のサイズ）。
減算結果が負になる場合は 0 にクランプする。
子が 0 個なら何もしない。

### 事前条件
* 子は 0 個または 1 個であること。2 個以上ある場合、最初の子のみが配置され、残りの子の bounds は未定義（UB）。
  これはデコレータとして単一の子をラップする用途を想定しているため。

## コンテナーの最小サイズを計算する
```zig
computeMinSize: *const fn (*LayoutManager, *const Container) Size;
```

最初の子の `effectiveMinSize()` に `(insets.horizontalTotal(), insets.verticalTotal())` を加えた値を返す。
子が 0 個なら `(insets.horizontalTotal(), insets.verticalTotal())`。

## コンテナーの最大サイズを計算する
```zig
computeMaxSize: *const fn (*LayoutManager, *const Container) Size;
```

最初の子の `effectiveMaxSize()` に `insets` を加えた値を返す。
子の max が無限なら結果も無限（無限 + 有限 = 無限）。
子が 0 個なら `(insets.horizontalTotal(), insets.verticalTotal())`。

---

## 利用例
任意の `Container` に余白を付ける。
`app_filer` の 6px 左マージン（従来は幅 6 の空 `Container` を `BorderLayout` の west に置いていた）を、空スペーサなしで表現する。

```zig
// 余白付きのセル: 外側 Container が PaddingLayout、その単一の子が中身
const cell = try app.container();
cell.setLayout(try PaddingLayout.create(app.allocator, .{ .left = 6 }));

const inner = try app.container();          // ラベル + フィールドなどの中身
inner.setLayout(nimbus.BorderLayout.get());
try cell.add(&inner.component);             // 子は 1 個だけ

// cell を破棄すれば PaddingLayout も inner も自動で解放される
```

上下左右に均等な余白。

```zig
const padded = try app.container();
padded.setLayout(try PaddingLayout.create(app.allocator, Insets.all(8)));
try padded.add(&content.component);
```

水平・垂直で別の余白。

```zig
const box = try app.container();
box.setLayout(try PaddingLayout.create(app.allocator, Insets.symmetric(16, 8)));
try box.add(&content.component);
```

## 機能要望
* 走査時に PaddingLayout が挿入する中間 `Container` を `role` で読み飛ばす（a11y / snapshotTree のノード数削減）。
* 複数の子をまとめて同じ inset 矩形へ重ねる「スタック」モード（現状は単一の子のみ）。
