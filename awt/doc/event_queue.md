---
unsafe: true
---

# event_queue
別スレッドから UI スレッドへタスクをポストするための同期プリミティブ。
Swing の `EventQueue.invokeLater` / `invokeAndWait` 相当。
Application が 1 個所有してイベントループの末尾でドレインする。
CLAUDE.md「非同期処理」セクションも参照。

## 型定義
```zig
pub const EventQueue = struct {
    // 内部: ミューテックスで保護されたアイテムキュー + invokeAndWait 完了通知用 condvar

    // ... メソッド
};

pub const TaskFn = *const fn (*anyopaque) void;
pub const InputDispatchFn = *const fn (*anyopaque, *Event) void;

// 内部表現 (利用者は直接見ない)
const Task = struct {
    fn_ptr:    TaskFn,
    user_data: *anyopaque,
};

const InputItem = struct {
    event:       Event,
    target:      *anyopaque,
    dispatch_fn: InputDispatchFn,
};

const Item = union(enum) { task: Task, input: InputItem };
```

キューは「タスク (`invokeLater` / `invokeAndWait` の関数オブジェクト)」と「入力イベント (`postEvent`)」を同じ FIFO に並べる。
利用者が直接 `Task` / `InputItem` を構築することは無い。
3 つの post API のいずれかを使う。

## キューの生成
```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*EventQueue;
```

EventQueue を allocator で確保して初期化する。
内部のミューテックスと condvar も初期化する (`io` を `std.Io.Mutex` / 条件変数のセットアップに使う)。

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

## 入力イベントの post
```zig
pub fn postEvent(
    self: *EventQueue,
    event: Event,
    target: *anyopaque,
    dispatch_fn: InputDispatchFn,
) !void;
```

入力イベント (`Event`) をキューに追加して即座に return する。
`drain` でアイテムが取り出された時点で `dispatch_fn(target, &event)` が呼ばれる。
`target` は dispatch fn 側が解釈する不透明ポインタ。
通常は framework 層の OS 入力コールバックが `target = *framework.Window`、`dispatch_fn = Window.dispatchInputThunk` を渡す。

### 事前条件
* どのスレッドから呼んでもよい（GLFW コールバック由来の UI スレッドからの呼び出しが典型だが、テスト用合成イベントを別スレッドから注入することも可）
* `dispatch_fn` の指す関数は UI スレッドで実行される前提で書かれていること

## キューのドレイン
```zig
pub fn drain(self: *EventQueue) void;
```

キューに溜まっているアイテム（タスク + 入力イベント）をすべて post 順に処理する。
UI スレッドのみが呼ぶ前提。
通常は Application のイベントループが `awt.waitEvents` の直後に呼ぶ（`framework/doc/application.md` 参照）。

実行中に新しいアイテムがポストされてもこの `drain` 呼び出しの中では拾わない（その時点でキューにあったぶんだけ処理する）。
新しいアイテムは次のループ反復で拾われる。

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
* `.move` イベントの coalescing（連続する mouse move を 1 個にまとめて drain 時に最新値のみ配送）
