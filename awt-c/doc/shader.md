---
unsafe: false
---

# shader
シェーダーに関する設計ノート。
頂点シェーダーとピクセルシェーダーをコンパイル / 保持する仕組みを提供する。

## 型定義
```c
typedef enum nmShaderStage {
    nmShaderStageVertex,
    nmShaderStagePixel,
} nmShaderStage;

typedef struct nmShader nmShader;
```

`nmShaderStage` でサポートする種別は頂点シェーダーとピクセルシェーダーのみ。
ジオメトリ / ハル / ドメイン / コンピュートはサポートしない。

`nmShader` の内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。
ここには、コンパイル済みのシェーダーバイトコードを保持する。
たとえば、以下のようなもの。
* DX12 における DXBC バイトコードバッファ

シェーダーソースの言語は現在のプラットフォームに依存する (Windows なら HLSL、macOS なら MSL)。
複数言語の管理は呼び出し側 (awt 層) の責務。

## シェーダーのコンパイル
nmShader* nmCompileShader(nmShaderStage stage, const char* source);

`source` のシェーダーをランタイムにコンパイルして生成する。
失敗時は `NULL` を返す。

### 事前条件
* `source` が NUL 終端された UTF-8 文字列であること。違反した場合の動作は UB。

### 診断情報
コンパイルに失敗した場合、コンパイラから得られたエラーメッセージを `nmLogLevelError` でログに流す (詳細は `log.md` を参照)。

## シェーダーの破棄
void nmDestroyShader(nmShader* self);

シェーダーを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。
* `self` に依存するパイプラインが残っていないこと。違反した場合の動作は UB。

## コンパイル済みバイナリからのロード
nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size);

事前にコンパイルされたシェーダーバイトコード (DX12 なら DXBC) をロードして `nmShader` として保持する。
起動時間の短縮や、配布バイナリの実行環境からシェーダーコンパイラ依存を切るために使う。
失敗時は `NULL` を返す。

Metal バックエンドでは現状未対応 (`[ERROR] [shader] nmLoadShader: precompiled bytecode not supported in Metal backend` を流して NULL を返す)。

### 事前条件
* `binary` が NULL でなく、`size` ぶん有効なメモリを指していること。違反した場合の動作は UB。

### 診断情報
ロードに失敗した場合、原因を `nmLogLevelError` でログに流す (詳細は `log.md` を参照)。

## 機能要望
* (現状なし — `nmLoadShader` の Metal バックエンド対応は将来の課題だが、本ドキュメントの担当範囲外。)
