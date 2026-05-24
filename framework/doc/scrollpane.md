# scrollpane
1 つのコンポーネント (ビュー) を、それより小さい矩形 (ビューポート) 越しに表示し、はみ出した分を水平 / 垂直にスクロールできるようにするコンテナー。
Swing の `JScrollPane` 相当。

## 型定義
```zig
pub const ScrollPane = struct {
    component:      Component,
    view:           *Component,       // コンテンツ (所有)
    viewport:       Container,        // ビューを 1 個だけ抱える内部コンテナー (クリップ + オフセット用)
    hbar:           *ScrollBar,       // 水平バー (所有)
    vbar:           *ScrollBar,       // 垂直バー (所有)
    h_policy:       Policy,
    v_policy:       Policy,
    unit_increment: f32,              // ホイール 1 ノッチのスクロール量 (px)
    allocator:      std.mem.Allocator,
};

pub const Policy = enum {
    as_needed,  // コンテンツがビューポートを超える軸だけバーを出す (既定)
    always,     // 常にバーを出す
    never,      // バーを出さない (ホイール / プログラムでのスクロールは可)
};
```

### ビューのスクロール挙動宣言 (`Component.scrollable`)
ビューが「ビューポートのサイズに追従する」ことを宣言するためのオプショナルなヒント。
`DirtyNotify` / `FocusController` と同じく `Component` に定義し、 **`Component` の optional フィールドとして持つ** (property バッグや @typeName キーは使わない — これはビュー固有の静的属性なので、 付け外しの動的さが要らず、 素の変数が素直):

```zig
// Component.zig
pub const Scrollable = struct {
    tracks_viewport_width:  bool = false,
    tracks_viewport_height: bool = false,
};

scrollable: ?Scrollable = null,   // Component のフィールド。既定 null
```

ビューウィジェット (将来の `TextArea` 等) が自分で `self.component.scrollable = .{ .tracks_viewport_width = true }` のように代入する。
`ScrollPane` はサイズ決定時に `view.scrollable` を読み、 `null` なら「両軸とも自然サイズ」として扱う (後述「サイズ決定とビューの契約」)。

`viewport` は内部実装の詳細で、 普通の `Container` をそのまま使う。
`Container` は子に配る前に `containsWindowPoint` で門番し (`container.md`)、 描画は `paintAt` が bounds でクリップする。
ビューを `viewport` の唯一の子として offset 位置に置くだけで、 **スクロールの描画クリップも当たり判定の絞り込みも既存機構でそのまま成立する** (専用のクリップ / ヒットテストコードは要らない)。

