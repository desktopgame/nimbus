---
unsafe: true
---

# snapshot
ゴールデン画像テスト用の比較ヘルパ。
RGBA8 バッファを期待値 PNG と比較し、許容差を超える差分があれば内訳と差分画像を返す。

## 型定義
```zig
pub const CompareOptions = struct {
    /// チャンネルごとの絶対許容差 (0..255)。これ以下の差は一致扱い。
    /// 既定値 1 は GPU ドライバ間の丸めゆらぎを吸収するため。
    tolerance: u8 = 1,
};

pub const CompareResult = struct {
    /// `tolerance` を超えた チャンネル差の個数。0 のとき一致。
    mismatch_channels: usize,
    /// 観測された最大のチャンネル差 (許容差にかかわらず)。
    /// 診断メッセージ用。
    max_diff: u8,

    pub fn ok(self: CompareResult) bool;
};
```

`CompareResult.ok()` は `mismatch_channels == 0` を返す。

## ピクセル比較
```zig
pub fn compare(actual: []const u8, expected: []const u8, opts: CompareOptions) CompareResult;
```

`actual` と `expected` を 1 バイトずつ比較する。
両者は同じ画像サイズを表す RGBA8 バッファである前提で、長さが一致している必要がある。

### 事前条件
* `actual.len == expected.len` であること。違反した場合の動作は UB (debug ビルドでは assert で弾く)。

## PNG の読み込み
```zig
pub fn readPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected_w: usize,
    expected_h: usize,
) ![]u8;
```

`path` の PNG を読み込み、RGBA8 (`expected_w * expected_h * 4` バイト) として返す。
内部で `zigimg` を使う。戻り値の所有権は呼び出し側で、`allocator.free` で解放する。

ファイルの寸法が `expected_w` / `expected_h` と一致しない場合は `error.SnapshotSizeMismatch` を返す。
ファイル不存在は `error.FileNotFound`、その他 zigimg のデコードエラーはそのまま伝播。

## PNG の書き込み
```zig
pub fn writePng(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rgba: []const u8,
    w: usize,
    h: usize,
) !void;
```

RGBA8 バッファを `path` に PNG として書き出す。
親ディレクトリは事前に存在している必要がある (呼び出し側で `std.Io.Dir.cwd().createDirPath` を使う)。

### 事前条件
* `rgba.len == w * h * 4` であること。違反した場合の動作は UB (zigimg 側で内部 assert)。

## 差分画像の生成
```zig
pub fn diffImage(
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
) ![]u8;
```

チャンネルごとに `|actual - expected|` を 5 倍に増幅 (255 でクランプ) し、アルファを 255 (不透明) にした画像を返す。
一致箇所は黒、不一致は明るく光る。目視で差分の位置を即特定するのが用途。

戻り値の所有権は呼び出し側で、`allocator.free` で解放する。

### 事前条件
* `actual.len == expected.len` であること。違反した場合の動作は UB (debug ビルドでは assert)。

---

## 利用例
ゴールデン画像テストの典型フロー。

```zig
const std = @import("std");
const awt = @import("awt");

fn assertRenderMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    actual_rgba: []const u8,
    w: usize,
    h: usize,
    fixture_path: []const u8,
) !void {
    const expected = try awt.snapshot.readPng(allocator, io, fixture_path, w, h);
    defer allocator.free(expected);

    const result = awt.snapshot.compare(actual_rgba, expected, .{ .tolerance = 1 });
    if (!result.ok()) {
        std.debug.print(
            "{} channel(s) exceed tolerance (max diff {})\n",
            .{ result.mismatch_channels, result.max_diff },
        );
        // 差分画像を保存して目視確認用に残す
        const diff = try awt.snapshot.diffImage(allocator, actual_rgba, expected);
        defer allocator.free(diff);
        try awt.snapshot.writePng(allocator, io, "tmp/diff.png", diff, w, h);
        return error.SnapshotMismatch;
    }
}
```

`actual_rgba` は通常 `awt.RenderTarget.readback` の結果。
fixture の初回作成 / 環境変数による一括更新 / 失敗時アーティファクトの命名規約等は利用側 (テストハーネス) の責任で、本モジュールはそれらに関与しない。

## 機能要望
* SSIM 等の知覚的画像差分メトリクス (現状は単純なチャンネル差分のみ)。
* PNG 以外のフォーマット (BMP / JPEG) の読み書きヘルパ。
