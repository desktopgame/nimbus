---
unsafe: false
---

# pipeline
パイプラインステートに関する設計ノート。
シェーダー、ルートシグネチャ、頂点入力レイアウト、各種ステートを束ねた描画パイプライン。

## 型定義
```c
typedef enum nmVertexLayout {
    nmVertexLayoutVertex2D,
    nmVertexLayoutVertexTexCoord2D,
} nmVertexLayout;

typedef enum nmPrimitiveTopology {
    nmPrimitiveTopologyTriangleList,
    nmPrimitiveTopologyLineList,
    nmPrimitiveTopologyPointList,
} nmPrimitiveTopology;

typedef enum nmBlendMode {
    nmBlendModeNone,
    nmBlendModeAlpha,
    nmBlendModePremultipliedAlpha,
} nmBlendMode;

typedef enum nmStencilOp {
    nmStencilOpKeep,
    nmStencilOpZero,
    nmStencilOpReplace,
    nmStencilOpIncrementSat,
    nmStencilOpDecrementSat,
    nmStencilOpInvert,
    nmStencilOpIncrementWrap,
    nmStencilOpDecrementWrap,
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
    bool          enable;
    nmStencilOp   fail_op;
    nmStencilOp   depth_fail_op;
    nmStencilOp   pass_op;
    nmCompareFunc compare_func;
    uint8_t       read_mask;
    uint8_t       write_mask;
} nmStencilState;

typedef struct nmPipelineDesc {
    nmRootSignature*    root_signature;
    nmShader*           vertex_shader;
    nmShader*           pixel_shader;
    nmVertexLayout      vertex_layout;
    nmPrimitiveTopology topology;
    nmBlendMode         blend;
    nmStencilState      stencil;
    bool                color_write_enable;
} nmPipelineDesc;

typedef struct nmPipeline nmPipeline;
```

`nmVertexLayout` の各値は以下の頂点フォーマットを表す。
* `nmVertexLayoutVertex2D`: `(x, y)`
* `nmVertexLayoutVertexTexCoord2D`: `(x, y, u, v)`

利用者が任意の頂点フォーマットを定義することはできない。
新しいレイアウトが必要になったら enum に追加する。

`nmBlendMode` の各値の用途は以下。
* `nmBlendModeNone`: 不透明描画
* `nmBlendModeAlpha`: 通常のアルファ合成
* `nmBlendModePremultipliedAlpha`: 事前乗算アルファ

`nmStencilOp` の各値の意味は以下。
* `nmStencilOpKeep`: 値を保持
* `nmStencilOpZero`: 0 にする
* `nmStencilOpReplace`: 参照値で上書き
* `nmStencilOpIncrementSat` / `nmStencilOpDecrementSat`: ±1 (オーバー・アンダーフロー時は飽和)
* `nmStencilOpInvert`: ビット反転
* `nmStencilOpIncrementWrap` / `nmStencilOpDecrementWrap`: ±1 (オーバー・アンダーフロー時は wrap)

`nmStencilState` の各メンバの意味は以下。
* `enable`: `false` ならステンシルテスト無効
* `fail_op`: ステンシルテスト失敗時の操作
* `depth_fail_op`: 深度テスト失敗時の操作 (現状は深度バッファ無いため常に `nmStencilOpKeep` を指定)
* `pass_op`: 両方成功時の操作
* `compare_func`: 比較関数
* `read_mask`: 比較時の AND マスク
* `write_mask`: 書き込み時の AND マスク

`nmPipelineDesc` の `color_write_enable` は、`false` でカラー書き込みを無効化する (ステンシルマスク書き込み用)。
通常の描画では `true` を指定する。

`nmPipeline` の内部実装に関する知識は外部に漏らさない。
ここには、コンパイル済みのパイプラインステートを保持する。
たとえば、以下のようなもの。
* ID3D12PipelineState

## パイプラインの生成
nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc);

`desc` の内容からパイプラインを生成する。
失敗時は `NULL` を返す。

### 事前条件
* `desc->root_signature` / `desc->vertex_shader` / `desc->pixel_shader` がいずれも有効な (破棄されていない) オブジェクトであること。違反した場合の動作は UB。
* `desc->vertex_shader` の入力レイアウトが `desc->vertex_layout` と一致していること。違反した場合の動作は UB。

## パイプラインの破棄
void nmDestroyPipeline(nmPipeline* self);

パイプラインを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## パイプラインのバインド
void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline);

記録中のコマンドバッファに対し、`pipeline` をバインドする。
以降のドローコールはバインドされたパイプラインで描画される。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。違反した場合の動作は UB。

## ステンシル参照値の設定
void nmSetStencilRef(nmCommandBuffer* self, uint32_t value);

記録中のコマンドバッファに対し、ステンシル参照値を設定する。
`nmStencilOpReplace` で書き込む値、`nmCompareFuncEqual` 等で比較される値として使われる。
draw の前に毎回呼べる (per-draw)。

### 事前条件
* `self` に対して `nmBeginCommandBuffer` が呼ばれていること。違反した場合の動作は UB。

## 機能要望
* 新しい頂点レイアウトの追加 (現状は 2 種類固定)。
* 深度バッファのサポート (現状は深度テストが無いため `nmStencilState.depth_fail_op` は実質発火しない)。
