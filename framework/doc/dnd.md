---
unsafe: true
---

# dnd
ドラッグ&ドロップ。 あるウィジェットからデータをつかみ、 別のウィジェットの上で放して受け渡す機構。

ドラッグ&ドロップは実は 2 つの別物が混ざる。

* **アプリ内 DnD** — リスト行の並べ替え、 ペイン間でのアイテム移動など。 マウスを追跡して落とし先を求め、 モデルを書き換えるだけ。 データのシリアライズも型交渉も要らない。
* **OS からのドロップ** — エクスプローラ等から外部のファイルをウィンドウへ落とす。 こちらはプラットフォーム連携が要る。

v1 では **アプリ内 DnD だけ**を実装する。 OS ドロップは後付け (`doc/build.md` のプラットフォーム方針に従い段階導入) だが、 **後から `DropTarget` / `DragSource` の署名を壊さず additive に足せる**ことを設計目標にする。 その鍵は、 受け側へ渡す「荷物」を生のポインタではなく `Transfer` という抽象にし、 ドラッグの司令塔の入口を発生源に依存させないこと。 この 2 点を以下で固定する。

## 型定義
運ぶデータの種類。 OS 由来の種別 (`files` / `text`) は v1 では使わないが、 後付けを additive にするため**今から予約**する。 受け側は自分が扱える `Flavor` 以外を素通しするので、 種別が増えても既存の受け側は壊れない。

```zig
pub const Flavor = enum {
    object, // アプリ内 DnD: アプリ定義のオブジェクト。 `type_tag` で具体型を識別
    files,  // OS ファイルドロップ用に予約 (後付け)。 paths を運ぶ
    text,   // テキスト DnD 用に予約 (後付け)
};
```

利用者が要求するアクション。 修飾キー (典型的には Ctrl) で切り替わる。

```zig
pub const Action = enum {
    copy, // 元を残す
    move, // 元を移す (既定)
};
```

`object` フレーバの具体型を識別する不透明トークン。 **identity (アドレス) で比較**するだけで、 中身は持たない。 ドラッグ可能な型ごとに利用者が 1 つ鋳造する。 受け側は自分の受け入れ型のトークンと一致するかだけを見る。

```zig
pub const TypeTag = *const anyopaque;

// 型ごとに一意なトークンを返すヘルパ。 `T` の instantiation ごとに別の static を
// 指すので、 アドレス比較で型を弁別できる。
pub fn tagOf(comptime T: type) TypeTag {
    const Marker = struct {
        var byte: u8 = 0;
    };
    return &Marker.byte;
}
```

運ばれる荷物。 **アプリ内 DnD と OS ドロップの収束点**で、 受け側はこれ越しにしかデータを見ない。
`ctx` は `flavor` ごとに解釈する不透明ポインタ。 `source` はドラッグの発生元コンポーネント (OS 発は null)。
typed なアクセサは `flavor` を assert したうえで中身を取り出す (誤った `flavor` での呼び出しは UB)。

```zig
pub const Transfer = struct {
    flavor:   Flavor,
    ctx:      *anyopaque,        // 中身。 flavor + 発生源ごとに解釈する
    type_tag: ?TypeTag = null,   // flavor == .object のとき具体型を識別
    source:   ?*Component = null,// アプリ内発はドラッグ元、 OS 発は null

    pub fn object(self: *const Transfer) *anyopaque;       // flavor == .object を要求
    pub fn files (self: *const Transfer) []const []const u8;// flavor == .files を要求
    pub fn text  (self: *const Transfer) []const u8;        // flavor == .text を要求
};
```

受け側のコールバックに渡るイベント。 座標は**受け側ローカル**で、 司令塔がウィンドウ座標から変換して渡す。

```zig
pub const DragEvent = struct {
    x:        f32,
    y:        f32,
    transfer: *const Transfer,
    action:   Action,           // 利用者が要求しているアクション (修飾キー由来)
};
```

