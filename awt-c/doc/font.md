---
unsafe: true
---

# font
フォントに関する設計ノート。
freetype の薄いラッパー。指定 codepoint をビットマップにラスタライズする責務のみを持つ。

アトラス管理・テキスト用頂点バッファ構築・改行・描画は上位レイヤー (awt) で行う。
awt-c はグリフ単体のラスタライズと、フォント・グリフのメトリクス提供までを担当する。

## 型定義
```c
typedef struct nmGlyphMetrics {
    int   bitmap_width;
    int   bitmap_height;
    int   bitmap_pitch;
    int   bearing_x;
    int   bearing_y;
    float advance_x;
} nmGlyphMetrics;

typedef struct nmFontMetrics {
    float ascender;
    float descender;
    float line_gap;
    float line_height;
} nmFontMetrics;

typedef struct nmFont nmFont;
```

`nmGlyphMetrics` の各メンバの意味は以下。
* `bitmap_width` / `bitmap_height`: 出力ビットマップの幅・高さ (pixel)
* `bitmap_pitch`: ビットマップの行ストライド (バイト)。freetype の都合で `bitmap_width` より大きくなる (行末にパディングが入る) 場合があるため、行間移動には必ずこちらを使う
* `bearing_x`: pen 位置からビットマップ左端までのオフセット
* `bearing_y`: baseline からビットマップ上端までのオフセット (上方向が正)
* `advance_x`: このグリフ描画後の pen 進行量

`nmFontMetrics` の各メンバの意味は以下。
* `ascender`: baseline から最上点まで
* `descender`: baseline から最下点まで (正の値)
* `line_gap`: 行間の追加スペース
* `line_height`: `ascender + descender + line_gap` の合計 (便利値)

`nmFont` の内部実装に関する知識は外部に漏らさない。
ここには、freetype の `FT_Face` を保持する。

## ライフサイクル
`FT_Library` は `nmInitAwt` 時に内部で 1 個確保される (詳細は [backend_lifecycle](backend_lifecycle.md) 参照)。
`nmFont` は `FT_Face` のラッパーで複数生成可能。
全ての `nmFont` は `nmTerminateAwt` より前に破棄しておくこと。

## フォントの生成
nmFont* nmCreateFont(const void* data, size_t size, int face_index);

メモリ上のフォントデータからフォントを生成する。
* `data`: フォントファイル (TTF / OTF / TTC / OTC) のバイト列
* `size`: `data` のバイト数
* `face_index`: 通常 0。TTC / OTC コレクションのときに特定 face を選ぶ

freetype は内部で `data` ポインタを保持する。
`@embedFile` で埋め込まれた静的データを渡す想定。
失敗時は `NULL` を返す。

### 事前条件
* `nmInitAwt()` が事前に呼び出されていること。違反した場合の動作は UB。
* `data` が `nmFont` の生存期間中、有効かつ不変であること。違反した場合の動作は UB。

## フォントの破棄
void nmDestroyFont(nmFont* self);

フォントを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## ピクセルサイズの設定
void nmSetFontPixelSize(nmFont* self, int pixel_size);

以降の操作で使用するピクセルサイズを設定する。
`nmGetFontMetrics` / `nmRasterizeGlyph` / `nmGetGlyphAdvance` の結果はこのサイズに依存する。
別サイズで使う場合は呼び直すこと。

### 事前条件
* `pixel_size` が 1 以上であること。違反した場合の動作は UB。

## フォントメトリクスの取得
void nmGetFontMetrics(nmFont* self, nmFontMetrics* out);

現在のピクセルサイズにおけるフォント全体のメトリクスを `out` に書き込む。
行送り (`line_height`) の計算等に使う。

### 事前条件
* `self` に対して `nmSetFontPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフのラスタライズ
int nmRasterizeGlyph(nmFont* self, uint32_t codepoint, nmGlyphMetrics* out_metrics, const uint8_t** out_bitmap);

指定 codepoint を現在のピクセルサイズでラスタライズする。
* `out_metrics`: グリフのメトリクス (ビットマップサイズ・行ストライド・bearing・advance)
* `out_bitmap`: 8bit grayscale ビットマップへのポインタ (R8 配列、row major)。バッファ全長は `bitmap_pitch * bitmap_height` バイト

成功時は 0 を返す。失敗時 (フォントに glyph が無い等) は非ゼロ。

`*out_bitmap` は freetype 内部のスクラッチバッファを指す。
同じ `nmFont` に対する次の `nmRasterizeGlyph` 呼び出しで上書きされる。
利用者は呼び出し直後にアトラスへコピーすること。
コピーや行間移動の際は `bitmap_width` ではなく `bitmap_pitch` をストライドに使うこと (freetype が行末にパディングを入れる場合がある)。

### 事前条件
* `self` に対して `nmSetFontPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフのアドバンスのみ取得
float nmGetGlyphAdvance(nmFont* self, uint32_t codepoint);

ラスタライズを伴わずアドバンスのみ取得する。
テキスト幅の事前測定・改行位置の判定等で、ビットマップが不要な場面に使う。

### 事前条件
* `self` に対して `nmSetFontPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフの有無確認
bool nmFontHasGlyph(nmFont* self, uint32_t codepoint);

フォントが指定 codepoint のグリフを持つか確認する。

## 機能要望
* 太字・斜体の合成 (`ftsynth` ベースで別 API として追加検討)
* ヒンティングモードの選択 (現状はデフォルトの `FT_LOAD_DEFAULT` のみ)
* LCD subpixel AA (現状は grayscale のみ)
* CJK フォールバック (Latin フォントに無い codepoint を CJK フォントへ振る等の分岐に `nmFontHasGlyph` を活用)
