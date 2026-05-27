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

## 能力をフィールドに置く理由 (VTable を増やさない)
DnD のために `Component.VTable` にメソッドを足さない。 `drag_source` / `drop_target` は `scrollable` と同じく**コンポーネントが任意で持つインライン optional フィールド**にする。

* VTable は全ウィジェット共通の必須インターフェースで、 オプショナルな能力を足すたびに膨らむのは避けたい (`component.md` の方針)。
* DnD に参加するかどうかは、 ウィジェット型ごとに静的に決まる **intrinsic な属性**で、 ちょうど `scrollable` (折り返し追従するか) と同類。 動的なのはスロットの中身 (`onOver` 等の判定) であってスロットの有無ではない。
* 祖先が後付けする能力 (`ScrollController` のような property + `enclosing...` 探索) とは違い、 DnD 能力は**そのコンポーネント自身が宣言**する。 だから property バッグではなくフィールドが合う。

これは「オプショナルな能力＝付けたコンポーネントだけが持つメソッド群」という形で、 同じ流儀の `Scrollable` / `ScrollController` / `CellFactory` に連なる。 将来の C ABI / バインディングでも、 これらの能力は「能力を登録するメソッド」として素直に出せる。

## ドラッグの司令塔 (Window)
ドラッグのライフサイクルは `Window` が司る。 `Window` が既に mouse capture / overlay / ヒットテストを握っているため (`event.md`)。 司令塔の入口は**発生源に依存しない**形にし、 アプリ内ジェスチャも (後付けの) OS コールバックも同じ入口に合流させる。

```zig
// Window 内部の source-agnostic な入口 (概念上の契約)。
fn beginDrag (self: *Window, transfer: Transfer) void;          // ドラッグ開始 (onDragStart 後)
fn updateDrag(self: *Window, win_point: Point, action: Action) void; // 受け側解決・enter/over/leave
fn finishDrag(self: *Window, win_point: Point) void;            // 受理中なら onDrop、 後始末
fn cancelDrag(self: *Window) void;                              // 受理せず後始末
```

司令塔の責務:

* **受け側の解決** — `win_point` 下のコンポーネントから祖先方向へ歩き、 最初に `drop_target` を持つものを候補にする (`enclosingScrollController` と同型の探索)。 その候補の `onOver` の戻り値が受理を決める。 v1 では候補は 1 つだけで、 拒否されてもさらに祖先へは遡らない (bubbling は機能要望)。
* **enter / over / leave** — 候補が前フレームから変わったら、 旧候補に `onLeave`、 新候補に `onEnter` を投げる。 候補が同じで移動しているあいだは毎フレーム `onOver` を呼ぶ。 これは hover の解除 (合成 move) と同型の追跡 (`container.md`)。
* **フィードバック** — nimbus はゴーストを描かない。 送り側が `onDrag` で自分のゴースト (passthrough overlay) を動かし、 受け側が `onOver` で挿入線を描く (「描画 (ゴースト / 挿入先)」)。 受理中か否かでカーソルを変えるのは機能要望。
* **アクション** — 修飾キーから `action` (`copy` / `move`) を決め、 `DragEvent` に載せて受け側へ渡す。

## ライフサイクル (アプリ内 DnD)
1. **開始** — `drag_source` を持つコンポーネント上で press し、 閾値を超えて move したらジェスチャ成立。 `onDragStart(x, y)` を呼び、 返った `Transfer` で `beginDrag` する。 null が返ればドラッグしない。
2. **移動** — move のたび `updateDrag(win_point, action)`。 受け側解決・enter/leave・`onOver` によるフィードバック更新と受理判定。
3. **確定** — 受理中の受け側の上で release したら `finishDrag`。 受け側の `onDrop(e)` を**先に**呼び (受け側が荷物を取り込む)、 そのあと move かつ受理されたときに限りドラッグ元の `onDragDone(.move)` を呼ぶ (元を消す)。 copy なら `onDragDone(.copy)`。
4. **取り消し** — Escape、 または受理されない場所での release は `cancelDrag`。 ドラッグ元には `onDragDone(null)` を通知し、 元は残す。

`onDrop` → `onDragDone` の順序を守るのは、 move で「先に入れてから消す」を保証するため。 受理されなかった場合に `onDragDone(null)` を渡すのは、 move 元が「結局ドロップされなかったので消さない」と判断できるようにするため。

