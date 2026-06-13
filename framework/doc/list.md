---
unsafe: true
---

# list
item を縦に並べて表示し、 項目を選択できるウィジェット (単一 / 複数)。
Swing の `JList` 相当だが、 セルの実現方法は JavaFX の `ListView` (内部の VirtualFlow) に倣う。

セルは実体のあるコンポーネント部分木で、 **可視範囲＋少しのバッファぶんだけ生成**する。
スクロールで画面外に出たセルは破棄せず、 新しく現れた行へ **再利用 (リサイクル)** する。
これによりメモリは総行数 N ではなく可視行数に比例し (O(可視))、 かつセルが実体なので描画もイベント処理もウィジェット本来の機構をそのまま使える。

v1 スコープ:
* 単一 / 複数選択 (`SelectionModel` を共有。 既定は単一)
* 固定の行高 (可変行高は機能要望)
* セルは既定で 読み取り専用 (項目の値をセルへ投影するだけ)。 セル内のボタン等は押せる。
  加えて、 `Cell.edit` を与えたセルは編集モード (セル内テキスト編集) を持てる (「セルの編集 (CellEditor)」を参照)

## 型定義
```zig
pub const List = struct {
    component:        Component,
    model:            *ListModel,         // 観測可能な item ソース
    owns_model:       bool,               // create 経由なら true、 createWithModel なら false
    factory:          CellFactory,        // 実セルを生成する binder (借用)
    selection:        SelectionModel,    // 選択状態 (単一 / 複数。 Table と共有)
    row_height:       f32,                // 固定行高 (v1)
    pool:             std.ArrayList(PooledCell), // 可視範囲を覆う実セル群 (List が所有)
    has_focus:        bool,               // キーボードフォーカス保持中か (ctx.focused 用)
    hovered:          ?*Component,         // ポインタが乗っているセル (hover 解除用、 後述)
    editing:          ?usize,             // 編集中の行 (高々 1 つ。 読み取り専用なら常に none)
    edit_trigger:     EditTrigger,        // 編集開始トリガ (既定 .double_click_or_enter)
    focus_lost:       FocusLostPolicy,    // 編集中フォーカス喪失時の決着 (既定 .commit)
    change_listeners: ChangeListenerList, // 選択変更通知
    action_listeners: ActionListenerList, // 行アクティベーション通知 (後述)
    context_listeners: ContextMenuListenerList, // コンテキストメニュー要求 (後述)
    allocator:        std.mem.Allocator,

    // ... メソッド
};

const PooledCell = struct {
    cell: Cell,
    row:  ?usize,   // 現在束縛している行 (none = 余り / 非表示)
};
```

実セルを 1 つ生成する factory。
プールを増やすとき (可視範囲が広がり手持ちのセルが足りないとき) に呼ばれ、 **毎回新しいインスタンス**を返す。
返ったセルの所有権は List (プール) に移る。

```zig
pub const CellFactory = struct {
    create:    *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell,
    user_data: *anyopaque,
};
```

1 つの実セル。
`component` がセル部分木のルートで、 leaf (Label 等) でも `Container` (ラベル + ボタン等) でもよい。
`update` は JavaFX の `updateItem` 相当で、 そのセルを ある行のデータに束縛し直す ときに呼ばれる (生成直後とリサイクル時)。
`edit` は編集可能セルだけが持つ任意の編集ライフサイクルで、 読み取り専用セルは null のまま (「セルの編集 (CellEditor)」を参照)。

```zig
pub const Cell = struct {
    component: *Component,   // セル部分木のルート (この Cell が所有)
    update:    *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy:   *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    edit:      ?CellEdit = null,   // null = 読み取り専用 (編集不可)
    user_data: *anyopaque,   // セルごとの状態構造体 (factory が new したもの)
};
```

セルが編集可能なら `edit` に編集ライフサイクルを与える。
`start` で編集モードへ入り (部分木をスクラッチ入力へ差し替え、 item で seed)、 `commit` でスクラッチを item へ書き戻し、 `cancel` で破棄して表示モードへ戻す。

```zig
pub const CellEdit = struct {
    start:  *const fn (self: *anyopaque, ctx: CellContext) void,
    commit: *const fn (self: *anyopaque) void,
    cancel: *const fn (self: *anyopaque) void,
};
```

編集の開始トリガと、 編集中にスクラッチがフォーカスを失ったときの決着方針。

```zig
pub const EditTrigger = enum {
    double_click,
    enter,
    double_click_or_enter,   // 既定
    manual,                  // edit(idx) のみ。 UI からは開始しない
};

pub const FocusLostPolicy = enum {
    commit,   // 既定。 フォーカス喪失で確定
    cancel,   // フォーカス喪失で取り消し
};
```

