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
`@embedFile` は **call-site の相対パス** で解決される comptime 機構なので、ライブラリ関数の中に隠蔽できない
(隠すと利用者の path 起点ではなくライブラリ起点で解決されてしまう)。
そのため、`@embedFile` の呼び出しは利用者側のファイルに書いてもらう前提とする。

## 生成ファクトリの設計 (計画)
リッチな L&F のために、エンコード済みバイト列のデコード (`fromMemory`) 以外にも、CPU 側で手続き的にピクセルを生成して `Image` を作るファクトリを設ける。
**まだ未実装** であり、実装時にシグネチャを spec (`image.md`) の `## 関数定義` へ昇格させる。

```zig
pub const Axis = enum { vertical, horizontal };
pub const Stop = struct { offset: f32, color: Color };  // offset は 0..1

// axis 方向に stops を線形補間した 1×N (または N×1) のテクスチャを生成する。
pub fn linearGradient(device: Device, axis: Axis, stops: []const Stop) !Image;

// 単色 1×1 テクスチャを生成する。fill を image 経路に寄せたいとき用 (任意)。
pub fn solid(device: Device, color: Color) !Image;
```

### グラデーションを Graphics 関数にしない理由
グラデーション塗りを `Graphics` のメソッドにすると、内部で「色の組み合わせごとに極小テクスチャをキャッシュする」隠れ状態が必要になり、
寿命管理が `Graphics` (値型・フレーム借用) の責務と噛み合わない。
代わりに `Image` として生成し `drawImageScaled` で引き伸ばして描く。
これは「グラデーション = 引き伸ばされた極小テクスチャ」(`narrative/graphics.md` 参照) を素直に体現する。
寿命は通常の `Image` と同じく呼び出し側が持つ。テーマは起動時に必要な数枚を作って使い回し、テーマ破棄時に `deinit` する。

### `linearGradient` が線形フィルタに乗る仕組み
生成するのは段数ぶんのテクセルだけ (2 色なら 1×2) で、描画時の static sampler の bilinear 補間が中間色を作る。
したがって極小テクスチャを任意サイズに引き伸ばしても滑らかなグラデーションになる。

## 設計要件
* `Image` の取り扱いに必要な依存 (PNG / JPEG デコーダ等) は利用者から見えないこと。
* デコードに使う一時メモリは関数呼び出しの中で完結すること (`Image` の寿命と切り離す)。
* ビルトインアセット (CLAUDE.md 参照: Open / Save / Cut / Copy 等) を埋め込んで提供する際にも、同じ `fromMemory` API でロードできること。
