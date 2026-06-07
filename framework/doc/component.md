---
unsafe: true
---

# component
コンポーネントについての設計ノート。
nimbus のすべてのウィジェットのルートとなる基本型。
データ + VTable + プロパティ + レイアウト属性を持つ。

## 型定義
```zig
pub const Component = struct {
    // VTable の関数はできるだけこれ以上増やさないこと。やむを得ない場合は仕方ないけど、まずは増やさずに済む方法を考える
    pub const VTable = struct {
        install:      *const fn (*Component) anyerror!void,
        uninstall:    *const fn (*Component) void,
        paint:        *const fn (*Component, *awt.Graphics) void,
        processEvent: *const fn (*Component, *awt.Event) void,
        destroy:      *const fn (*Component, std.mem.Allocator) void,
    };

    vtable:     *const VTable,                  // ★ 書き換え可能 (個別差替 / 一斉差替)
    position:   Point,
    size:       Size,
    min_size:   Size,                           // レイアウト下限 (デフォルト 0,0)
    max_size:   Size,                           // レイアウト上限 (デフォルト inf,inf)
    grow_x:     f32,                            // 水平方向の余白分配重み (デフォルト 0)
    grow_y:     f32,                            // 垂直方向の余白分配重み (デフォルト 0)
    align_x:    Alignment,                      // 水平方向のアラインメント (デフォルト stretch)
    align_y:    Alignment,                      // 垂直方向のアラインメント (デフォルト stretch)
    scrollable:  ?Scrollable,                   // ScrollPane 配下で挙動を変えるための opt-in ヒント
    drag_source: ?dnd.DragSource,               // DnD のソース側 opt-in (`dnd.md`)
    drop_target: ?dnd.DropTarget,               // DnD のターゲット側 opt-in (`dnd.md`)
    size_query:  ?SizeQuery,                    // 幅依存の高さを返すための opt-in (後述「SizeQuery」)
    parent:     ?*Component,
    container:  ?*Container,                    // Container embed のみ self を指す
    focusable:  bool,                           // キーボードフォーカスを受け取れるか (デフォルト false)
    name:       ?[]const u8,                    // Java AWT 互換
    properties: ?std.StringHashMap(Property),   // Swing putClientProperty 互換
    allocator:  std.mem.Allocator,

    // ... メソッド
};
```

### SizeQuery
幅で内容の高さが変わるウィジェット (折り返し `TextArea` 等) が、レイアウトに「この幅での最小高さ」を聞かれるための opt-in 能力構造体。`DragSource` / `DropTarget` と同じく `Component` のオプショナルフィールドとして持ち、`VTable` を増やさない。

```zig
pub const SizeQuery = struct {
    minHeightForWidth: *const fn (self: *const Component, w: f32) f32,
};
```

`*const Component` を受け取る純粋クエリ。同じ widget 状態と同じ `w` に対して同じ結果を返し、観測可能な状態 (`min_size` 等) を変更しない。内部 cache (折り返し結果の memoization 等) の更新は `@constCast` 経由で許される。

`w` は親レイアウトが当該ウィジェットに与えようとしている外側の幅 (padding / border 込み)。`null` のとき呼び出し側は `min_size.height` をそのまま使う。

`Event` の型定義は `awt/doc/event.md` を参照。
`processEvent` は mutable `*Event` を受け取り、消費は `event.consume()` で表現する（戻り値ではなくフィールドで管理する）。

`Alignment` はレイアウトが交差軸に沿った位置決めに使う列挙：

```zig
pub const Alignment = enum { start, center, end, stretch };
```

* `stretch` — コンテナの当該軸サイズいっぱいに広げる（v1 デフォルト、min/max でクランプ）
* `start` — 当該軸の低い側（上端 / 左端）に詰める、サイズは min
* `center` — 中央寄せ、サイズは min
* `end` — 当該軸の高い側（下端 / 右端）に詰める、サイズは min

## コンポーネントの初期化
```zig
pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) Component;
```

デフォルト値で `Component` のフィールドを初期化する。
`vtable` は呼び出し時に渡す（後から `setVTable` で差し替え可能）。
`min_size = (0, 0)`、`max_size = (inf, inf)`、`grow_x = grow_y = 0`、`align_x = align_y = .stretch` で初期化される。
`install` はここでは呼ばれない（factory が `vtable.install(&component)` を別途呼ぶ）。

## コンポーネントの後片付け
```zig
pub fn deinit(self: *Component) void;
```

