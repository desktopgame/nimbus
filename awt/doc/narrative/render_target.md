---
unsafe: false
---

# render_target
awt 層の `RenderTarget` のスナップショット用途と設計要件。

## オフスクリーンスナップショットの典型用法
ウィンドウを開かずに 1 枚の絵を PNG に焼き出す手順。
テスト / `examples/snapshot` (将来) / Claude 自走時の視覚確認等で使う:

```zig
const dev = try Device.init();
defer dev.deinit();

var rt = try RenderTarget.create(dev, 800, 600);
defer rt.deinit();

// Context (programs / rings / atlas) を組み立てる
var ctx = try Graphics.Context.init(...);
defer ctx.deinit();

// 1 フレーム paint
var cb = try CommandBuffer.acquire(dev);
defer cb.release();
ctx.uniforms.reset();
ctx.vertex_ring.reset();

cb.begin();
cb.bindRenderTarget(rt);
cb.clearColor(...);

var g = Graphics.init(cb, &ctx, 800, 600, 800, 600);
// ここで好きな描画
g.setColor(.{ ... });
g.fillRect(.{ .x = 100, .y = 100, .width = 200, .height = 100 });

cb.end();
cb.submit(dev);

// readback は内部で GPU 完了待ちをするので、 submit 後すぐ呼んで良い
try rt.readbackToPng(allocator, io, 800, 600, "tmp/snap.png");
```

このパターンは `Application` / `Frame` / `Swapchain` を経由しないので、 ウィンドウが画面に出ない。
作業中のデスクトップを邪魔しないため、 自動化に向いている。

## 設計要件
* スワップチェイン借用と新規生成を同じ `RenderTarget` 型で扱える (描画 API 側は所有関係を意識しない)。
* スナップショット (readback) は `Application` / `Window` / `Swapchain` を経由せずに完結できる (画面を出さない、 オフライン用途) こと。これによりテストや自動視覚確認のための無人実行が可能になる。
* PNG ヘルパは `zigimg` への依存を隠蔽し、 利用側が encoder の API を意識しないで済むこと。
