---
unsafe: false
---

# gapbuffer
編集位置に「ギャップ」を持たせたバイト列。
同じ位置への連続編集を amortized O(1) で行えるようにし、`TextField` より長い文字列を扱う `TextArea` のバッキングに使う。
エンコーディングには非依存で、UTF-8 の境界判定は呼び出し側 (`TextArea`) が担う。

## 型定義
```zig
pub const GapBuffer = struct {
    buf:       []u8,                 // バッキング領域。ギャップは [gap_start, gap_end)
    gap_start: usize,
    gap_end:   usize,
    allocator: std.mem.Allocator,
};
```

公開する位置はすべて **論理バイトオフセット** `[0, len()]` で、ギャップは呼び出し側から見えない。
論理長は `buf.len - (gap_end - gap_start)`。

## 生成
```zig
pub fn init(allocator: std.mem.Allocator) GapBuffer;
pub fn initFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !GapBuffer;
```

`init` は空のバッファを返す (バッキング未確保)。
`initFromSlice` は `bytes` を初期内容としてコピーする。失敗時は途中で確保した分を解放する。

## 破棄
```zig
pub fn deinit(self: *GapBuffer) void;
```

バッキング領域を解放する。以後の使用は UB。

## 長さ
```zig
pub fn len(self: GapBuffer) usize;
```

ギャップを除いた論理バイト長を返す。

## バイトの参照
```zig
pub fn byteAt(self: GapBuffer, i: usize) u8;
```

論理インデックス `i` のバイトを返す。

### 事前条件
* `i < len()` であること。違反した場合は UB。

## 範囲のコピー
```zig
pub fn copyRange(self: GapBuffer, dst: []u8, start: usize, end: usize) void;
```

論理範囲 `[start, end)` を `dst` へコピーする。
ギャップをまたぐ範囲は 2 回の memcpy で処理する。

### 事前条件
* `start <= end <= len()` かつ `dst.len >= end - start` であること。違反した場合は UB。

## ギャップの移動
```zig
pub fn moveGap(self: *GapBuffer, pos: usize) void;
```

`gap_start == pos` (論理) になるようギャップを動かす。移動量に比例したコスト。

## 挿入
```zig
pub fn insert(self: *GapBuffer, pos: usize, bytes: []const u8) !void;
```

論理位置 `pos` に `bytes` を挿入する。
必要ならバッキングを拡張する (拡張時はギャップを論理位置を保ったまま再配置する)。

## 削除
```zig
pub fn delete(self: *GapBuffer, pos: usize, count: usize) void;
```

論理位置 `pos` から `count` バイトを削除する。`count` は残り長にクランプされる。

## 置換
```zig
pub fn replace(self: *GapBuffer, start: usize, count: usize, bytes: []const u8) !void;
```

`[start, start+count)` を `bytes` で置き換える。`delete` + `insert` を 1 呼び出しにまとめたもの (キャレット計算が単純になる)。

## クリア
```zig
pub fn clear(self: *GapBuffer) void;
```

内容をすべて捨てる。バッキング領域は再利用のため保持する。

## 機能要望
* 行インデックスの内蔵 (現状は呼び出し側が走査)。巨大テキストでの行モデル再構築を O(編集量) にしたい場合に有用。
* piece table への差し替え余地 (undo/redo を効率化したくなった場合)。公開 API は論理オフセットなので、内部表現の差し替えは閉じている。
