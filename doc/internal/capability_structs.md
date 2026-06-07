# capability-structs
Component に optional フィールドとして持たせる「能力構造体」 (capability struct) パターンの整理。
関数ポインタを内包した struct を `Component` の `?T` フィールドにし、必要な widget だけ中身を入れる。
Zig には継承も interface もないので、これが事実上の interface 表現になる。

このドキュメントでは:

* なぜ VTable や properties ではなくこの形にするのか
* Provider 型と Consumer 型の 2 サブパターン
* 新しく追加するときの判断フロー

を整理する。「将来きれいに整理したくなったとき」のための語彙合わせが目的。

## 立ち位置: VTable / properties との関係

Component には情報の持たせ方が現状 3 系統ある。

| 方式 | 性質 | コスト | 用途 |
|---|---|---|---|
| **VTable** (`*const VTable`) | 全 widget が必須 | 関数ポインタの分だけ全 widget が負担 | 描画 / イベント処理 / 寿命 — どの widget も実装する核 |
| **Capability 構造体** (本ドキュメント) | opt-in (optional フィールド) | null pointer 1 個 (使う widget だけ実体を持つ) | 「持つ widget だけがやる」性質の機能 (DnD, 折り返し, スクロール統合) |
| **Properties** (`StringHashMap`) | opt-in (HashMap 経由) | HashMap lookup + 型名比較 | 利用者の任意 attach (Swing `JComponent.putClientProperty` 相当) + 一部 framework-internal |

判断軸:

* **全 widget が必要**: VTable
* **一部の widget だけが持つが、framework が型を知っている**: Capability 構造体
* **任意のデータを利用者が attach する (型を framework が知らない)**: Properties

VTable に枠を増やすと、全 widget が使わない枠まで持つ。Capability 構造体なら null = 0 コスト。
逆に properties は HashMap allocation と lookup コストを払うので、framework が事前に知っている定型の接続点には重い。
**「framework が型を知っているが全員には使わせない接続点」**が capability の最適レンジ。

## サブパターン 1: Provider

widget が「この機能を提供する」と宣言するパターン。実装の中身は widget が書き、外 (= 親 layout や framework のコア) が呼ぶ。

### 形

```zig
pub const SizeQuery = struct {
    minHeightForWidth: *const fn (self: *const Component, w: f32) f32,
};
```

レシーバが `*const Component` (or `*Component`)。`user_data` は持たない。

### なぜ `user_data` を持たないか

実装側は widget なので、レシーバの `Component*` から `@fieldParentPtr` で外側 widget を復元できる:

```zig
fn minHeightForWidth(self: *const Component, w: f32) f32 {
    const ta: *TextArea = @constCast(@fieldParentPtr("component", self));
    // ta から好きにアクセス可能
    return ta.computeHeight(w);
}
```

クロージャ的なキャプチャは不要。`Component*` 自体が「環境」になる。

### 例

* `SizeQuery` — 親 layout が呼ぶ pure query (height-for-width)
* `Scrollable` — ScrollPane が読むヒント (関数ポインタはないが、optional struct で意図を表す capability)

## サブパターン 2: Consumer

widget が「外部のサービスを使う」ためのチャンネル。中身は外 (Window / ScrollPane / Frame) が install し、widget はそれを呼ぶ。

### 形

```zig
pub const FocusController = struct {
    user_data:         *anyopaque,
    request_focus_for: *const fn (*anyopaque, ?*Component) void,
};
```

`user_data` を持つ。レシーバが `*anyopaque` (= 実装側の任意オブジェクトへの opaque pointer)。

### なぜ `user_data` を持つか

実装側は widget ではなく Window や ScrollPane のような別オブジェクト。
レシーバが `*Component` でも、そこから Window* は復元できない (Window は Component を抱えるが、Component の `@fieldParentPtr` で取れる位置にいない)。
そこで install 時に Window* を `@ptrCast` して `user_data` に詰めておく。呼び出し時にそれを取り出して使う。

これはラムダの「環境キャプチャ」と完全に同型。C で関数オブジェクトを作る古典パターン (qsort の comparator, GTK signal handler, libuv callback) と同じ。

### install / 呼び出し

```zig
// Window が root container に install (Component は Window 型を知らない)
component.focus_controller = .{
    .user_data         = @ptrCast(window),
    .request_focus_for = focusImpl,
};

// widget (TextField 等) が呼ぶ
fn requestFocus(self: *Component) void {
    // 親を遡って FocusController を見つける
    var node: ?*Component = self;
    while (node) |cur| {
        if (cur.focus_controller) |fc| {
            fc.request_focus_for(fc.user_data, self);  // user_data でキャプチャ展開
            return;
        }
        node = cur.parent;
    }
}
```

