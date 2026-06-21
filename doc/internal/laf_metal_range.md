# Metal Look（Group B＝レンジ系: Slider / ScrollBar）設計 spec

LAF Step 3 横展開の **Group B＝レンジ系**（Slider / ScrollBar）を Metal Look へ差し替える **設計 spec**。
Button Metal（[laf_metal_button.md](laf_metal_button.md)）／選択系 Metal（[laf_metal_selection.md](laf_metal_selection.md)）で確立した
レシピ（外枠全面塗り→縦グラデ→ベベルリング・自前パレット・`@fieldParentPtr` で具象型へ戻り状態を読む）を踏襲・再利用する。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。

関連: [laf_metal_button.md](laf_metal_button.md)（MetalPalette・`bodyGradient`・`drawBevel`／`drawInsetBevel`・`drawRectBorder`・
`drawChevron` ヘルパ）、[laf_metal_selection.md](laf_metal_selection.md)（`metalTable()` への追記方式・true leaf re-measure）、
[laf_enabler.md](laf_enabler.md)（`applyLook` / `RemapEntry` / **automation walk が container.children を辿る** §3.3.3・GPU 非ゲート §5.0）、
[awt_primitives_laf.md](awt_primitives_laf.md)（`fillGradientRect`）。

---

## 0. 大前提とスコープ（確定・再議論しない）

- **Metal は縦グラデ＋ベベル・角丸なし・Theme 非依存の自前パレット**。既存 `framework/src/laf/metal.zig` の
  `MetalPalette`／helper（`bodyGradient`・`drawBevel`・`drawInsetBevel`・`drawRectBorder`・`drawChevron`）を **踏襲・再利用**する。
- 各 widget の Metal look は `Component.LookVTable{paint, paintOver, measureMinSize}`。`@fieldParentPtr("component", self)` で
  具象型へ戻り状態を読む（**振る舞い不変・見た目だけ**）。**前景色は利用者尊重**（Button/選択系と同じ方針）。
- enabler `nimbus.laf.applyLook(root, table)` で **init 時 1 回**当てる（`laf.zig`）。
- **スコープは Slider / ScrollBar の 2 種**。他 widget は部分 LAF で FlatLaf のまま（[laf_enabler.md](laf_enabler.md) §4）。

参照スクショ（`tmp/`）から読み取った Metal Ocean の特徴:

- **Slider**（`swingset_metal21.png` 左上「セル間のスペース」「行の高さ」の 2 本）: **沈んだ細い溝トラック**＋鋼の角型 thumb（縦グラデ＋ベベル）。
- **ScrollBar**（`_metal21.png` 右端の縦バー／`_metal11.png` ファイル一覧下の横バー／`_metal13.png` リスト右の縦バー）:
  **沈んだ明るいトラック**＋鋼グラデ thumb（ベベル）＋**両端の三角矢印ボタン**（鋼＋▲▼／◀▶）。

---

## 1. 既存構造の調査結果（重要・確定事実）

### 1.1 Slider（`framework/src/Slider.zig`）

- **leaf widget**（`container == null` かつ `tree_children == null`）＝true leaf。enabler が `min_size` を焼く。
- `look_vtable`（`Slider.zig:37`・**pub**）＝`{lookPaint, lookPaintOver, lookMeasureMinSize}`。`@fieldParentPtr("component", self)` で
  `*Slider` へ戻り `model`（`*BoundedRangeModel`）・`orientation`・`focused`・`dragging` を読む。
- `lookPaint`（`:180`）: トラック（`fillRoundRect`・`t.slider_track`）＋ thumb（`fillCircle`・`t.accent`）＋ focus ring（`drawRect`）。
  **Theme 色を読む**（`self.theme.slider_track` / `.accent` / `.focus_ring`）＝Metal では読まない（自前パレット）。
- 定数は **Slider.zig 内 private**: `TRACK_THICKNESS = 4`（`:17`）／`THUMB_RADIUS = 8`（`:18`）。
- `lookMeasureMinSize`（`:109`）: `long_min = THUMB_RADIUS*4 = 32`、`cross = THUMB_RADIUS*2+4 = 20`。
  horizontal は `{32, 20}`、vertical は `{20, 32}`。
