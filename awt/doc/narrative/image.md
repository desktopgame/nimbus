---
unsafe: true
---

# image
`Image` の利用方法と設計要件に関する補足。

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