`vtable.uninstall` を呼び、`properties` がアロケート済みなら解放する。
メモリ自体の解放（`allocator.destroy`）はここでは行わない（`vtable.destroy` の責務）。

## bounds の設定
```zig
pub fn setBounds(self: *Component, bounds: Rect) void;
```

位置とサイズを同時に変更する。
`position` / `size` 両方の差分を見て、変化があれば対応する dirty を立てる。

## bounds の取得
```zig
pub fn getBounds(self: Component) Rect;
```

値レシーバ。`Component` は中身が小さい (ポインタ数個 + プリミティブ) ので値で受けても安価。

## 再描画の要求
```zig
pub fn repaint(self: *Component) void;
```

paint_dirty を立てる。レイアウトには影響しない。
ウィジェットの setter（`setColor` 等、見た目だけ変える操作）が内部的に呼ぶことを想定。

## 再レイアウトの要求
```zig
pub fn markLayoutDirty(self: *Component) void;
```

ルートまで親をたどり、Window の layout_dirty + paint_dirty を立てる。
あわせて、経路上の全コンテナーの `invalidateSizeCache` を呼んでサイズキャッシュを落とす（`container.md` 参照）。
これは「変更されたノードを含むサブツリーのコンテナー」＝計測結果が変わり得るものだけが対象になる。

サイズや子構成を変えるウィジェットの setter が内部的に呼ぶことを想定。
利用者が直接呼ぶのは、標準のセッターを経由せずにサイズへ影響する変更を加えたとき（`container.md`「サイズキャッシュの無効化」のケースを参照）。

## 最小サイズの設定
```zig
pub fn setMinSize(self: *Component, size: Size) void;
```

下限を更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。

## 最小サイズの取得
```zig
pub fn getMinSize(self: *const Component) Size;
```

(他の getter / Container 側の embed フィールド参照のため、こちらは `*const` 受け取り。)

## 最大サイズの設定
```zig
pub fn setMaxSize(self: *Component, size: Size) void;
```

上限を更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。

## 最大サイズの取得
```zig
pub fn getMaxSize(self: *const Component) Size;
```

## レイアウト測定用の min/max サイズ
```zig
pub fn effectiveMinSize(self: *const Component) Size;
pub fn effectiveMaxSize(self: *const Component) Size;
```

レイアウトマネージャ (BoxLayout 等) が子の min/max を見るときに使うべきヘルパー。
plain な Component に対しては `min_size` / `max_size` の値をそのまま返すが、Container を embed したコンポーネントに対しては `Container.getMinSize` / `getMaxSize` を呼び出し、レイアウト計算済みのサイズを取得する。

これにより、空 Panel やネストした Container を BoxLayout の子に置いたとき、内側の子から自動的にサイズが伝播する。
利用者が `setMinSize` / `setMaxSize` で明示的に値をセットしていれば、Container の場合「min は明示値と計算値の大きい方」「max は明示値と計算値の小さい方」が採用される (両方の制約を同時に満たす)。

計算量は実質 `O(N)` (N = subtree のノード数)。
Container 側で `min_cache` / `max_cache` に memoize されており、 同じ layout サイクル内で複数回呼ばれてもキャッシュヒットで即座に返る (詳細は `container.md`、 `layout.md`「キャッシュ」参照)。
キャッシュは `markLayoutDirty` が経路上の Container に対して `invalidateSizeCache` を呼ぶことで自動的に落ちる。 LayoutManager / 利用者から見るとキャッシュは透過。

利用者が直接呼ぶ機会はほぼなく、layout 実装者向けのフック。

## 水平方向 grow の設定
```zig
pub fn setGrowX(self: *Component, weight: f32) void;
```

水平方向の余白分配重みを更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。

## 水平方向 grow の取得
```zig
pub fn getGrowX(self: *const Component) f32;
```

## 垂直方向 grow の設定
```zig
pub fn setGrowY(self: *Component, weight: f32) void;
```

垂直方向の余白分配重みを更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。

## 垂直方向 grow の取得
```zig
pub fn getGrowY(self: *const Component) f32;
```

## 水平方向アラインメントの設定
```zig
pub fn setAlignX(self: *Component, a: Alignment) void;
```

水平方向のアラインメントを更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。
垂直 box などコンテナの主軸が y のとき、コンテナはこの値を見て子の水平位置を決める。

## 水平方向アラインメントの取得
```zig
pub fn getAlignX(self: *const Component) Alignment;
```

