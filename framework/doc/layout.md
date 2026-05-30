---
unsafe: true
---

# layout
レイアウトに関する型と仕組み。
Container が子の bounds を計算するための差し替え可能なオブジェクト `LayoutManager` と、子を包む `LayoutElement` を定義する。
設計方針の詳細は `{REPO_ROOT}/doc/layout-design.md` を参照。

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

## コンテナーの最大サイズを計算する
```zig
computeMaxSize: *const fn (*LayoutManager, *const Container) Size;
```

このレイアウトでコンテナーが取りうる最大サイズを返す。
無制限の場合は両軸に `std.math.inf(f32)` を入れる。

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
container.setLayout(&BoxLayout.horizontal_singleton);
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
* 組み込み BoxLayout（horizontal / vertical）
* 組み込み BorderLayout（NORTH / SOUTH / EAST / WEST / CENTER）
* 組み込み GridBagLayout 相当
* 宣言的レイアウト API（手続き型 LayoutManager をラップする DSL 風 API）
* レイアウト結果のキャッシュとサブツリー部分再計算
