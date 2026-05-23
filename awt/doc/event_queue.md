# event_queue
別スレッドから UI スレッドへタスクをポストするための同期プリミティブ。
Swing の `EventQueue.invokeLater` / `invokeAndWait` 相当。
Application が 1 個所有してイベントループの末尾でドレインする。
CLAUDE.md「非同期処理」セクションも参照。

## 型定義
```zig
pub const EventQueue = struct {
    // 内部: ミューテックスで保護されたタスクキュー + invokeAndWait 完了通知用 condvar

    // ... メソッド
};

pub const Task = struct {
    fn_ptr:    *const fn (*anyopaque) void,
    user_data: *anyopaque,
};
```

`Task` は内部表現で、利用者が直接見ることは無い。
`invokeLater` / `invokeAndWait` の引数として関数ポインタ + user_data を渡せばよい。

## キューの生成
```zig
pub fn init(allocator: std.mem.Allocator) !*EventQueue;
```

EventQueue を allocator で確保して初期化する。
内部のミューテックスと condvar も初期化する。

### 失敗時の保証
途中で失敗した場合、`init` 内で確保したリソースはすべて関数内で解放される。

## キューの破棄
```zig
pub fn deinit(self: *EventQueue) void;
```

キューに残っているタスクは破棄される（実行されない）。
利用者は deinit 前に必要なタスクが消化されていることを保証する責任を持つ（通常は Application.run() がループを抜けた時点で空になっている）。

## タスクの非同期ポスト
```zig
pub fn invokeLater(
    self: *EventQueue,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) !void;
```

`(fn_ptr, user_data)` をキューに追加して即座に return する。
内部で GLFW の `glfwPostEmptyEvent` を呼び、UI スレッドが `nmWaitEvents` でブロックしていれば起こす。
タスク自体はその後の `drain` 呼び出しで実行される。

### 事前条件
* どのスレッドから呼んでもよい
* `fn_ptr` の指す関数は UI スレッドで実行される前提で書かれていること

## タスクの同期ポスト
```zig
pub fn invokeAndWait(
    self: *EventQueue,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) !void;
```

タスクをキューに追加したのち、UI スレッドがそれを実行し終わるまで呼び出しスレッドをブロックする。
内部の condvar で同期する。

### 事前条件
* **UI スレッドから呼んではいけない**（呼ぶとデッドロックする）。debug ビルドでは assert で弾く

### 診断情報
* UI スレッドから呼ばれた場合、debug ビルドでは即 panic、release ビルドではログ `[ERROR] [event_queue] invokeAndWait called from UI thread (would deadlock)` を出して即 return する

## キューのドレイン
```zig
pub fn drain(self: *EventQueue) void;
```

キューに溜まっているタスクをすべて順番に実行する。
UI スレッドのみが呼ぶ前提。
通常は Application のイベントループが `awt.waitEvents` の直後に呼ぶ（`framework/doc/application.md` 参照）。

実行中に新しいタスクがポストされてもこの `drain` 呼び出しの中では拾わない（その時点でキューにあったぶんだけ実行する）。
新しいタスクは次のループ反復で拾われる。

---

## なぜ awt 層に置くか
EventQueue は GLFW の `glfwPostEmptyEvent` で UI スレッドを起こす仕組みに依存する。
これは awt-c のイベントループプリミティブ（`nmPostEmptyEvent`、別途追加予定）と組になる。

CLAUDE.md「非同期処理」セクションでは「いくつかイベントキューに関するプリミティブを提供しなければならない」とあり、awt 層に置くのが自然。
framework 層からは `app.getEventQueue()` 経由でアクセスする（`framework/doc/application.md` 参照）。

## スレッド安全性
* `invokeLater` / `invokeAndWait` は任意スレッドから安全に呼べる
* `drain` は UI スレッドのみ
* `deinit` は他スレッドからの呼び出しが完了していることを利用者が保証する

内部はミューテックスで保護されているため、複数スレッドから同時に `invokeLater` を呼んでも順序は決定的（FIFO）。

## ドレインのタイミング
ドレインは「UI スレッドが安全にタスクを実行できる時点」で行う必要がある。
Application のイベントループでは：

1. `awt.waitEvents()` — イベント待ち（OS / GUI イベントまたは `glfwPostEmptyEvent` で起きる）
2. `event_queue.drain()` — ポストされたタスクを実行
3. 各 Window の dirty 再描画
4. OS 状態同期
5. close 回収

タスクが UI 状態を変えると `layout_dirty` / `paint_dirty` が立ち、ステップ 3 でその反映が走る。
したがって「別スレッドが invokeLater で UI 更新 → 次のイベントループで自動的に再描画」が成立する。

## SecondaryLoop との関係
SecondaryLoop も内部で `awt.waitEvents` を呼ぶので、ネストしたループ中でも `invokeLater` でポストされたタスクは消化される（SecondaryLoop が drain を呼ぶ前提、`secondary_loop.md` 参照）。

## 期待される利用パターン
別スレッドで時間のかかる処理を実行し、結果を UI に反映する典型。

1. UI スレッドがワーカースレッドを spawn
2. ワーカーが長い処理を実行
3. 完了したら `invokeLater` で「結果を UI に反映するタスク」をポスト
4. UI スレッドが次のループでそのタスクを実行 → setText 等で UI 更新
5. 再描画が自動的に走る

`invokeAndWait` は「ワーカーが UI スレッドの応答を待たないと先に進めない」場合のみ使う（稀）。
理由：UI スレッドの応答時間に依存するため、ワーカーがブロックする。
通常は `invokeLater` で fire-and-forget するか、`std.Thread.Channel` などで結果を返す。

---

## 利用例
別スレッドで時間のかかる処理を実行して結果を Label に反映する例。

```zig
const WorkContext = struct {
    queue: *awt.EventQueue,
    label: *framework.Label,
    result: []u8 = undefined,
};

fn workerThread(ctx: *WorkContext) !void {
    ctx.result = try doExpensiveWork(ctx);

    // UI スレッドで Label を更新するタスクをポスト
    try ctx.queue.invokeLater(updateLabelTask, @ptrCast(ctx));
}

fn updateLabelTask(user_data: *anyopaque) void {
    const ctx: *WorkContext = @ptrCast(@alignCast(user_data));
    ctx.label.setText(ctx.result) catch return;
}

// メインスレッド
var ctx = WorkContext{ .queue = app.getEventQueue(), .label = my_label };
const t = try std.Thread.spawn(.{}, workerThread, .{&ctx});
defer t.join();

try app.run();
```

invokeAndWait の使用例（稀なケース）。
ワーカーが UI 上のダイアログ結果を待ってから先に進む場合。

```zig
// 別スレッドから
var result: DialogResult = undefined;
try queue.invokeAndWait(showDialogTask, &result);
// ここに来た時点で result が埋まっている
if (result == .ok) doNext();
```

## 機能要望
* 優先度付きタスク（重要なものを先に実行）
* タスクの cancel 機能（ポスト後にキャンセル可能）
* タスクのバッチ実行（同一タスクの重複ポストを 1 回に集約）
* タイマー連携（`invokeAfter(duration, fn, data)`）
