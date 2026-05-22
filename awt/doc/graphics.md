# graphics
Component の paint メソッドが受け取る高水準描画 API。
Java AWT の `java.awt.Graphics` 相当。

## 依存関係
`awt-c` に依存し、その低レベルなグラフィックス機能を隠蔽して抽象的な描画 API として提供する。
利用者 (framework 層の `Component.paintComponent`) からは awt-c や個別の program、CommandBuffer の存在は見えない。

## 座標系
* **原点は左上**、x は右、y は下 (GUI 標準)。
* 単位は **論理ポイント (float)** 。非 HiDPI なら 1pt = 1px、Retina 2x なら 1pt = 2px。
  * 同じ `100pt × 30pt` ボタンは表示密度に関わらず物理的に同じ大きさで描かれる。
  * Graphics に渡す座標はすべてこのポイント単位。
* 内部で NDC (y up) への変換は Graphics が行う。
  * ビューポートはフレームバッファ全体に張る (NDC → ピクセルは GPU 任せ)。
  * **シザー矩形だけ** はフレームバッファピクセル単位なので、Graphics が `fb_size / window_size` のスケール比でクリップ矩形を変換する。
* 整数ポイント値で指定すれば pixel-perfect になる (HiDPI でも整数 pt は整数 fb ピクセル境界に乗る)。float の小数部は AA を持つウィジェットでだけ意味を持つ。

## 型定義
```zig
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Size = struct {
    width: f32,
    height: f32,
};

pub const Color = struct {
    r: f32, g: f32, b: f32, a: f32,
    // コンストラクタは color.md 参照
};

pub const Font = struct {
    face: *awt.Font,
    pixel_size: i32,

    pub fn measureString(self: Font, s: []const u8) Size;
};
```

`Color` のコンストラクタ (`rgba` / `rgb` / `bytes`) は `color.md` を参照。

`Font` 自体は値型で軽量に複製可能。`face` は借用 (詳細は `setFont` の項を参照)。
`measureString` は Graphics が手元に無い場面 (レイアウト計算時など) でも文字幅を測れるよう、Font 側に置く。

## 文字列の表現
**UTF-8 の `[]const u8` スライス** を使う。Zig の文字列リテラルそのまま渡せる。
CLAUDE.md の文字コード方針 (UTF-8 統一) と整合。

利用者がコードポイント単位の扱いを意識する必要はない。
```zig
g.drawString("こんにちは", 10, 20);
g.drawString("Hello", 10, 40);
```

## クリッピング (子 paint への引き渡しを兼ねる)
```zig
pub fn clip(self: Graphics, r: Rect) Graphics;
```

**新しい Graphics を値で返す** 。Java AWT の `Graphics.create(x, y, w, h)` 相当。返された Graphics は:

* 描画範囲が `r` に制限される (内部的にはシザー矩形に反映)。
* **原点が `(r.x, r.y)` に平行移動** される。子側は `(0, 0)` から始まるローカル座標で描ける。
* 自身のクリップは親のクリップとの **積集合** (絶対座標で計算)。
* color / font などその他の状態は親から copy-on-call。

呼び出し元 (親) の Graphics は変更されない。子の paint が終わったあと、親は元の Graphics でそのまま描画を続けられる。これで `save` / `restore` を持たずにネストしたクリップを実現する。

```zig
fn paintComponent(self: *Self, g: *Graphics) void {
    g.setColor(.bg);
    g.fillRect(.{ .x = 0, .y = 0, .width = self.bounds.width, .height = self.bounds.height });

    for (self.children.items) |child| {
        var cg = g.clip(child.bounds);
        child.paintComponent(&cg);
        // cg はスコープを抜けて消える。GPU リソースの解放は不要 (値型)。
    }
}
```

非矩形クリップ (角丸、任意形状) はステンシルマスクで実装するが、v1 のシグネチャは矩形のみ。

## 状態の設定 / 取得
```zig
pub fn setFont(self: *Graphics, font: Font) void;
pub fn getFont(self: *Graphics) Font;
pub fn setColor(self: *Graphics, color: Color) void;
pub fn getColor(self: *Graphics) Color;
```

描画呼び出しは現在の color / font を参照する。`drawString` 等で都度引数に渡さない。

`setFont` で渡す `Font` の `face` (`*awt.Font`) は **借用** である。
Graphics は `face` の所有権を取らず、寿命の管理は呼び出し側 (`Application` 等で保持される default font 等) が行う。
渡した `Font` の `face` を Graphics が参照している間に解放してはならない。

## 描画
```zig
pub fn drawString(self: *Graphics, s: []const u8, x: f32, y: f32) void;

pub fn drawRect(self: *Graphics, r: Rect) void;  // 矩形のアウトラインを 1px
pub fn fillRect(self: *Graphics, r: Rect) void;  // 矩形塗り

pub fn drawRoundRect(self: *Graphics, r: Rect, corner_radius: f32) void;  // 角丸のアウトライン (1px)
pub fn fillRoundRect(self: *Graphics, r: Rect, corner_radius: f32) void;  // 角丸塗り

pub fn drawCircle(self: *Graphics, r: Rect) void;  // bounding box r のアウトライン (1px)
pub fn fillCircle(self: *Graphics, r: Rect) void;  // bounding box r 塗り

pub fn drawImage(self: *Graphics, image: awt.Image, x: f32, y: f32) void;
```

色は current color、フォントは current font を参照する。
`Image` の詳細は `image.md` を参照。

## drawString の y 基準について
Swing は `y = baseline`、現代的 UI ライブラリ (Cairo / Skia / Direct2D / CoreGraphics) は `y = bounding box の top` 。
**nimbus は top-of-bounding-box 派** を採用する (レイアウト計算で扱いやすい)。
baseline 派の API が必要になったら `drawStringAtBaseline(s, x, baseline_y)` 等を別途追加する。

## drawString の改行
`\n` を含む文字列は **改行を無視 (リテラル文字としても描かない)** する。
複数行レンダリングが必要なら呼び出し側で行ごとに `drawString` を呼ぶ。

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
* **GPU リソースのフレームライフサイクル**: 1 フレーム内の draw が参照する vertex / uniform データは、次に `nmAcquireCommandBuffer` が返るタイミングまで GPU から読まれ続ける前提でメモリを保持する。`nmAcquireCommandBuffer` は前フレームの GPU 完了を保証するため (`command_buffer.md` 参照)、それ以降は同じ領域を新しいフレームで安全に上書きできる。
* **リソース集約**: 同種のデータ (vertex / uniform 等) は可能な限り単一のバッファに詰めて、heap オブジェクト数とバインド切替を減らす。

## 機能要望
| 機能 | 理由 / 想定対応 |
|---|---|
| `drawLine` | GUI で実用上少ない (axis-aligned なら細い `fillRect` で代用可能) |
| `drawPolygon` / `fillPolygon` | 任意形状、別実装が必要 |
| `setStroke` (線幅・破線) | 現状 `drawRect` / `drawRoundRect` の thickness は 1px 固定 |
| `setTransform` (rotate / translate / scale) | アニメ時に必要だが当面不要 |
| `setAntiAlias` | 暗黙対応 (rect は AA 不要、滑らか形状は常時 1px AA) のため明示 API なし |
| `save` / `restore` | `clip` で値返しすることで不要 |
| `drawImage` の scale / subimage 指定 | 元サイズで貼るのみ |
| 複数行 `drawString` (`\n` の自動レイアウト) | テキストレイアウトは別レイヤーで対応予定 |
| グラデーション塗り | 当面 image / texture で代用 |
