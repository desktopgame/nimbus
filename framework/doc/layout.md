---
unsafe: false
---

# layout
レイアウトに関する型と仕組み。
Container が子の bounds を計算するための差し替え可能なオブジェクト `LayoutManager` と、子を包む `LayoutElement` を定義する。
設計方針の詳細は `{REPO_ROOT}/doc/internal/layout-design.md` を参照。

## 型定義
```zig
pub const LayoutElement = struct {
    component:    *Component,
    hint:         ?*anyopaque = null,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
};

pub const LayoutManager = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        doLayout:       *const fn (*LayoutManager, *Container) void,
        computeMinSize: *const fn (*LayoutManager, *const Container) Size,
        computeMaxSize: *const fn (*LayoutManager, *const Container) Size,
        deinit:         ?*const fn (*LayoutManager, std.mem.Allocator) void = null,
    };
};
```

`Size` は両軸 `f32` の構造体。`std.math.inf(f32)` を入れて無制限を表せる。

## 子の bounds を決定する
```zig
doLayout: *const fn (*LayoutManager, *Container) void;
```

`container` の現在のサイズと各子の MinimumSize / MaximumSize / GrowX / GrowY および hint を読み、各子の bounds を計算して `child.setBounds(...)` を呼び出す。
直接の子のみを対象とする。孫以下への再帰呼び出しは Container 側の責務であり、LayoutManager は関知しない。

幅で高さが変わる子 (折り返し `TextArea`、 将来の折り返し `Label` 等) を正しく扱うには、 子の `component.size_query` (オプショナル) を見て `minHeightForWidth(child, chosen_width)` を呼んで高さを得る。 `size_query` が null の子に対しては従来通り `getMinSize().height` を使えばよい (`component.md`「SizeQuery」参照)。 現状の組み込み `BoxLayout` / `BorderLayout` は size_query を参照していない (= 折り返し系の子は ScrollPane 経由でしか height-for-width が機能しない) が、 これは将来の拡張余地。

### 事前条件
* `container` の bounds が有効な値で確定していること（ルートのみは Window の resize イベントが、ネストされたものは親コンテナーの doLayout が事前にこれを保証する）

## コンテナーの最小サイズを計算する
```zig
computeMinSize: *const fn (*LayoutManager, *const Container) Size;
```

このレイアウトでコンテナーが取りうる最小サイズを返す。
子の MinimumSize 群とこの LayoutManager 自身のアルゴリズム（縦 box なら合計、横 box なら最大、など）から導く。

純粋関数として扱われる。
`*const Container` で受け取る理由は、計算によってコンテナーや子の状態を変更しないことを型で示すため。

### キャッシュ
戻り値は `Container` 側で memoize される (`min_cache`、 `container.md` 参照)。
同じ layout サイクル内で `computeMinSize` が複数回呼ばれてもキャッシュヒットで即座に返るため、 深さ `D` のツリーを top-down で `doLayout` 走査する際の重複計算が抑えられる (キャッシュ無しでは深い兄弟ノードが各階層で再走査され `O(N×D)`、 キャッシュ有りで実質 `O(N)`)。

キャッシュ無効化は `markLayoutDirty` がパス上の祖先 Container すべてに対して `invalidateSizeCache` を呼ぶことで自動的に行われる (= 変更されたサブツリーを含む Container のキャッシュだけが落ちる、 兄弟サブツリーには影響しない)。
LayoutManager 実装者から見るとキャッシュは透過で、 純粋関数として書いてさえいれば正しく動く。 逆に **純粋性を破る (副作用で観測可能な状態を変える、 内部状態に依存する乱数を返す、 等) と古いキャッシュ値が返ってバグになる**。

LayoutManager 自身が独自キャッシュを持つ必要は通常ない (`deinit` 不要、 const シングルトンで提供できる)。
複雑な内部キャッシュを持つ場合は `markLayoutDirty` の通知が LayoutManager まで届かない点に注意 (= 自前で dirty 管理を入れる必要がある)。

## コンテナーの最大サイズを計算する
```zig
computeMaxSize: *const fn (*LayoutManager, *const Container) Size;
```

このレイアウトでコンテナーが取りうる最大サイズを返す。
無制限の場合は両軸に `std.math.inf(f32)` を入れる。

キャッシュおよび純粋性に関する規約は `computeMinSize` と同じ (`max_cache` 側に memoize される)。

## LayoutManager 自身の解放
```zig
deinit: ?*const fn (*LayoutManager, std.mem.Allocator) void = null;
```

オプショナル。
LayoutManager がアロケート済みの内部状態（キャッシュなど）を持つ場合のみ実装する。
標準的に提供される const シングルトンの LayoutManager では不要なため、デフォルトは null である。

## 利用例
hint なしで子を追加する例（BoxLayout など）。

```zig
container.setLayout(BoxLayout.horizontal());
try container.add(&label_a.component);
try container.add(&label_b.component);
```

hint 付きで子を追加する例（BorderLayout 風）。caller 所有のスタック変数を渡す。

```zig
const north_region: BorderRegion = .north;
try container.addWithHint(&label.component, @ptrCast(&north_region), null);
```

動的アロケートした hint を渡す例（GridBagLayout 風）。
`hint_destroy` を渡せば Container 側で自動解放される。

```zig
const constraints = try allocator.create(GridBagConstraints);
constraints.* = .{ .col = 1, .row = 2 };
try container.addWithHint(
    &label.component,
    @ptrCast(constraints),
    GridBagConstraints.destroy,
);
```

カスタム LayoutManager の実装テンプレ。LayoutManager を embed する形が典型。

```zig
pub const MyLayout = struct {
    base: LayoutManager,

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
    };

    pub const singleton = MyLayout{ .base = .{ .vtable = &vtable } };

    fn doLayout(self: *LayoutManager, container: *Container) void {
        const this: *MyLayout = @fieldParentPtr("base", self);
        _ = this;
        for (container.children.items) |elem| {
            // hint と child の min/max/grow を読んで bounds を決め、
            // elem.component.setBounds(...) を呼ぶ
        }
    }

    fn computeMinSize(_: *LayoutManager, container: *const Container) Size { ... }
    fn computeMaxSize(_: *LayoutManager, container: *const Container) Size { ... }
};

// 利用側
container.setLayout(&MyLayout.singleton.base);
```

カスタム LayoutManager から独自型の hint を取り出す例。

```zig
const MyHint = struct { col: i32, row: i32 };

fn doLayout(self: *LayoutManager, container: *Container) void {
    _ = self;
    for (container.children.items) |elem| {
        const my_hint = if (elem.hint) |h|
            @as(*const MyHint, @ptrCast(@alignCast(h))).*
        else
            MyHint{ .col = 0, .row = 0 };
        _ = my_hint;
        // ...
    }
}
```

## 機能要望
* 組み込み GridBagLayout 相当
* 宣言的レイアウト API（手続き型 LayoutManager をラップする DSL 風 API）
* サブツリー単位の部分再レイアウト (validate root 相当)。 ある subtree より上には dirty を伝播させず、 そのサブツリー内だけで `doLayout` を完結させる仕組み。 現状は Window 全体が 1 単位で、 N が大きくなったときの最適化余地
