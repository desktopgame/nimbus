# list
item を縦に並べて表示し、 1 項目を選択できるウィジェット。
Swing の `JList` 相当だが、 セルの実現方法は JavaFX の `ListView` (内部の VirtualFlow) に倣う。

セルは **実体のあるコンポーネント部分木**で、 **可視範囲＋少しのバッファぶんだけ生成**する。
スクロールで画面外に出たセルは破棄せず、 新しく現れた行へ **再利用 (recycle)** する。
これによりメモリは総行数 N ではなく可視行数に比例し (O(可視))、 かつセルが実体なので描画もイベント処理もウィジェット本来の機構をそのまま使える。

v1 スコープ:
* 単一選択のみ (複数選択は機能要望)
* 固定の行高 (可変行高は機能要望)
* セルは **読み取り専用** (項目の値をセルへ投影するだけ)。 セル内のボタン等は押せるが、 セル内でのテキスト編集は対象外 (「編集 (CellEditor)」を参照)

## 型定義
```zig
pub const List = struct {
    component:        Component,
    model:            *ListModel,         // 観測可能な item ソース
    owns_model:       bool,               // create 経由なら true、 createWithModel なら false
    factory:          CellFactory,        // 実セルを生成する binder (借用)
    selected:         ?usize,             // 単一選択 (none = 未選択)
    row_height:       f32,                // 固定行高 (v1)
    pool:             std.ArrayList(PooledCell), // 可視範囲を覆う実セル群 (List が所有)
    has_focus:        bool,               // キーボードフォーカス保持中か (ctx.focused 用)
    hovered:          ?*Component,         // ポインタが乗っているセル (hover 解除用、 後述)
    change_listeners: ChangeListenerList, // 選択変更通知
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
`update` は JavaFX の `updateItem` 相当で、 そのセルを **ある行のデータに束縛し直す**ときに呼ばれる (生成直後と recycle 時)。

```zig
pub const Cell = struct {
    component: *Component,   // セル部分木のルート (この Cell が所有)
    update:    *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy:   *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    user_data: *anyopaque,   // セルごとの状態構造体 (factory が new したもの)
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
`selected` は none、 `row_height` は既定値、 `pool` は空で始まる (最初のレイアウトで可視範囲ぶん生成する)。
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
`model.md`「Model の所有モデル」に従い、 借用した model は `destroy` で解放しない。

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
```zig
pub fn getSelected(self: List) ?usize;
pub fn setSelected(self: *List, idx: ?usize) void;
```

`setSelected` は範囲外なら none に丸める。
値が変化したときだけ `change_listeners` を発火 + repaint する (不変なら no-op)。
変化があれば、 影響する可視セル (旧選択行・新選択行) を **その場で `update` し直して** 選択表示を投影する。 加えて List 自身が選択行の背景ハイライトを描く (「描画」参照)。

## 行高の取得 / 設定
```zig
pub fn getRowHeight(self: List) f32;
pub fn setRowHeight(self: *List, h: f32) void;
```

固定行高を更新する。
値が変わったら内容の総高 (`min_size.height`) を再計算して `markLayoutDirty` + repaint する (総高と可視行数が変わるため)。

## 選択変更リスナー
```zig
pub fn addChangeListener   (self: *List, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeChangeListener(self: *List, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
```

`selected` が変化した瞬間に発火する。
hover やセル内ボタンの押下では発火しない (それらはセルが配線したコールバックの領分)。

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

### サイズ / 要素アクセス
```zig
pub fn getSize     (self: ListModel) usize;
pub fn getElementAt(self: ListModel, idx: usize) ?*anyopaque;
```

`getElementAt` は範囲外なら null。 返り値の解釈 (実型) は呼び出し側の責任。

---

## 可視範囲だけ実体化する
List は「全行ぶんのセル」を持たない。 **可視範囲を覆うのに必要な数＋少しのバッファ**だけ実セルを `pool` に持つ。

* `component.min_size.height = model.getSize() * row_height` を報告する。 これにより外側の `ScrollPane` がスクロール範囲を決める (`scrollpane.md`)。
* List は自分のビューポート内でのオフセット (自分の `position`) とビューポートの高さから **可視行範囲**を求める。
* `pool` 内の各セルを 1 つの可視行に割り当て、 `cell.component.position` を行の矩形 (`y = row * row_height`、 高さ `row_height`、 幅は List 内幅) にセットする。 割り当てた行に対して `cell.update(ctx)` を呼ぶ。
* 可視範囲が動いたら (スクロール / リサイズ / `row_height` 変更 / model 変更)、 プールを **再調整 (reconcile)** する。 足りなければ `factory.create` で増やし、 余ったセルは非表示 (`row = null`) にし、 行が変わったセルにだけ `update` を呼び直す (= recycle)。

可視セルは List の子として `parent` チェーンに繋ぐ。
描画クリップも当たり判定も `Container` と同じ既存機構 (`paintAt` の bounds クリップ、 `containsWindowPoint` の門番) でそのまま成立する (`container.md`)。 専用のセル dispatch コードは要らない。

### なぜ単一インスタンスの判子にしないか
セルを 1 個だけ使い回し、 paint / dispatch のたびに位置と内容を付け替える「判子」方式も考えられるが、 **対話 (interaction) で破綻する**ため採らない。

描画は行の純関数 (`value, index, selected, focused` から一意に決まる) なので 1 個を使い回せる。
だが押下状態のような対話状態は「どの物理行で押し下げたか」という **入力履歴と identity の関数**であって、 行データからは導出できない。
判子は 1 インスタンス共有で identity を持たないため、 「3 行目だけ押下中」を表現できない (全行同じ表示になるか、 行データから復元できず消えるか)。
さらにマウスキャプチャは捕捉コンポーネントへ直送されるため (`event.md`)、 判子が paint で位置を付け替えられると、 ドラッグ中に「自分がどの行か」が失われる。

対話は「対話中セルごとの安定した identity」を要求する。
可視ぶんの実セルを置くと、 操作の間そのセルは同じ行に固定されるので identity が自然に保たれ、 判子方式に必要だった特殊機構 (List 側のジェスチャ調停 / controlled 駆動) が一切要らなくなる。

## 状態の置き場所
セルの状態を **寿命**で 3 つに分け、 置き場所を変える。 これがこの設計の要。

| 状態の種類 | 例 | 置き場所 | 寿命 |
|---|---|---|---|
| 投影 (一方向) | 表示テキスト / アイコン / 選択ハイライト | **ListModel の item** (＋ `ctx.selected` 等)。 `update` で毎回上書き | 行データと同じ |
| 一時的な対話状態 | pressed / armed / hover | **セル実体**が普通に持つ | セル実体と同じ (recycle で消えてよい) |
| 永続的な per-row 状態 | checked / expanded / 編集後テキスト | **ListModel の item** が真実。 `update` で投影し、 変更はコールバックで item へ書き戻す | 行データと同じ |

要点:

* **投影状態は状態ではない** — 表示テキストはセルが originate しない。 `update` で item から毎回上書きされるだけなので、 recycle されても正しい行の値になる。
* **一時的な対話状態はセルに任せてよい** — セルが実体なので、 `processEvent` で `setPressed` 等が走っても他の行に漏れない。 recycle で別の行に使い回されるとき、 押下中の行は recycle されない (操作中＝可視＆フォーカス近傍) ので問題にならない。
* **永続 per-row 状態をセルに溜め込まない** — 例えばセルに Checkbox を置いて `selected` をセル側だけに持つと、 recycle で別行に使い回した瞬間に値が紛れる。 真実は item に置き、 セルは投影＋書き戻しの view に徹する (controlled)。

## 「個別のボタンを認識する」問題が消える理由
Swing でセル内ボタンの行を `getEditingRow()` で逆引きする必要があったのは、 判子に実体と行 identity が無かったから。

この設計ではセルが実体で、 factory が **セルごとに専用の状態構造体 (`user_data`) を new する**。
セル内ボタンの action listener は、 そのセルの状態構造体を `user_data` にして **生成時に一度だけ** 登録する (`getModel().addActionListener(fn, &cell_state)`、 `button.md`)。
`update` のたびにセルは自分の状態構造体へ現在の行 (`ctx.index`) を書き込む。

セルは recycle されるまで同じ行に固定され、 イベントもその間に来るので、 action ハンドラが自分のセル状態から現在行を読めば常に正しい行が取れる。
共有インスタンスからの逆引きも、 editor のライフサイクルも要らない。

> action が `EventQueue.invokeLater` 等で遅延実行される場合は、 遅延時に行が recycle で変わっている可能性があるため、 行番号を先にコピーしておくこと。

## イベント処理
可視セルは List の子なので、 セル内のマウス処理 (ボタン押下、 ドラッグ、 キャプチャ) は通常のウィジェットと同じコードでそのまま動く。
List 自身の `processEvent` は、 その上に行選択とキーボード操作を足すだけ。

| 入力 | 動作 |
|---|---|
| マウス move | ポインタ下のセルへ配送。 加えて hover 追跡 (後述) を更新する |
| マウス left press (行上) | まず子 (セル) へ配送。 セルが消費すれば終わり。 消費しなければその行を選択 (`setSelected`) し、 List にフォーカスを要求する (矢印キーを効かせるため) |
| マウス wheel (scroll) | 何もしない (外側の `ScrollPane` に処理させるため消費しない) |
| ↓ / ↑ キー | `selected` を移動 (端でクランプ)、 ChangeListener 発火、 `enclosingScrollController` 経由で可視域へスクロール |

セル内ボタンの press → drag → release は、 そのボタンが `requestCapture` してキャプチャ先で完結する (`event.md`「マウスキャプチャ」)。
List はキャプチャに関与しない (実セルなのでボタン自身の identity が安定しているため)。

### hover の解除 (合成 move)
nimbus には OS の enter/leave が無く、 ウィジェットは受け取った `.move` の inside 判定で rollover を更新する。 ポインタがセルから離れると、 そのセル内ボタンは move を受け取らなくなり rollover が固着しうる。
そこで List は「いまポインタが乗っているセル」(`hovered`) を覚え、 **乗っているセルが変わったら、 離れた側のセルへ現在のポインタ座標 (＝もうそのセルの外) の `.move` を合成して送る**。 セルはその move を通常処理して rollover を落とし、 セルがコンテナーなら自分の子へ同じ伝播が連鎖する。 これは `Container` / `Panel` と同一の hover 解除機構 (`container.md`)。 List 自身も viewport の子なので、 ポインタが List の外へ出たときは viewport から同じ合成 move が届いて連鎖が起きる。

## 描画
ビューポート (typically `ScrollPane`) 越しに表示される前提。
`paint` はまず可視範囲を再調整 (reconcile) し、 背景を塗り、 選択行があればその矩形に背景ハイライトを描く。 その後、 `pool` の各可視セル (`cell.component`) を `paintAt` で重ねて描く。
画面外の行はそもそもセルが割り当たっていない (プールが可視範囲しか覆わない) ので、 描画コストは行数 N ではなく可視行数に比例する。

選択ハイライトを List 側で描くのは、 read-only セルが選択表示を持たなくても見た目が成立するようにするため。 セルは `ctx.selected` を受け取るので、 必要なら自前で選択時の描画を上書きしてもよい。

## 編集 (CellEditor)
v1 List のセルは読み取り専用 (投影のみ) なので編集機構は持たない。
セル内で **テキスト編集**が要るケース (将来の Table / Tree のセル編集) のために、 ここに方針を定め additive に足せる余地を残す。
Swing は renderer (判子) と editor (実体) を別コンポーネントに分けるが、 ここでは JavaFX に倣い **同じ実セルが編集モードへトグルする**形にする (実セルは既にあるので別オーバーレイが要らない)。

編集にまつわる状態 (キャレット位置 / 選択範囲 / IME の未確定文字列) は **編集している間だけ**実セル内の入力ウィジェットが保持し、 編集が終われば失われる。
これは pressed が recycle で消えるのと同型で、 「per-row でない一時状態は、 それを抱える文脈が終われば消える」という一貫した扱い。 失って困るのは確定テキストだけで、 それは item へ書き戻すので残る。

仕組み (additive):

* List に **編集中の行**を表すフィールドを 1 つ足す (`editing: ?usize`)。
* セルに編集ライフサイクル (`startEdit` / `commitEdit` / `cancelEdit`) を足す。 `startEdit` でセル部分木を入力ウィジェットへ差し替え、 item の値で seed する。 この入力ウィジェットが **スクラッチ**で、 確定まで item を触らない。
* **編集中のセルは `update` の投影を止める** (item から上書きすると入力中の文字が消えるため)。 これが編集を守る唯一の核。
* `commitEdit` でスクラッチの確定値を item へ書き戻し、 model の変更を通知する。 `cancelEdit` はスクラッチを破棄して表示モードへ戻す。

次の 2 つを制約として置く (これにより recycle / identity の厄介がすべて消える):

* **同時に 2 つ以上のセルが編集状態になることはない。**
* **編集が開始してから終了するまでの間、 そのセルがプールに返される (recycle される) ことはない。** 編集中セルが可視域外へスクロールされそうなときは、 その時点で編集を終える (commit か cancel)。

## 寿命
`factory` の所有者は **利用者** (typically factory を実装した view 構造体)。 List は借用するだけで `destroy` で解放しない。
一方、 factory が生成した **セル (`Cell` とその部分木) は List が所有**する (動的に増減するため)。 `destroy` が `pool` 内の全セルを `cell.destroy` で解放する。

`model` は `owns_model` を見て、 `create` で内部生成した場合のみ List が解放する (`createWithModel` の借用は触らない)。

item の実メモリ (`*anyopaque` の指す先) は利用者の所有。 ListModel は借用ポインタを並べるだけで、 List / ListModel より長生きさせる責任は利用者にある。

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
    fn onDelete(ud: *anyopaque) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
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
    try cell.delete_btn.getModel().addActionListener(TaskCell.onDelete, cell);
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
* 複数選択 (`SelectionModel`、 Swing の `ListSelectionModel` 相当)
* 可変行高 (累積高 / 推定で可視範囲を求める。 固定行高より可視範囲算出が複雑になる)
* 行全体の hover ハイライト (現状は選択行のみ背景を描く。 セル内ウィジェットの rollover は「hover の解除」機構で機能するが、 行をまたぐ hover 表示は未対応)
* 細粒度の変更通知 (`ListDataListener` 相当、 挿入 / 削除レンジを引数で渡す)
* 抽象 `ListModel` (vtable 化して computed / 仮想モデルを許す)
* 同じセル機構の 2 次元拡張としての Table (行 / 列)、 階層版としての Tree
* `CellEditor` (「編集」参照) — セルを編集モードへトグルする機構。 List では不要だが Table / Tree で必須
* incremental search (キー入力で先頭一致する item へジャンプ)
