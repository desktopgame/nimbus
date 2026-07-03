---
unsafe: true
---

# undo_stack
型消去した `Command` の列を保持する、上限付きのアンドゥ/リドゥスタック。
特定のデータ構造に依存せず、`Command` の vtable を実装すれば任意の可逆操作を積める汎用プリミティブ。

## 型定義
```zig
pub const Command = struct {
    vtable: *const VTable,
    ctx:    *anyopaque,

    pub const VTable = struct {
        redo:        *const fn (ctx: *anyopaque) anyerror!void,
        undo:        *const fn (ctx: *anyopaque) anyerror!void,
        deinit:      *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        tryMerge:    ?*const fn (ctx: *anyopaque, next: Command) bool = null,
        displayName: ?*const fn (ctx: *anyopaque) []const u8 = null,
    };
};

pub const default_limit: usize = 200;

pub const UndoStack = struct {
    list:             std.ArrayList(Command),
    index:            usize,   // undo と redo の境界 (canUndo: index > 0)
    limit:            usize,   // 保持する最大コマンド数
    allocator:        std.mem.Allocator,
    change_listeners: listener.ChangeListenerList,
};
```

`Command` は 1 つの可逆操作を表す。`ctx` は操作固有の状態への不透明ポインタで、`vtable` の各関数がそれを解釈する。
`redo` / `undo` / `deinit` は必須、`tryMerge` / `displayName` は省略可 (既定 `null`)。
`index` は「これまでに適用済みのコマンド数」で、`[0, index)` がアンドゥ可能、`[index, list.len)` がリドゥ可能を表す。

## 関数定義

### 生成
```zig
pub fn init(allocator: std.mem.Allocator) UndoStack;
pub fn initWithLimit(allocator: std.mem.Allocator, limit: usize) UndoStack;
```

`init` は上限 `default_limit` (200) で生成する。`initWithLimit` は上限を明示する。どちらも値で返す。

### 破棄
```zig
pub fn deinit(self: *UndoStack) void;
```

保持している全コマンドの `deinit` を呼んでから、内部リストとリスナーを解放する。

### 可否の取得
```zig
pub fn canUndo(self: UndoStack) bool;
pub fn canRedo(self: UndoStack) bool;
```

`canUndo` は `index > 0`、`canRedo` は `index < list.len` を返す。

### コマンドの追加
```zig
pub fn push(self: *UndoStack, cmd: Command) !void;
pub fn ensureUnusedCapacity(self: *UndoStack, n: usize) !void;
pub fn pushAssumeCapacity(self: *UndoStack, cmd: Command) void;
```

`push` は `cmd` の所有権を受け取り、末尾へ積む。積む前にリドゥ側 (`[index, list.len)`) のコマンドを捨てる。
直前のコマンドが `cmd` を `tryMerge` で受け入れたら、`cmd` は合体先に取り込まれ `cmd` 自身は `deinit` される (スタックは伸びない)。
上限 `limit` を超えたら最古のコマンドから `deinit` して落とし、`index` を詰める。
`ensureUnusedCapacity` + `pushAssumeCapacity` は `push` の分割版。
先にリストの確保だけ済ませてから確実に積みたい呼び出し側 (`EditableText.applyEdit` の all-or-nothing) 向け。

#### 失敗時の保証
`push` が確保に失敗した場合は `cmd.deinit` を呼んでから `error.OutOfMemory` を返す (`cmd` はリークしない)。

### undo / redo
```zig
pub fn undo(self: *UndoStack) !void;
pub fn redo(self: *UndoStack) !void;
```

`undo` は直前のコマンドの `undo` を呼んで `index` を 1 減らす。`redo` は次のコマンドの `redo` を呼んで `index` を 1 増やす。
アンドゥ / リドゥ できる手が無ければ何もしない。
コマンドの `undo` / `redo` がエラーを返した場合は `index` を操作前へ戻し、状態を巻き戻す。

### 全消去
```zig
pub fn clear(self: *UndoStack) void;
```

全コマンドを `deinit` して `index` を 0 に戻す (確保容量は保持する)。

### 可否変化リスナー
```zig
pub fn addCanChangeListener   (self: *UndoStack, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeCanChangeListener(self: *UndoStack, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

`canUndo` / `canRedo` の**いずれかが変化したとき**だけ発火する (積む・戻す・進む・消去のうち、境界状態を変えたもの)。
アンドゥ / リドゥ ボタンの enable 切り替えを polling せずに受け取るために使う。`event.source` は発火元の `*UndoStack`。

### Command のメソッド
```zig
pub fn redo(self: Command) anyerror!void;
pub fn undo(self: Command) anyerror!void;
pub fn deinit(self: Command, allocator: std.mem.Allocator) void;
pub fn tryMerge(self: Command, next: Command) bool;
pub fn displayName(self: Command) ?[]const u8;
```

vtable の対応する関数へ委譲する薄いラッパー。
`tryMerge` は vtable が `null` なら常に `false`、`displayName` は `null` なら常に `null` を返す。
`deinit` の `allocator` は `ctx` とその内部確保物を解放するために渡される (コマンドを積んだときの `UndoStack.allocator` と同じ)。

---

## 利用例
可逆操作を `Command` として実装し、スタックへ積む骨組み。

```zig
const Insert = struct {
    // ... 操作固有の状態 ...

    fn redo(ctx: *anyopaque) anyerror!void { /* apply */ }
    fn undo(ctx: *anyopaque) anyerror!void { /* revert */ }
    fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*Insert, @ptrCast(@alignCast(ctx))));
    }

    const vtable = UndoStack.Command.VTable{ .redo = redo, .undo = undo, .deinit = deinit };
};

var stack = UndoStack.init(allocator);
defer stack.deinit();

const ctx = try allocator.create(Insert);
// ... ctx.* を埋める ...
try stack.push(.{ .vtable = &Insert.vtable, .ctx = ctx });

if (stack.canUndo()) try stack.undo();
if (stack.canRedo()) try stack.redo();
```

テキスト編集向けの実装済み `Command` は `EditableText` が持つ (`editable_text.md` 参照)。

## 機能要望
* `displayName` を使った「元に戻す: 〈操作名〉」形式のメニューラベル (現状 vtable にフックはあるが利用側が未実装)。
* 時間ベースのコアレッシング区切り (一定時間入力が途切れたら自動でアンドゥ単位を割る)。
