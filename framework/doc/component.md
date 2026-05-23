# component
コンポーネントについての設計ノート。
nimbus のすべての widget のルートとなる基本型。
データ + VTable + プロパティ + レイアウト属性を持つ。

## 型定義
```zig
pub const Component = struct {
    pub const VTable = struct {
        install:      *const fn (*Component) void,
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
    parent:     ?*Component,
    container:  ?*Container,                    // Container embed のみ self を指す
    name:       ?[]const u8,                    // Java AWT 互換
    properties: ?std.StringHashMap(Property),   // Swing putClientProperty 互換
    allocator:  std.mem.Allocator,

    // ... メソッド
};
```

`Event` の型定義は `awt/doc/event.md` を参照。
`processEvent` は mutable `*Event` を受け取り、消費は `event.consume()` で表現する（戻り値ではなくフィールドで管理する）。

## コンポーネントの初期化
```zig
pub fn init(allocator: std.mem.Allocator) Component;
```

デフォルト値で `Component` のフィールドを初期化する。
`vtable` は呼び出し側（widget の `create` または factory）が後からセットする責務を持つ。
`min_size = (0, 0)`、`max_size = (inf, inf)`、`grow_x = grow_y = 0` で初期化される。

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
pub fn getBounds(self: *const Component) Rect;
```

## 再描画の要求
```zig
pub fn repaint(self: *Component) void;
```

paint_dirty を立てる。レイアウトには影響しない。
widget の setter（`setColor` 等、見た目だけ変える操作）が内部的に呼ぶことを想定。

## 最小サイズの設定
```zig
pub fn setMinSize(self: *Component, size: Size) void;
```

下限を更新する。値が変わったら layout_dirty + paint_dirty を立てる。

## 最小サイズの取得
```zig
pub fn getMinSize(self: *const Component) Size;
```

## 最大サイズの設定
```zig
pub fn setMaxSize(self: *Component, size: Size) void;
```

上限を更新する。値が変わったら layout_dirty + paint_dirty を立てる。

## 最大サイズの取得
```zig
pub fn getMaxSize(self: *const Component) Size;
```

## 水平方向 grow の設定
```zig
pub fn setGrowX(self: *Component, weight: f32) void;
```

水平方向の余白分配重みを更新する。値が変わったら layout_dirty + paint_dirty を立てる。

## 水平方向 grow の取得
```zig
pub fn getGrowX(self: *const Component) f32;
```

## 垂直方向 grow の設定
```zig
pub fn setGrowY(self: *Component, weight: f32) void;
```

垂直方向の余白分配重みを更新する。値が変わったら layout_dirty + paint_dirty を立てる。

## 垂直方向 grow の取得
```zig
pub fn getGrowY(self: *const Component) f32;
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
pub fn getName(self: *const Component) ?[]const u8;
```

## VTable の差し替え
```zig
pub fn setVTable(self: *Component, new_vt: *const VTable) void;
```

現在の `vtable.uninstall` を呼んだあと、新しい vtable に差し替え、`new_vt.install` を呼ぶ。
個別の差し替え（1 コンポーネントだけ paint をフックする）と、一斉差し替え（ルックアンドフィール）の両方に対応する。

## プロパティの書き込み
```zig
pub fn putProperty(self: *Component, key: []const u8, value: Property) !void;
```

`properties` マップに `key` / `value` を登録する。
`properties` がまだアロケートされていなければここで初期化する。
Swing `JComponent.putClientProperty` 相当。

## プロパティの読み取り
```zig
pub fn getProperty(self: *const Component, key: []const u8) ?Property;
```

---

## プラッガブルな設計
Component を継承した Button、Label などは VTable を独自に実装する。
利用者は普通にビルトインの widget を使えばよく、カスタマイズしたいときだけ VTable を差し替える。
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

`min_size` / `max_size` はハード境界であり、grow による分配は max を超えない。

### コンテンツ依存の min_size
Label のようにテキスト幅から自然な min_size が決まる widget では、widget 側 (`Label.setText` など) が自前で `component.min_size` を計算してセットする。
Component 自身には「コンテンツから min を導出する」仕組みは持たない（widget ごとに参照する内部状態が違うため）。

利用者が明示的に上書きしたい場合は `setMinSize` を呼ぶ。
ただし widget が次回 setter を呼んだときに再計算で上書きされる場合がある（widget の方針による）。

## メモリ解放
Container が子を解放するとき、`allocator.destroy(child)` で素直に free できないのが Zig の制約。
`child` の型は `*Component` だが実体は外側の widget (Label、Button 等) であり、`allocator.destroy` は引数の静的サイズ（sizeof Component）しか free しない。
このままだと widget 固有のフィールドが leak する。

そのため VTable に `destroy` を持ち、各 widget が `@fieldParentPtr` で外側に戻して正しいサイズで free する責務を負う。
ファクトリー経由で生成された widget を利用者が自分で free する場合も `component.vtable.destroy(&comp, allocator)` を呼ぶのが正規ルート。

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
Zig は継承を持たないので、派生 widget (Label、Container など) からの Component メソッド呼び出しは**親フィールド直接アクセス**で書く。
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

利用者が頻繁に呼ぶのは widget 固有 setter (`label.setText`、`label.setColor`) であり、親 Component メソッドはほぼ呼ばない。
委譲を生やしても普段使われない上にボイラープレートになる。
将来「本当に頻出と判明したメソッド」が出てきたら、その時に派生型に委譲を生やす。

### アップキャスト用 helper
Container には `asComponent()` という親型へのアップキャストのための明示的 helper がある。

```zig
try container.add(label.asComponent());
```

Label など leaf widget には `asComponent` はないが、`&label.component` で同等。

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
factory（または widget の `create`）が次の手順をひとまとめに行う。

1. `allocator.create(WidgetType)` で widget 全体を確保
2. `init` で widget 固有のフィールドを初期化（Component のフィールドも含む）
3. `component.vtable = &WidgetType.vtable` をセット
4. `component.vtable.install(&component)` を呼ぶ

deinit の前に必ず `uninstall` を呼び出すこと。
正規ルートは `component.vtable.destroy(&component, allocator)` で、これが内部で `deinit`（uninstall + cleanup）と `allocator.destroy(widget)` を順に行う。

## ルックアンドフィールの想定実装
コンポーネントを再帰的に列挙して `setVTable` を呼ぶ、というのが想定。
nimbus 自身はこの実装を提供しない。利用者の自由領域。

## install / uninstall
`install` を呼んだら必ず対応する `uninstall` も呼び出さなければならない。
VTable を差し替えるときは古い vtable の `uninstall` → 新しい vtable の `install` の順（`setVTable` が内部で行う）。

---

## 利用例
利用者が直接 Component を生成することはほぼなく、widget（Label 等）の `create` または Application の factory が内部で組み立てる。
利用者から見える典型コードは label.md / application.md の利用例を参照。

派生 widget の Component メソッドにアクセスする場合の例。

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
label.component.setVTable(&my_vt);
```

## 機能要望
* `PropertyChangeListener` 相当 — setter からの変更通知。Swing PCE と同等
* Component 単位の `dirty` フラグ — 現状は Frame 単位で持つ（`{REPO_ROOT}/doc/layout-design.md` 参照）