受け取る能力。 これを持つコンポーネントだけがドロップ先になれる。
`user_data` は典型的には外側ウィジェット自身 (`@fieldParentPtr` で戻す) を指す。 `Cell` / `CellFactory` と同じ流儀。

```zig
pub const DropTarget = struct {
    // 任意: 荷物がこの受け側に入ったとき一度。 ドロップゾーン全体のハイライト等。
    onEnter:   ?*const fn (self: *anyopaque, e: *const DragEvent) void = null,
    // ドラッグ移動のたび (受け側の中にいる間) 呼ばれる。 挿入先インジケータ等の
    // 位置追従フィードバックをここで更新し、 この地点でドロップを受理するかを返す。
    // 戻り値がカーソル表示と onDrop 発火の可否を駆動する。 false でも本体は走る
    // (受理不可の表示を描ける)。 受理判定と移動フックを兼ねる (canDrop は持たない)。
    onOver:    *const fn (self: *anyopaque, e: *const DragEvent) bool,
    // 任意: 荷物がこの受け側から出たとき一度。 フィードバックをクリアする。
    onLeave:   ?*const fn (self: *anyopaque) void = null,
    // ドロップ確定。 直前の onOver が true を返した受け側で放されたとき一度だけ。
    onDrop:    *const fn (self: *anyopaque, e: *const DragEvent) void,
    user_data: *anyopaque,
};
```

送り出す能力。 OS 発のドラッグは送り手が外部なので、 これは**アプリ内 DnD 専用**。

```zig
pub const DragSource = struct {
    // この地点でドラッグが成立したとき呼ばれ、 運ぶ荷物を組み立てて返す。
    // null を返すとそのドラッグは抑制される。
    onDragStart: *const fn (self: *anyopaque, x: f32, y: f32) ?Transfer,
    // 任意: ドラッグ中、 move のたびにカーソル位置 (**ウィンドウ座標**) で呼ばれる。
    // 送り側の per-move フック (`DropTarget.onOver` と対称)。 ゴーストを出したい
    // 側は、 onDragStart で passthrough overlay を登録し、 ここで位置を更新する
    // (nimbus はゴーストを描かない。 「描画 (ゴースト)」参照)。
    onDrag:      ?*const fn (self: *anyopaque, x: f32, y: f32) void = null,
    // 任意: ドラッグが決着したとき、 実際に行われたアクションを通知する。
    // `performed` が null なら、 ドロップが起きなかった (取り消し / 受理されず) こと
    // を意味し、 move 元はオリジナルを残す。
    onDragDone:  ?*const fn (self: *anyopaque, performed: ?Action) void = null,
    user_data:   *anyopaque,
};
```

`Component` には能力スロットを 2 つ足す。 既定はどちらも null (= DnD に参加しない)。

```zig
drag_source: ?DragSource = null,
drop_target: ?DropTarget = null,
```

## 利用例
ラベルをドラッグ元、 箱をドロップ先にした最小の DnD。 `object` フレーバ + `tagOf` で型を弁別し、 move で元を消す。

