# Metal Look（Button 縦スライス）設計 spec

LAF 機構の **Step 2＝Button 縦スライス＝初の実 Metal Look** の **設計 spec**。`laf_enabler.md`（develop マージ済み）が
用意した一括差し替え機構の上に、**Button 1 種だけ**を Swing Metal 風の見た目へ差し替える Look を定義する。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。

関連: [laf_design.md](laf_design.md)（§2.7 default＝FlatLaf／§2.9 theme と Look の分離／§4.1 狙う LAF）、
[laf_enabler.md](laf_enabler.md)（`applyLook` / `RemapEntry` / detached facet・§5.0 GPU 非ゲートの教訓）、
[awt_primitives_laf.md](awt_primitives_laf.md)（`fillGradientRect`＝縦固定 2 stop／bevel は既存 `fillRect`+`drawRect` で描ける）。

---

## 0. 大前提とスコープ（確定・再議論しない）

- **見た目は「縦 linear グラデ ＋ bevel」まで**（bumps＝点描なし。`awt_primitives_laf.md` §0）。角丸はやらない（Metal は矩形＋ベベル）。
- **色は current Theme に依存せず自前ベイク**（`laf_design.md` §2.9）。`component.theme` は読まない。
- **スコープは Button だけ**。他 widget は部分 LAF で FlatLaf のまま（`laf_enabler.md` §4 が対応済み）。
- **配置は framework 内蔵 Zig モジュール**。binding 層は将来この表を「metal」と名付けるだけ（`laf_design.md` §1.2）。
- **awt プリミティブは完成済み**: `fillGradientRect(rect, top, bottom)`＝縦グラデ（`Graphics.zig:297`）、
  `fillRect`（`:293`）/ `drawRect`（`:354`）/ `drawString`（`:491`）/ `drawImageScaled`（`:446`）。新プリミティブ不要。
- **enabler の使い方（確定済み API）**:
  `RemapEntry{ .from = &Button.look_vtable, .to = .{ .vtable = &metal_button_look, .ctx = &metal_palette } }` を
  1 件だけ持つ表を `nimbus.laf.applyLook(root, table)` で **init 時 1 回**当てる（`laf.zig:3-13`）。

スコープ外（依存・将来）: 他 widget の Metal 化、JTattoo、テクスチャ 9-slice、binding 層の名前付き LAF。

---

## 1. モジュール構成（確定提案）

### 1.1 ファイルと公開シンボル

新規 `framework/src/laf/metal.zig`（仮）に Metal Look 一式をまとめる:

- **`metal_button_look`**: `Component.LookVTable`（`paint` / `paintOver` / `measureMinSize` の 3 フック）。
  Button の FlatLaf 版（`Button.zig:45-49` の `look_vtable`）と **同じ `self: *Component` シグネチャ**で、
  `@fieldParentPtr("component", self)` で `*Button` へ戻り `model.armed/pressed/rollover/enabled`・`text`・`icon`・
  `focused` を読む（**振る舞いは触らず見た目だけ**＝FlatLaf の `lookPaint`/`lookMeasureMinSize` と同じ読み筋）。
- **`metal_palette`**: 自前ベイクの鋼色 const 群（§2）。型 `MetalPalette` も同ファイルに定義。
- **`pub fn buttonTable() laf.LookTable`**（または `pub const button_table`）: Button エントリ 1 件のみを返す
  ビルダ（§1.3）。

### 1.2 root.zig からの露出

`laf` は現在 1 ファイル `framework/src/laf.zig`（`root.zig:14` で `pub const laf = @import("laf.zig")`）。
そこへ **`pub const metal = @import("laf/metal.zig");`** を 1 行足し、`nimbus.laf.metal.*` で参照できるようにする
（`metal.zig` の import は `../Component.zig` / `../Button.zig` 相対）。利用側:

```zig
const table = nimbus.laf.metal.buttonTable();
nimbus.laf.applyLook(window.container.component, table);  // init 時 1 回
```

