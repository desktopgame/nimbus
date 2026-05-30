---
unsafe: false
---

# font
font モジュールのスコープ境界と、上位レイヤーとの責務分担。

## awt-c で提供しないもの
以下は上位レイヤーまたは利用者側の責任とする。
* グリフアトラスの管理 — Zig 層で R8 テクスチャ + shelf packing として実装
* テキストの shaping — HarfBuzz 等の連結処理は v1 未対応
* 改行位置の決定 — line break iterator / 禁則処理は上位層
* テキスト幅の累積計算 — 上位で glyph advance を累積
* `nmDrawFont` 等のドロー API — 描画は `nmBuffer` / `nmPipeline` / `nmDraw` を組み合わせて上位層で実現