- **位置計算 `valueToPos`/`posToValue`（`:136`/`:147`）は両端を `THUMB_RADIUS` だけ inset する**（`THUMB_RADIUS + t*(len - 2*THUMB_RADIUS)`）。
  これは private method なので metal.zig からは **呼べない**が、**同じ式を metal.zig 内で再実装する**（`drawCheck` 再実装と同型・[laf_metal_selection.md](laf_metal_selection.md) §2.1）。
  → **重要な正しさ制約**: Metal thumb の主軸方向の半幅は **Slider の `THUMB_RADIUS`（＝8）と一致させる**。さもないと
  「カーソル直下の値」と「描かれる thumb 位置」がずれる（drag 時に thumb が指から逃げる）。§3.4 で固定値として明記。
- 矢印ボタンは **無い**（Slider は thumb＋track のみ）。

### 1.2 ScrollBar（`framework/src/ScrollBar.zig`）

- **leaf widget**（container/tree_children なし）＝true leaf。
- `look_vtable`（`:44`・**pub**）。`@fieldParentPtr` で `*ScrollBar` へ戻り `model`・`orientation`・`dragging`・`rollover` を読む。
- `lookPaint`（`:233`）: トラック（`fillRect`・`t.scrollbar_track`）＋ thumb（`fillRoundRect`・`t.scrollbar_thumb`／`_thumb_hover`）。
  ここも **Theme 色を読む**＝Metal では自前パレットに差し替える。`sz.width<=0 or sz.height<=0` で早期 return（畳まれたバー）。
- 定数: `THICKNESS = 14`（`:19`・**pub**）／`MIN_THUMB = 20`（`:20`・private）。
- thumb 幾何（`thumbLen`/`thumbStart`/`offsetToValue`・`:183`〜）は **トラック全長**を使う（矢印ぶんの予約は無い）。
- **矢印ボタンは leaf 内に存在しない**: 別 child コンポーネントでもなく、`lookPaint` 内でも描いていない（track＋thumb のみ）。
  → Metal で機能する矢印を足すには **geometry（両端を予約）＋ processEvent（押下で step）の変更が要り、Look の差し替えだけでは閉じない**（§4.3 で確定判断）。

### 1.3 ScrollPane / List / Table への波及（確定・配線が成立する）

- **ScrollBar は ScrollPane の通常の子**: `ScrollPane.create` が `sp.hbar`/`sp.vbar`（`ScrollBar.createWithModel`）を
  `sp.container.add(...)` で `container.children` に入れる（`ScrollPane.zig:133-147`）。overlay 遅延 attach ではない。
- enabler の walk は `automationChildCount`/`automationChildAt`（＝container があれば `container.children`）を辿る（[laf_enabler.md](laf_enabler.md) §3.3.3）。
  よって **`applyLook` は ScrollPane 配下の hbar/vbar に普通に届く**。detached_look_roots は **不要**（ComboBox/Menu の popup と違い静的ツリー上にある）。
- **List / Table は ScrollPane の view として内包される**（自前の ScrollBar を持たない。`List.zig:427`「enclosing ScrollPane」・
  `Table.zig:332,1154-1157`）。スクロールバーは常に enclosing ScrollPane の hbar/vbar。
- 帰結: **`ScrollBar.look_vtable` → Metal を 1 エントリ入れるだけで、全 ScrollPane・その中の List/Table のバーが自動で Metal 化**される
  （矢印 child look のような追加エントリは不要）。これが「1 つ Metal 化で複数 widget に波及」の配線。§7b で回帰ガードする。

---

## 2. MetalPalette の拡張（確定提案・RGBA）

既存 `MetalPalette`（`metal.zig:29-79`）に **レンジ系トークンを 2 つ追加**する。thumb の鋼グラデは **既存 `body_*`＋`bevel_*`＋`border` を
再利用**（新グラデトークンは足さない）。沈んだトラックの地色だけ新規に持つ。追加トークン:

| トークン | RGBA | 用途 |
|---|---|---|
| `track_groove` | `(198, 206, 216, 255)` | Slider の沈んだ細い溝トラックの地（鋼の暗めチャネル） |
| `scroll_track` | `(224, 225, 229, 255)` | ScrollBar の沈んだ明るいトラックの地（`_metal21` 右バーの明灰） |

