# shader
シェーダーに関する設計ノート。

## 型定義
typedef enum nmShaderStage { nmShaderStageVertex, nmShaderStagePixel } nmShaderStage;
typedef struct nmShader nmShader;

内部実装に関する知識は外部に漏らさない。
awtの内部で定義された抽象化済みの型については保持しても構わない。
シェーダー種別について、頂点シェーダー、ピクセルシェーダー以外はサポートしない。

## シェーダーのコンパイル
nmShader* nmCompileShader(nmShaderStage stage, const char* source);

シェーダーをランタイムにコンパイルして生成する。
失敗時は `NULL` を返す。
`source` は現在のプラットフォームに対応するシェーダー言語の文字列（Windows なら HLSL、macOS なら MSL）。
複数言語の管理は呼び出し側（awt 層）の責務。

DirectX12では `D3DCompile()` にmainの関数名を要求されるが、nimbusではこれを統一するので呼び出し側で区別しない。
シェーダーのエントリ関数名は stage ごとに固定。
- nmShaderStageVertex → vsMain
- nmShaderStagePixel → psMain

コンパイル時にエラーメッセージが得られる場合、それをログシステム（log.mdを参照）に流します。

## シェーダーのロード
nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size);

コンパイル済みのシェーダーバイナリからロードする。
失敗時は `NULL` を返す。
※当面はランタイムのコンパイルで実装するので、これは現時点での草案に過ぎません。

## シェーダーの破棄
void nmDestroyShader(nmShader* self);

シェーダーを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。