## 自分にドロップする (並べ替え)
1 つのコンポーネントが `drag_source` と `drop_target` を**両方**持てる。 これにより「自分からドラッグして自分に落とす」= リスト行の並べ替えなどが成立する。 司令塔の受け側解決は `win_point` からのヒットテストなので、 解決結果がドラッグ元自身でも特別扱いは要らない。 受け側は `e.transfer.source == &self.component` で「自分から来た荷物」を判定し、 外部からの挿入と並べ替えを区別する (これが `Transfer.source` を持つ主目的)。

注意は move の書き戻しだけ。 cross-component move は「`onDrop` で受け側が入れ、 `onDragDone(.move)` で送り側が消す」分担だが、 自分→自分の並べ替えでこれをそのまま行うと、 `onDrop` で remove + insert したものを `onDragDone` がもう一度消す**二重操作**になる。

source == target のときは **同じ backing 構造体が `onDrop` と `onDragDone` の両方を受け取る** (`user_data` が同一インスタンス) ので、 自分のフィールドで調停できる。 推奨パターン:

* **並べ替えは `onDrop` で完結させる** — `e.transfer.source == &self.component` なら、 ドロップ位置から行を求めて `remove` + `insert` を**ここで一括**で行う (挿入と削除の index は相互依存するため、 1 箇所でやらないと off-by-one を生む)。 そのうえで「済んだ」フラグを立てる。
* **`onDragDone` はそのフラグを見て no-op** にする。 外部へ move されたときだけ元を消す。

ドロップ位置 (行間のどこに落ちたか) の算出や、 端へドラッグしたときの autoscroll は List 側の統合の領分で、 「機能要望」に挙げる。

## 描画 (ゴースト / 挿入先)
ドラッグ中の描画は 2 つあり、 **どちらもアプリ側が制御する**。 nimbus は何も決め打ちで描かない。

### ゴースト (掴んだ物の見た目、 カーソル追従)
ゴーストの見た目は用途で大きく変わる (影だけ / ドラッグ元の縮小 / ラベル…) ので、 **nimbus は既定のゴーストを描かない**。 出したい側が自分で用意し、 overlay として制御する。

ゴーストは**入力を取らない純粋な浮遊物**なので、 `passthrough` ポリシーの overlay として乗せる (`overlay.md`)。 passthrough はヒットテストと dismiss の対象外なので、 受け側解決や capture / フォーカスと干渉しない。 アプリ側の手順:

* `onDragStart` でゴーストの Component を用意し、 `window.addPassthroughOverlay(ghost)` で登録する。
* `onDrag(x, y)` (ドラッグ中 move ごと、 **ウィンドウ座標**) でゴーストの `position` を更新する。 ドラッグ中はアプリのコンポーネントへ通常の move が届かない (司令塔が握る) ため、 位置はこの per-move フックで受け取る。
* `onDragDone` で `removeOverlay` する (ドロップ・取り消しのどちらでも呼ばれる)。

ゴーストの寿命と見た目はアプリの所有物。 ポップアップ系 (modal_popup) と同じ overlay スタック・z 順に乗る。

### 挿入先インジケータ (行間の線・セルのハイライト)
これは受け側に固有 (List は行間に横線、 グリッドはセル枠) なので司令塔は描けない。 受け側が**一時状態として保持し、 自分の `paint` で描く**。

* `onOver` は**受け側の中にいる間、 ドラッグ移動のたびに呼ばれる**。 受け側はここで `e.y` 等から挿入位置を算出して一時状態 (例: `drop_at: ?usize`) に保存し、 repaint を要求する。 同時に「この地点で受理するか」を bool で返す。
* `paint` はその一時状態がセットされていればインジケータを描く。
* `onLeave` / `onDrop` でクリアする (null + repaint)。

### 挿入先インジケータ (行間の線・セルのハイライト)
これは受け側に固有 (List は行間に横線、 グリッドはセル枠) なので司令塔は描けない。 受け側が**一時状態として保持し、 自分の `paint` で描く**。

* `onOver` は**受け側の中にいる間、 ドラッグ移動のたびに呼ばれる**。 受け側はここで `e.y` 等から挿入位置を算出して一時状態 (例: `drop_at: ?usize`) に保存し、 repaint を要求する。 同時に「この地点で受理するか」を bool で返す。
* `paint` はその一時状態がセットされていればインジケータを描く。
* `onLeave` / `onDrop` でクリアする (null + repaint)。

`onOver` が受理判定と移動ごとのフィードバック更新を兼ねるので、 純粋述語の `canDrop` を別に持たずに位置追従フィードバックが書ける。 `DropTarget` は DnD に参加する受け側しか持たない opt-in の能力なので、 こうしたコールバックを足しても全コンポーネント共通の `Component.VTable` のようには波及しない。 インジケータの見た目は受け側ごとに自由。

