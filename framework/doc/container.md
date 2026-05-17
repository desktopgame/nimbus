# container
コンテナーについての設計ノート。Component を継承した「子を持つ」widget。

## 型定義
```zig
pub const Container = struct {
    component: Component,
    children:  std.ArrayList(*Component),
    allocator: std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
    };

    // ... メソッド
};
```

## 役割
Container は Component の派生型の一つで、子 Component を所有する。
- 子の追加/削除
- 子の再帰描画 (paint)
- 子へのイベント dispatch (processEvent)

framework としては Container を特別扱いしているわけではない。
`Component.container` フィールドが non-null になっているものを Container とみなす、
というルールで識別する。

ユーザーが「子を持つ独自 widget」を作りたい場合、Container を embed して使うのが標準的。
あるいは同じ pattern (children + `component.container = self`) を自前で実装してもよい。

## 子の所有
CLAUDE.md「所有権」セクションのとおり、Container が children を所有し、
deinit で再帰的に開放する。アロケーターは Application から借用したものを使う。

```zig
pub fn add(self: *Container, child: *Component) !void {
    try self.children.append(self.allocator, child);
    child.parent = &self.component;
}

pub fn remove(self: *Container, child: *Component) void {
    // children から外すだけ。解放はしない (付け替え用)
}

pub fn deinit(self: *Container) void {
    for (self.children.items) |child| {
        child.deinit();                     // vtable.uninstall + properties cleanup
        self.allocator.destroy(child);      // メモリ free
    }
    self.children.deinit(self.allocator);
    self.component.deinit();                // 自分の Component の uninstall
}
```

remove と destroy は分離している。Swing の `Container.remove` も解放はしない。

## 描画
デフォルト vtable.paint は子を順番に描画する:

```zig
fn paint(self: *Component, g: *awt.Graphics) void {
    const container = self.container.?;
    for (container.children.items) |child| {
        var child_g = g.clip(child.getBounds());
        child.vtable.paint(child, &child_g);
    }
}
```

Container 自身は背景描画をしない (透明)。背景を持たせたいユーザーは setVTable で差し替えるか、
自前で Container を継承して paint を書き直す。

## イベント
デフォルト vtable.processEvent は子に dispatch する。
v1 では Event 型がまだ定義されていないので、プレースホルダ実装のみ。

## install / uninstall
Container 固有の install/uninstall は基本 no-op。
ただし children の install は **add 時** に既に走っている (factory 経由で生成された Component は
install 済みのものが渡される) ので、ここで再度 install を呼ばないこと。

## 列挙との関係
Container は init で `self.component.container = self` をセットする。
これにより Application などからツリーを再帰的に辿れる。詳細は
component.md「コンポーネントの列挙」を参照。

## ライフサイクル
factory コード例 (内部):

```zig
pub fn container(self: *Application) !*Container {
    const c = try self.allocator.create(Container);
    c.* = Container.init(self.allocator);
    c.component.vtable    = &Container.vtable;
    c.component.container = c;                       // 列挙用に self を入れる
    c.component.vtable.install(&c.component);
    return c;
}
```

deinit は子から先、自分が後。Container.deinit は内部で全 children に対して
`child.deinit()` + `allocator.destroy(child)` を実行する。
そのため、Container を deinit した後にユーザーが children のポインタを保持していると dangling になる。

## ユーザーが直接使うか
通常ユーザーは `app.container()` を直接使わず、`Frame` 経由で widget を add する。
`Frame` は内部で Container を持っており、`frame.add(label)` は実質的に
`frame.container.add(&label.component)` への委譲。

`Container` を直接使うのは「子をグルーピングして配置したい」ような中間ノードが必要な場合。
将来 LayoutManager が入れば、その単位として Container を使うのが自然になる。