- thumb（Slider/ScrollBar とも）: **`bodyGradient(p, enabled, rollover, false)` を再利用**して縦グラデ、外枠 `border`
  （disabled は `border_disabled`）、凸ベベル `drawBevel`（上・左 `bevel_light`／下・右 `bevel_dark`）。鋼ボタンと同じレシピ。
- 沈んだトラックの凹みベベルは **`drawInsetBevel`（既存・`metal.zig:419`＝dark/light 反転）を再利用**（井戸＝CheckBox 沈み井戸と同じ向き）。
- disabled thumb は `body_disabled_*`＋`border_disabled`＋ベベル省略（Button/選択系 disabled と同じ）。
- focus ring は既存 `focus_ring`。

これらは **提案値**で、showcase 目視（§7c）で作者が微調整してよい（§8）。新トークンは 2 つに留め、残りは既存再利用。

---

## 3. Slider Metal レシピ（確定提案）

`metal.zig` に `metal_slider_look`（`LookVTable`）を追加。FlatLaf の `Slider.lookPaint`（`Slider.zig:180`）の
**orientation 分岐と focus ring をそのまま踏襲**し、**トラックと thumb の描き方だけ** Metal 化する（Theme は読まない）。

`*Slider` へ戻り `model.value`/`model.min`/`model.max`・`orientation`・`model` の enabled・`focused` を読む。
状態フラグ: `enabled = model.enabled`（`BoundedRangeModel` の enabled）／`focused`（drag 中の rollover 表現は Slider に無いので使わない）。

### 3.1 paint（`metal_slider_look.paint`）

`sz = self.size`、`p = palette`、`R = SLIDER_THUMB_RADIUS`（§3.4・＝8）、`TR = SLIDER_TRACK_THICKNESS`（§3.4・＝6）:

1. **沈んだ溝トラック**（中央・角丸なしの矩形チャネル）:
   - horizontal: `cy = sz.height/2 - TR/2`、矩形 `{R, cy, sz.width - 2*R, TR}`。vertical: `cx = sz.width/2 - TR/2`、矩形 `{cx, R, TR, sz.height - 2*R}`。
   - 地を `track_groove` で `fillRect`、続けて `drawInsetBevel`（凹み・dark 上左／light 下右）でチャネル縁に 1px 沈みベベル。
2. **鋼の thumb**（角型・縦グラデ＋凸ベベル）: 主軸位置 `pos = sliderPos()`（§3.3 で valueToPos を再実装）。
   thumb 矩形は主軸方向の半幅 `R`、交差軸方向は `cross = R*2`（交差中央寄せ）:
   - horizontal: `{pos - R, sz.height/2 - R, R*2, R*2}`。vertical: `{sz.width/2 - R, pos - R, R*2, R*2}`。
   - 描画は Button 標準モードと同手順（§ laf_metal_button.md §3.1）: 外枠 `drawRectBorder`（`border`／disabled は `border_disabled`）→
     interior 縦グラデ `fillGradientRect`（inset 2・`bodyGradient(p, enabled, false, false)`）→ 凸ベベル `drawBevel`（inset 1・enabled のみ）。
3. **focus ring**（`focused` のとき）: `focus_ring` で `drawRect({1,1,sz.w-2,sz.h-2})`（FlatLaf と同じ・`Slider.zig:231-234`）。

`paintOver` は no-op（leaf）。

### 3.2 状態別

- enabled（通常）: 沈み溝＋上明下暗の鋼 thumb（凸ベベル）。
- disabled: `track_groove` のまま（ベベル省略可）＋ thumb は `body_disabled_*`＋`border_disabled`・ベベル省略。
- focused: 上記＋focus ring。
- rollover/pressed: Slider は thumb hover/pressed 状態を持たない（FlatLaf も使っていない）。Metal でも演出しない（§8 で任意）。

### 3.3 thumb 位置の再実装（valueToPos の写し・確定）

`Slider.valueToPos`（private・`Slider.zig:136-145`）と **同式**を `metal.zig` 内 helper `sliderPos` として書く:

```
range = max - min;  if range <= 0 -> pos = R
t = (value - min) / range
pos = R + t * (mainLen - 2*R)   // horizontal: mainLen=sz.width / vertical: sz.height
```

