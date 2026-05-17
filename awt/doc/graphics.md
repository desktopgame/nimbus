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
    face: *awt.Font,     // freetype face (already exists)
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

### Clipping
```zig
pub fn clip(self: *Graphics, r: Rect) void;
```
矩形クリップを設定。内部的には `nmSetScissor` を呼ぶ。
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

pub fn drawCircle(self: *Graphics, r: Rect) void;  // bounding box r、アウトライン
pub fn fillCircle(self: *Graphics, r: Rect) void;  // bounding box r、塗り

pub fn drawImage(self: *Graphics, image: awt.Image, x: f32, y: f32) void;
```

## drawString の y 基準について
Swing は `y = baseline`、現代的 UI ライブラリ (Cairo / Skia / Direct2D / CoreGraphics) は `y = bounding box の top`。
**nimbus は top-of-bounding-box 派** を採用する（layout で計算しやすい）。
baseline 派の API が必要になったら `drawStringAtBaseline(s, x, baseline_y)` 等を別途追加。

## 状態スタック（save / restore）
**v1 は持たない**。
`Component.paintComponent` の入り口で受け取った Graphics は、ネストせず 1 つの描画スコープで使い切る前提。
ネストした paint（親 → 子 → 孫の clip 連鎖など）が出てきた段階で `save()` / `restore()` を導入する。

## 実装ストラテジ
Graphics は内部で以下を持つ:
- `*CommandBuffer`（呼び出し元から受け取る、毎フレーム新規取得）
- `*Programs`（Text / Color / Image を束ねる Renderer 的なもの、Application or Window 寿命）
- `*UniformBuffer`（共有リング、フレーム頭で reset 済み）
- 現在の状態（`current_color`, `current_font`, `current_clip`）

各 draw 呼び出しで:
1. 必要な program を bind
2. uniform を push して bindUniforms
3. quad の頂点を組み立てて VB に upload
4. draw

頻繁な program 切替が出るが、 GUI スケール（数十〜数百 draw / frame）なら問題なし。
将来バッチング（同 program ぶんを集めて 1 draw call にまとめる）の余地は残す。

## v1 の範囲外

| 機能 | 理由 |
|---|---|
| drawLine | GUI で実用上少ない |
| drawPolygon / fillPolygon | 任意形状、SDF program 必要 |
| drawRoundRect / fillRoundRect | 角丸、SDF program 必要 |
| setStroke (線幅・破線) | drawRect は 1px 固定 |
| setTransform (rotate / translate / scale) | アニメ時に必要だが v1 不要 |
| setAntiAlias | 暗黙対応（rect は AA 不要、円は将来 SDF で対応） |
| save / restore | 状態スタック |
| drawImage の scale / subimage 指定 | 元サイズで貼るのみ |
| 複数行 drawString（`\n` の自動レイアウト） | テキストレイアウトは別レイヤー |
| グラデーション塗り | 当面 image / texture で代用 |

## Image との関係
`awt.Image` はまだ存在しない（hello は `awt.Texture` + zigimg 直叩き）。
Graphics の `drawImage` を実装するタイミングで以下のような awt.Image を作る:

```zig
pub const Image = struct {
    texture: Texture,
    width: i32, height: i32,

    pub fn fromMemory(device: Device, bytes: []const u8) !Image; // zigimg + texture upload
    pub fn fromEmbedded(device: Device, comptime path: []const u8) !Image; // @embedFile + 上記
    pub fn deinit(self: *Image) void;
};
```

`awt.zigimg` の直接露出は `awt.Image` 実装と同時に外す。

## 未決定事項

- **Font の所有権**: `Font { face: *awt.Font, pixel_size }` で face を借用するか、Font が face を所有するか。複数 pixel_size の同 face を持ちたいので borrow が自然。誰が `awt.Font` を所有するかは framework `Application` の責務（default font 等を持つ）
- **getFontMetrics() を Graphics に置くか**: Java は `Graphics.getFontMetrics()` で `FontMetrics` を返す。nimbus は `Font.measureString` だけで済むので不要。ascender/descender が必要になったら `Font.metrics() -> FontMetrics` を別に
- **Color の `0..1 float` vs `0..255 u8`**: float 内部表現、コンストラクタで両対応（`Color.rgb(...)` と `Color.bytes(...)`）
- **drawString の改行**: v1 は `\n` を含まない 1 行のみ受け付ける。`\n` を含む場合は実装定義（無視 / 文字として描く / panic のいずれか）
