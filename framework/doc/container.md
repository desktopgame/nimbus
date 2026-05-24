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

`component.setBounds(bounds)` を呼んだのち、自動的に `doLayout()` を実行する。
Swing の手動 `validate` のような呼び出しは不要。

## レイアウトの実行
```zig
pub fn doLayout(self: *Container) void;
```

`layout` が non-null なら `layout.doLayout(self)` を呼んで直接の子の bounds を設定する。
そのあと、各子のうち Container であるものに対して再帰的に `doLayout()` を呼ぶ。

---

## 役割
Container は Component の派生型の一つで、子 Component を所有する。

* 子の追加 / 削除
* 子の再帰描画 (paint)
* 子へのイベント dispatch (processEvent)
* LayoutManager 経由の bounds 計算

framework としては Container を特別扱いしているわけではない。
`Component.container` フィールドが non-null になっているものを Container とみなすルールで識別する。
利用者が「子を持つ独自ウィジェット」を作りたい場合、Container を embed して使うか、同じパターン（children + `component.container = self`）を自前で実装する。

## 子の所有
CLAUDE.md「所有権」セクションのとおり、Container が children を所有し、destroy で再帰的に解放する。
アロケーターは Application から借用したものを使う。

各子は `LayoutElement { component, hint, hint_destroy }` でラップして保持する。
hint と hint_destroy の意味と所有モデルについては `framework/doc/layout.md` を参照。

`remove` と `destroy` は分離している（Swing `Container.remove` も解放はしない）。
子の解放は必ず `elem.component.vtable.destroy` を経由する。
`allocator.destroy(elem.component)` を直接呼ぶと sizeof Component しか free できず、ウィジェット固有のメモリが leak する（`component.md`「メモリ解放」参照）。

## 描画
デフォルトの `vtable.paint` は子を順番に描画する。
各子の `getBounds()` で `Graphics.clip(...)` を作って子の `vtable.paint` に渡す。

Container 自身は背景描画をしない（透明）。
背景を持たせたい場合は `setVTable` で paint を差し替えるか、Container を embed した独自型を作って paint を書く。

## イベント
デフォルトの `vtable.processEvent` は子に dispatch する。
MouseEvent の場合はヒットテスト（マウス座標が含まれる子）で対象を選び、KeyEvent はフォーカス保持子に渡す。
渡す前にウィンドウローカル座標を子のローカル座標に変換する（`awt/doc/event.md`「座標系」参照）。
子が `event.consume()` を呼んだら以降の子への dispatch は行わない。

Event 型の詳細は `awt/doc/event.md` を参照。

## install / uninstall
Container 固有の `install` / `uninstall` は基本 no-op。
ただし children の `install` は add 時にすでに走っている（factory 経由の Component は install 済みで渡される）ので、ここで再度 install を呼ばないこと。

## レイアウト
`layout` が null の場合、子の位置・サイズは利用者が `child.component.setBounds(...)` で手動指定する。
通常は `setLayout` で BoxLayout や BorderLayout を差して使う。

LayoutManager は直接の子の bounds のみを設定し、孫以下への再帰は Container 側が担当する。
詳細は `framework/doc/layout.md` と `{REPO_ROOT}/doc/layout-design.md` を参照。

## 列挙との関係
Container は init で `self.component.container = self` をセットする。
これにより Application などからツリーを再帰的にたどれる。
詳細は `component.md`「コンポーネントの列挙」を参照。

## 利用者が直接使うか
通常、利用者は `app.container()` を直接使わず、`Frame` 経由でウィジェットを add する。
`Frame` は内部で Container を持っており、`frame.add(label)` は実質的に `frame.container.add(&label.component)` への委譲。

`Container` を直接使うのは「子をグルーピングして配置したい」ような中間ノードが必要な場合。
LayoutManager の適用単位としてもこの中間 Container を使うのが自然である。

---

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
