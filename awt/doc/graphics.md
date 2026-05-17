# graphics
Component の paint メソッドが受け取る高水準描画 API の設計ノート。
Java AWT の `java.awt.Graphics` 相当。

## 立ち位置
- レイヤー: **awt 層**（`programs` + `UniformBuffer` + `CommandBuffer` の上に乗る）
- 利用者: framework 層の `Component.paintComponent(Graphics)` など
- 内部実装: `awt.programs.Text` / `Color` / `Image` を使い分けて draw を発行する
- framework 側から見ると awt-c や個別 program の存在は見えない

## 座標系
- **原点は左上**、x は右、y は下（GUI 標準）
- 単位は **ピクセル (float)**
- 内部で NDC (y up) への変換は Graphics が行う
- 整数ピクセル値で指定すれば pixel-perfect、float の小数部は AA を持つ widget でだけ意味を持つ

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

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color;
    pub fn rgb(r: f32, g: f32, b: f32) Color;          // a = 1.0
    pub fn bytes(r: u8, g: u8, b: u8, a: u8) Color;   // 0..255 → 0..1
};

pub const Font = struct {
    /// Borrow. Font は face を所有しない。寿命は呼び出し側 (Application 等) が管理。
    face: *awt.Font,
    pixel_size: i32,

    pub fn measureString(self: Font, s: []const u8) Size;
};
```

## 文字列の表現
**UTF-8 の `[]const u8` スライス** を使う。Zig の文字列リテラルそのまま渡せる。
CLAUDE.md の文字コード方針（UTF-8 一本）と整合。

Graphics 内部で codepoint デコード → glyph atlas lookup → quad emit、という流れ。
利用者が codepoint 単位の扱いを意識する必要はない。

```zig
g.drawString("こんにちは", 10, 20);
g.drawString("Hello", 10, 40);
```

## 描画 API

### Clipping (子 paint への引き渡しを兼ねる)
```zig
pub fn clip(self: Graphics, r: Rect) Graphics;
```
**新しい Graphics を値で返す**。Java AWT の `Graphics.create(x, y, w, h)` 相当。返された Graphics は:

* 描画範囲が `r` に制限される（内部的に `nmSetScissor` のクリップに反映）
* **原点が `(r.x, r.y)` に平行移動** される。つまり子側は `(0, 0)` から始まるローカル座標で描ける
* 自身のクリップは親のクリップとの **積集合**（絶対座標で計算）
* color / font などその他の状態は親から copy-on-call

呼び出し元 (親) の Graphics は変更されない。子の paint が終わったあと、親は元の Graphics でそのまま描画を続けられる。これで `save` / `restore` を持たずにネスト clip を実現する。

```zig
fn paintComponent(self: *Self, g: *Graphics) void {
    g.setColor(.bg);
    g.fillRect(.{ .x = 0, .y = 0, .width = self.bounds.width, .height = self.bounds.height });

    for (self.children.items) |child| {
        var cg = g.clip(child.bounds);
        child.paintComponent(&cg);
        // cg はスコープを抜けて消える。GPU リソースの解放は不要（値）。
    }
}
```

非矩形クリップ（角丸、任意形状）はステンシルマスクで実装するが、v1 のシグネチャは矩形のみ。

### 状態
```zig
pub fn setFont(self: *Graphics, font: Font) void;
pub fn getFont(self: *Graphics) Font;
pub fn setColor(self: *Graphics, color: Color) void;
pub fn getColor(self: *Graphics) Color;
```
描画呼び出しは現在の color / font を参照する。drawString 等で都度引数に渡さない。

### 描画
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

### 描画 API の実装方針

| API | 実装 |
|---|---|
| `fillRect` | Color program で塗り。pixel-perfect、AA 不要 |
| `drawRect` | **4 つの細い fillRect**（top / bottom / left / right、各 1px）。axis-aligned なので AA 不要、pixel-perfect |
| `fillRoundRect` / `drawRoundRect` | **RoundedRect program**（SDF）。`corner_radius > 0` を指定、1px smoothstep で AA |
| `fillCircle` / `drawCircle` | **RoundedRect program** に `corner_radius = min(w, h) / 2` を渡すだけ。内部的には rounded rect と同じパス |
| `drawString` | Text program + freetype アトラス。色は current color、フォントは current font |
| `drawImage` | Image program、tint は (1,1,1,1) 固定。texture は `image.texture` |

## drawString の y 基準について
Swing は `y = baseline`、現代的 UI ライブラリ (Cairo / Skia / Direct2D / CoreGraphics) は `y = bounding box の top`。
**nimbus は top-of-bounding-box 派** を採用する（layout で計算しやすい）。
baseline 派の API が必要になったら `drawStringAtBaseline(s, x, baseline_y)` 等を別途追加。

## drawString の改行
`\n` を含む文字列は **改行を無視（リテラル文字としても描かない）** する。複数行レンダリングが必要なら呼び出し側で行ごとに `drawString` を呼ぶ。
将来 `drawText` のような自動レイアウト付き API を別途用意する想定。

## 状態管理: save/restore は持たない
`clip` が新しい Graphics を返す方式（[Clipping](#clipping-子-paint-への引き渡しを兼ねる) 参照）にしたことで、save/restore に相当するネストは clip 経由で表現できる。

色やフォントは `setColor` / `setFont` で **現在の Graphics に対するミューテーション**。子の paint で setColor しても、親の Graphics は影響を受けない（clip で値コピーが行われているため）。

## 実装ストラテジ
Graphics は **値型 (struct)**。`clip` で複製されるため alloc は発生しない。
内部で以下を持つ:
- `*CommandBuffer`（フレームごとに呼び出し元が acquire）— 借用
- `*Renderer` or `*Programs` 集（Application / Window 寿命）— 借用
- `*UniformBuffer`（共有リング、フレーム頭で reset 済み）— 借用
- 状態（値）:
  - `origin: struct { x: f32, y: f32 }` — clip により累積される平行移動
  - `clip_rect: Rect` — 絶対座標。各 draw 呼び出し時に `nmSetScissor` に反映
  - `current_color: Color`
  - `current_font: Font`

各 draw 呼び出しで:
1. clip_rect で `nmSetScissor` を毎回設定（変更検知でスキップしてもよいが v1 は素朴に）
2. 必要な program を bind
3. uniform を push して bindUniforms
4. ローカル座標を `origin + local` で絶対座標に変換 → NDC へ
5. quad の頂点を組み立てて VB に upload
6. draw

頻繁な program 切替が出るが、GUI スケール（数十〜数百 draw / frame）なら問題なし。
将来バッチング（同 program ぶんを集めて 1 draw call にまとめる）の余地は残す。

## v1 の範囲外

| 機能 | 理由 |
|---|---|
| drawLine | GUI で実用上少ない（線が要るなら axis-aligned は thin fillRect で代用） |
| drawPolygon / fillPolygon | 任意形状、専用 SDF or テッセレーションが必要 |
| setStroke (線幅・破線) | drawRect / drawRoundRect の thickness は 1px 固定 |
| setTransform (rotate / translate / scale) | アニメ時に必要だが v1 不要 |
| setAntiAlias | 暗黙対応（rect は AA 不要、SDF 形状は常時 1px AA） |
| save / restore | 状態スタック（clip で値返しすることで不要） |
| drawImage の scale / subimage 指定 | 元サイズで貼るのみ |
| 複数行 drawString（`\n` の自動レイアウト） | テキストレイアウトは別レイヤー |
| グラデーション塗り | 当面 image / texture で代用 |

## Image との関係
`awt.Image` は実装済み。zigimg の存在を隠して RGBA8 デコード + GPU upload まで一発でやる:

```zig
pub const Image = struct {
    texture: Texture,
    width: i32, height: i32,

    pub fn fromMemory(allocator: std.mem.Allocator, device: Device, bytes: []const u8) !Image;
    pub fn deinit(self: *Image) void;
};
```

`fromMemory` はデコードと format 変換に `allocator` を一時的に使うだけで、戻り値の `Image` には GPU テクスチャしか残らない。

`@embedFile` 相当を `Image.fromEmbedded(comptime path)` 形式で提供しようとしたが、Zig の `@embedFile` は **call-site の相対 path** で解決される comptime 機構のため、library 関数の中に隠せない。代わりに利用側で:

```zig
const png_bytes = @embedFile("assets/example.png");
var image = try awt.Image.fromMemory(allocator, device, png_bytes);
defer image.deinit();
```

と書いてもらう方針。

## 決定済み（このセクションは記録用、新しい論点が出たら上に移す）

- **Font の所有権**: `Font { face: *awt.Font, pixel_size }` で face を **borrow**。Font 自体は値型で軽量に複製可能。`awt.Font` (FT_Face) の所有は framework `Application` の責務（default font 等）
- **measureString の置き場所**: `Font.measureString` に置く。Graphics 経由にしない理由は、レイアウト計算時など Graphics が手元に無い場面（paint コールバック外）でも文字幅を測りたいから
- **drawString の改行**: `\n` は無視。複数行は呼び出し側で行ごとに分けて drawString
- **clip の挙動**: 新しい Graphics を値で返す（origin 平行移動 + clip 積集合）。save/restore は持たない
- **Color**: 内部 `f32 × 4`、コンストラクタで `rgba(f32)` / `rgb(f32)` / `bytes(u8)` 両対応