`R` は **必ず Slider の `THUMB_RADIUS`（8）と同じ値**にする（§1.1 の正しさ制約）。これで描画位置と drag の値算定が一致する。

### 3.4 measure（`metal_slider_look.measureMinSize`）と Metal 定数

FlatLaf と **同式**（`Slider.zig:109-117`）。Metal 定数（`metal.zig` 内 private const）:

| 定数 | Metal 値 | Slider（FlatLaf）値 | 備考 |
|---|---|---|---|
| `SLIDER_THUMB_RADIUS` | `8` | `8`（`THUMB_RADIUS`） | **据え置き必須**（§3.3 の位置一致制約）。layout も不変 |
| `SLIDER_TRACK_THICKNESS` | `6` | `4`（`TRACK_THICKNESS`） | 溝をやや太く（沈み感）。measure には効かないので layout 不変 |

min: `long = R*4 = 32`、`cross = R*2+4 = 20`。horizontal `{32,20}`／vertical `{20,32}`＝**FlatLaf と同値**（layout 不変）。
Slider は true leaf なので enabler が `min_size` へ焼く。

---

## 4. ScrollBar Metal レシピ（確定提案）

`metal.zig` に `metal_scrollbar_look` を追加。FlatLaf の `ScrollBar.lookPaint`（`ScrollBar.zig:233`）の
**orientation 分岐・hover 判定・畳み early return をそのまま踏襲**し、トラックと thumb の描き方だけ Metal 化（Theme は読まない）。

`*ScrollBar` へ戻り `model`・`orientation`・`dragging`・`rollover` を読み、thumb 幾何は ScrollBar の private helper と
**同式を再実装**（`thumbLen`/`thumbStart` は private method ＝metal.zig から呼べない。§4.4）。

### 4.1 paint（`metal_scrollbar_look.paint`）

`sz = self.size`、`p = palette`、`inset = 2`（FlatLaf と同じ・`ScrollBar.zig:245`）:

1. **畳み early return**: `sz.width <= 0 or sz.height <= 0` なら何も描かない（FlatLaf 同様・`ScrollBar.zig:237`）。
2. **沈んだトラック**: `fillRect({0,0,sz.w,sz.h})` を `scroll_track`。外周 1px 枠を `drawRectBorder`（`border_disabled`＝控えめな鋼枠）。
   （任意で `drawInsetBevel` の沈みベベルを足してもよいが、スクショのトラックは概ねフラット＋細枠なので枠のみで十分。§8）
3. **鋼グラデ thumb**（角型・縦グラデ＋凸ベベル）: `len = sbThumbLen()`、`start = sbThumbStart()`（§4.4）。
   thumb 矩形（inset 2）:
   - horizontal: `{start, inset, len, sz.height - inset*2}`。vertical: `{inset, start, sz.width - inset*2, len}`。
   - 描画は Button 標準モードと同手順: 外枠 `drawRectBorder`（`border`）→ interior 縦グラデ `fillGradientRect`（inset 1・§4.2 で hover 反映）→
     凸ベベル `drawBevel`（enabled のみ）。**角丸はやめる**（FlatLaf は `fillRoundRect` だが Metal は角型）。

`paintOver` は no-op（leaf）。**矢印ボタンは描かない**（§4.3）。

### 4.2 状態別

- 通常: `scroll_track` トラック＋上明下暗の鋼 thumb（`bodyGradient(p, true, false, false)`）。
- hover/drag（`dragging or rollover`）: thumb グラデを `bodyGradient(p, true, true, false)`（rollover グラデ＝一段明るい）に差し替え。
  FlatLaf の `scrollbar_thumb_hover` 相当を Metal の rollover グラデで表現。
- スクロール不能（`max - min <= extent`）/ 畳み: トラックのみ（thumb は track 全長になり実質バー全体＝FlatLaf と同じ挙動）。

### 4.3 矢印ボタン＝**v1 では描かない（確定判断・理由を明記）**

Metal の ScrollBar は伝統的に両端に三角矢印ボタン（▲▼／◀▶）を持つ。スクショ（`_metal13`/`_metal11`）にもある。
だが **v1 の Metal Look では矢印ボタンを足さない**。理由:

- **機能する矢印は Look の範疇を超える**。現 ScrollBar は両端を予約せず（`thumbLen`/`thumbStart` がトラック全長を使う・§1.2）、
  押下イベントの分岐も track-click（page）／thumb-drag のみ（`ScrollBar.zig:273-323`）。機能矢印にするには
  **(a) geometry で両端 `THICKNESS` ぶんを矢印ゾーンに予約し thumb 走行域を縮める**＋**(b) processEvent で矢印ゾーン押下を unit step に割り当てる**
  の 2 つが要る。これは `ScrollBar.zig` 本体の **振る舞い変更**で、「Look は見た目だけ・振る舞い不変」（Button/選択系で確立した原則）に反する。
- **装飾だけの矢印は破綻する**: lookPaint 内で両端に三角を描くだけだと、thumb は依然トラック全長を走る（geometry 未変更）ので
  **thumb が矢印に重なる**。見た目専用の矢印は整合しない。
- 帰結: v1 は **沈みトラック＋鋼グラデ thumb のみ**で「鋼の質感」を出す。これは Slider Metal や Button Metal と一貫し、
  measure（`THICKNESS`/`MIN_THUMB`）も不変・全 ScrollPane/List/Table へ無条件に波及する（§1.3）。
- **機能矢印は将来の別タスク**（Look 差し替えではなく ScrollBar 本体の geometry＋event 拡張）として §8 に残す。
  作者が「矢印必須」と判断したら、Slider/ScrollBar 共通の "両端ボタン付きトラック" として別 spec で起票する。

### 4.4 thumb 幾何の再実装（確定）

`ScrollBar.thumbLen`/`thumbStart`（private・`ScrollBar.zig:183-201`）と **同式**を `metal.zig` 内 helper として書く
（`track = horizontal? sz.width : sz.height`）:

```
thumbLen:  if track <= MIN_THUMB -> track; range = max-min; if range<=0 -> track;
           len = extent/range*track; clamp(len, MIN_THUMB, track)
thumbStart: travel = track - thumbLen; if travel<=0 -> 0;
            span = (max-min) - extent; if span<=0 -> 0; clamp((value-min)/span,0,1) * travel
```

`MIN_THUMB`（＝20）は Metal 定数として `metal.zig` に再定義（ScrollBar の private と同値）。`THICKNESS`（14）は ScrollBar の
**pub 定数を直接参照**してよい（measure で使う・§4.5）。

### 4.5 measure（`metal_scrollbar_look.measureMinSize`）

FlatLaf と **同式・同値**（`ScrollBar.zig:118-124`）。`THICKNESS = 14`（ScrollBar の pub 定数）／`MIN_THUMB = 20`:
horizontal `{MIN_THUMB*2, THICKNESS} = {40,14}`／vertical `{THICKNESS, MIN_THUMB*2} = {14,40}`。**据え置き**（layout 不変）。
ScrollBar は true leaf なので enabler が `min_size` へ焼く。

---

## 5. metalTable() の拡張（確定提案）

現状 `metal_table`（`metal.zig:111-132`）は Button＋選択系 4 種＝5 エントリ。これに **Slider＋ScrollBar の 2 エントリを追加**する。

```zig
const metal_table = [_]laf.RemapEntry{
    .{ .from = &Button.look_vtable,         .to = .{ .vtable = &metal_button_look,    .ctx = &metal_palette } },
    .{ .from = &CheckBox.look_vtable,       .to = .{ .vtable = &metal_checkbox_look,  .ctx = &metal_palette } },
    .{ .from = &RadioButton.look_vtable,    .to = .{ .vtable = &metal_radio_look,     .ctx = &metal_palette } },
    .{ .from = &ComboBox.look_vtable,       .to = .{ .vtable = &metal_combobox_look,  .ctx = &metal_palette } },
    .{ .from = &ComboBox.popup_look_vtable, .to = .{ .vtable = &metal_combobox_popup_look, .ctx = &metal_palette } },
    .{ .from = &Slider.look_vtable,         .to = .{ .vtable = &metal_slider_look,    .ctx = &metal_palette } },   // ← 追加
    .{ .from = &ScrollBar.look_vtable,      .to = .{ .vtable = &metal_scrollbar_look, .ctx = &metal_palette } },   // ← 追加
};
```

