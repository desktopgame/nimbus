---
unsafe: true
---

# dnd
DnD の能力配置の理由・司令塔の責務・ライフサイクル・自分への drop・ゴースト/インジケータ・Transfer の寿命・OS ドロップの後付け・制約。

## 能力をフィールドに置く理由 (VTable を増やさない)
DnD のために `Component.VTable` にメソッドを足さない。
`drag_source` / `drop_target` は `scrollable` と同じく**コンポーネントが任意で持つインライン optional フィールド**にする。

* VTable は全ウィジェット共通の必須インターフェースで、 オプショナルな能力を足すたびに膨らむのは避けたい (`component.md` の方針)。
* DnD に参加するかどうかは、 ウィジェット型ごとに静的に決まる intrinsic な属性で、 ちょうど `scrollable` (折り返し追従するか) と同類。
  動的なのはスロットの中身 (`onOver` 等の判定) であってスロットの有無ではない。
* 祖先が後付けする能力 (`ScrollController` のような property + `enclosing...` 探索) とは違い、 DnD 能力は**そのコンポーネント自身が宣言**する。
  だから property バッグではなくフィールドが合う。

これは「オプショナルな能力＝付けたコンポーネントだけが持つメソッド群」という形で、 同じ流儀の `Scrollable` / `ScrollController` / `CellFactory` に連なる。
将来の C ABI / バインディングでも、 これらの能力は「能力を登録するメソッド」として素直に出せる。

## ドラッグの司令塔 (Window)
ドラッグのライフサイクルは `Window` が司る。 `Window` が既に mouse capture / overlay / ヒットテストを握っているため (`event.md`)。
司令塔の入口は**発生源に依存しない**形にし、 アプリ内ジェスチャも (後付けの) OS コールバックも同じ入口に合流させる。

```zig
// Window 内部の source-agnostic な入口 (概念上の契約)。
fn beginDrag (self: *Window, transfer: Transfer) void;          // ドラッグ開始 (onDragStart 後)
fn updateDrag(self: *Window, win_point: Point, action: Action) void; // 受け側解決・enter/over/leave
fn finishDrag(self: *Window, win_point: Point) void;            // 受理中なら onDrop、 後始末
fn cancelDrag(self: *Window) void;                              // 受理せず後始末
```

司令塔の責務:

* 受け側の解決 — `win_point` 下のコンポーネントから祖先方向へ歩き、 最初に `drop_target` を持つものを候補にする (`enclosingScrollController` と同型の探索)。
  その候補の `onOver` の戻り値が受理を決める。 v1 では候補は 1 つだけで、 拒否されてもさらに祖先へは遡らない (bubbling は機能要望)。
* enter / over / leave — 候補が前フレームから変わったら、 旧候補に `onLeave`、 新候補に `onEnter` を投げる。
  候補が同じで移動しているあいだは毎フレーム `onOver` を呼ぶ。 これは hover の解除 (合成 move) と同型の追跡 (`container.md`)。
* フィードバック — nimbus はゴーストを描かない。
  送り側が `onDrag` で自分のゴースト (passthrough overlay) を動かし、 受け側が `onOver` で挿入線を描く (「描画 (ゴースト / 挿入先)」)。
  受理中か否かでカーソルを変えるのは機能要望。
* アクション — 修飾キーから `action` (`copy` / `move`) を決め、 `DragEvent` に載せて受け側へ渡す。

## ライフサイクル (アプリ内 DnD)
1. 開始 — `drag_source` を持つコンポーネント上で press し、 閾値を超えて move したらジェスチャ成立。
   `onDragStart(x, y)` を呼び、 返った `Transfer` で `beginDrag` する。 null が返ればドラッグしない。
2. 移動 — move のたび `updateDrag(win_point, action)`。 受け側解決・enter/leave・`onOver` によるフィードバック更新と受理判定。
3. 確定 — 受理中の受け側の上で release したら `finishDrag`。 受け側の `onDrop(e)` を先に呼び (受け側が荷物を取り込む)、
   そのあと move かつ受理されたときに限りドラッグ元の `onDragDone(.move)` を呼ぶ (元を消す)。 copy なら `onDragDone(.copy)`。
