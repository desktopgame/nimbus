# awt LAF 描画プリミティブ 設計探索

LAF（Metal / JTattoo）を実現するために awt 層へ足す 2 つの描画プリミティブの **設計提案**。
`laf_design.md` §4.2（awt に要る 2 プリミティブ）／§6-5（未決の詳細）の続きにあたり、
あちらが「別ワークストリーム・依存として挙げるだけ」と切り出した部分をここで詰める。
laf_design の流儀に倣い、**「確定」と「未決」を明確に分ける**。実装はまだしない（コードは書かない）。

対象は以下 2 つ:

1. **linear グラデーション fill**（Swing Metal の縦グラデ用）。
2. **テクスチャ ＋ 9-slice（＋tint）**（JTattoo の skin 機構用）。

関連: `laf_design.md`（LAF 機構本体・develop にマージ済み）、`awt_backlog.md` #9（ベクター / テクスチャ描画）、
`framework_backlog.md` #27（小アイコンの脱・階段描画）、`awt/doc/graphics.md`（描画 API spec）、
`awt/doc/programs.md`（ビルトイン program 管理方針）。

---

## 0. 大前提（laf_design / 作者決定から引き継ぐ・再議論しない）

- **Metal は「縦 linear グラデ＋bevel」まで**。bumps（点描）はやらない → 点描テクスチャ / ディザは **不要**。
  bevel は既存 `fillRect` / `drawRect` の光 / 影エッジで描けるので **新プリミティブ不要**（本 doc の対象外）。
  グラデ＋bevel を実際に Button へ組む Look 側の設計は [laf_metal_button.md](laf_metal_button.md)。
- **JTattoo は機構だけ**。本家スキン素材は同梱しない。awt は texture + 9-slice の **機構**だけ出す。
  名前付き LAF・スキン調達はバインディング層 / サンプルの仕事（`laf_design.md` §1.2）。
- **C バックエンド無改修で足せる**ことが両プリミティブの前提（下記 §1.0）。頂点カラー方式
  （全 4 バックエンドに新 vertex layout 追加）は **回避する** — グラデは uniform 駆動で賄う。

### 1.0 なぜ C 無改修で足せるか（裏取り）

- グラデ: 既存 `RoundedRect` program（`programs.zig:231-252`）と同型。VS が uv を PS へ渡し、PS が uv から色を
  lerp する。既存の `vertex_texcoord_2d` レイアウトと共有 `QuadIndexBuffer` をそのまま使える。
  追加物は **shaders 4 枚 ＋ program 1 個 ＋ Graphics メソッド ＋ Context 配線**だけで、awt-c / 各バックエンドは無改修。
- 9-slice: `Image` program（`programs.zig:199-218`）・`cb.bindTexture`・static sampler s0・**tint uniform**
  が既に全部揃っている（`drawImageScaled`、`Graphics.zig:338-364`。tint は今 `Graphics.zig:355` で常に
  `(1,1,1,1)` 素通り）。**新 program すら要らない**。足りないのは「UV サブ矩形指定」と
  「9 枚クアッド分割（inset から UV / 位置を算出）」だけで、これは Zig 側 `Graphics` の純ロジック。

---

## 1. グラデーション fill

### 1.1 軸と stop 数（確定＝縦固定・2 stop）

v1 は **縦固定（top→bottom）・2 stop** に確定する。

- API は `fillGradientRect(rect, top, bottom)`。PS は uv.y（0=上, 1=下）で `top`↔`bottom` を lerp する。
- **根拠**: 狙う実需は Swing Metal の縦グラデ（と Nimbus 系のボタン / バー）で、いずれも**縦・2 色**で賄える。
  任意軸（start/end 点）・N stop は実需が無く、過剰一般化を避ける（[[feedback_lightweight_workflows]]：
  実需が出るまで作り込まない）。
- **広げる余地（未決・先行記述しない）**: uniform を additive に拡張すれば C 無改修のまま広げられる。
  - 横 / 任意軸: uniform に方向ベクトル（または start/end 点を uv 空間で）を足し、PS で
    `t = clamp(dot(p - start, dir) / |dir|^2, 0, 1)` を計算する。vertex layout は不変。
  - N stop: 固定長 stop 配列 uniform（例 `[8]{offset, color}`）を足し PS でループ lerp する、
    または stop 区間ごとに複数ドローへ分割する。**いずれも v1 では持たない**。
  - 角丸グラデ（Metal の角丸ボタン）: SDF（`RoundedRect`）とグラデを 1 program に畳む必要があり別物。
    v1 のグラデは**矩形のみ**。角丸が要るときは別 program か SDF program へのグラデ合流として後で起票する。