- `metal.zig` 冒頭に `const Slider = @import("../Slider.zig");` / `const ScrollBar = @import("../ScrollBar.zig");` を追加。
- ctx は全エントリ共通 `&metal_palette`（単一パレット）。
- **ScrollBar エントリは 1 つだけ**（矢印 child look が無い＝§4.3）。これ 1 件で ScrollPane/List/Table の全バーに波及（§1.3）。
- `buttonTable()`（`metal_table[0..1]`）はそのまま維持。

---

## 6. showcase（確定提案・Codex 実装）

`examples/widget_showcase/main.zig` は既に `const Laf = enum{flatlaf, metal}` ＋ switch（[laf_metal_selection.md](laf_metal_selection.md) §6）で
`metalTable()` を当てる構成。本フェーズは **表の拡張だけで Slider/ScrollBar も自動的に Metal 化される**（showcase 側のコード変更は不要）。

- **既定は `.flatlaf`**（showcase の既定は変えない＝`develop` の正しい状態）。目視時に作者が一時的に `.metal` へ切り替える。
- 目視対象: Slider タブ（h/v・disabled）／Lists タブ・Table タブ（ScrollPane 経由の縦横バー）。§7c。

---

## 7. テスト / デモ計画（確定提案）

### 7a. Metal ゴールデン（snapshot・意図的に新ピクセル）

各 widget の Metal scene を `framework/tests/scenes.zig` に追加（`nimbus.laf.applyLook(root, metalTable())` を paint 前に当てる）。
ゼロピクセル不変は適用されない（FlatLaf と別物の絵＝新規 fixture を意図的に作る）。tolerance はグローバル `TOLERANCE = 1`
（`framework/tests/snapshot_test.zig`。整数構図＋縦グラデは決定的。Button spec §5a と同じ）。

- **Slider**: horizontal（normal / disabled / focused）／vertical（normal）。値を中間に置き thumb 位置を固定。
- **ScrollBar**: horizontal / vertical（normal・hover）。`model` に extent を与えて thumb 長を固定。
- **ScrollPane 経由（波及の絵）**: List か Table を view にした ScrollPane を組み、`applyLook(root, metalTable())` 後に paint。
  縦横バーが Metal（沈みトラック＋鋼 thumb）になることを 1 枚で押さえる（§1.3 の配線をゴールデンでも担保）。

### 7b. メトリクス＋表遷移の純ロジックテスト（GPU 非依存）

[laf_enabler.md](laf_enabler.md) §5.0 の教訓どおり **`Device.init` ゲート下に置かない**（`awt.Font.init(noto_ttf, 0)` を直接使う／
Slider・ScrollBar はフォント不要で `create` できる）。

- **measure**: `metal_slider_look.measureMinSize` / `metal_scrollbar_look.measureMinSize` の戻りが Metal 定数（§3.4/§4.5）から
  計算した既知値（Slider `{32,20}`/`{20,32}`・ScrollBar `{40,14}`/`{14,40}`）に一致することを assert。
- **表遷移**: 小さなツリーへ `applyLook(root, metalTable())` し、`slider.component.ui.vtable == &metal_slider_look`／
  `scrollbar.component.ui.vtable == &metal_scrollbar_look` を assert。
- **波及の回帰ガード（§1.3 の肝）**: `ScrollPane` を含むツリーへ `applyLook` 後、
  **`sp.vbar.component.ui.vtable == &nimbus.laf.metal.metal_scrollbar_look`** と `sp.hbar.~` を assert
  （automation walk が `container.children` 経由でバーまで remap が届いたことを突く）。これが「1 エントリで全バー Metal」の証拠。
- **thumb 位置の一致（任意・推奨）**: Slider に値を入れ、metal.zig の `sliderPos` 再実装が `Slider.valueToPos` と
  同値（同じ `R=8`）を返すことを境界値（min/中間/max）で assert（§3.3 の正しさ制約の回帰ガード）。
- `error.SkipZigTest` 経路を踏まないこと。

### 7c. showcase 目視

`widget_showcase` を一時的に `const LAF: Laf = .metal;` にして `run`。Slider タブ（h/v・disabled）と
Lists/Table タブ（ScrollPane の縦横バー）が Metal（沈みトラック＋鋼 thumb）になることを目視。確認後 `.flatlaf` に戻す。