## 垂直方向アラインメントの設定
```zig
pub fn setAlignY(self: *Component, a: Alignment) void;
```

垂直方向のアラインメントを更新する。値が変わったら `markLayoutDirty` を呼ぶ (ルートまで遡って Window の layout_dirty + paint_dirty が立つ)。
水平 box などコンテナの主軸が x のとき、コンテナはこの値を見て子の垂直位置を決める。

## 垂直方向アラインメントの取得
```zig
pub fn getAlignY(self: *const Component) Alignment;
```

## 名前の設定
```zig
pub fn setName(self: *Component, name: ?[]const u8) void;
```

デバッグ用の名前を保持する。
内部で `allocator.dupe` で複製を取り、古い名前は free される。
`null` を渡すと名前を削除する。

## 名前の取得
```zig
pub fn getName(self: Component) ?[]const u8;
```

値レシーバ (`getBounds` と同じ理由)。

## フォーカス可能性の取得
```zig
pub fn isFocusable(self: *const Component) bool;
```

`focusable` フィールドの getter。

## フォーカス可能性の設定
```zig
pub fn setFocusable(self: *Component, v: bool) void;
```

`focusable` フィールドを更新する。
true にしたウィジェット (TextField 等) は `requestFocus` でフォーカスを取得できる。
レイアウトには影響しないので dirty フラグは立てない。

## フォーカスの要求
```zig
pub fn requestFocus(self: *Component) void;
```

自身を Window のフォーカスオーナーにするよう要求する。
内部的には親チェーンを上ってルートまで遡り、ルートに登録された `FocusController` プロパティを通じて Window に通知する。
ルートが Window 配下に attach されていない (factory 直後など) 場合は no-op。

`focusable == false` のコンポーネントに呼んでもフォーカス遷移は発生する（仕様）。
利用者側で必要なら呼び出し前に `isFocusable()` をチェックする。

## VTable の差し替え
```zig
pub fn setVTable(self: *Component, new_vt: *const VTable) !void;
```

現在の `vtable.uninstall` を呼んだあと、新しい vtable に差し替え、`new_vt.install` を呼ぶ。
個別の差し替え（1 コンポーネントだけ paint をフックする）と、一斉差し替え（ルックアンドフィール）の両方に対応する。

新しい `install` が失敗した場合は、旧 vtable は既に `uninstall` 済みで、新 vtable は install されなかった状態で error を返す。
呼び出し側が必要なら旧 vtable の `install` を再度呼ぶことでロールバックする責務を負う（自動巻き戻しはしない）。

## プロパティの書き込み
```zig
pub fn putProperty(
    self: *Component,
    key: []const u8,
    value: *anyopaque,
    destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void;
```

`properties` マップに `key` / `value` を登録する。
`destroy` が non-null なら `removeProperty` / `Component.deinit` 時に値の解放に使われる。
`properties` がまだアロケートされていなければここで初期化する。
Swing `JComponent.putClientProperty` 相当。

## プロパティの読み取り
```zig
pub fn getProperty(self: Component, key: []const u8) ?*anyopaque;
```

登録されていなければ `null` を返す。
返り値の解釈（実型）は呼び出し側の責任。型安全な薄いラッパー `putTyped(T, *T)` / `getTyped(T) ?*T` も同ファイルに存在する。

## 利用例
利用者が直接 Component を生成することはほぼなく、ウィジェット（Label 等）の `create` または Application の factory が内部で組み立てる。
利用者から見える典型コードは label.md / application.md の利用例を参照。

派生ウィジェットの Component メソッドにアクセスする場合の例。

```zig
const label = try app.label("hello");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 200, .height = 32 });
label.component.setMinSize(.{ .width = 100, .height = 24 });   // widget の自動算出を上書き
label.component.setName("submit_label");                        // デバッグ用
```

VTable の個別差し替え例。

```zig
const my_vt = Component.VTable{
    .install      = Label.vtable.install,
    .uninstall    = Label.vtable.uninstall,
    .paint        = myCustomPaint,
    .processEvent = Label.vtable.processEvent,
    .destroy      = Label.vtable.destroy,
};
try label.component.setVTable(&my_vt);
```

## 機能要望
* `PropertyChangeListener` 相当 — setter からの変更通知。Swing PCE と同等
* Component 単位の `dirty` フラグ — 現状は Frame 単位で持つ（`{REPO_ROOT}/doc/internal/layout-design.md` 参照）
