---
unsafe: true
---

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

## CPU への読み戻し
int nmReadbackRenderTarget(nmRenderTarget* self, void* out_rgba, size_t out_size);

`self` の現在の内容を CPU メモリに読み戻す。
描画結果の検証 / ゴールデン画像比較 / テストでの目視確認等の **オフライン用途** を主対象とし、 ホットパス (毎フレーム呼ぶ等) での使用は想定しない。

出力フォーマットは **隙間なし RGBA8 配列** に固定する (`width * height * 4` バイト)。
内部のレンダーターゲットが BGRA 等の別フォーマットで保持されている場合でも、 本 API がチャネル順を RGBA に揃えて返す。
GPU 側で行ストライドにパディングが入る場合もあるが、 本 API がコピー時に詰めるため、 利用者は単純な連続バッファを渡せばよい。

成功時はゼロ、失敗時は非ゼロを返す。

### 事前条件
* `self` が `nmCreateRenderTarget` で生成されたオフスクリーン由来であること。スワップチェイン由来 (`nmGetSwapchainTarget` の戻り値) は当面サポートしない。違反した場合の動作は UB。
* `out_rgba` が NULL でないこと。違反した場合の動作は UB。
* `out_size` が `self` の `width * height * 4` 以上であること。違反した場合の動作は UB。
* 本呼び出しの時点で、`self` に書き込み中のコマンドバッファが存在しない (paint 用のコマンドバッファは `nmSubmitCommandBuffer` まで済ませているか、何もしていない状態であること)。違反した場合の動作は UB。

### 設計要件
* オフライン用途専用なので、フル GPU 同期を取るブロッキング API で構わない。複雑な非同期パイプは不要。
* チャネル順序 / 行ピッチの差異は API 内部で吸収し、利用者は PNG エンコーダ等にそのまま渡せる連続 RGBA8 配列を受け取る。
* 内部で必要な一時リソース (readback heap / 中継コマンドバッファ等) はすべて本関数の呼び出し範囲内で確保・解放する。利用者は寿命管理の責任を負わない (`nmCreate` 系の失敗時セマンティクスと同様)。

## 機能要望
* フォーマットを引数で指定する API (現状はオフスクリーンは標準的なカラーフォーマット固定、スワップチェイン由来はスワップチェインに従う)。
* デプスバッファのサポート (現状はステンシルのみ)。
* オフスクリーンレンダーターゲットのリサイズ API (現状は作り直しが必要)。
* スワップチェイン由来レンダーターゲットの `nmReadbackRenderTarget` 対応 (ウィンドウ画面のスナップショット用途)。
* レンダーターゲットのサイズを後から取得する API (現状は生成時のサイズを利用者が覚えておく必要がある)。
* PNG / BMP への直接書き出しヘルパ (現状は呼び出し側で encoder と組み合わせる)。
