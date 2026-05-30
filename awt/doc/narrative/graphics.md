---
unsafe: false
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
  * **シザー矩形だけ** はフレームバッファピクセル単位なので、Graphics が `fb_size / window_size` のスケール比でクリップ矩形を変換する。
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
利用者が指定する `Font.pixel_size` は **論理ポイント** だが、freetype に渡す値は **物理ピクセル** でなければクッキリ rasterize されない (= 論理サイズで rasterize すると Retina で米粒大になる)。
`drawString` は内部で `scale = fb_w / window_w` を計算し、`pixel_size × scale` を freetype に渡す。

得られたグリフのメトリクス (bitmap 幅 / 高さ / bearing / advance) はすべて物理単位なので、quad 配置時には `1/scale` を掛けて論理に戻す。
このおかげで:
- グリフのテクスチャは物理ピクセル等倍 (= 鮮明)
- quad の頂点座標は論理ポイント (= NDC 変換と整合)
- viewport がフレームバッファ全体に張ってあるので、NDC → ピクセル変換で自動的に物理スケールにマップされる (= 1 物理ピクセル = 1 物理ピクセルの bilinear なし)

`GlyphAtlas` のキャッシュキーは物理 pixel size を含めるので、同じフォントが複数スケール環境に居ても衝突しない。

## 状態管理: save/restore は持たない
`clip` が新しい Graphics を返す方式 (上述) にしたことで、`save` / `restore` に相当するネストはクリップ経由で表現できる。

色やフォントは `setColor` / `setFont` で **現在の Graphics に対するミューテーション** 。
子の paint で `setColor` しても、親の Graphics は影響を受けない (`clip` で値コピーが行われているため)。

## 設計要件
描画 API の内部実装が以下から自然に導けるように、踏まえる制約を列挙する。

* **GUI 用途**: 1 フレームあたり数十〜数百 draw 程度を想定。1 draw あたりの抽象オーバーヘッドや program 切替コストは許容範囲。複雑なバッチング機構は不要。
* **描画品質**:
  * axis-aligned な矩形系 (`drawRect` / `fillRect`) は pixel-perfect、AA 不要。
  * 角丸 / 円のような滑らかな形状は 1px の AA を持つ。
* **テキスト**: 同じグリフが繰り返し現れる前提で、再ラスタライズが起きないよう設計する (キャッシュが効くこと)。
* **Graphics 自体**: 値型として軽量に複製可能であること (`clip` で子 paint に渡すため、ヒープアロケーションが入らない)。
* **GPU リソースのフレームライフサイクル**: 1 フレーム内の draw が参照する頂点 / uniform データは、次に `nmAcquireCommandBuffer` が返るタイミングまで GPU から読まれ続ける前提でメモリを保持する。`nmAcquireCommandBuffer` は前フレームの GPU 完了を保証するため (`command_buffer.md` 参照)、それ以降は同じ領域を新しいフレームで安全に上書きできる。
* **リソース集約**: 同種のデータ (頂点 / uniform 等) は可能な限り単一のバッファに詰めて、heap オブジェクト数とバインド切替を減らす。
