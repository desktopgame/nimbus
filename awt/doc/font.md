---
unsafe: true
---

# font
awt-c の `nmFont` (freetype 薄ラッパー) を Zig から扱いやすい形に再公開するモジュール。
グリフ単体のラスタライズ、フォント / グリフのメトリクス取得、UTF-8 文字列の幅計測を提供する。

## 依存関係
`awt-c` の `nmFont` 関連 API (`nmCreateFont` / `nmRasterizeGlyph` / `nmGetFontMetrics` 等) に依存する。
責務範囲は awt-c とそろえる: グリフ単体のラスタライズとメトリクスまで。
それ以上の機能 (アトラス管理、テキストの shaping、改行レイアウト、描画) は `Graphics` 等の上位層が担当する。

awt-c に存在しない補助として、UTF-8 文字列をデコードしてグリフアドバンスを累積する `measureString` のみを足す。

## 型定義
```zig
pub const GlyphMetrics = struct {
    bitmap_width:  i32,
    bitmap_height: i32,
    bitmap_pitch:  i32,
    bearing_x:     i32,
    bearing_y:     i32,
    advance_x:     f32,
};

pub const FontMetrics = struct {
    ascender:    f32,
    descender:   f32,
    line_gap:    f32,
    line_height: f32,
};

pub const TextSize = struct {
    width:  f32,
    height: f32,
};

pub const Font = struct {
    handle: *c.struct_nmFont,
    // メソッドは下記
};
```

`GlyphMetrics` / `FontMetrics` の各メンバの意味は awt-c/doc/font.md の `nmGlyphMetrics` / `nmFontMetrics` と同一。
`TextSize` は `measureString` の戻り値専用。

`Font` 自体は `nmFont*` を 1 つ保持するだけの値型で軽量に複製可能。
ただし所有権は `init` / `deinit` の組として管理されるため、複製したコピーで `deinit` を呼んではならない。

## フォントの生成
```zig
pub fn init(data: []const u8, face_index: i32) !Font;
```

メモリ上のフォントデータからフォントを生成する。
* `data`: TTF / OTF / TTC / OTC のバイト列
* `face_index`: 通常 `0`、コレクション形式の場合に特定 face を選ぶ

`@embedFile` で埋め込んだ静的データを渡す想定 (寿命要件を自動で満たすため)。
失敗時は `error.FontCreateFailed` を返す。

### 事前条件
* `data` が `Font` の生存期間中、有効かつ不変であること (`nmCreateFont` の事前条件と同じ)。違反した場合の動作は UB。

## フォントの破棄
```zig
pub fn deinit(self: *Font) void;
```

フォントを破棄する。
内部の `nmFont*` ハンドルは破棄後 `undefined` になる。

## ピクセルサイズの設定
```zig
pub fn setPixelSize(self: Font, pixel_size: i32) void;
```

以降の操作で使用するピクセルサイズを設定する。
`metrics` / `rasterize` / `glyphAdvance` / `measureString` の結果はこのサイズに依存する。

### 事前条件
* `pixel_size` が 1 以上であること (`nmSetFontPixelSize` の事前条件)。違反した場合の動作は UB。

## フォントメトリクスの取得
```zig
pub fn metrics(self: Font) FontMetrics;
```

現在のピクセルサイズにおけるフォント全体のメトリクスを返す。

### 事前条件
* `setPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフのラスタライズ
```zig
pub fn rasterize(self: Font, codepoint: u32) !struct {
    metrics: GlyphMetrics,
    bitmap:  []const u8,
};
```

指定 codepoint を現在のピクセルサイズでラスタライズする。
戻り値の `bitmap` は内部スクラッチバッファへのスライスで、長さは `bitmap_pitch * bitmap_height` バイトの R8 配列。
**同じ `Font` への次の `rasterize` 呼び出しで上書きされる** ため、保持したい場合は呼び出し直後にコピーすること。
コピーや行間移動の際は `bitmap_width` ではなく `bitmap_pitch` をストライドに使うこと (`awt-c/doc/font.md` 参照)。

ラスタライズに失敗した場合 (グリフが無い等) は `error.GlyphRasterizeFailed` を返す。

### 事前条件
* `setPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフのアドバンスのみ取得
```zig
pub fn glyphAdvance(self: Font, codepoint: u32) f32;
```

ラスタライズを伴わずアドバンスのみ取得する。
テキスト幅の事前測定など、ビットマップ不要な場面に使う。

### 事前条件
* `setPixelSize` が事前に呼ばれていること。違反した場合の動作は UB。

## グリフの有無確認
```zig
pub fn hasGlyph(self: Font, codepoint: u32) bool;
```

フォントが指定 codepoint のグリフを持つか確認する。

## 文字列幅の計測
```zig
pub fn measureString(self: Font, s: []const u8, pixel_size: i32) TextSize;
```

UTF-8 文字列 `s` を指定ピクセルサイズで描画したときの単一行の寸法を返す。
内部で `setPixelSize(pixel_size)` を呼んでから 1 文字ずつ `glyphAdvance` を累積する。

* `\n` は **無視** する (`Graphics.drawString` と同じ挙動。複数行レイアウトは別レイヤー)。
* 不正な UTF-8 シーケンスは読み飛ばす (描画もされない)。

戻り値の `height` は現在のフォントの `line_height`。

## 機能要望
* 書記素クラスタ単位の `measureString` (現状は codepoint 単位。CLAUDE.md の文字コード方針における初版扱いに対応)。
* RTL / 双方向テキストへの対応。
* グリフキャッシュ / アトラス管理を含む高水準 API (現状はグリフ単発ラスタライズのみで、アトラスは `Graphics` 内部で組む)。
