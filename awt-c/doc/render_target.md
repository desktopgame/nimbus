# render_target
レンダーターゲットに関する設計ノート。
描画コマンドの出力先となる GPU リソース。

## 型定義
typedef struct nmRenderTarget nmRenderTarget;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、描画先のリソースと付随するビュー類を保持する。
たとえば、以下のようなものです。
* 描画対象のテクスチャリソース
* ステンシル用のリソース
* それらに対する RTV / DSV

`nmRenderTarget` は次の 2 系統で得られる。
* `nmCreateRenderTarget` で利用者が明示的に生成（オフスクリーン用）
* `nmGetSwapchainTarget` でスワップチェインから借用（表示用）

### フォーマット
当面はフォーマットを引数で指定しない。
オフスクリーンは標準的なカラーフォーマット、スワップチェイン由来のものはスワップチェインに従う。
将来必要になったら拡張する。

### デプス / ステンシル
ステンシルバッファは `nmRenderTarget` に常に含まれる。
デプスバッファは現時点では含まれない（必要になったら追加する）。

### リソース状態の遷移
DX12 におけるリソース状態（PRESENT / RENDER_TARGET / PIXEL_SHADER_RESOURCE 等）の遷移は内部で自動的に処理される。
利用者は状態遷移を意識する必要はない。

## レンダーターゲットの生成
nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height);

オフスクリーン用のレンダーターゲットを生成する。
失敗時は `NULL` を返す。

## レンダーターゲットの破棄
void nmDestroyRenderTarget(nmRenderTarget* self);

レンダーターゲットを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

スワップチェインから取得したレンダーターゲット（`nmGetSwapchainTarget` の戻り値）に対して呼んではならない。
それらはスワップチェインが所有しており、寿命はスワップチェインに従う。

## スワップチェインからの取得
nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self);

スワップチェインの現フレームの描画先となるレンダーターゲットを返す。
返されたポインタはスワップチェインが所有しており、`nmDestroyRenderTarget` で破棄してはならない。
寿命はスワップチェインに従う（スワップチェインのリサイズや破棄で無効になる）。

## レンダーターゲットの bind
void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target);

以後の描画コマンドの出力先として `target` を設定する。
内部的に必要なリソース状態遷移が自動で挿入される。
ビューポートは `target` の全域に設定される。
部分描画には `nmSetViewport` を併用する。

## ビューポートの設定
void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height);

現在 bind されているレンダーターゲットへの描画範囲を設定する。
`nmBindRenderTarget` 直後の全域設定を上書きする場合に使う。

## クリア
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a);

現在 bind されているレンダーターゲットを指定色でクリアする。
ステンシルバッファのクリアは `nmClearStencil` を使う。

## ステンシルクリア
void nmClearStencil(nmCommandBuffer* self, uint8_t value);

現在 bind されているレンダーターゲットのステンシルバッファを指定値でクリアする。
通常は `0` を渡してマスクをリセットする。

## ウィンドウサイズ変更時の挙動

### スワップチェイン由来のレンダーターゲット
`nmResizeSwapchain` が呼ばれた時点で内部的に再作成される。
利用者は何もする必要はない。
ただし、`nmGetSwapchainTarget` で取得したポインタはリサイズで無効になるため、キャッシュせずに毎フレーム再取得すること。

### オフスクリーンのレンダーターゲット
ウィンドウサイズには追従しない。作成時のサイズで保持され続ける。
ウィンドウサイズに合わせたい場合は、利用者が `nmDestroyRenderTarget` + `nmCreateRenderTarget` で作り直す。
