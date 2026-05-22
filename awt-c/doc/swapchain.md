# swapchain
スワップチェインに関する設計ノート。
ちなみに、`Swapchain` と `SwapChain` の表記がウェブ上には存在する。
nimbus においては、つなげて一語とし、`swapchain` または `Swapchain` と表記する。

## 型定義
```c
typedef struct nmSwapchain nmSwapchain;
```

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。
ここには、ウィンドウごとに参照されるオブジェクトを保持する。
たとえば、以下のようなもの。
* IDXGISwapChain

## バッファ構成
ダブルバッファを提供する。
バックバッファはスワップチェイン由来のレンダーターゲットとして公開される。
カラー / ステンシルのフォーマットなど、レンダーターゲットとしての性質は `render_target.md` を参照。

## スワップチェインの生成
nmSwapchain* nmCreateSwapchain(const nmDevice* device, const nmWindow* window);

`device` と `window` を関連付けるスワップチェインを生成する。
失敗時は `NULL` を返す。

### 事前条件
* `device` / `window` がいずれも有効な (破棄されていない) オブジェクトであること。違反した場合の動作は UB。

## スワップチェインの破棄
void nmDestroySwapchain(nmSwapchain* self);

スワップチェインを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## ウィンドウサイズの変更
int nmResizeSwapchain(nmSwapchain* self, int width, int height);

スワップチェインのサイズを変更する。
内部的には GPU の完了待ち、バックバッファの解放、再確保、レンダーターゲットビューの再作成までを行う。
成功時はゼロ、失敗時は非ゼロを返す。

通常は `nmSetWindowResizeCallback` (`window.md` 参照) で受けた通知に応じて呼ぶ。

### 事前条件
* `width` / `height` がいずれも 1 以上であること。違反した場合の動作は UB。

## 描画先の取得
nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self);

スワップチェインの現フレームの描画先となるレンダーターゲットを返す。
返されたポインタはスワップチェインが所有しており、`nmDestroyRenderTarget` で破棄してはならない。
寿命はスワップチェインに従う (スワップチェインのリサイズや破棄で無効になる)。
詳細は `render_target.md` を参照。

## 画面への表示
void nmPresentSwapchain(nmSwapchain* self);

記録済みコマンドの投入 (`nmSubmitCommandBuffer`) 後、現フレームのバックバッファを画面に提示する。
内部的にはバックバッファのインデックスを次のフレーム分に進める。
この関数自体は GPU の完了を待たない (ノンブロッキング)。

呼び出し順序は次のとおり。
1. `nmAcquireCommandBuffer` で記録用バッファを取得
2. `nmBeginCommandBuffer` 〜 描画 〜 `nmEndCommandBuffer`
3. `nmSubmitCommandBuffer` で GPU に投入
4. `nmPresentSwapchain` で画面に提示
5. `nmReleaseCommandBuffer` でバッファを返却

## 機能要望
* トリプルバッファのサポート (現状はダブルバッファ固定)。
* tearing 対応 (可変リフレッシュレート / VRR 対応)。
* バックバッファ数やフォーマットを引数で指定する API (現状は固定)。
