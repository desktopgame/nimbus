# buffer
バッファに関する設計ノート。
GPU が読み書きするメモリ領域。

## 型定義
typedef struct nmBuffer nmBuffer;

typedef enum nmBufferUsage {
    nmBufferUsageVertex   = 1 << 0,
    nmBufferUsageIndex    = 1 << 1,
    nmBufferUsageConstant = 1 << 2,
} nmBufferUsage;

typedef enum nmIndexFormat {
    nmIndexFormatU16,
    nmIndexFormatU32,
} nmIndexFormat;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、バッファのリソースとその利用を可能にするビュー類を保持する。
たとえば、以下のようなものです。
* GPU 上のリソース (DX12 では ID3D12Resource)
* CPU からマップするためのアドレス (CPU 書き込み可能なヒープの場合)

`nmBufferUsage` は OR で組み合わせ可能。
同じバッファを vertex と constant として使うなど、複数用途を持つ場合に指定する。

### コンスタントバッファのアラインメント
DX12 ではコンスタントバッファに 256 バイト境界の要件がある。
awt-c はこれを利用者から隠さず、`nmBindConstantBuffer` の `offset` には 256 の倍数を渡すことを期待する。
awt 層が `UniformPool` 等で suballocation を実装する際にパディングを入れて吸収する想定。

### サブアロケーションの考え方
awt-c 層では「1 用途 1 バッファ」を強制しない。
1 つの大きなバッファに複数のデータ領域を詰めて、offset で切り出して使うことが可能。
このため、`nmUploadBuffer` および各 `nmBind*Buffer` 関数は `offset` 引数を受け取る。
プール管理は上位の awt 層の責務。

### コンスタントバッファの名前について
DX12 でいう constant buffer のことを指す。
Vulkan / Metal / OpenGL では uniform buffer と呼ばれる同じ概念であり、awt 層では `UniformBuffer` の名前で抽象化される予定。
awt-c は DX12 用語に揃える。

## バッファの生成
nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage);

指定サイズのバッファを生成する。
`usage` は OR で複数の用途を指定可能。
失敗時は `NULL` を返す。

## バッファの破棄
void nmDestroyBuffer(nmBuffer* self);

バッファを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

## バッファへの書き込み
void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset);

CPU 側のデータをバッファに転送する。
`offset` バイト目から `size` バイトの領域に `data` の内容を書き込む。
buffer 全体を上書きしたい場合は `offset = 0`、`size = バッファ全体のサイズ` を渡す。

## 頂点バッファの bind
void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t stride, size_t offset);

記録中のコマンドバッファに対し、`buf` を頂点バッファとして `slot` 番に bind する。
`stride` は 1 頂点あたりのバイト数。
`offset` はバッファ先頭からのバイトオフセット。

## インデックスバッファの bind
void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf, nmIndexFormat fmt, size_t offset);

記録中のコマンドバッファに対し、`buf` をインデックスバッファとして bind する。
`fmt` はインデックス値の型 (u16 / u32)。
`offset` はバッファ先頭からのバイトオフセット。
インデックスバッファのスロットは 1 つしかないため、slot 引数はない。

## コンスタントバッファの bind
void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t offset, size_t size);

記録中のコマンドバッファに対し、`buf` のうち `offset` から `size` バイトの領域を、コンスタントバッファとして `slot` 番に bind する。
buffer 全体を bind したい場合は `offset = 0`、`size = バッファ全体のサイズ` を渡す。
`offset` には 256 バイト境界に揃った値を渡す必要がある (DX12 の要件)。

### 事前条件
* この呼び出しの前に `nmBindPipeline` でパイプラインが bind されていること
  （bind された pipeline の root signature を参照して slot を解決するため）

### 失敗時のログ
* `nmBindPipeline` 未呼び出しの状態で呼ぶと `[ERROR] [buffer] nmBindConstantBuffer: no pipeline bound` を出して何もしない
* `offset + size` がバッファサイズを超える場合は `[ERROR] [buffer] ... range out of bounds ...` を出して何もしない
* `slot` が現在の pipeline の root signature に存在しない場合（型違いを含む）は `[WARN] [buffer] no ConstantBuffer binding for slot N ...` を出して何もしない
  → このときシェーダー側がその slot を参照すると undefined behavior になるので、debug layer が draw call 時にさらに警告を出すはず
