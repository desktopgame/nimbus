# pipeline
パイプラインステートに関する設計ノート。
シェーダー、ルートシグネチャ、頂点入力レイアウト、各種ステートを束ねた描画パイプライン。

## 型定義
typedef enum nmVertexLayout {
    nmVertexLayoutVertex2D,           /* (x, y) */
    nmVertexLayoutVertexTexCoord2D,   /* (x, y, u, v) */
} nmVertexLayout;

typedef enum nmPrimitiveTopology {
    nmPrimitiveTopologyTriangleList,
    nmPrimitiveTopologyLineList,
    nmPrimitiveTopologyPointList,
} nmPrimitiveTopology;

typedef enum nmBlendMode {
    nmBlendModeNone,                  /* 不透明描画 */
    nmBlendModeAlpha,                 /* 通常のアルファ合成 */
    nmBlendModePremultipliedAlpha,    /* 事前乗算アルファ */
} nmBlendMode;

typedef enum nmStencilOp {
    nmStencilOpKeep,                  /* 値を保持 */
    nmStencilOpZero,                  /* 0 にする */
    nmStencilOpReplace,               /* 参照値で上書き */
    nmStencilOpIncrementSat,          /* +1 (オーバーフロー時は飽和) */
    nmStencilOpDecrementSat,          /* -1 (アンダーフロー時は飽和) */
    nmStencilOpInvert,                /* ビット反転 */
    nmStencilOpIncrementWrap,         /* +1 (オーバーフロー時は wrap) */
    nmStencilOpDecrementWrap,         /* -1 (アンダーフロー時は wrap) */
} nmStencilOp;

typedef enum nmCompareFunc {
    nmCompareFuncNever,
    nmCompareFuncLess,
    nmCompareFuncEqual,
    nmCompareFuncLessEqual,
    nmCompareFuncGreater,
    nmCompareFuncNotEqual,
    nmCompareFuncGreaterEqual,
    nmCompareFuncAlways,
} nmCompareFunc;

typedef struct nmStencilState {
    int enable;                       /* 0 ならステンシルテスト無効 */
    nmStencilOp fail_op;              /* ステンシルテスト失敗時の操作 */
    nmStencilOp depth_fail_op;        /* 深度テスト失敗時の操作 (深度バッファ無いので常に Keep) */
    nmStencilOp pass_op;              /* 両方成功時の操作 */
    nmCompareFunc compare_func;       /* 比較関数 */
    uint8_t read_mask;                /* 比較時の AND マスク */
    uint8_t write_mask;               /* 書き込み時の AND マスク */
} nmStencilState;

typedef struct nmPipelineDesc {
    nmRootSignature* root_signature;
    nmShader* vertex_shader;
    nmShader* pixel_shader;
    nmVertexLayout vertex_layout;
    nmPrimitiveTopology topology;
    nmBlendMode blend;
    nmStencilState stencil;
    int color_write_enable;           /* 0 ならカラー書き込み無効 (マスク書き込み用) */
} nmPipelineDesc;

typedef struct nmPipeline nmPipeline;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、コンパイル済みのパイプラインステートを保持する。
たとえば、以下のようなものです。
* ID3D12PipelineState

### 頂点フォーマットについて
`nmVertexLayout` は決め打ちの 2 種類のみ。
利用者が任意の頂点フォーマットを定義することはできない。
新しいレイアウトが必要になったら enum に追加する。

### winding と culling
front face は **CCW**（反時計回り）として規定する。
back-face culling は行わない（`CullMode = NONE`）。
winding は描画結果に影響しないが、規約として CCW を front とする。
DX12 では `FrontCounterClockwise = TRUE` を指定して D3D デフォルト（CW front）を反転させる。

### depth_fail_op について
現状の nimbus は深度バッファを持たないため、`depth_fail_op` は実際には発火しない。
2D 描画で使う pipeline には常に `nmStencilOpKeep` を指定すること。
将来 depth サポートを入れる時に意味を持つ。

### color_write_enable について
ステンシルマスクを書く pipeline では、カラーを画面に出さずステンシルだけ更新したい。
このとき `color_write_enable = 0` にして、カラー書き込みを無効化する。
通常の描画 pipeline では `color_write_enable = 1`。

### マスク描画の典型パターン
ステンシルマスクを使ったクリッピングは、次の 2 つの pipeline を用意することで実現する。

**Write 用 pipeline**: マスク形状を描いてステンシルに書き込む（カラーは出さない）。
* `stencil.enable = 1`
* `stencil.compare_func = nmCompareFuncAlways`
* `stencil.pass_op = nmStencilOpReplace`
* `stencil.fail_op = nmStencilOpKeep`
* `stencil.depth_fail_op = nmStencilOpKeep`
* `color_write_enable = 0`

**Read 用 pipeline**: ステンシルが参照値と一致する場所だけにカラーを描く。
* `stencil.enable = 1`
* `stencil.compare_func = nmCompareFuncEqual`
* `stencil.pass_op = nmStencilOpKeep`
* `stencil.fail_op = nmStencilOpKeep`
* `stencil.depth_fail_op = nmStencilOpKeep`
* `color_write_enable = 1`

参照値は `nmSetStencilRef` で per-draw で設定する。

## パイプラインの生成
nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc);

descriptor からパイプラインを生成する。
失敗時は `NULL` を返す。

## パイプラインの破棄
void nmDestroyPipeline(nmPipeline* self);

パイプラインを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

## パイプラインの bind
void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline);

記録中のコマンドバッファに対し、`pipeline` を bind する。
以降のドローコールは bind された pipeline で描画される。

## ステンシル参照値の設定
void nmSetStencilRef(nmCommandBuffer* self, uint32_t value);

記録中のコマンドバッファに対し、ステンシル参照値を設定する。
`nmStencilOpReplace` で書き込む値、`nmCompareFuncEqual` 等で比較される値として使われる。
draw の前に毎回呼べる（per-draw）。