4. 取り消し — Escape、 または受理されない場所での release は `cancelDrag`。 ドラッグ元には `onDragDone(null)` を通知し、 元は残す。

`onDrop` → `onDragDone` の順序を守るのは、 move で「先に入れてから消す」を保証するため。
受理されなかった場合に `onDragDone(null)` を渡すのは、 move 元が「結局ドロップされなかったので消さない」と判断できるようにするため。

## 自分にドロップする (並べ替え)
1 つのコンポーネントが `drag_source` と `drop_target` を両方持てる。
これにより「自分からドラッグして自分に落とす」= リスト行の並べ替えなどが成立する。
司令塔の受け側解決は `win_point` からのヒットテストなので、 解決結果がドラッグ元自身でも特別扱いは要らない。
受け側は `e.transfer.source == &self.component` で「自分から来た荷物」を判定し、
外部からの挿入と並べ替えを区別する (これが `Transfer.source` を持つ主目的)。

注意は move の書き戻しだけ。
cross-component move は「`onDrop` で受け側が入れ、 `onDragDone(.move)` で送り側が消す」分担である。
自分→自分の並べ替えでこれをそのまま行うと、 `onDrop` で remove + insert したものを `onDragDone` がもう一度消す**二重操作**になる。

`source == target` のときは **同じ backing 構造体が `onDrop` と `onDragDone` の両方を受け取る** (`user_data` が同一インスタンス) ので、
自分のフィールドで調停できる。 推奨パターン:

* 並べ替えは `onDrop` で完結させる — `e.transfer.source == &self.component` なら、 ドロップ位置から行を求めて `remove` + `insert` をここで一括で行う。
  挿入と削除の index は相互依存するため、 1 箇所でやらないと off-by-one を生む。
  そのうえで「済んだ」フラグを立てる。
* `onDragDone` はそのフラグを見て no-op にする。 外部へ move されたときだけ元を消す。

ドロップ位置 (行間のどこに落ちたか) の算出や、 端へドラッグしたときの autoscroll は List 側の統合の領分で、 「機能要望」に挙げる。

## 描画 (ゴースト / 挿入先)
ドラッグ中の描画は 2 つあり、 **どちらもアプリ側が制御する**。 nimbus は何も決め打ちで描かない。

### ゴースト (掴んだ物の見た目、 カーソル追従)
ゴーストの見た目は用途で大きく変わる (影だけ / ドラッグ元の縮小 / ラベル…) ので、 **nimbus は既定のゴーストを描かない**。
出したい側が自分で用意し、 overlay として制御する。

ゴーストは**入力を取らない純粋な浮遊物**なので、 `passthrough` ポリシーの overlay として乗せる (`overlay.md`)。
passthrough はヒットテストと dismiss の対象外なので、 受け側解決や capture / フォーカスと干渉しない。 アプリ側の手順:

* `onDragStart` でゴーストの Component を用意し、 `window.overlays.addPassthrough(ghost)` で登録する。
* `onDrag(x, y)` (ドラッグ中 move ごと、 ウィンドウ座標) でゴーストの `position` を更新する。
  ドラッグ中はアプリのコンポーネントへ通常の move が届かない (司令塔が握る) ため、 位置はこの per-move フックで受け取る。
* `onDragDone` で `removeOverlay` する (ドロップ・取り消しのどちらでも呼ばれる)。

ゴーストの寿命と見た目はアプリの所有物。 ポップアップ系 (modal_popup) と同じ overlay スタック・z 順に乗る。

### 挿入先インジケータ (行間の線・セルのハイライト)
これは受け側に固有 (List は行間に横線、 グリッドはセル枠) なので司令塔は描けない。 受け側が**一時状態として保持し、 自分の `paint` で描く**。

* `onOver` は**受け側の中にいる間、 ドラッグ移動のたびに呼ばれる**。
  受け側はここで `e.y` 等から挿入位置を算出して一時状態 (例: `drop_at: ?usize`) に保存し、 repaint を要求する。
  同時に「この地点で受理するか」を bool で返す。
