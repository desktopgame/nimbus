# render_target
レンダーターゲットに関する設計ノート。
描画コマンドの出力先となる GPU リソース。

## 型定義
```c
typedef struct nmRenderTarget nmRenderTarget;
```

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、描画先のリソースと付随するビュー類を保持する。
たとえば、以下のようなもの。
* 描画対象のテクスチャリソース
* ステンシル用のリソース
* それらに対する RTV / DSV

`nmRenderTarget` は次の 2 系統で得られる。
* `nmCreateRenderTarget` で利用者が明示的に生成 (オフスクリーン用)
* `nmGetSwapchainTarget` でスワップチェインから借用 (表示用)

ステンシルバッファは `nmRenderTarget` に常に含まれる。
デプスバッファは現時点では含まれない。

## リソース状態の遷移
DX12 におけるリソース状態 (PRESENT / RENDER_TARGET / PIXEL_SHADER_RESOURCE 等) の遷移は内部で自動的に処理される。
利用者は状態遷移を意識する必要はない。

## ウィンドウサイズ変更時の挙動
スワップチェイン由来のレンダーターゲットは `nmResizeSwapchain` が呼ばれた時点で内部的に再作成される。
利用者は何もする必要はないが、`nmGetSwapchainTarget` で取得したポインタはリサイズで無効になるため、キャッシュせずに毎フレーム再取得すること。

オフスクリーンのレンダーターゲットはウィンドウサイズには追従しない。
作成時のサイズで保持され続けるため、ウィンドウサイズに合わせたい場合は利用者が `nmDestroyRenderTarget` + `nmCreateRenderTarget` で作り直す。

## レンダーターゲットの生成
nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height);

オフスクリーン用のレンダーターゲットを指定サイズで生成する。
失敗時は `NULL` を返す。

### 事前条件
* `width` / `height` がいずれも 1 以上であること。違反した場合の動作は UB。

## レンダーターゲットの破棄
void nmDestroyRenderTarget(nmRenderTarget* self);

レンダーターゲットを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。
* `self` が `nmGetSwapchainTarget` の戻り値であってはならない。違反した場合の動作は UB。

## スワップチェインからの取得
nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self);

スワップチェインの現フレームの描画先となるレンダーターゲットを返す。
返されたポインタはスワップチェインが所有しており、寿命はスワップチェインに従う (スワップチェインのリサイズや破棄で無効になる)。

## レンダーターゲットのバインド
void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target);

以後の描画コマンドの出力先として `target` を設定する。
内部的に必要なリソース状態遷移が自動で挿入される。
ビューポートは `target` の全域に設定される。部分描画には `nmSetViewport` を併用する。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。違反した場合の動作は UB。

## ビューポートの設定
void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height);

現在バインドされているレンダーターゲットへの描画範囲を設定する。
`nmBindRenderTarget` 直後の全域設定を上書きする場合に使う。
内部的にシザー矩形も同じ矩形に設定される (`nmSetScissor` で個別に上書き可能)。

### 事前条件
* この呼び出しの前に `nmBindRenderTarget` でレンダーターゲットがバインドされていること。違反した場合の動作は UB。

## シザー矩形の設定
void nmSetScissor(nmCommandBuffer* self, int x, int y, int width, int height);

現在バインドされているレンダーターゲットのシザー矩形 (描画を制限する矩形クリップ) を設定する。
ビューポートとは独立に上書きできる。

GUI でウィジェット単位のクリッピングを実装する典型用途は以下。
* `nmBindRenderTarget` → ビューポートとシザー矩形がレンダーターゲット全域に設定される
* `nmSetScissor(ウィジェットの矩形)` → 以後の描画はその範囲に切り取られる
* draw → ウィジェットが描画される
* `nmSetScissor(...)` → 次のウィジェット用にシザー矩形を切替

シザーとステンシルマスクは以下のように使い分ける。
* 矩形クリップ → `nmSetScissor` (軽量、GPU 機能の直叩き)
* 任意形状クリップ (角丸 / 曲線等) → ステンシルマスク

`nmSetViewport` を呼ぶとシザー矩形がビューポートと同じ矩形にリセットされるため、シザー矩形を独立に保ちたい場合は **`nmSetViewport` の後** で `nmSetScissor` を呼ぶこと。

### 事前条件
* この呼び出しの前に `nmBindRenderTarget` でレンダーターゲットがバインドされていること。違反した場合の動作は UB。

## カラーのクリア
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a);

現在バインドされているレンダーターゲットを指定色でクリアする。
ステンシルバッファのクリアは `nmClearStencil` を使う。

### 事前条件
* この呼び出しの前に `nmBindRenderTarget` でレンダーターゲットがバインドされていること。違反した場合の動作は UB。

## ステンシルのクリア
void nmClearStencil(nmCommandBuffer* self, uint8_t value);

現在バインドされているレンダーターゲットのステンシルバッファを指定値でクリアする。
通常は `0` を渡してマスクをリセットする。

### 事前条件
* この呼び出しの前に `nmBindRenderTarget` でレンダーターゲットがバインドされていること。違反した場合の動作は UB。

## 機能要望
* フォーマットを引数で指定する API (現状はオフスクリーンは標準的なカラーフォーマット固定、スワップチェイン由来はスワップチェインに従う)。
* デプスバッファのサポート (現状はステンシルのみ)。
* オフスクリーンレンダーターゲットのリサイズ API (現状は作り直しが必要)。