既存 `laf.zig`（`applyLook` / `RemapEntry` / `LookTable`）は **無改修**。Metal は機構の上に乗る純追加で、
enabler の API を一切変えない。

### 1.3 表の表現と ctx の渡し方（確定）

- `buttonTable()` は **要素 1 の const スライス**を返す:
  `&[_]laf.RemapEntry{ .{ .from = &Button.look_vtable, .to = .{ .vtable = &metal_button_look, .ctx = &metal_palette } } }`。
- **`metal_palette` は `pub var` で置く**（`pub const` ではなく）。理由: `RemapEntry.to.ctx` は `*anyopaque`（非 const。
  `Component.UI`、`Component.zig:162-165`）なので、`const` のアドレスからは `@constCast` 無しに得られない。
  FlatLaf の既定 ctx `Component.default_look_context` も同じ理由で `pub var`（`Component.zig:167`）＝**前例に倣う**。
  `metal_palette` は規約上 immutable（書き換えない）だが型は `var`。`paint`/`measureMinSize` は ctx を
  `@ptrCast(@alignCast(ctx))` で `*MetalPalette` へ戻して読む（テストの `RecordingLookContext` と同型。
  `laf_test.zig:85-97`）。

---

## 2. Metal パレット（確定提案・RGBA 具体値）

`MetalPalette` は **鋼（steel）系の自前色**。Swing Metal の OceanTheme に寄せつつ、Theme から独立した固定値とする。
値は `awt.Graphics.Color`（`r,g,b,a` の f32。`Graphics.zig:42-53`）。下表は 0–255 表記（実装は `Color.bytes(r,g,b,255)`
で書ける。`Graphics.zig:54`）。**縦グラデは top/bottom の 2 色**（`awt_primitives_laf.md` §1.1）。

### 2.1 body（縦グラデ）

| 状態 | top（上端） | bottom（下端） | 意図 |
|---|---|---|---|
| enabled（通常） | `(248, 250, 252)` | `(199, 212, 227)` | 上が明・下が暗の自然な凸（光は上から） |
| rollover（ホバー） | `(255, 255, 255)` | `(214, 226, 240)` | 全体を一段明るく |
| armed-pressed（押下） | `(158, 173, 194)` | `(196, 209, 224)` | **上下反転**（上が暗・下が明）＝凹んで見える |
| disabled | `(232, 233, 236)` | `(214, 215, 219)` | 低コントラストの灰（凹凸を殺す） |

### 2.2 frame / bevel（1px エッジ）

| 役割 | 色 | 用途 |
|---|---|---|
| `border`（外枠） | `(122, 138, 153)` | 最外周 1px の鋼フレーム |
| `bevel_light`（明エッジ） | `(255, 255, 255)` | 内側 1px の上・左（通常時）。押下時は下・右へ回る |
| `bevel_dark`（暗エッジ） | `(132, 148, 168)` | 内側 1px の下・右（通常時）。押下時は上・左へ回る |
| `border_disabled` | `(180, 186, 194)` | disabled 時の薄い外枠 |

### 2.3 text / focus

| 役割 | 色 | 備考 |
|---|---|---|
| `text_enabled` | `(51, 51, 51)` | Metal の本文色（黒寄りグレー）。※`Button.color`（利用者指定）より Metal 定数を優先するかは §6-1 で未決 |
| `text_disabled` | `(153, 153, 153)` | 無効時 |
| `focus_ring` | `(99, 130, 191)` | Ocean のフォーカス青。内側 inset の `drawRect` で描く（§3.4） |
| `flat_hover` | `(214, 226, 240, 255)` | flat（アイコンのみ）モードのホバー地（§3.5） |
| `flat_armed` | `(190, 205, 224, 255)` | flat モードの押下地 |

すべて `a = 255`（不透明）。これらは **提案値**で、目視デモ（§5c）で作者が微調整してよい（§6-2）。

---

## 3. paint レシピ（`metal_button_look.paint`）（確定提案）

