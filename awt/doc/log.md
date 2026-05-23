# log
ログ出力に関する設計ノート。
awt 層および framework 層が「失敗したが続行する」種の事象を利用者に通知するための仕組み。
awt-c の `nm_log` (`awt-c/doc/log.md` 参照) を取り込み、Zig 側からのメッセージと併せて単一のコールバックに集約する。

## 型定義
C 側 (awt-c から再利用):
```c
typedef enum nmLogLevel {
    nmLogLevelDebug,
    nmLogLevelInfo,
    nmLogLevelWarn,
    nmLogLevelError,
} nmLogLevel;

typedef void (*nmLogCallback)(nmLogLevel level, const char* category, const char* message, void* user_data);
```

Zig 側 (C 型の薄いエイリアス):
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

`Level` / `Callback` は awt-c の同名型 (`nmLogLevel` / `nmLogCallback`) と ABI 互換になるよう揃える。
awt 層独自の意味論を新規に定義することはしない。
これにより「C 側の内部エラー」と「awt / framework から流すメッセージ」を 1 つの出口で受けられる。

Zig 側の `Level.err` だけは `error` が予約語のため `err` を使う (`std.log` 慣習と一致)。

`category` は発生源を示す短い文字列リテラル。
awt-c 由来は `"shader"`, `"dx12"`, `"glfw"`, `"device"` 等、awt / framework 由来は `"window"`, `"menu"`, `"event_queue"` 等を想定する。
列挙にせず文字列で運ぶことで、内部実装の都合で増減しても ABI に影響しない (`awt-c/doc/log.md` と同方針)。

`message` は NUL 終端された UTF-8 文字列。
コールバック呼び出しの間のみ有効で、利用者が後から参照したい場合は呼び出し側で複製する。

## ログコールバックの設定
```c
void nmSetLogCallback(nmLogCallback cb, void* user_data);
```
```zig
pub fn setCallback(cb: ?Callback, user_data: ?*anyopaque) void;
```

awt-c の `nmSetLogCallback` をそのまま転送する薄いラッパー。
awt 内部から発生したメッセージも、awt-c 内部から発生したメッセージも、ここで登録した単一のコールバックに同期的に届く。
awt が起動時 (`nmInitAwt` の延長) に内部の橋渡し関数を awt-c 側にセットするため、利用者が個別に awt-c の API を呼ぶ必要はない。

`cb` に `null` を渡すとデフォルト挙動 (`stderr` への `[LEVEL] [category] message\n` 形式の出力) に戻る。
コールバック未設定時もこのデフォルトが適用されるため、開発初期に何も設定しなくても重要なメッセージが見える。

### 事前条件
* `awt.init()` の前後どちらからでも呼び出し可能。
* 別スレッドからの呼び出しは想定しない (nimbus は単一 UI スレッド前提)。

