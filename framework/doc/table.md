---
unsafe: true
---

# table
複数カラム + ヘッダー付きの行テーブル (Swing `JTable` 相当の v1)。
行の仮想化 (可視範囲ぶんの実セル + recycle) は `List` と同じ VirtualFlow 方式で、
モデル・セルの契約も `List` と意図的に揃えている。設計の経緯・却下案は [narrative/table.md](narrative/table.md) を参照。

v1 のスコープ: 列定義 / ヘッダー描画 / ヘッダークリックのソート通知 / 列幅ドラッグ /
単一行選択 / 行アクティベーション / コンテキストメニュー。
セル編集・複数選択・伸縮列はスコープ外 (「機能要望」)。

## 型定義
```zig
pub const Table = struct {
    component:         Component,
    model:             *Model,            // 観測可能な行ソース (List.ListModel と同一型)
    owns_model:        bool,              // create 経由なら true、 createWithModel なら false
    columns:           []ColumnState,     // 列の定義 + 実行時状態 (Table が所有。 内部に列ごとのセルプール)
    selected:          ?usize,            // 単一行選択 (none = 未選択)
    row_height:        f32,               // 固定行高 (v1)
    sort_column:       ?usize,            // ソートインジケータ表示中の列 (none = 非表示)
    sort_direction:    SortDirection,
    has_focus:         bool,
    hovered:           ?*Component,       // ポインタが乗っているセル (hover 解除用、 List と同じ)
    header_drag:       ?HeaderDrag,       // 列幅ドラッグ中だけ non-null (内部状態)
    change_listeners:  ChangeListenerList,        // 選択変更
    action_listeners:  ActionListenerList,        // 行アクティベーション
    context_listeners: ContextMenuListenerList,   // コンテキストメニュー要求
    sort_listeners:    SortListenerList,          // ヘッダークリック
    allocator:         std.mem.Allocator,

    // ... メソッド
};

/// 行ソース。List.ListModel と同一の型 (行 = `*anyopaque` 借用 + ChangeListener)。
/// 同じモデルを List と Table の両ビューで共有できる (表示モード切替等)。
pub const Model = List.ListModel;

pub const SortDirection = enum { ascending, descending };
```

列の定義。`create` に渡すのは値の配列で、Table が内容をコピーして所有する
(`title` は dupe される。`factory` は List と同じく**借用** — 利用者が Table より長生きさせる)。

```zig
pub const Column = struct {
    title:     []const u8,
    width:     f32  = 120,   // 初期幅 (px)。 以後ドラッグで変わる
    min_width: f32  = 40,    // ドラッグ時の下限
    sortable:  bool = true,  // false ならクリックしてもソートイベントを発火しない
    factory:   CellFactory,  // この列のセルを生成する binder
};
```

セルの契約は `List` と同形 (実コンポーネントのサブツリー + `update` 投影 + recycle)。
`CellContext` に列番号が加わる点だけが違う。セルは**自分がどの列か知っている**ので、
行 item (`value`) から自分の列ぶんの表示を取り出すのはセルの仕事 — Table 本体は
行の中身を一切解釈しない (値取り出しのプロトコルを持たない。理由は narrative)。

```zig
pub const CellContext = struct {
    table:    *Table,
    value:    *anyopaque,   // この行の model item。 利用者がキャストする
    row:      usize,
    col:      usize,
    selected: bool,         // この行が選択中か
    focused:  bool,         // Table がフォーカスを持ち、 かつこの行が選択行か
};

pub const Cell = struct {
    component: *Component,
    update:    *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy:   *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    user_data: *anyopaque,
};

pub const CellFactory = struct {
    create:    *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell,
    user_data: *anyopaque,
};
```

ヘッダークリックの通知。**Table はソートしない** — 並べ替えは行 item の所有者 (アプリ) が
モデルに対して行い、Table はインジケータ表示とこのイベントだけを担う (理由は narrative)。

```zig
pub const SortEvent = struct {
    source:    *anyopaque,
    column:    usize,
    direction: SortDirection, // クリックで遷移した後の向き
};
```

