---
unsafe: false
---

# pipeline
パイプラインに関する規約と典型パターン。

## 巻き方とカリング
頂点の巻き方は CCW (反時計回り) を front として規定する (CLAUDE.md 参照)。
back-face culling は行わない (`CullMode = NONE`)。
巻き方は描画結果に影響しないが、規約として CCW を front とする。
DX12 では `FrontCounterClockwise = TRUE` を指定して D3D デフォルト (CW front) を反転させる。

## マスク描画の典型パターン
ステンシルマスクを使ったクリッピングは、次の 2 つのパイプラインを用意することで実現する。

**Write 用パイプライン**: マスク形状を描いてステンシルに書き込む (カラーは出さない)。
* `stencil.enable = true`
* `stencil.compare_func = nmCompareFuncAlways`
* `stencil.pass_op = nmStencilOpReplace`
* `stencil.fail_op = nmStencilOpKeep`
* `stencil.depth_fail_op = nmStencilOpKeep`
* `color_write_enable = false`

**Read 用パイプライン**: ステンシルが参照値と一致する場所だけにカラーを描く。
* `stencil.enable = true`
* `stencil.compare_func = nmCompareFuncEqual`
* `stencil.pass_op = nmStencilOpKeep`
* `stencil.fail_op = nmStencilOpKeep`
* `stencil.depth_fail_op = nmStencilOpKeep`
* `color_write_enable = true`

参照値は `nmSetStencilRef` で per-draw で設定する。