現状の再描画は dirty bool 単位 (部分再描画なし) なので、 ドラッグ中は move ごとにウィンドウ全体が再描画される。 ドラッグは能動的な一時操作なので許容する。

## Transfer の寿命
`Transfer` はドラッグ 1 回分のあいだだけ司令塔が保持する。 `ctx` の指す先は**借用**で、 ドラッグが終わるまで生存していればよい (アプリ内 DnD はジェスチャが同期的なので、 ドラッグ元のデータがその間に消えることはまずない)。 受け側がドロップ後もデータを保持したいなら、 `onDrop` の中で**自分側へコピー**すること (荷物そのものは保持しない)。

OS ドロップを後付けしたとき、 `files` の paths 文字列は awt 側が `finishDrag` の呼び出し中だけ所有する。 受け側が残すなら同様にコピーする。

## OS ドロップを後付けする (additive である理由)
OS からのファイルドロップは後段で足すが、 上記の型を**一切変えずに**乗る。

* **Phase 1 (glfw)** — glfw の drop コールバック (`glfwSetDropCallback`) はドロップ確定時にパス配列だけをくれる (ホバー中のイベントは無い)。 awt がこれを `Transfer{ flavor = .files, ctx = &paths, source = null }` に包み、 ドロップ位置で **同じ `finishDrag`** を呼ぶ。 ホバー演出は無し。
* **Phase 2 (native)** — Windows の `IDropTarget` / macOS の `NSDraggingDestination` を awt-c に実装すると、 DragEnter / DragOver が **同じ `updateDrag`** (→ `onEnter` / `onOver`) を駆動でき、 演出が点灯する。

ここがキモ: OS ドロップは `DropTarget` / `DragSource` に**新メソッドを足さない**。 増えるのは予約済みの `Flavor.files` を実際に使う場所と、 司令塔の入口を叩く新しい呼び出し元だけ。 `object` しか受けない既存の受け側は `onOver` で `e.transfer.flavor != .object` のとき false を返して素通しするので、 **1 つも壊れない**。

awt 層に唯一足りないのは、 OS ドロップを EventQueue へ届ける `Event` の新バリアント (`.file_drop` 相当) で、 これは enum への追加で additive。 アプリ内 DnD はこれを必要としない (既存のマウスイベントから framework 内で合成するため)。

## 制約
* **同時に成立するドラッグは高々 1 つ** (司令塔が単一の状態を持つ)。
* **受け側の解決は単一候補** — `win_point` 下の最近傍の `drop_target` のみ。 内側が拒否しても祖先の別の受け側へは渡さない (bubbling は機能要望)。
* **座標は受け側ローカル** — `DragEvent` の `x` / `y` は受け側コンポーネント原点基準。
* **単一 UI スレッド** — DnD は他のイベント処理と同じ UI スレッドで完結する (`CLAUDE.md` のスレッドモデル)。

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
        self.window.addPassthroughOverlay(&self.ghost.component) catch {};
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
        self.window.removeOverlay(@ptrCast(&self.ghost.component));
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
* スナップショットゴーストのヘルパ — ドラッグ元のサブツリーを**明度↓・アルファ↓のスナップショット**にしてゴーストにする定型 (`addPassthroughOverlay` + `onDrag` の上に乗るヘルパ。 現状はアプリが自前で組む)。 前提として awt 側に汎用プリミティブが 2 つ要る: (1) Component サブツリーをオフスクリーンのテクスチャへ描く (既存の RenderTarget / Texture / Image program から組み立て可)、 (2) テクスチャを RGBA 変調 (tint) して描く (明度 = ×RGB / アルファ = ×A)。 どちらもゴースト専用でなく `setEnabled(false)` の灰色化やサムネイル等にも効く汎用機能。 見た目は開始時に凍結するスナップショット方式を想定 (ライブ再描画は座標 / 状態が絡み複雑)。
* OS ファイルドロップ — Phase 1 (glfw `.files`) / Phase 2 (native ホバー演出)。 awt の `.file_drop` イベント追加を伴う
* ドラッグアウト (自アプリ → OS。 ファイル化してエクスプローラへ渡す)
* 開いたフレーバ / 任意 MIME — アプリ間で独自フォーマットを運ぶ (現状の閉じた `Flavor` を超える範囲)
* `text` フレーバを使うアプリ内テキスト DnD
* autoscroll — リスト等の端へドラッグしたら自動スクロール