コンテキストメニュー要求 (`List.ContextMenuEvent` と同形。横断の汎用化は framework#8)。

```zig
pub const ContextMenuEvent = struct {
    source: *anyopaque,
    row:    ?usize,
    x:      f32,    // ウィンドウ座標。そのまま PopupMenu.show に渡せる
    y:      f32,
};
```

### レイアウトと仮想化
* 内容は上から「ヘッダー行 (高さ固定) + データ行 × N」。行高は固定 (`row_height`)。
* 行は List と同じ可視範囲 + recycle。プールは**列ごと**に持ち、セル (row, col) は
  `x = 列の累積幅, y = ヘッダー高 + row × row_height, w = 列幅, h = row_height` に置かれる。
* `min_size` は幅 = 全列幅の合計、高さ = ヘッダー高 + 行数 × 行高。幅は viewport に追従**しない**
  (`scrollable` ヒントなし) — 列幅の合計が viewport を超えたら ScrollPane が横スクロールを出す。
* ScrollPane に入れて縦スクロールしても**ヘッダーは上端に固定表示**される
  (固定の仕掛けは内部実装。利用者は ScrollPane に入れるだけでよい)。

### ヘッダーの操作
* **タイトル部のクリック** — `sortable` な列なら、ソート状態を遷移させ
  (別の列 → その列の ascending、同じ列 → 向きを反転)、インジケータ (▲ / ▼) を更新し、
  `SortEvent` を発火する。並べ替え自体はリスナー側 (アプリ) がモデルに行う。
* **列境界 (境界 ±数 px) のドラッグ** — 左側の列の幅を変更する。`min_width` でクランプ。
  ドラッグ中は連続レイアウト (SplitPane のディバイダーと同じ方針)。
* 描画は既定 LAF の paint が `component.theme` を読む (専用フィールドは追加しない:
  ヘッダー背景 = `surface_window`、文字 = `text`、境界 = `border_soft`、インジケータ = `accent`)。

### キーボード / マウス
`List` と同じ: クリックで行選択 + フォーカス、↑↓ で選択移動 (可視域へ追従)、
左ダブルクリック / Enter で行アクティベーション、右プレスで行選択 + コンテキストメニュー発火。
編集は無いので、アクティベーションが編集トリガに横取りされる場合分けも無い。

## 関数定義

### 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    columns: []const Column,
) !*Table;
```

空の `Model` を内部生成して所有し (`owns_model = true`)、`columns` の内容をコピーして
(`title` は dupe、`factory` は借用) `Table` をヒープに返す。
`selected` / `sort_column` は none、`row_height` は既定値、プールは空で始まる。

ファクトリ:
```zig
const table = try app.table(&.{
    .{ .title = "Name", .width = 240, .factory = name_factory },
    .{ .title = "Size", .width = 80,  .factory = size_factory },
});
```

#### 失敗時の保証
失敗時は途中で確保した分をすべて解放する。

#### 事前条件
* `columns.len >= 1`。
* 各 `factory` (とその `user_data`) の寿命が Table 以上であること (借用)。

### 共有モデルでの生成
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *Model,
    columns: []const Column,
) !*Table;
```

利用者が事前に作った `model` を借用する (`owns_model = false`)。`destroy` で解放しない。

### 破棄
`vtable.destroy(table.asComponent(), allocator)` で破棄する。
全列のプール内セル (`cell.destroy`)、列定義 (dupe した title 含む) を解放する。
`factory` 自身には触れない。`owns_model` が true のときのみ `model` を解放する。

### コンポーネントの取得
```zig
pub fn asComponent(self: *Table) *Component;
```

### 選択の取得 / 設定
```zig
pub fn getSelected(self: Table) ?usize;
pub fn setSelected(self: *Table, idx: ?usize) void;
```

`List` と同じ契約: 範囲外は none に丸め、変化したときだけ `change_listeners` 発火 + 再描画。
行 index は**モデル順そのもの** (view 側の並び替え写像は存在しない。narrative 参照)。
アプリがソートでモデルを並べ替えた場合、選択 index の指す行は変わる —
選択を維持したいアプリは並べ替え後に item を探して選択し直す (app_filer の
リネーム後再選択と同じ手)。

### 行高の取得 / 設定
```zig
pub fn getRowHeight(self: Table) f32;
pub fn setRowHeight(self: *Table, h: f32) void;
```