```zig
const Item = struct { name: []const u8 };
const item_tag = dnd.tagOf(Item);   // この型の荷物を識別するトークン

// ── ドラッグ元: 1 つの Item を運ぶラベル ──
const DragLabel = struct {
    label: *Label,
    item:  *Item,

    fn onDragStart(ud: *anyopaque, x: f32, y: f32) ?dnd.Transfer {
        _ = x;
        _ = y;
        const self: *DragLabel = @ptrCast(@alignCast(ud));
        return .{
            .flavor   = .object,
            .ctx      = self.item,
            .type_tag = item_tag,
            .source   = &self.label.component,
        };
    }

    fn onDragDone(ud: *anyopaque, performed: ?dnd.Action) void {
        const self: *DragLabel = @ptrCast(@alignCast(ud));
        if (performed == .move) {
            // move で受理された: このラベルを元から取り除く (アプリ側のモデル操作)
            _ = self;
        }
        // performed == null なら何もしない (ドロップされなかった)
    }
};

// label.component.drag_source = .{
//     .onDragStart = DragLabel.onDragStart,
//     .onDragDone  = DragLabel.onDragDone,
//     .user_data   = &drag_label,
// };

// ── ドロップ先: Item だけ受け取る箱 ──
const DropBox = struct {
    panel: *Panel,

    fn onOver(ud: *anyopaque, e: *const dnd.DragEvent) bool {
        const self: *DropBox = @ptrCast(@alignCast(ud));
        // 自分が扱える型の object だけ受ける。 それ以外 (files 等) は素通し
        const ok = e.transfer.flavor == .object and e.transfer.type_tag == item_tag;
        self.highlight = ok;          // フィードバックを更新 (paint がこれを見る)
        self.requestRepaint();
        return ok;                    // 受理可否 (カーソル / onDrop 発火を駆動)
    }

    fn onDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *DropBox = @ptrCast(@alignCast(ud));
        const item: *Item = @ptrCast(@alignCast(e.transfer.object()));
        _ = self;
        _ = item; // 自分側へ取り込む (保持するならコピーする)
    }
};

// box.panel.component.drop_target = .{
//     .onOver    = DropBox.onOver,
//     .onDrop    = DropBox.onDrop,
//     .user_data = &drop_box,
// };
```

### List の行並べ替え (自身への drop)
`List` の行をドラッグして同じ `List` の別位置に落とし、 並べ替える。 **`List` ウィジェット本体 (`paint` / `processEvent` / 選択ロジック) は書き替えずに実装できる** — ドラッグ元能力をセルの root に、 ドロップ先能力を `List` の `Component` に、 それぞれ**外から付ける**だけ。 これは能力をフィールドで持つ設計 (「能力をフィールドに置く理由」) がコンポジションで素直に拡張できることの実証でもある。

非変更で済むことの内訳:

* **ドラッグ元 / ドロップ先** — `list.asComponent().drag_source` と `drop_target` を**外から**設定する。 List のセルは container ツリーの外 (pool 管理) で司令塔のヒットテストから見えないため、 能力は **List 本体**に付ける。 `onDragStart` は press 位置 (List ローカル y) から開始行を算出する。
* **並べ替え** — `onOver` が `getRowHeight` で挿入位置を算出して受理可否を返し、 `onDrop` がモデルを並べ替える。 source == target なので並べ替えは `onDrop` で完結する。
* **ゴースト** — nimbus は描かないので、 `onDragStart` で passthrough overlay を登録し、 `onDrag` (ウィンドウ座標) で追従させ、 `onDragDone` で外す (「描画 (ゴースト / 挿入先)」)。

非変更で済まないのは**モデルの順序変更**だけ — 行順を変えるので `ListModel` に順序変更 op (`move`) が要る。 モデル層の追加で、 現状 API の `clear` + `add` 再投入でも代用できる (`List` ウィジェットの挙動ではない)。

挿入線の描画は、 次のいずれでも `List` ソースを変えずに出せる:

* **vtable 装飾 (推奨)** — `List.vtable` は public なので、 それを**コピーして `paint` だけ差し替える** (他メソッドは元のまま。 委譲 stub も退避も不要)。 拡張 `paint` は**先に元の `List.paint` を呼んでから**挿入線を描く。 線が `List` 本来の描画と同じ `Graphics` (同じ translate / clip) の上に乗るので **scroll / clip が自動で追従**する。 `ScrollPane` が使うのと同じ vtable substitution の手 (`scrollpane.md`)。 非公開 vtable を装飾する一般形 (元をグローバル退避 + 委譲 stub。 teardown 順の罠あり) は `reference: vtable decoration` を参照。
* **passthrough overlay** — 薄い線を passthrough overlay として出し `onOver` で位置更新する (`overlay.md`)。 vtable に触らず単純だが、 線の位置を絶対座標で計算し overlay を別管理する必要がある。

drop 位置 (`drop_at`) は `Reorder` コントローラに持たせ、 `onOver` が書き `onLeave` / `onDrop` でクリアする。 vtable 装飾の `paint` からは `self.getTyped(Reorder)` で引く。

