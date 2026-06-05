---
unsafe: true
---

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
`Component` の optional フィールドとして持つ (property バッグや @typeName キーは使わない — これはビュー固有の静的属性なので、 付け外しの動的さが要らず、 素の変数が素直):

```zig
// Component.zig
pub const Scrollable = struct {
    tracks_viewport_width:  bool = false,
    tracks_viewport_height: bool = false,
};

scrollable: ?Scrollable = null,   // Component のフィールド。既定 null
```

ビューウィジェット (`TextArea` 等) が自分で `self.component.scrollable = .{ .tracks_viewport_width = true }` のように代入する。
`ScrollPane` はサイズ決定時に `view.scrollable` を読み、 `null` なら「両軸とも自然サイズ」として扱う (後述「サイズ決定とビューの契約」)。

### ビューの height-for-width クエリ (`Component.size_query`)
追従軸での「この幅での最小高さ」を問い合わせるための、 これも `Component` の optional フィールド (`component.md`「SizeQuery」参照)。
折り返しビュー (wrap mode の `TextArea` 等) が `scrollable.tracks_viewport_width = true` と一緒に `size_query = .{ .minHeightForWidth = ... }` をセットする。

`ScrollPane` は追従軸が tracked の場合、 `view.size_query` が non-null なら `minHeightForWidth(view, w)` を呼んで自由軸 (高さ) を決める。 `size_query` が null なら `view.effectiveMinSize()` の値を使う。
これは pure query なので副作用がない (= ビュー自身の `min_size` を書き換えない)。 詳細な契約は後述「サイズ決定とビューの契約」。

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

## 矩形を可視域へスクロール
```zig
pub fn scrollRectToVisible(self: *ScrollPane, rect: Component.Rect) void;
```

`rect` (ビューのローカル座標、 0 = ビュー左上) がビューポート内に入るよう、 必要最小限だけスクロールする。
ビューが自分のキャレットなどを見せ続けるために使う (例: `TextArea` のキャレット追従)。
ビューポートより大きい矩形は先頭側に寄せる。
スクロール量は内部でモデルの有効範囲にクランプされる。

ビューはこれを直接呼ぶのではなく、 `Component.enclosingScrollController` で囲っている `ScrollPane` を見つけて経由する (後述「ScrollController の設置」)。

## ChangeListener
```zig
pub fn addChangeListener   (self: *ScrollPane, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *ScrollPane, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

スクロール位置が変わると発火する (どちらの軸でも)。

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
