# component
コンポーネントについての設計ノート。
nimbus のすべてのウィジェットのルートとなる基本型。
データ + VTable + プロパティ + レイアウト属性を持つ。

## 型定義
```zig
pub const Component = struct {
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
    parent:     ?*Component,
    container:  ?*Container,                    // Container embed のみ self を指す
    focusable:  bool,                           // キーボードフォーカスを受け取れるか (デフォルト false)
    name:       ?[]const u8,                    // Java AWT 互換
    properties: ?std.StringHashMap(Property),   // Swing putClientProperty 互換
    allocator:  std.mem.Allocator,

    // ... メソッド
};
```

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

---

## プラッガブルな設計
Component を継承した Button、Label などは VTable を独自に実装する。
利用者は普通にビルトインのウィジェットを使えばよく、カスタマイズしたいときだけ VTable を差し替える。
ルックアンドフィールのような「全コンポーネントの VTable を一斉に入れ替える」操作も同じ仕組みで実現できる。

nimbus はルックアンドフィールそのものの設計は提供しない。
設計が難しいことと、カスタマイズポイントを露出しておけば利用者側で実装可能であることが理由。

VTable のカスタマイズポイントは以下の 5 つ。

| エントリ | 用途 |
|---|---|
| `install` | 差し替え時の初期化 hook（プロパティ登録など） |
| `uninstall` | 差し替え時の後片付け hook |
| `paint` | 描画ロジック |
| `processEvent` | イベント処理ロジック |
| `destroy` | メモリ解放（L&F カスタマイズではなく内部責務） |

`destroy` だけは L&F の範疇ではなく、Zig の制約から必要な内部責務（後述「メモリ解放」を参照）。

## プロパティ
VTable の差し替えだけでは「コンポーネントが追加の独自状態を持ち、イベントで変化する」ような拡張に対応できない。
このために `Component.properties` を提供する。
Swing `JComponent.putClientProperty` と同じ位置付け。

## レイアウト属性
LayoutManager が子の bounds を計算するための入力として、4 つの属性を持つ。
意味と分配アルゴリズムの詳細は `{REPO_ROOT}/doc/layout-design.md` を参照。

| フィールド | 型 | デフォルト | 意味 |
|---|---|---|---|
| `min_size` | `Size` | `(0, 0)` | これ以下のサイズにはならない |
| `max_size` | `Size` | `(inf, inf)` | これより大きいサイズにはならない |
| `grow_x` | `f32` | `0` | 水平方向に余白があるときの分配重み |
| `grow_y` | `f32` | `0` | 垂直方向に余白があるときの分配重み |
| `align_x` | `Alignment` | `.stretch` | 水平方向の配置（コンテナの主軸が y のとき適用） |
| `align_y` | `Alignment` | `.stretch` | 垂直方向の配置（コンテナの主軸が x のとき適用） |

`min_size` / `max_size` はハード境界であり、grow による分配は max を超えない。
`align_x` / `align_y` は当該軸がコンテナの**交差軸**になっているレイアウトが解釈する（BoxLayout 等）。

### コンテンツ依存の min_size
Label のようにテキスト幅から自然な min_size が決まるウィジェットでは、ウィジェット側 (`Label.setText` など) が自前で `component.min_size` を計算してセットする。
Component 自身には「コンテンツから min を導出する」仕組みは持たない（ウィジェットごとに参照する内部状態が違うため）。

利用者が明示的に上書きしたい場合は `setMinSize` を呼ぶ。
ただしウィジェットが次回 setter を呼んだときに再計算で上書きされる場合がある（ウィジェットの方針による）。

## メモリ解放
Container が子を解放するとき、`allocator.destroy(child)` で素直に free できないのが Zig の制約。
`child` の型は `*Component` だが実体は外側のウィジェット (Label、Button 等) であり、`allocator.destroy` は引数の静的サイズ（sizeof Component）しか free しない。
このままだとウィジェット固有のフィールドが leak する。

そのため VTable に `destroy` を持ち、各ウィジェットが `@fieldParentPtr` で外側に戻して正しいサイズで free する責務を負う。
ファクトリー経由で生成されたウィジェットを利用者が自分で free する場合も `component.vtable.destroy(&comp, allocator)` を呼ぶのが正規ルート。

`Component.deinit` 自体はメモリ解放を行わない（uninstall + properties cleanup まで）。
メモリ解放は `vtable.destroy` の責務。

## コンポーネントの列挙
コンポーネントを再帰的にたどるとき、leaf か container かを判別する手段が必要になる。
`Component.container` フィールドが non-null かどうかで判別する。
Container embed の場合だけ `container` が self を指す。

## コンポーネントのデバッグ
コンポーネントに名前をつけることができる（`setName` / `getName`）。
ルックアップ用ではなく、デバッグダンプ用を想定している。

## 派生型から Component メソッドへのアクセス
Zig は継承を持たないので、派生ウィジェット (Label、Container など) からの Component メソッド呼び出しは**親フィールド直接アクセス**で書く。
委譲メソッドは生やさない。

```zig
label.component.setBounds(.{ ... });
label.component.repaint();
label.component.setName("submit");
```

これは Zig 慣用（`std.ArrayList` の field 直接アクセスと同じスタンス）。
階層が見え、ボイラープレートがゼロになる。