FlatLaf の `Button.lookPaint`（`Button.zig:256-336`）の **状態判定とコンテンツ配置をそのまま踏襲**し、
**背景の描き方だけ**を「矩形フレーム＋ベベル＋縦グラデ」に差し替える。`paintOver` は leaf なので no-op
（FlatLaf と同じ。`Button.zig:338`）。

状態フラグは FlatLaf と同じ読み筋（`Button.zig:261-264`）:
`has_text = text.len > 0` / `has_icon = icon != null` / `flat = has_icon and !has_text` /
`armed_pressed = model.armed and model.pressed` / `enabled = model.enabled` / `rollover = model.rollover`。

### 3.1 標準（bordered）モードの描画順

`flat == false`（テキスト有り、または icon+text）のとき。`sz = self.size`、`p = palette`:

1. **base＝外枠を全面塗り**: `setColor(p.border 或いは p.border_disabled); fillRect({0,0,sz.w,sz.h})`。
   このあと内側を上塗りするので、残った最外周 1px が枠になる（角の継ぎ目が出ない描き方）。
2. **body 縦グラデ（interior, inset 2px）**: 状態に応じ §2.1 の {top,bottom} を選び
   `fillGradientRect({2,2,sz.w-4,sz.h-4}, top, bottom)`。
3. **bevel 1px リング（inset 1px）**: 通常時は **上・左＝`bevel_light`／下・右＝`bevel_dark`**、
   **armed-pressed 時は反転**（上・左＝dark／下・右＝light＝凹み）。各辺は `fillRect` の 1px セグメントで描く
   （上: `{1,1,sz.w-2,1}` / 左: `{1,1,1,sz.h-2}` / 下: `{1,sz.h-2,sz.w-2,1}` / 右: `{sz.w-2,1,1,sz.h-2}`）。
   disabled 時は bevel を省略（フラットに見せる）。
4. **focus ring（`focused` のとき）**: `setColor(p.focus_ring); drawRect({3,3,sz.w-6,sz.h-6})`（§3.4）。
5. **content（icon / text）**: FlatLaf と **同一の中央寄せ配置**（`Button.zig:298-335`）。色だけ Metal:
   text 色は enabled なら `p.text_enabled`（§6-1 の未決に留意）、disabled なら `p.text_disabled`。
   mnemonic 下線も FlatLaf と同じ（`Button.zig:322-334`）。

すべて **整数アライン矩形**で構成し、グラデ以外に anti-alias を持ち込まない（ゴールデンの決定性。§5a）。

### 3.2 状態別まとめ

- **enabled（通常）**: 枠＋上明下暗グラデ＋上左 light/下右 dark の凸ベベル。
- **rollover**: グラデを §2.1 hover（一段明るい）に差し替えるだけ。ベベル・枠は通常と同じ。
- **armed-pressed**: グラデ上下反転＋ベベル反転で凹み表現。任意で **content を (+1,+1) ずらす**と押下感が増す
   （推奨だが必須でない。§6-3）。
- **disabled**: 灰グラデ＋bevel 省略＋薄枠＋`text_disabled`。

### 3.3 なぜこの順序か

- 「外枠全面塗り → interior 上塗り」は、枠を `drawRect` で描くより**角の 1px 継ぎ目**が出ず、整数構図で決定的。
- bevel を grad の上に重ねるのは、エッジを最前面の 1px として明示するため（Swing Metal の押し出し表現と同型）。

### 3.4 focus ring

Swing Metal は内側の点線矩形だが、awt に点線プリミティブは無い。v1 は **`focus_ring` 色の実線 `drawRect`（inset 3px）**で
代用する（点線は将来。§6-4）。`Button.focused`（`Button.zig:30-32`）を読むのは FlatLaf（`Button.zig:292`）と同じ。

### 3.5 flat（アイコンのみ）モード

`flat == true` は Metal でも **枠・ベベルを付けない**（FlatLaf の flat 意図＝`Button.zig:266-276` を踏襲）:

- enabled かつ armed-pressed → `flat_armed` で全面 `fillRect`。
- enabled かつ rollover → `flat_hover` で全面 `fillRect`。
- それ以外 → 地は描かない（透明）。
- アイコンは中央配置（FlatLaf と同じ）。

