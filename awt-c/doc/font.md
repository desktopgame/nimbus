# font
フォントに関する設計ノート。
freetype の薄いラッパー。指定 codepoint をビットマップにラスタライズする責務のみを持つ。

アトラス管理・テキスト VB 構築・改行・描画は上位レイヤー (awt) で行う。
awt-c はグリフ単体のラスタライズと、フォント・グリフのメトリクス提供までを担当する。

## 型定義
typedef struct nmGlyphMetrics {
    int   bitmap_width;       /* 出力ビットマップの幅 (pixel) */
    int   bitmap_height;      /* 出力ビットマップの高さ (pixel) */
    int   bearing_x;          /* pen 位置からビットマップ左端までのオフセット */
    int   bearing_y;          /* baseline からビットマップ上端までのオフセット (上方向 = 正) */
    float advance_x;          /* このグリフ描画後の pen 進行量 */
} nmGlyphMetrics;

typedef struct nmFontMetrics {
    float ascender;           /* baseline → 最上点 */
    float descender;          /* baseline → 最下点 (正の値) */
    float line_gap;           /* 行間の追加スペース */
    float line_height;        /* ascender + descender + line_gap の合計 (便利値) */
} nmFontMetrics;

typedef struct nmFont nmFont;

内部実装に関する知識は外部に漏らさない。
ここには、freetype の `FT_Face` を保持する。

## ライフサイクル
`FT_Library` は `nmInitAwt` 時に内部で 1 個確保される（詳細は [backend_lifecycle](backend_lifecycle.md)）。
nmFont は `FT_Face` のラッパーで複数生成可能。
全ての nmFont は `nmTerminateAwt` より前に破棄しておくこと。

## フォントの生成
nmFont* nmCreateFont(const void* data, size_t size, int face_index);

メモリ上のフォントデータからフォントを生成する。
* `data`: フォントファイル (TTF / OTF / TTC / OTC) のバイト列
* `size`: data のバイト数
* `face_index`: 通常 0。TTC / OTC コレクションのときに特定 face を選ぶ

freetype は内部で `data` ポインタを保持する。nmFont の生存期間中、利用者は data を解放してはならない。
`@embedFile` で埋め込まれた静的データを渡す想定。

face_index で範囲外を指定した場合や対応していない形式の場合は `NULL` を返す。

## フォントの破棄
void nmDestroyFont(nmFont* self);

フォントを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

## ピクセルサイズの設定
void nmSetFontPixelSize(nmFont* self, int pixel_size);

以降の操作で使用するピクセルサイズを設定する。
`nmGetFontMetrics` / `nmRasterizeGlyph` / `nmGetGlyphAdvance` の結果はこのサイズに依存する。
別サイズで使う場合は呼び直すこと。

## フォントメトリクスの取得
void nmGetFontMetrics(nmFont* self, nmFontMetrics* out);

現在のピクセルサイズにおけるフォント全体のメトリクスを取得する。
行送り (`line_height`) の計算等に使う。

## グリフのラスタライズ
int nmRasterizeGlyph(nmFont* self, uint32_t codepoint,
                     nmGlyphMetrics* out_metrics,
                     const uint8_t** out_bitmap);

指定 codepoint を現在のピクセルサイズでラスタライズする。
* `out_metrics`: グリフのメトリクス (bitmap サイズ・bearing・advance)
* `out_bitmap`: 8bit grayscale ビットマップへのポインタ (R8 配列、row major、row pitch = `bitmap_width`)

成功時は 0 を返す。失敗時 (フォントに glyph が無い等) は非ゼロ。

`*out_bitmap` は freetype 内部のスクラッチバッファを指す。同じ nmFont に対する次の `nmRasterizeGlyph` 呼び出しで上書きされる。
利用者は呼び出し直後にアトラスへコピーすること。

## グリフのアドバンスのみ取得
float nmGetGlyphAdvance(nmFont* self, uint32_t codepoint);

ラスタライズを伴わずアドバンスのみ取得する。
テキスト幅の事前測定・改行位置の判定等で、ビットマップが不要な場面に使う。

## グリフの有無確認
int nmFontHasGlyph(nmFont* self, uint32_t codepoint);

フォントが指定 codepoint のグリフを持つか確認する。
無い場合は 0、ある場合は非ゼロ。

CJK フォールバック等で「Latin フォントに無いから CJK フォントを使う」といった分岐に使える（将来）。

## awt-c で提供しないもの
* グリフアトラスの管理 — Zig 層で R8 テクスチャ + shelf packing として実装
* テキストの shaping — HarfBuzz 等の連結処理は v1 未対応
* 改行位置の決定 — line break iterator / 禁則処理は上位層
* テキスト幅の累積計算 — 上位で glyph advance を累積
* 太字・斜体の合成 — 将来 `ftsynth` ベースで別 API として追加検討
* ヒンティングモードの選択 — デフォルト (`FT_LOAD_DEFAULT`) のみ
* LCD subpixel AA — grayscale のみ
* `nmDrawFont` 等のドロー API — 描画は `nmBuffer` / `nmPipeline` / `nmDraw` を組み合わせて上位層で実現
