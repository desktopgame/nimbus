---
unsafe: false
---

# command_buffer
コマンドバッファに関する設計ノート。
GPU に投入するコマンドの記録単位。

## 型定義
```c
typedef struct nmCommandBuffer nmCommandBuffer;
```

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、コマンドの記録と、GPU 投入後の完了管理に必要な状態を保持する。
たとえば、以下のようなもの。
* ID3D12GraphicsCommandList
* ID3D12CommandAllocator
* このバッファ専用のフェンス値

`nmCommandBuffer` は単独で生成・破棄するのではなく、デバイスが管理するプールから取得・返却する形で利用する。
DX12 における allocator と list の関係や、Metal の MTLCommandBuffer のような API ごとの差異はここに隠蔽される。

## ライフサイクル
コマンドバッファは以下の順序で利用する。
1. `nmAcquireCommandBuffer` でプールから取得
2. `nmBeginCommandBuffer` で記録開始
3. `nmBindPipeline` / `nmBindVertexBuffer` / `nmDraw` などで記録
4. `nmEndCommandBuffer` で記録終了
5. `nmSubmitCommandBuffer` で GPU に投入
6. (任意) `nmWaitForCommandBuffer` で完了を待つ
7. `nmReleaseCommandBuffer` でプールに返却

各関数の事前条件は、このライフサイクルにおける呼び出し順序を前提とする。

## コマンドバッファの取得
nmCommandBuffer* nmAcquireCommandBuffer(nmDevice* device);

デバイスが管理するプールから空いているコマンドバッファを 1 つ取得する。
返されるバッファは、過去の GPU 実行が完了しているか、未使用のものが保証される。
プール内に空きが無い場合の挙動は実装依存（完了待機やプール拡張など）。
失敗時は `NULL` を返す。

## コマンドバッファの返却
void nmReleaseCommandBuffer(nmCommandBuffer* self);

プールに返却する。
GPU で実行中であってもこの呼び出しは即座に戻り、ブロックしない。
返却後の `self` に対する操作は UB。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## 記録の開始
void nmBeginCommandBuffer(nmCommandBuffer* self);

このバッファへのコマンド記録を開始する。
取得後はかならず一度この呼び出しが必要であり、それ以前の記録内容は破棄される。

### 事前条件
* `self` が `nmAcquireCommandBuffer` で取得済みであること。違反した場合の動作は UB。
* 同じ `self` に対して `nmBeginCommandBuffer` を 2 回連続で呼ばないこと。違反した場合の動作は UB。

## 記録の終了
void nmEndCommandBuffer(nmCommandBuffer* self);

このバッファへのコマンド記録を終了する。
これ以降の記録系操作は許可されない。
記録した内容を実行するには `nmSubmitCommandBuffer` を使う。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。違反した場合の動作は UB。

## コマンドの投入
void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device);

記録済みのコマンドを GPU に投入する。
非同期で実行され、この呼び出し自体は完了を待たない。
完了を待つ必要があるなら `nmWaitForCommandBuffer` を使う。

### 事前条件
* `self` に対して `nmEndCommandBuffer` が呼ばれていること。違反した場合の動作は UB。
* `device` は `self` の取得元と同じデバイスであること。違反した場合の動作は UB。

## 完了待ち
void nmWaitForCommandBuffer(nmCommandBuffer* self);

このバッファに含まれるコマンドが GPU 上で完了するまで呼び出しスレッドをブロックする。
通常のフレームループでは呼ぶ必要はない（`nmAcquireCommandBuffer` が再取得時に内部で同期する）。
ウィンドウのリサイズや終了処理など、明示的な GPU フラッシュが必要な場面で使う。

### 事前条件
* `self` に対して `nmSubmitCommandBuffer` が呼ばれていない場合、なにもせずに戻る。

## ドローコール（頂点バッファのみ）
void nmDraw(nmCommandBuffer* self, int vertex_count, int start_vertex);

バインド済みのパイプライン・頂点バッファ・その他の状態を使い、`vertex_count` 個の頂点を描画する。
`start_vertex` は頂点バッファ内の開始インデックス（バッファ先頭から描画するなら `0`）。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。
* この呼び出しの前に以下がバインドされていること。
  * `nmBindPipeline` でパイプライン
  * `nmBindRenderTarget` で出力先
  * `nmBindVertexBuffer` で頂点データ
  * (パイプラインが定数バッファを参照する場合) `nmBindConstantBuffer` で定数
  * (パイプラインがテクスチャを参照する場合) `nmBindTexture` でテクスチャ
  * (ステンシルを使う場合) `nmSetStencilRef` でステンシル参照値

違反した場合の動作は UB。

## ドローコール（インデックスバッファ使用）
void nmDrawIndexed(nmCommandBuffer* self, int index_count, int start_index, int base_vertex);

バインド済みのパイプライン・頂点バッファ・インデックスバッファ・その他の状態を使い、`index_count` 個のインデックスを描画する。
`start_index` はインデックスバッファ内の開始位置。
`base_vertex` は各インデックス値に加算される値。複数の mesh を 1 つの頂点バッファに詰めて部分描画する時に使う。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。
* この呼び出しの前に以下がバインドされていること。
  * `nmBindPipeline` でパイプライン
  * `nmBindRenderTarget` で出力先
  * `nmBindVertexBuffer` で頂点データ
  * `nmBindIndexBuffer` でインデックス
  * (パイプラインが定数バッファを参照する場合) `nmBindConstantBuffer` で定数
  * (パイプラインがテクスチャを参照する場合) `nmBindTexture` でテクスチャ
  * (ステンシルを使う場合) `nmSetStencilRef` でステンシル参照値

違反した場合の動作は UB。