---

## 4. メトリクス（`metal_button_look.measureMinSize`）（確定提案）

FlatLaf の `lookMeasureMinSize`（`Button.zig:126-148`）と **同じ式**（text+icon から min を組む）で、
**padding 定数だけ Metal 用に差し替える**。Metal は FlatLaf より少しがっしりさせる。

Metal 定数（`metal.zig` 内の private const。FlatLaf の `Button.zig:16-20` とは別物でよい＝Look ごとの定数）:

| 定数 | Metal 値 | FlatLaf 値（参考） | 備考 |
|---|---|---|---|
| `PADDING_X` | `14` | `12` | 横をやや広く |
| `PADDING_Y` | `7` | `4` | 縦を厚く（鋼板感） |
| `ICON_TEXT_GAP` | `6` | `6` | 同じ |
| `FLAT_PADDING` | `4` | `4` | flat モードは同じ |

min 算出（FlatLaf と同形）:

- icon+text: `w = icon_w + ICON_TEXT_GAP + text_w + PADDING_X*2`、`h = max(icon_h, text_h) + PADDING_Y*2`。
- icon のみ（flat）: `w = icon_w + FLAT_PADDING*2`、`h = icon_h + FLAT_PADDING*2`。
- text のみ: `w = text_w + PADDING_X*2`、`h = text_h + PADDING_Y*2`。

`PADDING ≥ 2` なので、外枠 1px＋ベベル 1px（計 2px/辺）は padding 内に収まり、別途確保は不要。
**戻りは最小サイズ（`Size`）のみ**（`laf_design.md` §2.5）。enabler が init walk で `min_size` に焼く
（`laf.zig:26-28`：Button は container/tree_children を持たない true leaf なので re-measure 対象）。

---

## 5. テスト / デモ計画（確定提案）

### 5a. Metal ゴールデン（snapshot・意図的に新ピクセル）

**ゼロピクセル不変は適用されない**。Metal は FlatLaf と別物の絵なので、**新規 fixture を意図的に作る**
（既存 golden は 1 枚も動かない＝Button を Metal にした新 scene を足すだけ）。

- `framework/tests/scenes.zig` に Metal Button scene を追加（既存 `Scene` 構造＝`scenes.zig:26-34`、
  runner は `framework/tests/snapshot_test.zig`）。scene 内で Button を数個作り、
  `nimbus.laf.applyLook(root, nimbus.laf.metal.buttonTable())` を paint 前に当てる。
- **状態違いを 1〜数枚**: normal / pressed（`model.setArmed(true)`+`setPressed(true)`）/ disabled
  （`model.setEnabled(false)`）。rollover も足してよい。fixture PNG を `framework/tests/fixtures/` に置く。
- **tolerance 方針**: framework runner は **グローバル `TOLERANCE = 1`**（`snapshot_test.zig:16`。awt と違い
  per-scene tolerance フィールドは現状無い＝`scenes.zig:26-34`）。グラデは決定的（awt の `vertical_gradient`
  scene が tol=1 で通っている。`awt/tests/scenes.zig:66-83`）なので、**整数構図＋グローバル tol=1 で十分**。
  もし将来 Metal scene が 1 LSB を超えるなら、framework `Scene` に **per-scene `tolerance` フィールドを足す**
  （awt 版＝`awt/tests/scenes.zig:33-34` に倣う）。今回は不要の見込み。

### 5b. メトリクス純ロジックテスト（GPU 非依存）

`laf_enabler.md` §5.0 の教訓どおり、**`Device.init` ゲート下に置かない**（`Application.initHeadless` 経由禁止）。

- フォントは **`awt.Font.init(noto_ttf, 0)` を直接**使う（GPU 不要。glyph atlas / device を起こさない）。
- `Button.create(allocator, "OK", font, color)` で Button を組み、
  `nimbus.laf.metal.metal_button_look.measureMinSize(&button.component, &nimbus.laf.metal.metal_palette)` を呼び、
  **戻り `Size` が Metal 定数（§4）から計算した既知値に一致**することを assert。padding 差で FlatLaf と数値が違うことも突く。