`update` に渡るコンテキスト。
`value` は行の item で、 `selected` / `focused` は item には無い List 側の事実なので、 ここで供給して投影させる。

```zig
pub const CellContext = struct {
    list:     *List,
    value:    *anyopaque,   // この行の model item。 利用者がキャストする
    index:    usize,        // 束縛する行
    selected: bool,         // この行が選択中か
    focused:  bool,         // List がフォーカスを持ち、 かつこの行が選択行か
};
```

観測可能な item ソース。
item は型を持たない `*anyopaque` として **借用** で保持する (item の実メモリは利用者が所有し、 List / ListModel より長生きさせる)。

```zig
pub const ListModel = struct {
    items:            std.ArrayList(*anyopaque),
    change_listeners: ChangeListenerList,
    allocator:        std.mem.Allocator,

    // ... メソッド
};
```

`ListModel` は `model.md` の標準パターン (状態 + `ChangeListenerList` の embed) に従う。
item の追加 / 削除で `change_listeners.fire()` を呼び、 List はそれを購読してプールを再調整 + 再レイアウト + 再描画する。

## List の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    factory: CellFactory,
) !*List;
```

空の `ListModel` を内部生成して所有し (`owns_model = true`)、 `factory` を借用して `List` をヒープに返す。
`selection` は空、 `row_height` は既定値、 `pool` は空で始まる (最初のレイアウトで可視範囲ぶん生成する)。
失敗時は途中で確保した分をすべて解放する。

ファクトリ:
```zig
const list = try app.list(my_factory);
```

## 共有モデルでの生成
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ListModel,
    factory: CellFactory,
) !*List;
```

利用者が事前に作った `model` を借用する (`owns_model = false`)。
`model.md`「Model の所有モデル」に従い、 借用したモデルは `destroy` で解放しない。

## List の破棄
```zig
pub fn destroy(self: *List, allocator: std.mem.Allocator) void;
```

`pool` 内のすべてのセルを `cell.destroy` で解放する (factory が生成したインスタンスの所有者は List)。
`factory` 自身には触れない (借用。 「寿命」を参照)。
`owns_model` が true のときのみ内部生成した `model` を解放する。

## コンポーネントの取得
```zig
pub fn asComponent(self: *List) *Component;
```

公開 `Component` (`&self.component`) を返す。 `ScrollPane` に入れる / レイアウトに追加する際に使う。

## 選択の取得 / 設定
選択は `SelectionModel` が持つ (Table と共有する型。 `selection_model.md` 参照)。
List はその薄いラッパとして単一・複数の API を出す。

```zig
pub fn getSelected(self: List) ?usize;             // lead (現在行)
pub fn setSelected(self: *List, idx: ?usize) void; // その 1 行だけを選択 (他を解除)
pub fn getSelectedIndices(self: List) []const usize; // 昇順。 借用、 次の選択変更まで有効
pub fn isSelected(self: List, i: usize) bool;
pub fn clearSelection(self: *List) void;
pub fn setSelectionMode(self: *List, mode: SelectionModel.Mode) void; // .single (既定) / .multiple
```

選択が変化したときだけ `change_listeners` を発火 + repaint する (不変なら no-op)。
変化時は可視セルを `update` し直して選択表示を投影し、 List 自身が選択行の背景を描く (「描画」参照)。
範囲外の index は none に丸める。

入力ジェスチャ (既定 `.single` では常に単一に畳まれる):
* プレーン click / ↑ ↓ — その行だけを選択 (lead 移動)
* ctrl+click — その行の選択をトグル
* shift+click / shift+↑ ↓ — anchor からの範囲を選択
* 右 click — 未選択行ならその行だけ選択。 選択済み行なら選択を保つ (一括操作のため)

## 行高の取得 / 設定
```zig
pub fn getRowHeight(self: List) f32;
pub fn setRowHeight(self: *List, h: f32) void;
```

固定行高を更新する。
値が変わったら内容の総高 (`min_size.height`) を再計算して `markLayoutDirty` + repaint する (総高と可視行数が変わるため)。