### 1.2 Graphics メソッド署名と uniform（確定）

```zig
// awt/src/Graphics.zig（draw API 群に追加）
// 縦 linear グラデで rect を塗る。top が rect 上端、bottom が下端の色。
// alpha も補間する（program の blend は .alpha）。
pub fn fillGradientRect(self: *Graphics, r: Rect, top: Color, bottom: Color) void
```

- 幾何の積み方は **`fillRectColor`（`Graphics.zig:219-244`）の矩形 ＋ `drawImageScaled`
  （`Graphics.zig:338-364`）の uv 付き頂点**を合成した形になる。頂点は 4-float（x, y, u, v）、
  uv は TL=(0,0) … BR=(1,1)。テクスチャは bind しない。
- uniform 構造体（`programs.zig` の新 program 内・PS slot 0）:

```zig
// 上端色・下端色。PS は uv.y で lerp する。
extern struct {
    color0: [4]f32, // top
    color1: [4]f32, // bottom
}
```

- 新 program `programs.Gradient`（`vertex_layout = .vertex_texcoord_2d`, `blend = .alpha`）。
  shaders は `awt/src/shaders/Gradient/gradient.{hlsl,msl}.{vs,ps}` の 4 枚。
  VS は `RoundedRect` / `Image` の VS と同じ「uv 素通し」、PS が `lerp(color0, color1, uv.y)`。
- `Color` は既存の値型（`Graphics.zig:35-60`、`{r,g,b,a: f32}`）をそのまま使う。`Color.asArray()` で `[4]f32` 化。

---

## 2. テクスチャ + 9-slice

### 2.1 inset の表現（確定＝4 inset・source texel 単位）

inset は **4 値 `Insets{ left, top, right, bottom }`**（source texel 単位）で表す。source-rect 方式は採らない。

- **根拠**: 9-slice の本質は「四隅を引き伸ばさず、辺は片軸、中央は両軸で伸ばす」ための **境界幅**であり、
  それは 4 inset そのもの。source-rect（サブ UV）は「テクスチャのどの部分を使うか」という直交した別概念で、
  v1 では画像全体（UV 0..1）を source とすれば足り、混ぜると API が太る。
- inset の単位は **source texel**。9 枚の source 矩形は texel 空間の inset から UV（`/image.width`,
  `/image.height`）へ落とす。**四隅は 1:1**（source inset サイズ ＝ dst 上の論理ポイントサイズ）で描き、
  辺は片軸・中央は両軸を線形フィルタで伸縮する。DPI 換算は `drawImageScaled` と同じ
  （論理ポイントで積み、GPU viewport が framebuffer へ拡大）。
- **退化ケース（doc に明記して実装で守る）**: `left+right > dst.width`（または上下）なら inset を
  比例クランプ。幅 0 の辺 / 中央クアッドは積まず捨てる（空クアッドは描画コスト・スナップショット脆化の元）。

### 2.2 メソッド署名と drawImageScaled との関係（確定）

```zig
// awt/src/Graphics.zig
pub const Insets = struct { left: f32, top: f32, right: f32, bottom: f32 };

// image を dst へ 9-slice で描く。insets は source texel 単位（四隅は伸ばさない）。
// tint は Image program の tint uniform に渡る。無着色なら white を渡す。
pub fn drawTextureNineSlice(self: *Graphics, image: Image, dst: Rect, insets: Insets, tint: Color) void
```

- **別メソッドだが実装を共有する**（共通化 ＋ 別メソッド）。`drawImageScaled` は「UV 0..1 の 1 クアッド」、
  9-slice は「サブ UV の最大 9 クアッド」で、両者は **同じ Image program へクアッドを積む**だけ。
  内部に private ヘルパを 1 本切る:

```zig
// dst 矩形へ image のサブ UV 矩形を tint 付きで 1 クアッド描く（両 public API の土台）。
fn imageQuad(self: *Graphics, image: Image, dst: Rect, u0: f32, v0: f32, u1: f32, v1: f32, tint: Color) void
```

  - `drawTextureNineSlice` は inset から 9 個の (dst, uv) を出して `imageQuad` を最大 9 回呼ぶ。
  - `drawImageScaled` も `imageQuad(..., 0, 0, 1, 1, white)` の特殊形に寄せられる
    （現状 `Graphics.zig:355` の tint ハードコード `(1,1,1,1)` をヘルパ側へ移すだけ。
    public 署名は不変・additive）。tint を `drawImageScaled` にも将来開ける布石になるが、
    **v1 では `drawImageScaled` の署名は変えない**（実需が無い）。