- `error.SkipZigTest` 経路を踏まないこと（常に実行される）。

### 5c. デモ example（目視）

- 新規 `examples/widget_metalbutton`（`widget_*` 命名＝`example-guide`）。Window に Button を数個置き、
  ループ前に `nimbus.laf.applyLook(window.container.component, nimbus.laf.metal.buttonTable())` を 1 回当てる。
  押下・ホバー・無効化が目視できる構成（1 個は `setEnabled(false)`）。
- **`examples/readme.md` に項目追加**（`example-guide` の規約）。`run` で目視確認できる形にする。

---

## 6. 未決（解決しない・列挙のみ）

1. **text 色は Metal 定数 vs 利用者指定 `Button.color`**: FlatLaf は enabled 時 `button.color`（利用者指定）を使う
   （`Button.zig:318`）。Metal が自前 `text_enabled` で**上書き**するか、`button.color` を尊重するかは未決。
   §3.1 は暫定で Metal 定数を提案したが、Theme 非依存の方針と「利用者が色を渡せる」現 API の両立は作者判断。
2. **パレットの最終 RGBA**: §2 は提案値。デモ（§5c）の目視で作者が微調整しうる。
3. **押下時の content オフセット (+1,+1)**: 押下感を増す任意演出（§3.2）。入れるかは未決（golden の手間と相談）。
4. **focus ring の点線化**: v1 は実線 `drawRect`（§3.4）。点線プリミティブは awt 側の将来課題。
5. **モジュール名 `metal.zig` / `buttonTable` / `MetalPalette`**: 仮。`laf_design.md` §6-1 の命名未決の延長で確定不要。
6. **複数 Button エントリの将来統合**: 他 widget を Metal 化する際、各 Look の表をどう合成して 1 枚の表にするか
   （`buttonTable()` を `metalTable()` へ拡張する等）は本フェーズ外。
   → Group A（選択系）への横展開と `metalTable()` 化は [laf_metal_selection.md](laf_metal_selection.md) で確定。

---

## 7. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | スコープ＝Button 1 種のみ。縦グラデ＋bevel、角丸なし、Theme 非依存の自前色（§0） |
| 確定 | `framework/src/laf/metal.zig` に `metal_button_look`＋`metal_palette`＋`buttonTable()`。`laf.zig` に `pub const metal` 1 行追加で `nimbus.laf.metal` 露出（§1.1-1.2） |
| 確定 | 表は Button エントリ 1 件の const スライス。ctx は `pub var metal_palette`（`*anyopaque` 要件＋`default_look_context` 前例）（§1.3） |
| 確定 | パレットは鋼系 RGBA を具体提案（body 縦グラデ 4 状態／border・bevel／text・focus・flat）（§2） |
| 確定 | paint＝外枠全面塗り→interior 縦グラデ→bevel 1px リング（押下で反転）→focus ring→content(FlatLaf 配置)（§3） |
| 確定 | 状態別: 通常=上明下暗+凸ベベル／hover=明グラデ／pressed=反転グラデ+反転ベベル／disabled=灰+ベベル省略（§3.2） |
| 確定 | flat（アイコンのみ）は枠・ベベルなし。hover/armed は flat 地で塗る（§3.5） |
| 確定 | measure は FlatLaf と同式・Metal padding 定数（PADDING_X=14 / PADDING_Y=7）。true leaf として enabler が min_size へ焼く（§4） |
| 確定 | テスト: (a) Metal golden＝意図的に新ピクセル・状態違い 1〜数枚・グローバル tol=1（b）metrics 純ロジック GPU 非ゲート（c）example `widget_metalbutton`（§5） |
| 未決 | text 色（Metal 定数 vs `Button.color`）／RGBA 微調整／押下オフセット／focus 点線／命名／複数 Look 表の統合（§6） |