## 選択変更リスナー
```zig
pub fn addChangeListener   (self: *List, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *List, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

選択が変化した瞬間に発火する。
hover やセル内ボタンの押下では発火しない (それらはセルが配線したコールバックの領分)。

## 行アクティベーションリスナー
```zig
pub fn addActionListener   (self: *List, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeActionListener(self: *List, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
```

行が「開かれた」ときに発火する。 発火条件は次の 2 つで、 いずれも**そのジェスチャで編集が始まらなかった場合のみ**
(編集トリガが先取りする。 セルが読み取り専用 = `Cell.edit` が null なら常にアクティベーション側に落ちる):
* 行への左ダブルクリック
* 選択行がある状態での Enter

アクティベートされた行は `getSelected()` で得る (選択がアクティベーションに先行する契約)。
ファイル一覧の「シングルクリック = 選択、 ダブルクリック / Enter = 開く」がこの API の想定ユースケース。
動く例は `{REPO_ROOT}/examples/app_filer`。

## コンテキストメニューリスナー
```zig
pub const ContextMenuEvent = struct {
    source: *anyopaque,
    row:    ?usize, // ヒットした行 (non-null なら発火前に選択済み)。null = 行の無い領域
    x:      f32,    // ウィンドウ座標。そのまま PopupMenu.show に渡せる
    y:      f32,
};

pub fn addContextMenuListener   (self: *List, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) !void;
pub fn removeContextMenuListener(self: *List, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) void;
```

List 上の**右プレス**で発火する。発火前に List は次を済ませる:
* 編集中で、 押下が編集行の外なら `FocusLostPolicy` に従い編集を決着する (左プレスと同じ規則)
* フォーカスを取り、 ヒットした行があればそれを選択する

メニュー自体は List は持たない。 アプリ側がリスナー内で自前の `PopupMenu` を
`popup.show(window, e.x, e.y)` で出す。
現状 `Component` は生のマウスリスナーを公開していないため、 右クリックのフックは List が提供している。
コンポーネント横断の汎用化は検討中 — framework バックログ参照。
動く例は `{REPO_ROOT}/examples/app_filer`。

## セルの編集 (CellEditor)
```zig
pub fn edit              (self: *List, idx: usize) void;
pub fn commitEdit        (self: *List) void;
pub fn cancelEdit        (self: *List) void;
pub fn getEditing        (self: List) ?usize;
pub fn setEditTrigger    (self: *List, t: EditTrigger) void;
pub fn setFocusLostPolicy(self: *List, p: FocusLostPolicy) void;
```

`edit` は `idx` 行の編集を開始する。
別の行が編集中なら先に確定 (`commitEdit`) し、 対象行を可視範囲へスクロール + 実体化してからそのセルの `edit.start` を呼ぶ。
範囲外、 またはセルの `edit` が null (読み取り専用) なら no-op。
`commitEdit` は編集中セルに `edit.commit` を呼ばせてスクラッチを item へ書き戻し、 表示モードへ戻して再投影する。
`cancelEdit` は `edit.cancel` でスクラッチを破棄し、 item は変えない。
どちらも編集中でなければ no-op で、 終了後はフォーカスを List 本体へ戻す (矢印キー操作のため)。
`getEditing` は編集中の行 (なければ none)。 `setEditTrigger` / `setFocusLostPolicy` は開始トリガ / フォーカス喪失時の決着を変更する。

同時に編集状態になるセルは高々 1 つ。
編集中の行は reconcile で投影 (`update`) をスキップし、 プールへ返さない (リサイクルしない)。
そのため、 キャレットや IME 未確定文字が投影で消えたりセルが別行へ束縛し直されたりしない (設計の根拠は narrative 参照)。
編集中のキーは固定で `Enter` = commit、 `Escape` = cancel。
動く例は `{REPO_ROOT}/examples/widget_listedit`。

---

## ListModel の関数
### 生成
```zig
pub fn init(allocator: std.mem.Allocator) ListModel;
```

空のモデルを返す。 内部の動的アロケーションは最初の `add` まで遅延される。

### 破棄
```zig
pub fn deinit(self: *ListModel) void;
```

`items` の内部バッファと `change_listeners` を解放する。
item の指す先 (借用) には触れない。

### item の追加 / 削除 / クリア
```zig
pub fn add   (self: *ListModel, item: *anyopaque) !void;
pub fn remove(self: *ListModel, idx: usize) void;
pub fn clear (self: *ListModel) void;
```

いずれも構造が実際に変わったときに `change_listeners.fire()` を呼ぶ。
`remove` は範囲外なら no-op。

### item の移動
```zig
pub fn move(self: *ListModel, from: usize, to: usize) void;
```

`from` 位置の item を `to` 位置 (移動前のインデックスで 0..=size) へ移し替える。 行の drag-to-reorder で使う (`dnd.md`「List の行並べ替え」)。
`from` が範囲外、または順序が変わらない移動なら no-op。 構造が変わったときだけ `change_listeners.fire()` する。

### サイズ / 要素アクセス
```zig
pub fn getSize     (self: ListModel) usize;
pub fn getElementAt(self: ListModel, idx: usize) ?*anyopaque;
```

`getElementAt` は範囲外なら null。 返り値の解釈 (実型) は呼び出し側の責任。

## 利用例
ラベル + 削除ボタンを持つ interactive なセルの List。
セルは factory がインスタンスごとに生成し、 自分の行番号を `update` で覚える。

```zig
const Row = struct { name: []const u8 };

// factory はセル生成時に List を参照したい (onDelete で行を消すため) が、 List は
// factory を登録してから生成されるので、 user_data には「後から list を埋める」
// コンテキストを渡す。 factory は最初の paint (reconcile) まで呼ばれないので間に合う。
const Ctx = struct { app: *Application, list: *List = undefined };

// 1 セルぶんの実体 (factory が行数ぶんではなく可視ぶんだけ new する)
const TaskCell = struct {
    root:        *Panel,
    label:       *Label,
    delete_btn:  *Button,
    list:        *List,
    current_row: usize = 0,   // update が毎回ここへ現在の行を書く

    // Cell.update として登録される (= JavaFX updateItem)
    fn update(ud: *anyopaque, ctx: CellContext) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(ctx.value));
        self.label.setText(row.name) catch {};
        self.current_row = ctx.index;   // ★ このセルが今どの行か
        // 選択ハイライト等は ctx.selected から投影する (ここでは省略)
    }

    // セル内ボタンの action。 自分のセル状態から行が分かる (逆引き不要)
    fn onDelete(self: *TaskCell, _: *const ActionEvent) void {
        self.list.model.remove(self.current_row);   // model が変われば List が追従
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        const c = &self.root.container.component;
        c.vtable.destroy(c, allocator);   // Panel + 子 + 子の model を解放
        allocator.destroy(self);
    }
};