* `paint` はその一時状態がセットされていればインジケータを描く。
* `onLeave` / `onDrop` でクリアする (null + repaint)。

### 挿入先インジケータ (行間の線・セルのハイライト)
これは受け側に固有 (List は行間に横線、 グリッドはセル枠) なので司令塔は描けない。 受け側が**一時状態として保持し、 自分の `paint` で描く**。

* `onOver` は**受け側の中にいる間、 ドラッグ移動のたびに呼ばれる**。
  受け側はここで `e.y` 等から挿入位置を算出して一時状態 (例: `drop_at: ?usize`) に保存し、 repaint を要求する。
  同時に「この地点で受理するか」を bool で返す。
* `paint` はその一時状態がセットされていればインジケータを描く。
* `onLeave` / `onDrop` でクリアする (null + repaint)。

`onOver` が受理判定と移動ごとのフィードバック更新を兼ねるので、 純粋述語の `canDrop` を別に持たずに位置追従フィードバックが書ける。
`DropTarget` は DnD に参加する受け側しか持たない opt-in の能力なので、
こうしたコールバックを足しても全コンポーネント共通の `Component.VTable` のようには波及しない。
インジケータの見た目は受け側ごとに自由。

現状の再描画は dirty bool 単位 (部分再描画なし) なので、 ドラッグ中は move ごとにウィンドウ全体が再描画される。 ドラッグは能動的な一時操作なので許容する。

## Transfer の寿命
`Transfer` はドラッグ 1 回分のあいだだけ司令塔が保持する。
`ctx` の指す先は**借用**で、 ドラッグが終わるまで生存していればよい
(アプリ内 DnD はジェスチャが同期的なので、 ドラッグ元のデータがその間に消えることはまずない)。
受け側がドロップ後もデータを保持したいなら、 `onDrop` の中で自分側へコピーすること (荷物そのものは保持しない)。

OS ドロップを後付けしたとき、 `files` の paths 文字列は awt 側が `finishDrag` の呼び出し中だけ所有する。 受け側が残すなら同様にコピーする。

## OS ドロップを後付けする (additive である理由)
OS からのファイルドロップは後段で足すが、 上記の型を**一切変えずに**乗る。

* Phase 1 (glfw) — glfw の drop コールバック (`glfwSetDropCallback`) はドロップ確定時にパス配列だけをくれる (ホバー中のイベントは無い)。
  awt がこれを `Transfer{ flavor = .files, ctx = &paths, source = null }` に包み、 ドロップ位置で 同じ `finishDrag` を呼ぶ。 ホバー演出は無し。
* Phase 2 (native) — Windows の `IDropTarget` / macOS の `NSDraggingDestination` を awt-c に実装する。
  これにより DragEnter / DragOver が 同じ `updateDrag` (→ `onEnter` / `onOver`) を駆動でき、 演出が点灯する。

ここがキモ: OS ドロップは `DropTarget` / `DragSource` に**新メソッドを足さない**。
増えるのは予約済みの `Flavor.files` を実際に使う場所と、 司令塔の入口を叩く新しい呼び出し元だけ。
`object` しか受けない既存の受け側は `onOver` で `e.transfer.flavor != .object` のとき false を返して素通しするので、 1 つも壊れない。

awt 層に唯一足りないのは、 OS ドロップを EventQueue へ届ける `Event` の新バリアント (`.file_drop` 相当) で、 これは enum への追加で additive。
アプリ内 DnD はこれを必要としない (既存のマウスイベントから framework 内で合成するため)。

## 制約
* 同時に成立するドラッグは高々 1 つ (司令塔が単一の状態を持つ)。
* 受け側の解決は単一候補 — `win_point` 下の最近傍の `drop_target` のみ。 内側が拒否しても祖先の別の受け側へは渡さない (bubbling は機能要望)。
* 座標は受け側ローカル — `DragEvent` の `x` / `y` は受け側コンポーネント原点基準。
* 単一 UI スレッド — DnD は他のイベント処理と同じ UI スレッドで完結する (`CLAUDE.md` のスレッドモデル)。