### 例

* `FocusController` — Window が install、widget が `requestFocus` で利用
* `ScrollController` — ScrollPane が viewport に install、scrolled view (TextArea 等) が `scrollRectToVisible` で利用
* `DirtyNotify` — Window が install、Component が `markLayoutDirty` で利用

## ハイブリッド (Provider + user_data)

実装側が必ずしも widget 本体じゃない場合に、Provider 形に `user_data` を加える折衷もある。

```zig
pub const DragSource = struct {
    onDragStart: *const fn (self: *anyopaque, x: f32, y: f32) ?Transfer,
    user_data:   *anyopaque,
    // ...
};
```

例: List の DnD で「行ごとのドラッグ実装が List 全体を必要とする」場合、`user_data` に `*List` を入れて行から List にアクセスする。

「Provider だが実装の所在を後から差し替え可能にしたい」「コントローラ (controller object) パターンで widget の外に実装を出したい」場合に選ぶ。
完全に widget 内部実装で十分なら `*const Component` だけで足りる (= Pure Provider)。

## 早見表

| サブパターン | レシーバ | user_data | 例 |
|---|---|---|---|
| **Pure Provider** | `*const Component` (or `*Component`) | 不要 | `SizeQuery` |
| **Provider + 柔軟性** | `*anyopaque` | 要 | `DragSource`, `DropTarget` |
| **Pure Consumer** | `*anyopaque` | 要 | `FocusController`, `ScrollController`, `DirtyNotify` |

判別軸: **「実装側が Component から `@fieldParentPtr` で取れるオブジェクトか」**。

* Yes → Pure Provider で十分 (user_data なし)
* No (widget 外のオブジェクトが実装) → user_data が要る

## 新規追加時の判断フロー

新しい接続点が必要になったときの decision tree:

```
全 widget が実装する必要があるか?
├ Yes → VTable に追加 (高コスト判断、慎重に)
└ No → 一部 widget だけが持つ
    ├ framework が型を事前に知っているか?
    │  ├ Yes → Capability 構造体
    │  │   ├ 実装が widget 本体か?
    │  │   │  ├ Yes → Pure Provider (*const Component, user_data なし)
    │  │   │  └ No (外部オブジェクトが実装) → Consumer (user_data あり)
    │  │   │      or Provider + user_data ハイブリッド
    │  └ No (利用者が任意の型を attach する) → Properties (putTyped)
```

## 現状の inventory

2026-05-31 時点。

### Provider 系 (widget が実装、外が呼ぶ)
* `Scrollable` — フラグだけ (関数なし)。ScrollPane が読む
* `SizeQuery` — `minHeightForWidth` 1 個。height-for-width のための pure query
* `DragSource` — DnD ソース側 (`onDragStart` 他)。ハイブリッド (user_data あり)
* `DropTarget` — DnD ターゲット側 (`onOver`, `onDrop` 他)。ハイブリッド (user_data あり)

### Consumer 系 (外が install、widget が呼ぶ)
これらは現状 **`Component.properties` 経由** で install されている (`putTyped` / `getTyped`)。
将来 capability 構造体として direct field に移すかは未決定。動機は「Component 構造体定義に並べることで widget が持つ interface 一覧を 1 ヶ所で見えるようにする」程度で、機能面の理由は薄い。

* `FocusController` — Window が root container に install
* `ScrollController` — ScrollPane が viewport に install
* `DirtyNotify` — Window が root container に install

## 整理する場合のメモ

将来 Consumer 系も capability 構造体 (direct field) に昇格させるなら:

1. Component に `focus_controller: ?*const FocusController = null` 等を追加
2. install 側は `component.focus_controller = &fc` で直接代入 (properties.putTyped をやめる)
3. lookup 側は `component.focus_controller` で直接読む (getTyped をやめる)
4. `enclosingScrollController` 等の walk-up ロジックは形そのまま、HashMap lookup が field アクセスに置き換わるだけ

利点: Component の構造体定義に「この widget が持ちうる接続点」が全部並ぶ。framework 内部の plumbing と利用者の任意 attach (properties) が分離する。
欠点: Component 構造体サイズが (使う widget の有無に関わらず) ポインタ 3 個ぶん増える。

判断は cost-benefit 次第。現状は properties で動いていて性能問題もないので積極的にやる理由は薄い。**「整理したくなった瞬間に名前が揃っていて整理しやすい」**ことがこのドキュメントの目的。
