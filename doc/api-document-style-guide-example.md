※このドキュメントはドキュメントの記述例としてのサンプルファイルです。

---

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

## コンスタントバッファのバインド
void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t offset, size_t size);

記録中のコマンドバッファに対し、`buf` のうち `offset` から `size` バイトの領域を、コンスタントバッファとして `slot` 番にバインドする。
buffer 全体をバインドしたい場合は `offset = 0`、`size = バッファ全体のサイズ` を渡す。
`offset` には 256 バイト境界に揃った値を渡す必要がある (DX12 の要件)。

コンスタントバッファとは、DX12ではシェーダー中の以下に対応するバッファです。
```hlsl
cbuffer Uniforms : register(b0) {
    float4 color;
};
```

Metalでは以下のように表現されます。
```hlsl
struct Uniforms {
    float4 color;
};

fragment float4 psMain(VsOut in [[stage_in]],
                       constant Uniforms& u [[buffer(0)]]) {
    return u.color;
}
```

### 事前条件
* この呼び出しの前に `nmBindPipeline` でパイプラインがバインドされていること
  （バインドされた pipeline の root signature を参照して slot を解決するため）

### 診断情報
* `nmBindPipeline` 未呼び出しの状態で呼ぶと `[ERROR] [buffer] nmBindConstantBuffer: no pipeline bound` を出して何もしない
* `offset + size` がバッファサイズを超える場合は `[ERROR] [buffer] ... range out of bounds ...` を出して何もしない
* `slot` が現在の pipeline の root signature に存在しない場合（型違いを含む）は `[WARN] [buffer] no ConstantBuffer binding for slot N ...` を出して何もしない
  * このときシェーダー側がその slot を参照すると undefined behavior になるので、debug layer が draw call 時にさらに警告を出すはず