## 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    view: *Component,
) !*ScrollPane;
```

`view` を内部 `viewport` の子として取り込み (所有権が移る)、 水平 / 垂直の `ScrollBar` を作って `ScrollPane` をヒープに返す。
ポリシーは両軸 `as_needed`、 `unit_increment` は既定値 (初版 40px) で始まる。
失敗時は途中で確保した分をすべて解放する。

ファクトリ:
```zig
const sp = try app.scrollPane(&content.component);
```

### 事前条件
* `view` がまだどのコンテナーにも add されていないこと (multi-mount は未対応)。

## 破棄
`vtable.destroy(sp.asComponent(), allocator)` で破棄する。
`view` (および推移的にその子)、 `hbar` / `vbar`、 内部 `viewport` をすべて解放する。
通常は親コンテナーの `deinit` 経由で間接的に呼ばれる。

## ビューの取得 / 差し替え
```zig
pub fn getView(self: ScrollPane) *Component;
pub fn setView(self: *ScrollPane, view: *Component) void;
```

`setView` は現在のビューを破棄して新しいビューに差し替える (所有権が移る)。
スクロール位置は 0 にリセットされ、 再レイアウトされる。

## スクロール位置の取得 / 設定
```zig
pub fn getScrollX(self: ScrollPane) f32;
pub fn getScrollY(self: ScrollPane) f32;
pub fn setScrollX(self: *ScrollPane, px: f32) void;
pub fn setScrollY(self: *ScrollPane, px: f32) void;
```

スクロールオフセット (ビュー左上をビューポート左上からどれだけ隠したか) を px で扱う。
`set` は有効範囲 `[0, コンテンツ長 - ビューポート長]` にクランプする。
内部的にはバーの `BoundedRangeModel.value` を更新し、 その `ChangeListener` 経由でビューの位置が更新される。

## ポリシーの設定
```zig
pub fn setHorizontalPolicy(self: *ScrollPane, policy: Policy) void;
pub fn setVerticalPolicy(self: *ScrollPane, policy: Policy) void;
```

## ホイール量の設定
```zig
pub fn setUnitIncrement(self: *ScrollPane, px: f32) void;
```

ホイール 1 ノッチで動くスクロール量。
将来ビューが `Scrollable` で行高などのヒントを出せるようになれば、 そちらを優先する余地を残す (機能要望)。

## ChangeListener
```zig
pub fn addChangeListener   (self: *ScrollPane, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeChangeListener(self: *ScrollPane, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
```

スクロール位置が変わると発火する (どちらの軸でも)。

---

## 構成
`ScrollPane` は自前 vtable を持つ複合コンポーネントで、 3 つの領域を抱える:

```
+-----------------------------+--+
| viewport (center)           |vb|  vb = 垂直 ScrollBar (east gutter)
|   └ view (offset 配置)       |ar|
|                             |  |
+-----------------------------+--+
| hbar (south gutter)         |  |  hbar = 水平 ScrollBar
+-----------------------------+--+
                              corner (小さな filler)
```

* `viewport` / `hbar` / `vbar` は**互いに重ならない矩形**を占める。 これにより `ScrollPane` のイベント配送は領域ごとにきれいに分かれ、 はみ出したビューへの誤クリックは起きない (重なりを避けるために viewport を独立させている)。
* バーは `as_needed` のとき必要な軸だけ表示する。 非表示の軸では gutter を畳んで viewport がその分広がる。
* スクロールの単一の真実は **バーの `BoundedRangeModel`**。 ホイールやプログラム設定はバーの `value` を更新し、 その `ChangeListener` で `viewport` 内のビュー位置 (`view.position = {-h.value, -v.value}`) を更新して repaint する。

メニュー系のようなオーバーレイ / dismiss / 専用 dispatch は一切使わない。 `ScrollBar` も `viewport` も通常のコンポーネントツリーの一部である。

## サイズ決定とビューの契約
レイアウト時、 軸ごとにビューのサイズを次のように決める:

* `view.scrollable` が `null` (既定): その軸は **ビューの自然サイズ** (`effectiveMinSize`) を使う。 自然サイズ > ビューポートならスクロールバーを出す。 自然サイズがビューポート以下ならビューをビューポートいっぱいに広げる (`max(自然, ビューポート)`)。
* `scrollable.tracks_viewport_width = true`: ビューの**幅をビューポート内幅に固定**し、 その軸はスクロールしない。
* `scrollable.tracks_viewport_height = true` も同様 (縦方向)。

### height-for-width の扱い (TextArea 折り返しのための前提)
折り返すビュー (将来の `TextArea` wrap モード等) では、 高さが幅に依存する。
そこで ScrollPane は **「幅を確定してからビューの高さを読む」** 順序でレイアウトする:

1. ビューの幅を確定する (追従ならビューポート内幅、 でなければ `max(自然幅, ビューポート幅)`)。
2. その幅でビューを `setBounds` → `doLayout` する。
3. **ビューの高さを読み直す** (折り返した結果の高さ)。 これで垂直スクロール範囲を決める。

このときビュー側に課す契約は **「幅が変わったら (= `setBounds` で新しい幅を受けたら) 内容を測り直して自分の `min_size.height` を更新すること」**。
nimbus に汎用の height-for-width クエリは無いので、 「ScrollPane が幅をセット → ビューが高さを再計算 → ScrollPane が読む」 の 2 段でそれを代用する。
通常の (折り返さない) ビューはサイズが幅に依存しないので、 この契約は自動的に満たされる。

これにより `TextArea` の 2 モードが**公開 API を変えずに**載る:

| `TextArea` モード | 宣言 | 挙動 |
|---|---|---|
| 折り返しなし (overflow) | `scrollable = null` | 最長行の自然幅 → 水平にもスクロール (既定パス) |
| 折り返しあり (wrap) | `scrollable.tracks_viewport_width = true` | 幅をビューポートに固定 → 折り返して高さが伸びる → 垂直のみスクロール |

### スクロールバー表示の相互作用
垂直バーを出すと内幅が減り、 折り返しや横はみ出しが変わって水平バーの要否が変わる、 という相互依存がある。
これは「ポリシーから仮定して数パス回す」形で収束させる (アルゴリズム詳細はソースコメント領分)。

## イベント処理
* `viewport` 上のホイール (`.scroll`) → 縦は `vbar`、 `Shift` 併用で横は `hbar` の `value` を `unit_increment` 分動かす。
* `hbar` / `vbar` 上の操作 → 各 `ScrollBar` が処理 (ドラッグ / トラッククリック、 `scroll_bar.md` 参照)。
* それ以外 → `viewport` 経由でビューに配送 (`Container` の門番 + オフセット位置で自動的に正しく当たる)。

## レイアウト (ScrollPane 自身のサイズ)
`ScrollPane` の `min_size` は**コンテンツの大きさに依存しない** (依存させるとスクロールの意味が無い)。
初版では小さめの既定推奨サイズを返し、 利用者が `setGrowX/Y` やレイアウトで広げて使う想定。
`BorderLayout.center` に置く、 あるいは `setGrowX(1)` + `setGrowY(1)` で領域いっぱいに広げるのが典型。

## 寿命
`ScrollPane` は `view` / `hbar` / `vbar` / 内部 `viewport` をすべて所有し、 `destroy` で再帰的に解放する。
`view` は `viewport` の子として登録されるので、 `viewport.deinit` (= `Container.deinit`) が `view` の `destroy` を呼ぶ。
利用者は `view` を別途解放してはならない (所有権は ScrollPane に移っている)。

---

## 利用例
大きな内容をスクロール領域に入れる典型コード。

```zig
// スクロールさせたい中身 (ビューポートより大きく育つコンテナー)
const content = try app.container();
content.setLayout(nimbus.BoxLayout.vertical());
for (0..50) |i| {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "item {d}", .{i});
    try content.add(&(try app.label(text)).component);
}

const sp = try app.scrollPane(&content.component);
sp.asComponent().setGrowX(1);
sp.asComponent().setGrowY(1);

try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());
```

## 機能要望
* 可視範囲カリング: 現状はオフスクリーンの子も `paint` が呼ばれる (描画自体は空シザーで早期 return するので GPU 仕事は無いが、 ツリー巡回コストは残る)。 巨大なコンテンツ (数千行) では、 ビューポート外の子の巡回をスキップする仮想化が要る
* `Component.scrollable` のヒント拡張 (`unit_increment` / `block_increment` をビューが行高ベースで返す)
* 行 / 列ヘッダー + コーナー (Swing `JScrollPane` の rowHeader / columnHeader。 表計算 / テーブル向け)
* スクロール位置のアニメーション (慣性 / スムーズスクロール)
* キーボードスクロール (フォーカス時の PageUp/Down、 矢印)
* ビューポートサイズ基準の推奨サイズ指定 (`setPreferredViewportSize`)
* 自動スクロール (ドラッグで端に寄せると送る、 D&D 連携)