### なぜ委譲メソッドを置かないか
Java の感覚だと `setBounds` / `repaint` あたりは利用者が頻繁に呼ぶ気がするが、nimbus の API 設計だと実際にはそうならない。

| メソッド | 実際の呼び出し主 |
|---|---|
| `setBounds` / `getBounds` | **LayoutManager**。利用者は設定しない |
| `repaint` | **setter が内部で呼ぶ** (`setText` 等)。利用者が直接呼ぶ機会は稀 |
| `setName` / `getName` | デバッグ用。出番少 |
| `setVTable` / properties | 上級者用、明示的でいい |

利用者が頻繁に呼ぶのはウィジェット固有 setter (`label.setText`、`label.setColor`) であり、親 Component メソッドはほぼ呼ばない。
委譲を生やしても普段使われない上にボイラープレートになる。
将来「本当に頻出と判明したメソッド」が出てきたら、その時に派生型に委譲を生やす。

### アップキャスト用 helper
Container には `asComponent()` という親型へのアップキャストのための明示的 helper がある。

```zig
try container.add(label.asComponent());
```

Label など leaf ウィジェットには `asComponent` はないが、`&label.component` で同等。

## setter / getter の方針
書き換え可能なプロパティは **setter / getter をペアで提供する**（Swing 流の対称性）。

| 用途 | 方法 |
|---|---|
| 書き換え（副作用あり） | `setXxx(...)` 必須。内部で dup / repaint / dirty フラグ更新 / (将来) PropertyChangeEvent 等を行う |
| 読み（副作用なし） | `getXxx()` が公式。フィールド直接 read もショートカットとして許容（Zig 慣用） |

Zig はフィールド単位の private 修飾子を持たないので、言語レベルでフィールド直接 write を禁止することはできない。
しかし副作用を必要とする書き換えは setter 経由でないと壊れる（例: text の単純代入は旧 text が leak）。
したがって read は getter / 直接 read どちらも可、write は setter 必須（直接 write 禁止は doc / レビューでカバー）。

将来 `PropertyChangeListener`（Swing の PCE 相当）を導入する余地を残している。
入った時に setter が listener 通知を担う。

## ライフサイクル
factory（またはウィジェットの `create`）が次の手順をひとまとめに行う。

1. `allocator.create(WidgetType)` でウィジェット全体を確保
2. `init` でウィジェット固有のフィールドを初期化（Component のフィールドも含む）。Component の `init(allocator, vtable)` でデフォルト vtable をセット
3. `try component.vtable.install(&component)` を呼ぶ（失敗時は手順 1 で確保した分を errdefer で free して伝搬）

deinit の前に必ず `uninstall` を呼び出すこと。
正規ルートは `component.vtable.destroy(&component, allocator)` で、これが内部で `deinit`（uninstall + cleanup）と `allocator.destroy(widget)` を順に行う。

## ルックアンドフィールの想定実装
コンポーネントを再帰的に列挙して `setVTable` を呼ぶ、というのが想定。
nimbus 自身はこの実装を提供しない。利用者の自由領域。

## フォーカス
`focusable` フィールドはこのコンポーネントがキーボードフォーカスを受け取れるかを示す。
デフォルトは false で、Button / Label / Slider など v1 のウィジェットの多くはフォーカスを取らない。
TextField / TextArea のようにテキスト入力を受けるウィジェットだけが true にセットする。

`requestFocus` を呼ぶと、Window が `focus_owner` を切り替え、新旧のフォーカスオーナーに `FocusEvent` を dispatch する。
詳細は `window.md`「フォーカス」を参照。

framework は Component と Window の直接依存を避けるため、`FocusController` プロパティを介して通知する設計を採る。
Window が各ルートコンポーネント (`container.component`、`menu_bar`、各 overlay) にこのプロパティを install しておき、`Component.requestFocus` は親チェーンを遡ってルートで読み取り、コールバック経由で Window に届ける。
`DirtyNotify` プロパティと同じパターン。

```zig
pub const FocusController = struct {
    user_data:         *anyopaque,
    request_focus_for: *const fn (*anyopaque, ?*Component) void,
};
```

利用者がこの型に触る必要はない (Window が install / 利用する内部仕掛け)。

## install / uninstall
`install` を呼んだら必ず対応する `uninstall` も呼び出さなければならない。
VTable を差し替えるときは古い vtable の `uninstall` → 新しい vtable の `install` の順（`setVTable` が内部で行う）。

`install` は失敗し得る (`anyerror!void`)。
リスナー登録 / プロパティ登録など allocator を使う処理を含むウィジェットの install が OOM 等で失敗した場合、`create` factory がその error を呼び出し元に伝搬する。
利用者は通常通り `try app.button(...)` の形で受け取る。

`uninstall` はデストラクタ風で、常に void を返す。
リソース解放しかしないため失敗を返さない設計。
（リスナー解除 / プロパティ free などは失敗しても呼び出し側が回復できないため、`uninstall` 自身が握りつぶす or panic する責任を負う。）

---

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
* Component 単位の `dirty` フラグ — 現状は Frame 単位で持つ（`{REPO_ROOT}/doc/layout-design.md` 参照）
