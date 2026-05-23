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

---

## LayoutElement
Container は子コンポーネントを `*Component` のリストとして直接保持せず、`LayoutElement` のリストとして保持する。

* `component` は子コンポーネント本体
* `hint` は親コンテナーの LayoutManager が解釈するためのデータ。型は LayoutManager 側が決める。フレームワーク自身は中身を解釈しない
* `hint_destroy` は hint が動的にアロケートされている場合の解放関数

## hint の型は LayoutManager に依存する
LayoutManager ごとに hint の型は異なる。

| LayoutManager | hint の型の例 |
|---|---|
| BoxLayout | なし（常に null） |
| BorderLayout | `BorderRegion` enum（NORTH / SOUTH / EAST / WEST / CENTER） |
| GridBagLayout | 独自の `GridBagConstraints` 構造体 |

LayoutManager 実装側は hint を `@ptrCast(@alignCast(...))` で自前の型に戻して読む。
他の LayoutManager 用に書かれた hint を別の LayoutManager に渡すと UB になる。

## hint の所有モデル
opt-in destroy hook 方式。

* `hint_destroy = null`（デフォルト）: caller 所有。スタック変数や const のポインタを渡す。framework は hint に触らない
* `hint_destroy = fn` を渡せば、Container の remove / destroy で自動的に hint の解放を行う

## LayoutManager の構造
コンテナーが子の bounds を計算する責務をカプセル化したオブジェクト。
Component の VTable と同じく per-instance VTable パターンで実装する。
標準レイアウトマネージャは const シングルトンとして提供されることを想定している。

## Container との連携
Container は内部に `layout: ?*LayoutManager` を持ち、以下のように LayoutManager に処理を委譲する。
詳細は `container.md` を参照。

* `container.getMinSize()` → `layout.computeMinSize(container)` を呼ぶ（layout が null なら 0）
* `container.getMaxSize()` → `layout.computeMaxSize(container)` を呼ぶ（layout が null なら inf）
* `container.setBounds(...)` → 自身に bounds を設定したあと、自動的に `doLayout()` を走らせる
* `container.doLayout()` → `layout.doLayout(container)` を呼んだあと、子の Container に対して再帰的に `doLayout` を呼ぶ

LayoutManager 自身は再帰について何もしない。
これは関心の分離のためで、LayoutManager の実装者は直接の子だけを考えればよい。

---

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