### 列幅の取得 / 設定
```zig
pub fn getColumnWidth(self: Table, col: usize) f32;
pub fn setColumnWidth(self: *Table, col: usize, width: f32) void;
```

`set` は `min_width` でクランプして再レイアウトを要求する (ドラッグと同じ経路)。
範囲外の `col` は no-op (`get` は 0 を返す)。

### ソートインジケータの取得 / 設定
```zig
pub fn getSortColumn(self: Table) ?usize;
pub fn getSortDirection(self: Table) SortDirection;
pub fn setSortIndicator(self: *Table, column: ?usize, direction: SortDirection) void;
```

`setSortIndicator` は表示だけを変える (イベントは発火しない)。
アプリが起動時に「最初から Name 昇順で出す」等の初期状態を示すために使う
(並べ替え自体はアプリが既にモデルに施している前提)。

### 選択変更リスナー
```zig
pub fn addChangeListener   (self: *Table, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

### 行アクティベーションリスナー
```zig
pub fn addActionListener   (self: *Table, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeActionListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
```

左ダブルクリック / 選択行での Enter で発火。対象行は `getSelected()`。

### コンテキストメニューリスナー
```zig
pub fn addContextMenuListener   (self: *Table, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) !void;
pub fn removeContextMenuListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) void;
```

`List` と同じ契約 (右プレスで選択 + フォーカスを済ませてから発火)。ヘッダー上の右プレスでは発火しない。

### ソートリスナー
```zig
pub fn addSortListener   (self: *Table, comptime T: type, comptime f: fn (*T, *const SortEvent) void, user_data: *T) !void;
pub fn removeSortListener(self: *Table, comptime T: type, comptime f: fn (*T, *const SortEvent) void, user_data: *T) void;
```

`sortable` な列のヘッダータイトルがクリックされ、インジケータが更新された後に発火する。
リスナーは `e.column` / `e.direction` に従ってモデルを並べ替える
(モデル変更通知で Table は自動で再投影される)。

---

## 利用例
ファイラーの詳細表示 (名前 / サイズ / 更新日時)。行 item はアプリ所有の `*Entry`。

```zig
const Entry = struct { name: []u8, size: u64, mtime: i64, is_dir: bool };

// 列ごとのセル: 自分の列の値を Entry から取り出して投影する
const NameCell = struct {
    label: *nimbus.Label,
    fn update(ud: *anyopaque, ctx: nimbus.Table.CellContext) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.label.setText(e.name) catch {};
    }
    // destroy / create は List のセルと同じ流儀
};

const table = try app.table(&.{
    .{ .title = "Name",     .width = 260, .factory = name_factory },
    .{ .title = "Size",     .width = 90,  .factory = size_factory },
    .{ .title = "Modified", .width = 140, .factory = mtime_factory },
});

// ソートはアプリの仕事: ヘッダークリック → 自分の配列を並べ替えてモデルへ反映
fn onSort(s: *State, e: *const nimbus.Table.SortEvent) void {
    s.sortEntries(e.column, e.direction); // entries を並べ替え、 model を clear + add し直す
}
try table.addSortListener(State, onSort, &state);
table.setSortIndicator(0, .ascending); // 初期表示は Name 昇順 (並べ替え済み前提)

const sp = try app.scrollPane(table.asComponent());
sp.asComponent().setGrowX(1);
sp.asComponent().setGrowY(1);
```

## 機能要望
* セル編集 (List の CellEdit 相当。ファイラー詳細表示でのインプレースリネームに必要)
* 複数選択 (framework#10。List と選択モデルを共有する形で)
* 伸縮列 (列に grow を与え、 余り幅を配る。 ファイラーの Name 列が欲しがる)
* 列のドラッグ並べ替え / 表示・非表示の切り替え
* `ListModel.move` 級のモデル並べ替え op (`sortInPlace` 等) — 現状の clear + add 再投入は
  行数が多いと通知が冗長 (まとめ通知の仕組みと合わせて)
* PageUp / PageDown / Home / End のキーボードナビゲーション
* 行の zebra ストライプ / グリッド線の表示オプション (テーマ拡張と合わせて)
* ScrollPane の columnHeader 領域方式への移行検討 (scrollpane.md 機能要望と対応)
