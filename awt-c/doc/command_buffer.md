# command_buffer
コマンドバッファに関する設計ノート。
GPU に投入するコマンドの記録単位。

## 型定義
typedef struct nmCommandBuffer nmCommandBuffer;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、コマンドの記録と、GPU 投入後の完了管理に必要な状態を保持する。
たとえば、以下のようなものです。
* ID3D12GraphicsCommandList
* ID3D12CommandAllocator
* このバッファ専用のフェンス値

`nmCommandBuffer` は単独で生成・破棄するのではなく、デバイスが管理するプールから取得・返却する形で利用する。
DX12 における allocator と list の関係や、Metal の MTLCommandBuffer のような API ごとの差異はここに隠蔽される。

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
返却したバッファに対する以後の操作は許可されない。

## 記録の開始
void nmBeginCommandBuffer(nmCommandBuffer* self);

このバッファへのコマンド記録を開始する。
取得後はかならず一度この呼び出しが必要であり、それ以前の記録内容は破棄される。

## 記録の終了
void nmEndCommandBuffer(nmCommandBuffer* self);

このバッファへのコマンド記録を終了する。
これ以降の記録系操作は許可されない。
記録した内容を実行するには `nmSubmitCommandBuffer` を使う。

## コマンドの投入
void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device);

記録済みのコマンドを GPU に投入する。
非同期で実行され、この呼び出し自体は完了を待たない。
完了を待つ必要があるなら `nmWaitForCommandBuffer` を使う。

## 完了待ち
void nmWaitForCommandBuffer(nmCommandBuffer* self);

このバッファに含まれるコマンドが GPU 上で完了するまで呼び出しスレッドをブロックする。
通常のフレームループでは呼ぶ必要はない（`nmAcquireCommandBuffer` が再取得時に内部で同期する）。
ウィンドウのリサイズや終了処理など、明示的な GPU フラッシュが必要な場面で使う。
