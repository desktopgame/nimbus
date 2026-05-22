# image
画像リソースの管理。
エンコード済みの画像バイト列をデコードして GPU テクスチャとして保持する。

## 型定義
```zig
pub const Image = struct {
    texture: Texture,
    width: i32,
    height: i32,

    pub fn fromMemory(allocator: std.mem.Allocator, device: Device, bytes: []const u8) !Image;
    pub fn deinit(self: *Image) void;
};
```

`texture` は GPU 上のテクスチャ。
`width` / `height` は実ピクセル単位の寸法。

`Image` はデコード済みの GPU リソースを保持するだけで、CPU 側のピクセルバッファは持たない。

サポートする画像形式は CLAUDE.md の方針に従い、PNG / JPEG / GIF (静止画) / BMP。

## メモリからの生成
```zig
pub fn fromMemory(allocator: std.mem.Allocator, device: Device, bytes: []const u8) !Image;
```

エンコード済みの画像バイト列をデコードして GPU テクスチャを生成する。
`bytes` の参照は本関数から戻るまでの間のみ必要。

`allocator` はデコードとフォーマット変換のための **一時バッファ確保にのみ** 使われる。
関数から戻った時点で `allocator` から確保したメモリはすべて解放されており、`Image` には GPU テクスチャしか残らない。
利用者は本関数の呼び出しに使ったアロケータを `Image` の寿命とは独立に扱える。

### 事前条件
* `bytes` がサポート形式 (PNG / JPEG / GIF / BMP) のいずれかとして有効なエンコードであること。違反した場合はエラーを返す。

## 破棄
```zig
pub fn deinit(self: *Image) void;
```

`Image` が保持する GPU テクスチャを解放する。

## 利用方法 (`@embedFile` との組み合わせ)
バイナリに埋め込んだ画像を読みたい場合は `@embedFile` で得たバイト列を `fromMemory` に渡す。
```zig
const png_bytes = @embedFile("assets/example.png");
var image = try awt.Image.fromMemory(allocator, device, png_bytes);
defer image.deinit();
```

### `Image.fromEmbedded` を提供しない理由
`@embedFile` は **call-site の相対パス** で解決される comptime 機構なので、ライブラリ関数の中に隠蔽することができない (隠すと利用者の path 起点ではなくライブラリ起点で解決されてしまう)。
そのため、`@embedFile` の呼び出しは利用者側のファイルに書いてもらう前提とする。

## 設計要件
* `Image` の取り扱いに必要な依存 (PNG / JPEG デコーダ等) は利用者から見えないこと。
* デコードに使う一時メモリは関数呼び出しの中で完結すること (`Image` の寿命と切り離す)。
* ビルトインアセット (CLAUDE.md 参照: Open / Save / Cut / Copy 等) を埋め込んで提供する際にも、同じ `fromMemory` API でロードできること。

## 機能要望
* `Image.fromFile` (パスから直接読み込み、内部で fs アクセス)。
* リサイズ / 部分切り出し用の API。
* mipmap 生成 (現状は単一レベルのみ)。
* 動画 / アニメーション GIF のフレーム抽出。
