---
unsafe: true
---

# container
コンテナーについての設計ノート。
Component を継承した「子を持つ」ウィジェット。
`LayoutManager` を差すことで子の bounds を自動計算できる。

## 型定義
```zig
pub const Container = struct {
    component: Component,
    children:  std.ArrayList(LayoutElement),
    layout:    ?*LayoutManager,                                             // null なら手動配置
    allocator: std.mem.Allocator,
    min_cache: ?Size = null,                                                // layout 由来 min のメモ。null なら未計算 / 無効
    max_cache: ?Size = null,                                                // layout 由来 max のメモ。null なら未計算 / 無効

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    // ... メソッド
};
```

`LayoutElement` と `LayoutManager` の定義は `framework/doc/layout.md` を参照。

## コンテナーの生成
```zig
pub fn create(allocator: std.mem.Allocator) !*Container;
```

allocator で `Container` を確保し、`children` を空で初期化、`layout` を null（手動配置）、vtable をセットして `install` まで実行する。
`component.container` には self が入る（列挙用）。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## コンテナーの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Container.vtable.destroy` として登録される。
全 children に対して再帰的に `hint_destroy` → `component.vtable.destroy` を呼んで解放したのち、自分の `Component` を uninstall して `allocator.destroy` で free する。

利用者が直接呼ぶ機会は通常無い。
スタンドアロンで使うなら `container.component.vtable.destroy(&container.component, allocator)` を呼ぶ。

## 子の追加
```zig
pub fn add(self: *Container, child: *Component) !void;
```

`children` リストに `child` を追加し、`child.parent = &self.component` をセットする。
hint なし。layout 変化により layout_dirty + paint_dirty が立つ。

## 子の追加（hint 付き）
```zig
pub fn addWithHint(
    self: *Container,
    child: *Component,
    hint: *anyopaque,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void;
```

`add` と同じだが、LayoutManager 固有の hint を一緒に保持する。
`hint_destroy` を渡せば Container の remove / destroy 時に自動 free される。
hint の所有モデルは `framework/doc/layout.md` を参照。

## 子の取り外し
```zig
pub fn remove(self: *Container, child: *Component) void;
```

`children` から該当要素を外す。
`hint_destroy` が設定されていれば hint だけ解放する。
`child` 本体（Component / ウィジェット）は解放しない（付け替え用途のため）。
レイアウトと再描画の dirty フラグを立てる。

## LayoutManager の取得
```zig
pub fn getLayout(self: *const Container) ?*LayoutManager;
```

## LayoutManager の差し替え
```zig
pub fn setLayout(self: *Container, layout: ?*LayoutManager) void;
```

LayoutManager を差し替えて再レイアウトを走らせる。
差し替え前にサイズキャッシュを無効化する（古い LayoutManager が計算したサイズは新しい LayoutManager では無効なため）。
古い LayoutManager の解放は呼び出し側の責務（const シングルトンであれば不要）。

## 最小サイズの取得
```zig
pub fn getMinSize(self: *const Container) Size;
```

`layout` が non-null ならそちらの `computeMinSize` に委譲する（null なら 0,0）。
Container 自身に `component.min_size` が設定されていれば、その値と layout 由来の値の max を取る。

`computeMinSize` の結果は `min_cache` にメモ化される。`computeMinSize` はサブツリー全体を再帰測定するため、
キャッシュが有効な間は再計算を避ける。キャッシュは `invalidateSizeCache` で無効化される（後述）。
メモ化のため `*const` レシーバだが内部で書き込みを行う。Container 実体は可変であり、メモは不変サブツリーの純関数なので、論理的には const のまま矛盾しない。

## 最大サイズの取得
```zig
pub fn getMaxSize(self: *const Container) Size;
```

`layout` が non-null ならそちらの `computeMaxSize` に委譲する（null なら inf,inf）。
`getMinSize` と同様に結果を `max_cache` にメモ化する。

## サイズキャッシュの無効化
```zig
pub fn invalidateSizeCache(self: *Container) void;
```

`min_cache` / `max_cache` を null に戻し、次回の `getMinSize` / `getMaxSize` で再計算させる。

利用者がこれを直接呼ぶ必要は通常ない。`markLayoutDirty`（`component.md` 参照）が、変更されたノードからルートまでの経路上の全コンテナーに対して自動的にこれを呼ぶ。
`add` / `remove` / `setLayout` / `setBounds` や Component 側のサイズ系セッター（`setMinSize` など）はすべて `markLayoutDirty` を経由するため、標準ウィジェットの利用ではキャッシュ整合性は自動で保たれる。

利用者が直接呼ぶ／`markLayoutDirty` を撃つべきなのは、上記の経路を通らずにサイズへ影響する変更を加えたときのみ。
具体的には次の 2 ケース。
* 独自ウィジェットで `component.min_size` / `component.max_size` を直接代入する場合（`setMinSize` を使わず）。
* 独自 `LayoutManager` の `computeMinSize` / `computeMaxSize` が、外部の可変状態に依存していてその状態を更新した場合。

どちらの場合も、再レイアウトと再描画もまとめてトリガーする `markLayoutDirty` を呼ぶのが望ましい。
`invalidateSizeCache` 単体ではキャッシュを落とすだけで再レイアウトは起こさない。

### 事前条件
特になし。キャッシュが既に null でも no-op として安全に呼べる。

## bounds の設定とレイアウト実行
```zig
pub fn setBounds(self: *Container, bounds: Rect) void;
```

`component.setBounds(bounds)` への委譲のみ。 `doLayout()` は呼ばない (= `Component.setBounds` と意味的に等価)。
過去は `doLayout()` を自動で走らせていたが、 これが LayoutManager から呼ばれた場合に 2^k の二重 layout を起こす footgun だったため取り除いた (`{REPO_ROOT}/doc/internal/optimize.md` 参照)。
レイアウト起動の起点は `Window.redraw` が明示的に呼ぶ `root.doLayout()` のみ。 利用者は通常これを意識しない (setter が `markLayoutDirty` を立てる → 次フレームの redraw で自動)。

## レイアウトの実行
```zig
pub fn doLayout(self: *Container) void;
```

`layout` が non-null なら `layout.doLayout(self)` を呼んで直接の子の bounds を設定する。
そのあと、各子のうち Container であるものに対して再帰的に `doLayout()` を呼ぶ。

## 利用例
Application 経由で中間 Container を作って子をまとめる例。

```zig
const wrapper = try app.container();
wrapper.setLayout(box_layout_horizontal);   // 横並びレイアウト

const label_a = try app.label("A");
const label_b = try app.label("B");
try wrapper.add(&label_a.component);
try wrapper.add(&label_b.component);

try frame.window.add(&wrapper.component);
```

hint を使った BorderLayout 風の配置例（LayoutManager 側の hint 型に依存）。

```zig
const region: BorderRegion = .north;
try wrapper.addWithHint(&label.component, @ptrCast(&region), null);
```

## 機能要望
* 子の挿入位置指定（現状 `add` は末尾追加のみ）
* `replace(old, new)` — 同位置で子を入れ替えるショートカット
* `findByName(name)` — デバッグ / テスト用に再帰検索
