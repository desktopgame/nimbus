# buffer
バッファに関する設計ノート。
GPU が読み書きするメモリ領域。

## 型定義
```c
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
```

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、バッファのリソースとその利用を可能にするビュー類を保持する。
たとえば、以下のようなもの。
* GPU 上のリソース (DX12 では ID3D12Resource)
* CPU からマップするためのアドレス (CPU 書き込み可能なヒープの場合)

`nmBufferUsage` は OR で組み合わせ可能。
同じバッファを頂点バッファかつ定数バッファとして使うなど、複数用途を持つ場合に指定する。

## バッファの生成
nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage);

指定サイズのバッファを生成する。
失敗時は `NULL` を返す。

### 事前条件
* `size` が 0 、または `usage` が 0 のとき、UB

## バッファの破棄
void nmDestroyBuffer(nmBuffer* self);

バッファを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## バッファへの書き込み
void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset);

CPU 側のデータをバッファに転送する。
`offset` バイト目から `size` バイトの領域に `data` の内容を書き込む。
バッファ全体を上書きしたい場合は `offset = 0`、`size = バッファ全体のサイズ` を渡す。

### 診断情報
* `offset` + `size` が バッファサイズを超える時、ログ出力して終了する。

## 頂点バッファのバインド
void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t stride, size_t offset);

記録中のコマンドバッファに対し、`buf` を頂点バッファとして `slot` 番にバインドする。
`stride` は 1 頂点あたりのバイト数。
`offset` はバッファ先頭からのバイトオフセット。

`slot` は基本的に 0 を指定する。
複数スロットはインスタンシングや 「静的データと動的データを別バッファに分ける」 用途で使うが、
nimbus 内部では現時点で使用していない。

### 事前条件
* `buf` の `usage` に `nmBufferUsageVertex` が含まれること。含まれない場合の動作は UB。

### 診断情報
* `offset` が `buf` のサイズ以上のとき `[ERROR] [buffer] nmBindVertexBuffer: offset out of bounds` を出力して何もしない。

## インデックスバッファのバインド
void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf, nmIndexFormat fmt, size_t offset);

記録中のコマンドバッファに対し、`buf` をインデックスバッファとしてバインドする。
`fmt` はインデックス値の型 (u16 / u32)。
`offset` はバッファ先頭からのバイトオフセット。
インデックスバッファのスロットは 1 つしかないため、スロット引数はない。

### 事前条件
* `buf` の `usage` に `nmBufferUsageIndex` が含まれること。含まれない場合の動作は UB。

### 診断情報
* `offset` が `buf` のサイズ以上のとき `[ERROR] [buffer] nmBindIndexBuffer: offset out of bounds` を出力して何もしない。

## 定数バッファのバインド
void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t offset, size_t size);

記録中のコマンドバッファに対し、`buf` のうち `offset` から `size` バイトの領域を、定数バッファとして `slot` 番にバインドする。
バッファ全体をバインドしたい場合は `offset = 0`、`size = バッファ全体のサイズ` を渡す。
`offset` には 256 バイト境界に揃った値を渡す必要がある (DX12 の要件)。

定数バッファとは、DX12ではシェーダー中の以下に対応するバッファである。
```hlsl
cbuffer Uniforms : register(b0) {
    float4 color;
};
```

Metalでは以下のように表現される。
```metal
struct Uniforms {
    float4 color;
};

fragment float4 psMain(VsOut in [[stage_in]],
                       constant Uniforms& u [[buffer(0)]]) {
    return u.color;
}
```

### 事前条件
* `buf` の `usage` に `nmBufferUsageConstant` が含まれること。含まれない場合の動作は UB。
* この呼び出しの前に `nmBindPipeline` でパイプラインがバインドされていること
  （バインドされたパイプラインの root signature を参照してスロットを解決するため）
* `offset` が 256 の倍数であること。違反した場合の動作は UB。

### 診断情報
* `nmBindPipeline` 未呼び出しの状態で呼ぶと `[ERROR] [buffer] nmBindConstantBuffer: no pipeline bound` を出して何もしない
* `offset + size` がバッファサイズを超える場合は `[ERROR] [buffer] ... range out of bounds ...` を出して何もしない
* `slot` が現在のパイプラインの root signature に存在しない場合（型違いを含む）は `[WARN] [buffer] no ConstantBuffer binding for slot N ...` を出して何もしない
  * このときシェーダー側がそのスロットを参照すると undefined behavior になるので、debug layer が draw call 時にさらに警告を出すはず
* `offset` が 256 の倍数でない場合は `[ERROR] [buffer] nmBindConstantBuffer: offset not aligned to 256` を出して何もしない

### 補足
256 バイトアラインを強制しないバックエンドでは offset 調整による無駄が生じるが、
実装の簡易さを優先してすべてのバックエンドで 256 に揃える。

## サブアロケーション
`nmCreateBuffer` で大きなバッファを 1 つ確保し、 `offset` 引数で複数領域に切り出して使うことが可能。
同一用途のデータを 1 つのバッファに詰める (例: 複数フレーム分の定数データを 1 つの定数バッファに置き、 offset で切り替える) ことも、
`usage` を OR で複数指定して頂点 / 定数として併用することもできる。
これにより heap オブジェクトの数を減らせる。
