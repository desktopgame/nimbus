---
unsafe: true
---

# render_target
awt-c の `nmRenderTarget` を Zig から扱いやすい形に再公開するモジュール。
スワップチェインから借用したレンダーターゲットと、 オフスクリーン用に新規生成したレンダーターゲットを同じ型で扱う。
描画結果を CPU メモリ / PNG ファイルに読み戻すヘルパも提供する。

## 依存関係
`awt-c` の `nmRenderTarget` 関連 API (`nmCreateRenderTarget` / `nmDestroyRenderTarget` / `nmReadbackRenderTarget`) に依存する。
PNG エンコードは `zigimg` を使う (`Image` と同じ依存)。

## 型定義
```zig
pub const RenderTarget = struct {
    handle: *c.struct_nmRenderTarget,
    // 借用 / 所有の区別はソース側で表現する
};
```

`RenderTarget` は薄いハンドルラッパー。
**「借用」 (`Swapchain.getTarget` の戻り値)** と **「所有」 (`create` で生成)** の 2 種があり、所有のみ `deinit` を呼ぶ。
借用に対する `deinit` 呼び出しは UB (`nmDestroyRenderTarget` のセマンティクスに従う)。

## オフスクリーンレンダーターゲットの生成
```zig
pub fn create(device: Device, width: i32, height: i32) !RenderTarget;
```

オフスクリーン用のレンダーターゲットを指定サイズで生成する。
内部で `nmCreateRenderTarget` を呼ぶ。
失敗時は `error.RenderTargetCreateFailed` を返す。

### 事前条件
* `width` / `height` がいずれも 1 以上であること (`nmCreateRenderTarget` の事前条件)。違反した場合の動作は UB。

## レンダーターゲットの破棄
```zig
pub fn deinit(self: *RenderTarget) void;
```

`create` で生成したレンダーターゲットを破棄する。
内部で `nmDestroyRenderTarget` を呼ぶ。

### 事前条件
* `self` が `create` の戻り値であること。`fromBorrowed` で構築したものに対して呼んではならない (借用元が所有しているため)。違反した場合の動作は UB。

## 借用ハンドルからの構築
```zig
pub fn fromBorrowed(handle: *c.struct_nmRenderTarget) RenderTarget;
```

スワップチェインから取得した raw ハンドルを `RenderTarget` でラップする。
所有権はラップ元 (スワップチェイン) に残るため、 `deinit` を呼んではならない。

## CPU への raw 読み戻し
```zig
pub fn readback(self: RenderTarget, width: i32, height: i32, out_rgba: []u8) !void;
```

`self` の現在の内容を `out_rgba` に **隙間なし RGBA8** で書き出す。
内部で `nmReadbackRenderTarget` を呼ぶ。
失敗時は `error.ReadbackFailed` を返す。

`width` / `height` は `self` の実寸 (生成時と同じ値) を渡す。

### 事前条件
* `out_rgba.len` が `width * height * 4` 以上であること。違反した場合の動作は UB。
* `self` がオフスクリーン由来で、 書き込み中のコマンドバッファが存在しないこと (`nmReadbackRenderTarget` の事前条件)。違反した場合の動作は UB。

## PNG ファイルへの書き出し
```zig
pub fn readbackToPng(
    self: RenderTarget,
    allocator: std.mem.Allocator,
    io: std.Io,
    width: i32,
    height: i32,
    path: []const u8,
) !void;
```

`readback` でピクセルを取得し、 `zigimg` で PNG エンコードして `path` に書き出す。
`allocator` は readback バッファと PNG エンコーダの一時メモリに使う (関数戻り時に解放済み)。
`io` は zigimg がファイル書き込みに使う (`std.Io` ベース)。

### 事前条件
* `readback` と同じ (生成時の寸法と一致する `width` / `height` 等)。
* 書き出し先の親ディレクトリが存在すること (本関数はディレクトリを作らない)。違反した場合はエラーを返す。

### 失敗時のエラー
* `error.ReadbackFailed` — awt-c の readback が失敗
* `error.OutOfMemory` — バッファ確保失敗
* `error.FileCreateFailed` / `error.PngEncodeFailed` — 書き出し / エンコード失敗

## 機能要望
* サイズ取得アクセサ (`size()` 等)。現状は生成時の寸法を利用側が覚えておく必要がある。
* スワップチェイン由来 RT の `readback` 対応 (実ウィンドウ画面のスナップショット用途)。
* `readbackToBmp` / `readbackToBytes` 等の他フォーマット対応。
* 期待 PNG との diff ヘルパ (ゴールデン画像テスト用)。
