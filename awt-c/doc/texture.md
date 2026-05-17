# texture
テクスチャに関する設計ノート。
シェーダーから読み取り可能な画像データ。

## 型定義
typedef enum nmTextureFormat {
    nmTextureFormatRGBA8,    /* カラー画像、スプライト */
    nmTextureFormatBGRA8,    /* swap chain と format を揃えたい場合 */
    nmTextureFormatR8,       /* フォントのカバレッジ、マスク */
} nmTextureFormat;

typedef struct nmTexture nmTexture;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、テクスチャリソースとシェーダーから参照するためのビューを保持する。
たとえば、以下のようなものです。
* GPU 上のリソース (DX12 では ID3D12Resource)
* シェーダーリソースビュー (DX12 では SRV)

### サポートしないもの
* mipmap（必要になったら別 API で追加）
* マルチサンプル
* 3D テクスチャ、テクスチャ配列、キューブマップ
* HDR / 広色域 (RGBA16F 等)
* 圧縮フォーマット (BC1/BC7 等)

GUI 用途では実寸表示が基本のため、上記は当面不要。
必要になった時点で対応する。

## テクスチャの生成
nmTexture* nmCreateTexture(nmDevice* device, int width, int height, nmTextureFormat format);

指定サイズ・フォーマットのテクスチャを生成する。初期データは持たない。
データ転送は `nmUploadTexture` または `nmUploadTextureRegion` で行う。
失敗時は `NULL` を返す。

## テクスチャの破棄
void nmDestroyTexture(nmTexture* self);

テクスチャを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

## テクスチャ全体への書き込み
void nmUploadTexture(nmTexture* self, const void* data, size_t size);

テクスチャ全体に CPU 側のデータを転送する。
`data` はテクスチャの format に合わせたピクセル配列、`size` はそのバイト数。
行間にパディングがある形式（row pitch がアラインメントされる等）の調整は内部で行う。
利用者は `width * height * bytes_per_pixel` 分の隙間なしデータを渡す。

## テクスチャ部分への書き込み
void nmUploadTextureRegion(nmTexture* self, int x, int y, int width, int height,
                           const void* data, size_t row_pitch);

テクスチャの指定矩形領域に CPU 側のデータを転送する。
フォントアトラスの追加グリフ書き込み等、部分更新の用途に使う。

`row_pitch` は `data` 内の 1 行のバイト数。
`width * bytes_per_pixel` と同じ値で良いが、ソースデータが大きな画像の一部を指している場合などは異なる値になる。

## テクスチャの bind
void nmBindTexture(nmCommandBuffer* self, nmTexture* texture, int slot);

記録中のコマンドバッファに対し、`texture` を `slot` 番に bind する。
シェーダー側では `Texture2D` を `register(t<slot>)` で参照する。

シェーダーリソースビューはテクスチャ生成時に device 内部の descriptor heap に登録されており、この関数はそのビューを root signature の `slot` 番から参照可能にする。
descriptor heap の構造は API には出ない（利用者が heap や slot 位置を意識する必要はない）。
同じシェーダーで draw ごとに異なるテクスチャを使い分けるために使う。

### 事前条件
* この呼び出しの前に `nmBindPipeline` でパイプラインが bind されていること
  （bind された pipeline の root signature を参照して slot を解決するため）

### 失敗時のログ
* `nmBindPipeline` 未呼び出しの状態で呼ぶと `[ERROR] [texture] nmBindTexture: no pipeline bound` を出して何もしない
* `slot` が現在の pipeline の root signature に存在しない場合（型違いを含む）は `[WARN] [texture] no Texture binding for slot N ...` を出して何もしない
  → このときシェーダー側がその slot を参照すると undefined behavior になるので、debug layer が draw call 時にさらに警告を出すはず