// CellFactory.create: 新しいセル実体を 1 つ組み立てて返す
fn createTaskCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell {
    const cx: *Ctx = @ptrCast(@alignCast(ud));
    const cell = try allocator.create(TaskCell);
    cell.* = .{ .root = ..., .label = ..., .delete_btn = ..., .list = cx.list };
    // action listener はセル生成時に一度だけ登録 (user_data = このセル状態)
    try cell.delete_btn.getModel().addActionListener(TaskCell, TaskCell.onDelete, cell);
    return .{
        .component = &cell.root.container.component,
        .update    = TaskCell.update,
        .destroy   = TaskCell.destroyCell,
        .user_data = cell,
    };
}

var ctx = Ctx{ .app = app };
const list = try app.list(.{ .create = createTaskCell, .user_data = &ctx });
ctx.list = list;                              // ★ List 生成後に埋める
for (rows) |*r| try list.model.add(@ptrCast(r));
```

チェックボックスの永続状態 (`done`) を行データへ書き戻す例を含む、 完全に動く実装は `{REPO_ROOT}/examples/widget_list` を参照。

## 機能要望
* 可変行高 (累積高 / 推定で可視範囲を求める。 固定行高より可視範囲算出が複雑になる)
* 行全体の hover ハイライト (現状は選択行のみ背景を描く。 セル内ウィジェットの rollover は「hover の解除」機構で機能するが、 行をまたぐ hover 表示は未対応)
* 細粒度の変更通知 (`ListDataListener` 相当、 挿入 / 削除レンジを引数で渡す)
* 抽象 `ListModel` (vtable 化して computed / 仮想モデルを許す)
* レイアウト方向 / wrap グリッド表示 (Swing `JList.setLayoutOrientation` 相当の `VERTICAL` / `HORIZONTAL_WRAP` / `VERTICAL_WRAP`)。
  **1 次元モデルのまま**セルを折り返してグリッド状に並べる (アイコンビュー風)。
  これは行 × 列の 2 次元モデルを持つ Table とは別物 — セルはどれも「1 要素 = 1 セル」で列ごとの型 / 幅の概念は無い。
  可視範囲算出を行インデックス → (col, row) の 2 次元に拡張する必要があり、 リサイクル / 可視範囲ロジックに影響する
* 同じセル機構の 2 次元 (行 / 列) **モデル**拡張としての Table、 階層版としての Tree。
  上の wrap グリッドと違い、 こちらは列ごとに renderer / editor / 幅を持つ本物の表 (Swing `JTable` / `TableModel` 相当)
* incremental search (キー入力で先頭一致する item へジャンプ)
* `ListModel` への任意位置挿入 `insert(idx, item)` — 現状 `add` は末尾追加のみ。
  行間挿入が要るとき用 (`move` は実装済み)。 モデル層の追加で List ウィジェット本体は非変更
* drop-indicator フック — 行間の挿入線を描くための組み込みの便宜フック。
  必須ではない: `List` ソースを変えずとも vtable 装飾 (元の `paint` を呼んでから線を描く) か passthrough overlay で出せる (`dnd.md`「List の行並べ替え」)。
  頻用するなら標準化する候補という位置づけ
