# container
コンテナーについての設計ノート。Component を継承した「子を持つ」widget。

## 型定義
```zig
pub const Container = struct {
    component: Component,
    children:  std.ArrayList(LayoutElement),
    layout:    ?*LayoutManager,                                             // v1 は null 許容
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

`LayoutElement` と `LayoutManager` の定義は `framework/doc/layout.md` を参照。

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
hint と hint_destroy の意味と所有モデルについては `framework/doc/layout.md` を参照。

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

## レイアウト
Container は `layout: ?*LayoutManager` を持ち、子の bounds の計算を LayoutManager に委譲する。
LayoutManager のインターフェイス定義は `framework/doc/layout.md`、設計方針は `{REPO_ROOT}/doc/layout-design.md` を参照。

v1 では LayoutManager の標準実装（BoxLayout / BorderLayout 等）はまだ存在せず、`layout` は null のまま運用する。
このとき子の位置・サイズは利用者が `child.setBounds(...)` で手動指定する。

### MinimumSize / MaximumSize の委譲
Container は leaf widget と同じ `getMinSize()` / `getMaxSize()` のインターフェイスを持つが、内部では `layout` に問い合わせて返す。
これにより利用者やレイアウトマネージャは leaf かコンテナーかを区別せずに min / max を取得できる。

```zig
pub fn getMinSize(self: *const Container) Size {
    const lm_min = if (self.layout) |lm|
        lm.vtable.computeMinSize(lm, self)
    else
        .{ .width = 0, .height = 0 };
    // Container 自身に明示的な下限が設定されていれば、それと合成する
    return .{
        .width  = @max(self.component.min_size.width,  lm_min.width),
        .height = @max(self.component.min_size.height, lm_min.height),
    };
}
```

### setBounds は自動で doLayout を呼ぶ
Container は自身の bounds が変更された時点で再レイアウトする。
Swing の手動 `validate` のような呼び出しは不要。

```zig
pub fn setBounds(self: *Container, bounds: Rect) void {
    self.component.setBounds(bounds);
    self.doLayout();
}
```

### 再帰は Container の責務
LayoutManager は直接の子の bounds のみを設定する。
孫以下への再帰は Container が担当し、それぞれの子 Container に対して `doLayout()` を呼ぶ。

```zig
pub fn doLayout(self: *Container) void {
    if (self.layout) |lm| lm.vtable.doLayout(lm, self);
    for (self.children.items) |elem| {
        if (elem.component.container) |child_c| child_c.doLayout();
    }
}
```

### LayoutManager の差し替え
`setLayout` で LayoutManager を差し替えることができる。
差し替え後は再レイアウトを行う。
古い LayoutManager の解放は呼び出し側の責務（標準提供される const シングルトンであれば不要）。

```zig
pub fn setLayout(self: *Container, layout: ?*LayoutManager) void {
    self.layout = layout;
    self.doLayout();
}
```

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