```zig
// 前提: Component / Cell / CellContext / List / Label / Window / Application は
// nimbus、 awt (Graphics / Color) は awt モジュール。
const Row = struct { name: []const u8 };
const row_tag = dnd.tagOf(Row);

// 並べ替え + ゴーストの共有コントローラ (List に 1 つ)。
const Reorder = struct {
    list:    *List,
    window:  *Window,   // ゴーストの overlay 登録 / 解除
    ghost:   *Label,    // アプリ所有のゴースト (ドラッグ中だけ表示)
    src_row: ?usize = null,
    drop_at: ?usize = null,   // 挿入位置 (装飾 paint が読む)

    // ドラッグ成立: press 位置 (List ローカル) から開始行を求め、 荷物を返し、
    // ゴーストを passthrough overlay として出す (位置は直後の onDrag で入る)。
    fn onDragStart(ud: *anyopaque, x: f32, y: f32) ?dnd.Transfer {
        _ = x;
        const self: *Reorder = @ptrCast(@alignCast(ud));
        const h = self.list.getRowHeight();
        if (h <= 0 or y < 0) return null;
        const row: usize = @intFromFloat(y / h);
        const item = self.list.model.getElementAt(row) orelse return null;
        self.src_row = row;
        const data: *Row = @ptrCast(@alignCast(item));
        self.ghost.setText(data.name) catch {};
        self.window.overlays.addPassthrough(&self.ghost.component) catch {};
        return .{ .flavor = .object, .ctx = item, .type_tag = row_tag, .source = self.list.asComponent() };
    }

    // ドラッグ中 move ごと (ウィンドウ座標): ゴーストを追従させる
    fn onDrag(ud: *anyopaque, x: f32, y: f32) void {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        self.ghost.component.position = .{ .x = x + 12, .y = y + 12 };
    }

    // 決着 (drop / cancel どちらでも呼ばれる): ゴーストを外す
    fn onDragDone(ud: *anyopaque, performed: ?dnd.Action) void {
        _ = performed;
        const self: *Reorder = @ptrCast(@alignCast(ud));
        self.window.overlays.remove(@ptrCast(&self.ghost.component));
    }

    fn onOver(ud: *anyopaque, e: *const dnd.DragEvent) bool {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        if (e.transfer.flavor != .object or e.transfer.type_tag != row_tag) return false;
        self.drop_at = self.insertionRow(e.y);
        self.list.asComponent().repaint();
        return true;
    }

    fn onLeave(ud: *anyopaque) void {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        self.drop_at = null;
        self.list.asComponent().repaint();
    }

    fn onDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        const src = self.src_row orelse return;
        const dst = self.insertionRow(e.y);
        self.drop_at = null;
        self.list.model.move(src, dst); // ← ListModel の追加 op
        self.list.asComponent().repaint();
        // source == target なので並べ替えはここで完結
    }

    // List ローカル y → 挿入位置 (0..=getSize)。 行の上半分なら手前、 下半分なら次
    fn insertionRow(self: *Reorder, y: f32) usize {
        const h = self.list.getRowHeight();
        const i: usize = if (y <= 0) 0 else @intFromFloat((y + h / 2) / h);
        return @min(i, self.list.model.getSize());
    }

    // 装飾 paint から: 挿入位置に 2px の線。 List 本来の paint と同じ Graphics に乗る
    fn drawLine(self: *Reorder, g: *awt.Graphics, row: usize) void {
        const h = self.list.getRowHeight();
        const w = self.list.asComponent().size.width;
        const y = @as(f32, @floatFromInt(row)) * h;
        g.setColor(awt.Graphics.Color.rgb(0.20, 0.52, 1.0));
        g.fillRect(.{ .x = 0, .y = y - 1, .width = w, .height = 2 });
    }
};

// vtable 装飾: List.vtable は public なのでコピーして paint だけ差し替える
fn decorPaint(self: *Component, g: *awt.Graphics) void {
    List.vtable.paint(self, g);          // 先に List 本来の描画
    if (self.getTyped(Reorder)) |r| {
        if (r.drop_at) |row| r.drawLine(g, row);
    }
}
const decor_vt = blk: {
    var vt = List.vtable;
    vt.paint = decorPaint;
    break :blk vt;
};

// セル: 表示専用のラベル (drag / drop は List 本体側に付く)
const RowCell = struct {
    label: *Label,
    fn update(ud: *anyopaque, ctx: CellContext) void {
        const self: *RowCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(ctx.value));
        self.label.setText(row.name) catch {};
    }
    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *RowCell = @ptrCast(@alignCast(ud));
        const c = &self.label.component;
        c.vtable.destroy(c, allocator);
        allocator.destroy(self);
    }
};
fn createRowCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell {
    const app: *Application = @ptrCast(@alignCast(ud));
    const cell = try allocator.create(RowCell);
    cell.* = .{ .label = try app.label("") };
    return .{ .component = &cell.label.component, .update = RowCell.update, .destroy = RowCell.destroyCell, .user_data = cell };
}

// ── 組み立て ──
const ghost = try app.label("");             // アプリ所有のゴースト
ghost.component.size = .{ .width = 120, .height = 24 };
// 終了時に破棄する (どのツリーにも属さないため): defer { ghost.component.vtable.destroy(...) }

const list = try app.list(.{ .create = createRowCell, .user_data = app });
var reorder = Reorder{ .list = list, .window = &frame.window, .ghost = ghost };

// drag / drop 能力を List 本体に外から付ける (List ソースは非変更)
list.asComponent().drag_source = .{
    .onDragStart = Reorder.onDragStart,
    .onDrag      = Reorder.onDrag,
    .onDragDone  = Reorder.onDragDone,
    .user_data   = &reorder,
};
list.asComponent().drop_target = .{
    .onOver = Reorder.onOver, .onLeave = Reorder.onLeave,
    .onDrop = Reorder.onDrop, .user_data = &reorder,
};
list.asComponent().vtable = &decor_vt;        // 挿入線の装飾
try list.asComponent().putProperty(@typeName(Reorder), &reorder, null);

for (rows) |*r| try list.model.add(@ptrCast(r));
```

