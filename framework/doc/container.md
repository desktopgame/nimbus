# container
コンテナーについての設計ノート。Component を継承した「子を持つ」widget。

## 型定義
```zig
pub const LayoutElement = struct {
    component:    *Component,
    hint:         ?*anyopaque = null,                                       // LayoutManager 用 hint (v2〜)
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void = null,   // 任意の destroy hook
};

pub const Container = struct {
    component: Component,
    children:  std.ArrayList(LayoutElement),
    layout:    ?*LayoutManager,                                             // v1 は null 固定
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
* 子の追加 / 削除
* 子の再帰描画 (paint)
* 子へのイベント dispatch (processEvent)

framework としては Container を特別扱いしているわけではない。
`Component.container` フィールドが non-null になっているものを Container とみなす、
というルールで識別する。

利用者が「子を持つ独自 widget」を作りたい場合、Container を embed して使うのが標準的。
あるいは同じ pattern (children + `component.container = self`) を自前で実装してもよい。

## 子の所有
CLAUDE.md「所有権」セクションのとおり、Container が children を所有し、
deinit で再帰的に開放する。アロケーターは Application から借用したものを使う。

各子は `LayoutElement { component, hint, hint_destroy }` でラップして保持する。
hint は LayoutManager (v2〜) が解釈するためのフィールドで、v1 では常に null。

```zig
pub fn add(self: *Container, child: *Component) !void {
    try self.children.append(self.allocator, .{ .component = child });
    child.parent = &self.component;
}

pub fn addWithHint(
    self: *Container,
    child: *Component,
    hint: *anyopaque,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void {
    try self.children.append(self.allocator, .{
        .component    = child,
        .hint         = hint,
        .hint_destroy = hint_destroy,
    });
    child.parent = &self.component;
}

pub fn remove(self: *Container, child: *Component) void {
    // children から該当要素を外すだけ。component 本体の解放はしない (付け替え用)。
    // hint_destroy が設定されていれば hint の destroy だけは呼ぶ。
}

pub fn deinit(self: *Container) void {
    for (self.children.items) |elem| {
        if (elem.hint_destroy) |destroy_hint| destroy_hint(elem.hint.?, self.allocator);
        elem.component.deinit();                                       // uninstall + properties cleanup
        elem.component.vtable.destroy(elem.component, self.allocator); // 正しい widget サイズで free
    }
    self.children.deinit(self.allocator);
    self.component.deinit();                                            // 自分の Component の uninstall
}
```

remove と destroy は分離している。Swing の `Container.remove` も解放はしない。

`elem.component.vtable.destroy` を経由しているのが要点。
`allocator.destroy(elem.component)` を直接呼ぶと sizeof Component しか free できず、
Label / Button の余剰メモリが leak する (component.md「メモリ解放」参照)。

## 描画
デフォルト vtable.paint は子を順番に描画する:

```zig
fn paint(self: *Component, g: *awt.Graphics) void {
    const container = self.container.?;
    for (container.children.items) |elem| {
        var child_g = g.clip(elem.component.getBounds());
        elem.component.vtable.paint(elem.component, &child_g);
    }
}
```

Container 自身は背景描画をしない (透明)。背景を持たせたい利用者は setVTable で差し替えるか、
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

## レイアウトと hint
v1 では LayoutManager は未実装で、子の位置・サイズは利用者が `child.setBounds(...)` で手動指定する。
このとき `LayoutElement.hint` は使われない (常に null)。

v2 以降で LayoutManager (BorderLayout / BoxLayout 等) が導入された時、
各 LayoutManager が hint を解釈して `child.setBounds(...)` を内部で呼ぶ:

```zig
// v2 想定: BorderLayout が hint を見て位置決め
const BorderRegion = enum { north, south, east, west, center };
const north_hint: BorderRegion = .north;
try container.addWithHint(&label.component, @ptrCast(&north_hint), null);

// BorderLayout.layoutContainer(container) が elem.hint を見て setBounds
```

hint の所有モデルは Component.properties と同じく **opt-in destroy hook**:
* `hint_destroy = null` (デフォルト): caller 所有、framework は触らない (上記 `&local_enum` 等)
* `hint_destroy = fn` を渡せば Container.remove / deinit で自動 free (動的 alloc した GridBagConstraints 等)

LayoutManager 本体の設計は別 doc で扱う。

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
`elem.component.deinit()` + `allocator.destroy(elem.component)` を実行し、
hint_destroy が設定されていれば hint の destroy も呼ぶ。
そのため、Container を deinit した後に利用者が children のポインタを保持していると dangling になる。

## 利用者が直接使うか
通常利用者は `app.container()` を直接使わず、`Frame` 経由で widget を add する。
`Frame` は内部で Container を持っており、`frame.add(label)` は実質的に
`frame.container.add(&label.component)` への委譲。

`Container` を直接使うのは「子をグルーピングして配置したい」ような中間ノードが必要な場合。
将来 LayoutManager が入れば、その単位として Container を使うのが自然になる。
