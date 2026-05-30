---
unsafe: true
---

# sampler
サンプラーに関する設計ノート。
nimbus では static sampler のみサポートし、利用者はバインド操作をしない。

## 機能要望
以下が必要になったら API を追加する。それまでは対応しない。
* カスタムフィルタ・アドレッシングの組み合わせ
* Anisotropic フィルタリング
* Mirror / Border アドレッシング
* LOD bias、MIP min/max
* Compare サンプラー (シャドウマップ用)