- **9 分割は純ロジック**（inset → 9 つの UV / dst 矩形）。ここを headless 単体テストの主対象にする（§3.2）。

---

## 3. テスト方針（確定）

テクスチャ / グラデは GPU・フィルタ差でゴールデンが誤検知しやすい（CLAUDE.md 警告・`awt_backlog.md` #9 と同じ懸念）。
**「安定な所だけ狭く張り、ぶれる所は純ロジック ＋ 局所 tolerance で受ける」**を方針にする。

### 3.1 現状のゴールデン基盤（裏取り）

- `awt/snapshot.zig` の `compare` は **per-call の `tolerance: u8`**（`CompareOptions`）を既に取る。
  既定 1（1 LSB）。`CompareResult` は `mismatch_channels` と `max_diff` を返す。
- ところが `snapshot_test.zig`（awt / framework 双方）は **global `const TOLERANCE: u8 = 1`** を全 scene へ一律適用
  （`awt/tests/snapshot_test.zig:21,207` / `framework/tests/snapshot_test.zig:16,220`）。
  `Scene`（`awt/tests/scenes.zig:23-34`）に tolerance フィールドは **無い**。

### 3.2 決めること（確定）

- **9-slice の幾何（inset → 9 矩形）は純ロジック headless 単体テストで exact に張る**。レンダリング前の
  UV / dst 計算なので GPU 非依存・決定論的。退化クランプ・空クアッド除去もここで検証する。
  これがプリミティブの**本体の正しさ**を担保し、ゴールデンは見た目の追認に格下げできる。
- **グラデのゴールデンは狭く張る**。縦 2 色の lerp は PS の fp 補間で、端点（上端 = top・下端 = bottom）と
  中点は安定しやすい。既定 tolerance 1 のまま縦グラデ scene を 1 枚足し、ぶれたら scene 単位で緩める。
- **9-slice のゴールデンは「整数倍スケール」で決定論を作る**。辺 / 中央の伸縮をドライバ非依存にするため、
  **dst 辺 = source 辺の整数倍**になる scene を選ぶ（線形フィルタのサブテクセル補間が起きない構図）。
  四隅 1:1 ＋ 整数倍辺なら tolerance 1 で張れる見込み。伸縮品質そのものを見たい scene は別途 tolerance を緩める。
- **per-scene tolerance を導入する**（小さな基盤拡張）。`Scene` に `tolerance: u8 = 1` を足し、
  `snapshot_test.zig` の compare へ `scene.tolerance` を渡す。**global TOLERANCE は 1 のまま**にして、
  グラデ / 9-slice の特定 scene だけ局所的に緩める（suite 全体の網を緩めない＝「安定な所だけ狭く張る」を実現）。
  この拡張は `framework_backlog.md` #2（テスト網羅の拡充）とも整合する。

---

## 4. Context への program 所有・配線（確定・全サイト列挙）

新 program（グラデのみ。9-slice は `Image` 再利用で program 追加なし）を **`Graphics.Context`
（`Graphics.zig:74-83`）に 1 フィールド**足し、その実体を所有する各サイトへ配る。

- `Graphics.Context` に `gradient_program: *programs.Gradient` を追加。
- **実体の所有は `Application`**（`framework/src/Application.zig`）:
  - フィールド `_gradient_program: awt.programs.Gradient`（`:109-116` の program 群の隣）。
  - `init` で `app._gradient_program = try awt.programs.Gradient.init(app.device);` ＋ `errdefer ....deinit();`
    （`:143-150` の並び）。
  - Context wiring（`:165-174`）に `.gradient_program = &app._gradient_program,` を追加。
  - `deinit`（`:230-231` 付近）に `self._gradient_program.deinit();` を追加。
- **Context を直接組む他サイトも同じく追加が要る**（漏らすとコンパイルエラー。逆に言えば漏れは型で検知できる）:
  - `awt/tests/snapshot_test.zig`（`:107-132` 付近で program を作り Context を組む）。
  - `framework/tests/snapshot_test.zig`（`:120-145` 付近）。
  - `examples/snapshot/main.zig`（`:42-67` 付近）。
  - `examples/hello/main.zig`（`:162-186` 付近）。
- program 生成は comptime メタから型を起こす既存パターン（`programs.ProgramFromMeta`、`programs.zig:50-122`）に
  `pub const Gradient = ProgramFromMeta(.{...})` を 1 個足すだけ（`Color` / `Image` / `RoundedRect` と同じ書式）。
  `awt/src/root.zig` の参照保持（`:91-98` の `_ = programs.Xxx;`）にも `Gradient` を 1 行足す。