---

## 8. 未決（解決しない・列挙のみ）

1. **追加パレットの最終 RGBA**: §2 の `track_groove` / `scroll_track` は提案値。showcase 目視で作者が微調整しうる。
2. **ScrollBar の機能矢印ボタン**: v1 は描かない（§4.3）。Metal らしさを上げるなら ScrollBar 本体の geometry（両端予約）＋
   processEvent（矢印押下で unit step）拡張が要る別タスク。Look 差し替えではないので本 spec 外。Slider にも端ボタンは無いので
   両者そろえるなら共通設計で。
3. **Slider thumb の形**: 本 spec は角型矩形（縦グラデ＋ベベル）。Swing Metal の "pointer/house" 形（片側が尖る）に寄せるかは未決
   （awt に多角形塗りが無く、矩形＋三角合成が要る）。
4. **沈みトラックのベベル強度**: Slider 溝は `drawInsetBevel` で凹みを付けるが、ScrollBar トラックは枠のみで近似（§4.1）。
   ScrollBar にも沈みベベルを足すかは目視判断。
5. **Slider の溝太さ `SLIDER_TRACK_THICKNESS=6`**: measure 不変なので layout に影響しないが、見た目の好みは未決。
6. **hover/pressed 演出**: Slider に thumb hover/pressed 表現を足すか（§3.2）。ScrollBar は rollover グラデを使う（§4.2）が
   Slider は現状演出しない。
7. **命名**: `metal_slider_look` / `metal_scrollbar_look` / `track_groove` / `scroll_track` / 各 Metal 定数は仮
   （`laf_design.md` §6-1 の命名未決の延長）。

---

## 9. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | スコープ＝Slider / ScrollBar の 2 種。既存 `metal.zig` のレシピ・helper を再利用・Theme 非依存（§0） |
| 確定 | Slider/ScrollBar はともに true leaf・`look_vtable` は pub。Theme 色を読む現状を自前パレットへ差し替える（§1.1/§1.2） |
| 確定 | ScrollBar は ScrollPane の通常 child（`container.children`）。walk が automation 経由で到達＝**1 エントリで全 ScrollPane/List/Table バーが Metal**（detached facet 不要）（§1.3） |
| 確定 | MetalPalette に `track_groove`／`scroll_track` の 2 トークン追加。thumb 鋼グラデは既存 `body_*`+`bevel_*`+`border` 再利用（§2） |
| 確定 | Slider: 沈み溝トラック（`drawInsetBevel`）＋角型鋼 thumb（縦グラデ＋凸ベベル）＋focus ring。orientation 両対応（§3） |
| 確定 | Slider thumb 位置は `valueToPos` を `R=8`（THUMB_RADIUS と一致必須）で再実装。measure は FlatLaf 同値・layout 不変（§3.3/§3.4） |
| 確定 | ScrollBar: 沈みトラック（`scroll_track`+細枠）＋角型鋼グラデ thumb（hover で rollover グラデ）。畳み early return 踏襲（§4.1/§4.2） |
| 確定 | **矢印ボタンは v1 で描かない**（機能矢印は geometry+event 変更＝Look 範疇外／装飾矢印は thumb と重なり破綻）。将来別タスク（§4.3） |
| 確定 | ScrollBar thumb 幾何（thumbLen/thumbStart）を再実装。measure は `THICKNESS=14`/`MIN_THUMB=20` 据え置き（§4.4/§4.5） |
| 確定 | `metalTable()` に Slider＋ScrollBar の 2 エントリ追加（ScrollBar は 1 件で波及）。`metal.zig` に 2 import 追加（§5） |
| 確定 | showcase は表拡張だけで自動 Metal 化（コード変更不要・既定 `.flatlaf` 維持）（§6） |
| 確定 | テスト: (a) Metal golden（Slider/ScrollBar 各状態＋ScrollPane 波及の絵・tol=1）（b）metrics＋表遷移＋**波及回帰ガード**＋thumb 位置一致を GPU 非ゲートで assert（c）showcase 目視（§7） |
| 未決 | 追加 RGBA 微調整／機能矢印ボタン／thumb 形状／トラック沈み強度／溝太さ／hover 演出／命名（§8） |
