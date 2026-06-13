---
unsafe: true
---

# graphics
描画 API の座標系・文字列表現・状態管理・設計要件などの背景。

## 座標系
* **原点は左上**、x は右、y は下 (GUI 標準)。
* 単位は **論理ポイント (float)** 。非 HiDPI なら 1pt = 1px、Retina 2x なら 1pt = 2px。
  * 同じ `100pt × 30pt` ボタンは表示密度に関わらず物理的に同じ大きさで描かれる。
  * Graphics に渡す座標はすべてこのポイント単位。
* 内部で NDC (y up) への変換は Graphics が行う。
  * ビューポートはフレームバッファ全体に張る (NDC → ピクセルは GPU 任せ)。
  * シザー矩形だけ はフレームバッファピクセル単位なので、Graphics が `fb_size / window_size` のスケール比でクリップ矩形を変換する。
* 整数ポイント値で指定すれば pixel-perfect になる (HiDPI でも整数 pt は整数 fb ピクセル境界に乗る)。float の小数部は AA を持つウィジェットでだけ意味を持つ。

## 文字列の表現
**UTF-8 の `[]const u8` スライス** を使う。Zig の文字列リテラルそのまま渡せる。
CLAUDE.md の文字コード方針 (UTF-8 統一) と整合。

利用者がコードポイント単位の扱いを意識する必要はない。
```zig
g.drawString("こんにちは", 10, 20);
g.drawString("Hello", 10, 40);
```

## drawString の y 基準について
Swing は `y = baseline`、現代的 UI ライブラリ (Cairo / Skia / Direct2D / CoreGraphics) は `y = bounding box の top` 。
**nimbus は top-of-bounding-box 派** を採用する (レイアウト計算で扱いやすい)。
baseline 派の API が必要になったら `drawStringAtBaseline(s, x, baseline_y)` 等を別途追加する。

## drawString の改行
`\n` を含む文字列は **改行を無視 (リテラル文字としても描かない)** する。
複数行レンダリングが必要なら呼び出し側で行ごとに `drawString` を呼ぶ。

## drawString と HiDPI
利用者が指定する `Font.pixel_size` は **論理ポイント** だが、
freetype に渡す値は物理ピクセルでなければクッキリ rasterize されない (= 論理サイズで rasterize すると Retina で米粒大になる)。
`drawString` は内部で `scale = fb_w / window_w` を計算し、`pixel_size × scale` を freetype に渡す。

得られたグリフのメトリクス (bitmap 幅 / 高さ / bearing / advance) はすべて物理単位なので、quad 配置時には `1/scale` を掛けて論理に戻す。
このおかげで:
- グリフのテクスチャは物理ピクセル等倍 (= 鮮明)
- quad の頂点座標は論理ポイント (= NDC 変換と整合)
- ビューポートがフレームバッファ全体に張ってあるので、NDC → ピクセル変換で自動的に物理スケールにマップされる
  (= 1 物理ピクセル = 1 物理ピクセルの bilinear なし)

`GlyphAtlas` のキャッシュキーは物理 pixel size を含めるので、同じフォントが複数スケール環境に居ても衝突しない。

## 状態管理: save/restore は持たない
`clip` が新しい Graphics を返す方式 (上述) にしたことで、`save` / `restore` に相当するネストはクリップ経由で表現できる。

色やフォントは `setColor` / `setFont` で **現在の Graphics に対するミューテーション** 。
子の paint で `setColor` しても、親の Graphics は影響を受けない (`clip` で値コピーが行われているため)。

## 画像描画 API の設計 (計画)
JTattoo 風のリッチなルックアンドフィールを、描画バックエンド (DX12 / Metal) への要請を増やさずに実現するための画像描画関数群。
**まだ未実装** であり、実装時に各シグネチャを spec (`graphics.md`) の `## 関数定義` へ昇格させる。

### 1 プリミティブ原則
画像系の描画はすべて `programs.Image` (テクスチャ付きクアッド + uniform tint + アルファ合成) 1 本に乗せる。
サブ画像 / アトラス / 9-slice / タイル / グラデーションは、**Graphics 側が頂点の dst 矩形・src UV・tint をどう積むか** だけで表現する。
新しい program (= バックエンドごとのシェーダ + パイプライン) を増やさない。
これにより「バックエンドに要請するインターフェイス」を太らせずに表現力だけを足せる。

現状の `drawImageScaled` は UV を 0..1 にハードコードしているが、これを「src 矩形 (画像ピクセル単位) → UV」に一般化するだけで万能プリミティブになる。
シェーダ自体の変更は不要で、頂点 UV の積み方を変えるだけ。

### 万能プリミティブと薄いラッパー
```zig
// 万能プリミティブ (これを表に出す)
// image の src 領域 (画像ピクセル単位) を dst へ描く。tint で乗算し、アルファ合成する。
// 以下の draw 系はすべてこれに畳める。
pub fn drawImageRegion(self: *Graphics, image: Image, dst: Rect, src: Rect, tint: Color) void;

// 日常用の薄いラッパー
pub fn drawImage(self: *Graphics, image: Image, x: f32, y: f32) void;            // 原寸・無加工
pub fn drawImageScaled(self: *Graphics, image: Image, dst: Rect) void;           // 全体 → dst
pub fn drawImageTinted(self: *Graphics, image: Image, dst: Rect, tint: Color) void; // 全体 × tint
```

