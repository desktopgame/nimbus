---
unsafe: true
---

# graphics
Component の paint メソッドが受け取る高水準描画 API。
Java AWT の `java.awt.Graphics` 相当。

## 依存関係
`awt-c` に依存し、その低レベルなグラフィックス機能を隠蔽して抽象的な描画 API として提供する。
利用者 (framework 層の `Component.paintComponent`) からは awt-c や個別の program、CommandBuffer の存在は見えない。

## 型定義
```zig
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn right(self: Rect) f32;   // self.x + self.width
    pub fn bottom(self: Rect) f32;  // self.y + self.height
};

pub const Color = struct {
    r: f32, g: f32, b: f32, a: f32,
    // コンストラクタは color.md 参照
};

pub const TextFont = struct {
    face: Font,        // awt.Font の値型 (handle は借用)
    pixel_size: i32,

    pub fn measureString(self: TextFont, s: []const u8) Font.TextSize;
};
```

`Color` のコンストラクタ (`rgba` / `rgb` / `bytes`) は `color.md` を参照。
`Font` および `Font.TextSize` (`width: f32, height: f32`) は `font.md` を参照。

`TextFont` 自体は値型で軽量に複製可能。
`face` は `awt.Font` を値で保持するが、`awt.Font` の中身は awt-c の handle ポインタなので、
実体の所有権は handle の最初の作成者 (典型的には Application の default_font) にある (詳細は `setFont` の項を参照)。
`measureString` は Graphics が手元に無い場面 (レイアウト計算時など) でも文字幅を測れるよう、TextFont 側に置く。

なお `Component.Size` (`width: f32, height: f32`) と `Font.TextSize` は構造的に同じだが、レイヤーごとに別型として持つ。
Graphics は文字寸法を `Font.TextSize`、framework のレイアウトは `Component.Size` で扱う。

## クリッピング (子 paint への引き渡しを兼ねる)
```zig
pub fn clip(self: Graphics, r: Rect) Graphics;
```

**新しい Graphics を値で返す** 。Java AWT の `Graphics.create(x, y, w, h)` 相当。返された Graphics は:

* 描画範囲が `r` に制限される (内部的にはシザー矩形に反映)。
* **原点が `(r.x, r.y)` に平行移動** される。子側は `(0, 0)` から始まるローカル座標で描ける。
* 自身のクリップは親のクリップとの 積集合 (絶対座標で計算)。
* color / font などその他の状態は親から copy-on-call。

呼び出し元 (親) の Graphics は変更されない。
子の paint が終わったあと、親は元の Graphics でそのまま描画を続けられる。
これで `save` / `restore` を持たずにネストしたクリップを実現する。

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
pub fn setFont(self: *Graphics, font: TextFont) void;
pub fn getFont(self: Graphics) ?TextFont;
pub fn setColor(self: *Graphics, color: Color) void;
pub fn getColor(self: Graphics) Color;
```

描画呼び出しは現在の color / font を参照する。`drawString` 等で都度引数に渡さない。

`getFont` が `?TextFont` になっているのは、`Graphics.init` の直後は font 未設定 (`null`) の状態だから。
`drawString` を呼ぶ前に必ず `setFont` で何らかのフォントをセットする必要がある (`current_font == null` の状態で `drawString` を呼ぶと UB)。

`setFont` で渡す `TextFont` 内の `face` (`awt.Font` 値) は **借用** である。
Graphics は `face` の awt-c handle の所有権を取らず、寿命の管理は呼び出し側 (`Application` の `default_font` 等) が行う。
渡した `face` の handle を Graphics が参照している間に `awt.Font.deinit` してはならない。

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
pub fn drawImageScaled(self: *Graphics, image: awt.Image, x: f32, y: f32, w: f32, h: f32) void;
```

色は current color、フォントは current font を参照する。
`Image` の詳細は `image.md` を参照。

## 機能要望
| 機能 | 理由 / 想定対応 |
|---|---|
| `drawLine` | GUI で実用上少ない (axis-aligned なら細い `fillRect` で代用可能) |
| `drawPolygon` / `fillPolygon` | 任意形状、別実装が必要 |
| `setStroke` (線幅・破線) | 現状 `drawRect` / `drawRoundRect` の thickness は 1px 固定 |
| `setTransform` (rotate / translate / scale) | アニメ時に必要だが当面不要 |
| `setAntiAlias` | 暗黙対応 (rect は AA 不要、滑らか形状は常時 1px AA) のため明示 API なし |
| `save` / `restore` | `clip` で値返しすることで不要 |
| `drawImageRegion` (src 部分指定) | 計画中。万能プリミティブとして src 矩形 → dst を描く。`programs.Image` 1 本に乗る。設計は `narrative/graphics.md` |
| `drawImageTinted` / `drawImageNineSlice` / `drawImageTiled` | 計画中。すべて `drawImageRegion` に畳み込み、契約を増やさない。設計は `narrative/graphics.md` |
| `drawImageScaled` の Rect 化 | 計画中。`(image, x, y, w, h)` → `(image, dst: Rect)` に寄せて draw 系を一貫させる |
| 複数行 `drawString` (`\n` の自動レイアウト) | テキストレイアウトは別レイヤーで対応予定 |
| グラデーション塗り | `Image.linearGradient` で画像として生成し `drawImageScaled` で描く方針。設計は `narrative/image.md` |
