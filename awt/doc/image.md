---
unsafe: false
---

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

## 機能要望
* `Image.fromFile` (パスから直接読み込み、内部で fs アクセス)。
* リサイズ / 部分切り出し用の API。
* mipmap 生成 (現状は単一レベルのみ)。
* 動画 / アニメーション GIF のフレーム抽出。