## デバッグメッセージの出力
```c
void nmLogDebug(const char* category, const char* fmt, ...);
```
```zig
pub fn debug(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`nmLogLevelDebug` でメッセージを 1 件流す。
開発時の詳細追跡 (リソース生成ログ等) を想定する。
本番ではコールバック側でフィルタすることを前提に、頻繁に呼んでも構わない。

C 側の `fmt` は `printf` 書式文字列。
Zig 側の `fmt` は `comptime []const u8` で、`std.fmt.bufPrint` と同じ書式 (`{s}`, `{d}` 等)。
どちらも内部で 1024 バイトのスタックバッファに format してから C 側コールバックに渡す。
バッファを超えた部分は捨てる (awt-c の `nm_log` と同じバッファサイズ)。

Zig 側の `category` は NUL 終端不要 (`[]const u8` で渡し、内部で C へ受け渡す際に短期の NUL 終端コピーを作る)。

## 情報メッセージの出力
```c
void nmLogInfo(const char* category, const char* fmt, ...);
```
```zig
pub fn info(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`nmLogLevelInfo` でメッセージを流す。
通常動作中の状態通知 (`"window created (1280x720)"` 等) を想定する。
書式・バッファサイズ・カテゴリの扱いは `nmLogDebug` / `debug` と同じ。

## 警告メッセージの出力
```c
void nmLogWarn(const char* category, const char* fmt, ...);
```
```zig
pub fn warn(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`nmLogLevelWarn` でメッセージを流す。
動作は継続するが利用者に気付いてほしい事象を示す。
典型例:
* メニュー展開中の OOM (展開を諦めるが UI ループは継続)
* 入力イベントキューの push 失敗 (該当イベントを取り落とすが UI ループは継続)
* swapchain のリサイズ失敗 (次フレームに望みを託す)

GUI フレームワーク慣習として、これらは握りつぶしてループを継続するのが正解で、その「沈黙」を観測可能にするのが本関数の主な役割。

## エラーメッセージの出力
```c
void nmLogError(const char* category, const char* fmt, ...);
```
```zig
pub fn err(category: []const u8, comptime fmt: []const u8, args: anytype) void;
```

`nmLogLevelError` でメッセージを流す。
失敗した操作の詳細 (シェーダーコンパイル時のエラー文字列等) を想定する。
関数が `null` / `error` で失敗を返した場合に、その原因をここで詳細出力する。
利用者はコールバックを設定することでエラーの原因を取得できる。

Zig 側関数名が `err` なのは `error` が予約語のため (型定義の `Level.err` と同じ理由)。

### 診断情報
本関数自体は診断情報を出力しない (出力する側なので)。

---

## 依存関係
awt-c 層の `nm_log` (`awt-c/src/nm_log.c`) に依存し、その上に Zig からの呼び出し口を生やしている。
awt は起動時に awt-c 側へ自身の橋渡し用関数を `nmSetLogCallback` で登録し、awt-c 内部から流れてきたログを Zig 側の dispatcher に取り込む。
dispatcher は「awt 自身が登録された外部コールバック」を最終出口とする。

```
awt-c 内部 (nm_log) ──┐
                     ├─→ awt の dispatcher ─→ 利用者が登録した nmLogCallback
awt / framework  ────┘
```

framework 層は awt-c を直接 import せず、`awt.log.warn(...)` のような awt API 経由でログを出す。
これによりレイヤー (`framework → awt → awt-c`) を守ったまま、利用者から見た出口は 1 つに保たれる。

## ログレベルの想定用途
awt-c の `nmLogLevel` と同じ運用方針を採る (`awt-c/doc/log.md` 参照)。

* `nmLogLevelDebug`: 開発時の詳細追跡。本番ではコールバック側でフィルタ可能。
* `nmLogLevelInfo`: 通常の動作情報。
* `nmLogLevelWarn`: 動作は継続するが注意が必要な事象。
* `nmLogLevelError`: 失敗した操作のエラー詳細。

awt / framework 層の握りつぶし箇所 (CLAUDE.md「エラーのC_ABIでの表現」および本リポジトリの監査 `doc/audit-2026-05-23.md` 参照) は、原則として `nmLogLevelWarn` でログを出してから握りつぶす方針とする。
握りつぶし自体は GUI 慣習として保ったまま、観測手段を確保する。

## カテゴリ命名
発生源モジュールに対応する短い小文字の文字列を使う。
awt 側で現状想定する category:

| 文字列 | 発生源 |
| --- | --- |
| `"window"` | `awt/src/Window.zig` / `framework/src/Window.zig` |
| `"event_queue"` | `awt/src/EventQueue.zig` |
| `"menu"` | `framework/src/Menu.zig`, `MenuBar.zig`, `PopupMenu.zig` |
| `"component"` | `framework/src/Component.zig` |
| `"graphics"` | `awt/src/Graphics.zig` |
| `"font"` | `awt/src/Font.zig`, `GlyphAtlas.zig` |
| `"image"` | `awt/src/Image.zig` |

awt-c から流れる category (`"shader"`, `"dx12"`, `"glfw"`, `"device"`, `"buffer"`, `"pipeline"`, `"texture"`, ...) はそのまま透過する。
両者で名前が衝突した場合は、awt-c のものに合わせて Zig 側を変更する。

## 利用例
ログ全体を自前の処理に流したい場合:

```zig
fn onLog(level: awt.LogLevel, category: [*:0]const u8, message: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    // utilizer 側の logging framework に流す等
    std.debug.print("[{s}] {s}: {s}\n", .{ @tagName(level), category, message });
}

pub fn main(init: std.process.Init) !void {
    awt.setLogCallback(onLog, null);

    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();
    // ...
}
```

開発中、まず stderr に流れるデフォルト挙動だけで十分なら `setLogCallback` を呼ばなくてよい。

## 機能要望
* ログレベルごとの個別 enable/disable フラグ (現状は受け取り側がフィルタする前提)
* category ごとの subscribe (現状は全 category が同じコールバックに流れる)
* スレッドセーフな登録 (現状は UI スレッド前提)