`drawImage` / `drawImageScaled` / `drawImageTinted` はいずれも `drawImageRegion` を `src` = 画像全体、`tint` = `(1,1,1,1)` などで呼ぶ特殊化として実装できる。

### L&F 合成 (`drawImageRegion` の繰り返し)
```zig
// 角は等倍のまま、辺は片軸方向に、中央は両軸に伸縮する 9 分割スケール。
// insets は src を 3×3 に割る境界 (画像ピクセル単位)。同じ幅を dst の縁にも使うので角は甘くならない。
pub fn drawImageNineSlice(self: *Graphics, image: Image, dst: Rect, insets: Insets) void;

// image を原寸で dst いっぱいに敷き詰める。
pub fn drawImageTiled(self: *Graphics, image: Image, dst: Rect) void;
```

どちらも内部では `drawImageRegion` を複数回呼ぶだけで、新しい program もバックエンド関数も要らない。

### 補助型
```zig
pub const Insets = struct { left: f32, top: f32, right: f32, bottom: f32 };
```

`Insets` は awt.Graphics 内に定義し、framework 層の同種の型には依存させない (レイヤーをまたがせない)。

### `drawImageScaled` の Rect 化
現行シグネチャ `(image, x, y, w, h)` を `(image, dst: Rect)` に寄せ、
他の draw 系 (`drawImageRegion` / `drawImageTinted` / `drawImageNineSlice` / `drawImageTiled`) と一貫させる。
既存呼び出し側に小さな移行が入るが、作者承認済み。

### 表現力の対応
| やりたいこと | 実現 |
|---|---|
| アイコン / 写真 | `drawImage` / `drawImageScaled` |
| スプライトシート / アトラス | `drawImageRegion` (`src` で切り出す) |
| グレースケール資産の色替え | `drawImageTinted` (テーマ色 × 1 枚) |
| 縦グラデ・艶ボタンの下地 | `Image.linearGradient` → `drawImageScaled` |
| 角丸ボーダー / ボタン枠 / 凹凸パネル | `drawImageNineSlice` |
| Texture テーマのタイル背景 | `drawImageTiled` |
| ソフトシャドウ | 事前ぼかし済み画像を `drawImageNineSlice` |

既存の `RoundedRect` (SDF) / `Color` / `Text` と合わせれば、リッチな L&F に必要な描画語彙が揃う。

### グラデーションは「画像」で出す
グラデーションを Graphics 関数にすると、内部に極小テクスチャのキャッシュという隠れ状態を抱えることになる。
これを避け、グラデーションは `Image` のファクトリ (`Image.linearGradient`) で生成し `drawImageScaled` で描く。
「グラデーション = 引き伸ばされた極小テクスチャ」という性質をそのまま設計に落とす形。テーマは起動時に数枚作って使い回す。詳細は `narrative/image.md`。

### タイルの端処理とサンプラー
`drawImageTiled` は「端を `src` でクランプした原寸クアッドを敷き詰める」実装とし、
wrap アドレッシングのサンプラーを要求しない (契約を増やさないため)。
1 draw で済ませたい最適化が欲しくなった場合のみ wrap の static sampler を 1 つ追加する — これが画像系で **唯一の未決のバックエンド判断**。
デフォルトは追加しない側。

### 線形フィルタ依存
スケールやグラデーション伸ばしの滑らかさは、static sampler が linear であることに依存する。
これは既存の `drawImageScaled` が既に前提にしているため、追加の判断はない。

## 設計要件
描画 API の内部実装が以下から自然に導けるように、踏まえる制約を列挙する。

* **GUI 用途**: 1 フレームあたり数十〜数百 draw 程度を想定。1 draw あたりの抽象オーバーヘッドや program 切替コストは許容範囲。複雑なバッチング機構は不要。
* 描画品質:
  * axis-aligned な矩形系 (`drawRect` / `fillRect`) は pixel-perfect、AA 不要。
  * 角丸 / 円のような滑らかな形状は 1px の AA を持つ。
* テキスト: 同じグリフが繰り返し現れる前提で、再ラスタライズが起きないよう設計する (キャッシュが効くこと)。
* Graphics 自体: 値型として軽量に複製可能であること (`clip` で子 paint に渡すため、ヒープアロケーションが入らない)。
* **GPU リソースのフレームライフサイクル**:
  1 フレーム内の draw が参照する頂点 / uniform データは、次に `nmAcquireCommandBuffer` が返るタイミングまで GPU から読まれ続ける前提でメモリを保持する。
  `nmAcquireCommandBuffer` は前フレームの GPU 完了を保証するため (`command_buffer.md` 参照)、それ以降は同じ領域を新しいフレームで安全に上書きできる。
* リソース集約: 同種のデータ (頂点 / uniform 等) は可能な限り単一のバッファに詰めて、heap オブジェクト数とバインド切替を減らす。
