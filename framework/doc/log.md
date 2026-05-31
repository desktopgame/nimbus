---
unsafe: false
---

# log
ログ出力に関する設計ノート。
framework 層 (Component / Container / Window / Menu / Application 等) が「失敗したが続行する」種の事象を利用者に通知するための仕組み。

awt 層の log システム (`awt/doc/log.md`) とは独立した dispatcher を持つ。
両方からメッセージを受け取りたい利用者は `framework.log.setCallback` と `awt.log.setCallback` の両方に同じコールバックを登録する。

## 型定義
```zig
pub const Level = enum(c_int) {
    debug = 0,
    info  = 1,
    warn  = 2,
    err   = 3,
};

pub const Callback = *const fn (
    level: Level,
    category: [*:0]const u8,
    message: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void;
```

`Level` / `Callback` は awt の同名型と**意図的に同じ shape** にしてある。
両方に同じ関数ポインタを登録できるようにするためで、意味論的に独立しているのは dispatcher のみ。

`Level.err` だけは `error` が予約語のため `err` を使う (`std.log` 慣習と一致)。

`category` は発生源を示す短い文字列リテラル (`"window"`, `"menu"`, `"component"` 等)。
列挙にせず文字列で運ぶことで、内部実装の都合で増減しても ABI に影響しない (`awt-c/doc/log.md` と同方針)。

`message` は NUL 終端された UTF-8 文字列。
コールバック呼び出しの間のみ有効で、利用者が後から参照したい場合は呼び出し側で複製する。

## ログコールバックの設定
```zig
pub fn setCallback(cb: ?Callback, user_data: ?*anyopaque) void;
```

framework 層から発生したメッセージを受け取るコールバックを登録する。
内部の静的な変数 (`g_cb` / `g_user`) に格納し、以降の `debug` / `info` / `warn` / `err` 呼び出しはここに同期的にディスパッチされる。

awt-c には全く触らない。
awt 層のメッセージや awt-c の内部エラーはここには届かない (`awt/doc/log.md` 参照)。

`cb` に `null` を渡すとデフォルト挙動 (`stderr` への `[LEVEL] [category] message\n` 形式の出力) に戻る。
コールバック未設定時もこのデフォルトが適用されるため、開発初期に何も設定しなくても重要なメッセージが見える。

### 事前条件
* `Application.init()` の前後どちらからでも呼び出し可能。
* 別スレッドからの呼び出しは想定しない (nimbus は単一 UI スレッド前提)。

## デバッグメッセージの出力
```zig
pub fn debug(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`Level.debug` でメッセージを 1 件流す。
開発時の詳細追跡 (内部状態の変化等) を想定する。
本番ではコールバック側でフィルタすることを前提に、頻繁に呼んでも構わない。

`fmt` は `comptime []const u8` で、`std.fmt.bufPrint` と同じ書式 (`{s}`, `{d}` 等)。
内部で 1024 バイトのスタックバッファに format してから dispatcher に渡す。
バッファを超えた部分は捨てる (awt 側と同じ saturating truncation)。

`category` は NUL 終端不要 (`[]const u8` で渡し、内部で短期の NUL 終端コピーを 64 バイトのスタックバッファに作る)。

## 情報メッセージの出力
```zig
pub fn info(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`Level.info` でメッセージを流す。
通常動作中の状態通知を想定する。
書式・バッファサイズ・カテゴリの扱いは `debug` と同じ。

## 警告メッセージの出力
```zig
pub fn warn(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`Level.warn` でメッセージを流す。
動作は継続するが利用者に気付いてほしい事象を示す。
典型例:
* メニュー展開時の OOM (展開を諦めるが UI ループは継続)
* 入力イベントキューへの post 失敗 (該当イベントを取り落とすが UI ループは継続)
* リスナー登録の OOM (該当リスナーが無効化されるが widget 構築は完了)

GUI フレームワーク慣習として、これらは握りつぶしてループを継続するのが正解で、その「沈黙」を観測可能にするのが本関数の主な役割。

## エラーメッセージの出力
```zig
pub fn err(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`Level.err` でメッセージを流す。
失敗した操作の詳細を想定する。
関数が `error` で失敗を返した場合に、その原因をここで詳細出力する。
利用者はコールバックを設定することでエラーの原因を取得できる。

Zig 側関数名が `err` なのは `error` が予約語のため (型定義の `Level.err` と同じ理由)。

### 診断情報
本関数自体は診断情報を出力しない (出力する側なので)。

## 利用例
framework 側のログだけ拾う場合:

```zig
fn onFwLog(level: framework.log.Level, category: [*:0]const u8, message: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    std.debug.print("[fw][{s}] {s}: {s}\n", .{ @tagName(level), category, message });
}

pub fn main(init: std.process.Init) !void {
    framework.log.setCallback(onFwLog, null);

    const app = try framework.Application.init(init.gpa, init.io);
    defer app.deinit();
    // ...
}
```

awt 側も同じハンドラに集約したい場合:

```zig
framework.log.setCallback(onFwLog, null);
awt.log.setCallback(@ptrCast(&onFwLog), null);  // 同じ shape なので登録可能
```

ソースを識別したいなら user_data を分けるか、ログメッセージ側で source-tagged な category を使う。

開発中、まず stderr に流れるデフォルト挙動だけで十分なら `setCallback` を呼ばなくてよい。

## 機能要望
* ログレベルごとの個別 enable/disable フラグ (現状は受け取り側がフィルタする前提)
* category ごとの subscribe (現状は全 category が同じコールバックに流れる)
* スレッドセーフな登録 (現状は UI スレッド前提)
* `awt.log` との統合的な subscribe API (利用者が 1 回の呼び出しで両方を購読できる) — 現状は 2 回の `setCallback` で代替可能