---

## 5. 実装フェーズ分け（実装計画）

awt-c / バックエンド無改修・既存ゴールデンを動かさない（グラデ / 9-slice は **新規 scene のみ**で、
既存 scene には現れないので 0 枚動くのが受け入れ条件）方針で 2 フェーズに割る。

### P1: linear グラデーション

- 追加: `programs.Gradient`（メタ 1 個）＋ shaders 4 枚 ＋ `Graphics.fillGradientRect` ＋ uniform 構造体 ＋
  `Context.gradient_program` ＋ §4 の全サイト配線 ＋ `root.zig` 参照。
- テスト: 縦 2 色グラデの新規ゴールデン scene 1 枚（tolerance 1）。グラデはロジックが薄いので主検証はゴールデン。
- doc: `graphics.md` に `fillGradientRect` を追記、`programs.md` に `Gradient` program を追記。

### P2: テクスチャ + 9-slice

- 追加: `Graphics.Insets` ＋ `drawTextureNineSlice` ＋ private `imageQuad` ヘルパ
  （`drawImageScaled` を `imageQuad` 上に載せ替え・署名不変）。**新 program / Context 配線なし**（`Image` 再利用）。
- テスト: **9 分割幾何の純ロジック headless 単体テスト**（exact・退化クランプ含む）＋ 整数倍スケールの
  9-slice ゴールデン scene（必要なら per-scene tolerance）。`Scene.tolerance` 拡張（§3.2）はここで入れる。
- doc: `graphics.md` に `drawTextureNineSlice` / `Insets` を追記。

P2 は C / program に触れない（Zig 純ロジック ＋ 既存 program 再利用）ので P1 より低リスク。
着手順は P1 → P2 でよいが、相互依存は無いので入れ替え可能。

---

## 6. 未決（解決しない・列挙のみ）

実装着手時 or 実需が出た時点で作者が決める。

1. **グラデの拡張軸**: 横 / 任意軸 / N stop / 角丸グラデ（§1.1）。v1 は縦固定 2 stop。実需が出たら additive に。
2. **inset の単位を texel か論理ポイントか**: §2.1 は source texel を推すが、JTattoo skin の実素材を
   入れたときに「論理ポイント指定の方が書きやすい」となる余地がある。実スキン投入時に再確認。
3. **`drawImageScaled` への tint 開放**: ヘルパ化で技術的には可能（§2.2）。public 署名を変えるかは実需待ち。
4. **per-scene tolerance のさらなる一般化**: §3.2 は `Scene.tolerance` の単純追加を推す。
   将来「チャンネル別 / 領域別 tolerance」が要るかは未決（`awt_backlog.md` #9 のベクター AA 脆化対策と合流しうる）。
5. **命名**: `fillGradientRect` / `drawTextureNineSlice` / `Insets` / `programs.Gradient` は仮。確定不要。

---

## 7. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | 両プリミティブは C / バックエンド無改修で足す（uniform 駆動グラデ・Image 再利用 9-slice）（§1.0） |
| 確定 | グラデは縦固定・2 stop。`fillGradientRect(rect, top, bottom)`。新 program `Gradient`（uv.y で lerp）（§1.1-1.2） |
| 確定 | グラデ uniform は `{ color0, color1: [4]f32 }`。vertex_texcoord_2d ＋共有 quad index を再利用（§1.2） |
| 確定 | 9-slice の inset は 4 値 `Insets`（source texel・四隅 1:1）。source-rect 方式は不採用（§2.1） |
| 確定 | `drawTextureNineSlice(image, dst, insets, tint)`。private `imageQuad` で `drawImageScaled` と実装共有（§2.2） |
| 確定 | 9 分割幾何は純ロジック headless テストで exact に張る（§3.2） |
| 確定 | グラデ / 9-slice ゴールデンは狭く張る（整数倍スケール構図）＋ `Scene.tolerance` 局所緩和。global TOLERANCE=1 維持（§3.2） |
| 確定 | program 所有は Application。Context 直組みの全 5 サイトへ `gradient_program` 配線（§4） |
| 確定 | P1 グラデ（program＋shader＋配線＋golden）→ P2 9-slice（純ロジック＋golden、C 無改修）（§5） |
| 未決 | グラデ拡張軸 / inset 単位 / drawImageScaled の tint 開放 / tolerance 一般化 / 命名（§6） |
</content>
</invoke>