完全に動く実装は `{REPO_ROOT}/examples/widget_listdnd` を参照。

## 機能要望
* ドロップ先の bubbling (最近傍が拒否したら祖先の受け側へ回す)
* 受理アクションの細分 — 受け側が「copy なら受けるが move は不可」等を返し、 カーソルを copy / move で描き分ける
* スナップショットゴーストのヘルパ — ドラッグ元のサブツリーを**明度↓・アルファ↓のスナップショット**にしてゴーストにする定型 (`overlays.addPassthrough` + `onDrag` の上に乗るヘルパ。 現状はアプリが自前で組む)。 前提として awt 側に汎用プリミティブが 2 つ要る: (1) Component サブツリーをオフスクリーンのテクスチャへ描く (既存の RenderTarget / Texture / Image program から組み立て可)、 (2) テクスチャを RGBA 変調 (tint) して描く (明度 = ×RGB / アルファ = ×A)。 どちらもゴースト専用でなく `setEnabled(false)` の灰色化やサムネイル等にも効く汎用機能。 見た目は開始時に凍結するスナップショット方式を想定 (ライブ再描画は座標 / 状態が絡み複雑)。
* OS ファイルドロップ — Phase 1 (glfw `.files`) / Phase 2 (native ホバー演出)。 awt の `.file_drop` イベント追加を伴う
* ドラッグアウト (自アプリ → OS。 ファイル化してエクスプローラへ渡す)
* 開いたフレーバ / 任意 MIME — アプリ間で独自フォーマットを運ぶ (現状の閉じた `Flavor` を超える範囲)
* `text` フレーバを使うアプリ内テキスト DnD
* autoscroll — リスト等の端へドラッグしたら自動スクロール
