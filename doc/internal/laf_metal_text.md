# Metal Look（Group D＝テキスト/ラベル系: Label / TextField / TextArea）設計 spec

LAF Step 3 横展開の **Group D＝テキスト/ラベル系**（Label / TextField / TextArea）を Metal Look へ差し替える **設計 spec**。
Button Metal（[laf_metal_button.md](laf_metal_button.md)）／選択系（[laf_metal_selection.md](laf_metal_selection.md)）／レンジ系
（[laf_metal_range.md](laf_metal_range.md)）／コンテナ系（[laf_metal_container.md](laf_metal_container.md)）で確立したレシピ
（外枠全面塗り→縦グラデ→ベベル・自前パレット・`@fieldParentPtr` で具象型へ戻る）を踏襲・再利用する。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。
**これで全 widget のメタル化が一巡する**（Group A 選択系・B レンジ系・C コンテナ系・D 本 spec）。

関連: [laf_metal_container.md](laf_metal_container.md)（`metalTable()` 拡張方式・既存 import 並び・`drawRectBorder`/`drawInsetBevel`/
`bodyGradient`・well/select トークン・素 Panel が remap に無害だった判断軸＝本 spec の Label 除外と同型）、
[border_model.md](border_model.md)（**枠所有の整理＝本 Group D の前提土台**。コントロール系（TextField）は自前枠を維持 §0/§1.5・
スクロール内容系（TextArea）は枠なし確定 §1.1/§2・content が `PADDING` 基準で枠幅に依存せず 1px も動かない §1.1/§2.2・
focus 反応枠は枠所有側 §5）、[laf_enabler.md](laf_enabler.md)（`applyLook`／`RemapEntry`／automation walk が
`container.children` を辿る §3.3.3・GPU 非ゲート §5.0・true leaf は enabler が `min_size` を焼く）。

---

## 0. 大前提とスコープ（確定・再議論しない）

作者方針（合意済み）:

- **Metal は縦グラデ＋ベベルまで**。**bumps（点描テクスチャ/ディザ）は描かない**。
- パレットは **Theme 非依存の自前ベイク**（既存 `framework/src/laf/metal.zig` の `MetalPalette`（`metal.zig:45-71`）拡張）。配置は framework 内蔵 Zig。
- スコープは **見た目のみ・振る舞い不変**（layout / イベント / 寸法 / hit-test / IME 動作は変えない）。
- **前景（テキスト色）は利用者尊重**（Metal 定数で上書きしない）。`tf.color`／`ta.color`／`label.color`、`caret_color` も触らない。

本 spec での「chrome / content」の切り分け（確定・本 Group D の設計軸）:

- **chrome（Metal 化する）**: 沈み井戸の地（well）・鋼の外周枠・focus 反応枠。コントロールの「面」。
- **content（触らない・前景尊重）**: テキスト・カーソル・選択ハイライト・IME preedit。利用者の文字内容とその装飾。
  選択ハイライトが `theme.accent` 由来（後述）なのは **content の色**だからで、`tf.color` と同じく利用者/Theme に委ねる範疇。

参照スクショ（`tmp/`）から読み取った Metal Ocean のテキスト系の特徴:

- **TextField / TextArea**: 内容を **沈んだ白い井戸**（lowered well・地は明るい白）に見せ、その外周を **鋼の枠**（コントロール系は自前枠・§1.5 border-model）で囲む。
- **Label**: 面を持たない素のテキスト（背景も枠も無い）。Metal Ocean でも JLabel は地も枠も描かない。

スコープ外（確定）: 各 widget の **layout / hit-test / イベント / 寸法 / IME / キャレット移動は一切変えない**。Metal は `look_vtable` の
`paint` 差し替えのみ（framework 側の公開化・署名変更は **不要**＝§1.0／Table ヘッダのような公開化は本 Group には無い）。

---

## 1. 既存構造の調査結果（重要・確定事実・行番号引用）

### 1.0 共通: 各 widget の look_vtable と公開状況

| widget | look_vtable | 現 lookPaint | 現 lookPaintOver | 公開 | Metal 対象 |
|---|---|---|---|---|---|
| TextField | `TextField.zig:91-95` | 背景＋自前 4 本枠＋content（`:281-377`） | no-op（`:379`） | **pub** | **対象**（well＋鋼枠＋focus） |
| TextArea | `TextArea.zig:88-92` | 背景＋content（`:552-640`・**枠なし**） | no-op（`:642`） | **pub** | **対象**（well のみ・枠なし） |
| Label | `Label.zig:27-31` | テキスト/アイコンのみ（`:172-199`・**地も枠も無し**） | no-op（`:201`） | **pub** | **対象外**（§5） |

→ 3 種とも `look_vtable` は **既に pub**＝`metalTable()` にエントリを足すだけで remap が効く（公開化は不要）。Table ヘッダのような
framework 改変は本 Group には無い（[laf_metal_container.md](laf_metal_container.md) §5.2.2 のような壁は無い）。

### 1.1 TextField（`framework/src/TextField.zig`）＝コントロール系＝自前枠を維持

border-model（[border_model.md](border_model.md) §0/§1.5）で **コントロール系（TextField）は自前で枠を描く**ことが確定（ScrollPane の単一 view にならないので枠が中身としてスクロールして消える問題が起きない）。

- `lookPaint`（`:281-377`）の構造:
  1. **背景**: `tf.background`（`:286-287`）で全面 `fillRect`。`background` は field（既定 **白** `Color.rgb(1,1,1)`・`:119`、`setBackground` で可変・`:171`）。
  2. **自前 4 本枠（1px）**: 色は `:292` で **`if (tf.has_focus) self.theme.accent else self.theme.border`**＝**focus で枠色が変わる**。
     上下左右 4 本 `fillRect`（`:293-296`）。`BORDER_WIDTH = 1`（`:27`）。
  3. **content（PADDING 基準・クリップ越し）**: `inner_w = sz.width - PADDING_X*2`（`:308`）で `cg = g.clip({PADDING_X,0,inner_w,height})`（`:310`）。
     選択ハイライト（`:314-326`・色 `selectionColor`＝**theme.accent 40% alpha**・`:35-37`/`:319`）／テキスト（`:329-331`・`tf.color`）／
     IME preedit（`:337-362`・下線色 `theme.ime_preedit_underline`/`_target`・`:346`/`:354`）／キャレット（`:367-376`・`tf.caret_color`）。
  4. `lookPaintOver` no-op（`:379`）。
- **focus は自分自身が focus owner**: TextField は `tf.has_focus`（field・`:53`）を FocusEvent で更新（`:388`）し、`:292` で直接読む。
  ScrollPane/Border のような `focusOwner()`/`isSelfOrDescendant` 機構は **使わない**（当事者がフォーカスを持つ・FlatLaf TextField と同型）。
- **content は枠幅 `BORDER_WIDTH` に依存しない**: クリップ原点・テキスト・選択・キャレット・IME はすべて `PADDING_X = 6`／`PADDING_Y = 4`（`:22-23`）基準
  （`:308-376`）。枠 4 本（`:293-296`）と色設定（`:292`）は描画専用で座標計算に寄与しない。`PADDING_X = 6 > BORDER_WIDTH = 1` なので
  Metal の沈みベベル枠（外周 1px＋内周 1px＝2px）を `x=0,1` に描いても **content（x≥6 から）には重ならない**。
  → **枠を鋼に差し替えるだけで content は 1px も動かない**（border-model §2.2 と同じ要領）。§3.3 で担保。
- **measure は vtable 経由**: `applyMetrics`（`:207-215`）が `ui.vtable.measureMinSize`（`:209`）を呼んで `min_size`（`:210`）/`max_size`（`:211`）を設定し、
  `setText`（`:153`）でも再実行される。→ **Metal の `measureMinSize` は FlatLaf 同式を再実装**しないと setText で寸法が化ける（§3.4・Slider と同型の「私有定数の写し」）。
  `lookMeasureMinSize`（`:217-230`）: 'M' を `DEFAULT_COLUMNS = 20`（`:25`）本＋`PADDING_X*2`、高さ `line_h + PADDING_Y*2`。**true leaf**（container なし）。

### 1.2 TextArea（`framework/src/TextArea.zig`）＝枠なし確定（枠は ScrollPane/Border 所有）

border-model（[border_model.md](border_model.md) §1.1/§2）で **TextArea は自前枠を描かない**ことが確定・実装済み。実コードを Read して検証:

- `lookPaint`（`:552-640`）の構造（**外周枠の `fillRect`/`drawRect` は無い**＝border-model §2 の枠除去が反映済み）:
  1. **背景**: `ta.background`（`:556-557`）で全面 `fillRect`。`background` は field（既定 **白**・`:129`、`setBackground` 可変・`:204`）。
  2. **content**: 可視行クリップ計算（`:569-584`）／選択ハイライト（`:592-600`・`selectionColor`＝theme.accent 40%・`:36-38`/`:598`）／
     行テキスト（`:604-609`・`ta.color`）／IME preedit（`:613-632`・`theme.ime_preedit_*`・`:621`/`:629`）／キャレット（`:635-639`・`ta.caret_color`）。
  3. `lookPaintOver` no-op（`:642`）。
- content は `PADDING_X = 6`／`PADDING_Y = 4`（`:23-24`）基準（行 `:589,604-608`・`caretGeom` `:442-450`）。枠が無いので枠依存もそもそも無い。
- **focus 反応枠は TextArea 自身は持たない**: フォーカス表示は枠所有側（ScrollPane/Border・Group C で Metal 済み・border-model §5/§2.3）。
  TextArea は `has_focus`（field・`:62`）をキャレット点滅・IME に使うのみで、枠色には使わない（枠が無いので）。
- **measure は vtable を経由しない（重要・load-bearing）**: TextArea の動的 re-measure は **look vtable を通らない**:
  - `refreshMinSize`（`:335-339`）→ `measureMinSizeFromLook`（`:341-344`）が **`lookMeasureMinSize(&self.component, ...)` を直接呼ぶ**（`:342`・`ui.vtable` 経由でない）。
  - `size_query`（`:94-96`）の `sizeQueryMinHeightForWidth`（`:240-245`）も TextArea 自身の `reflowAt` を直接呼ぶ。
  - → Metal が `look_vtable.measureMinSize` を差し替えても、TextArea の reflow / height-for-width は **従来どおり自前関数で動く**（layout 不変）。
    enabler の bake（true leaf・applyLook 時 1 回）だけが差し替え後の `measureMinSize` を呼ぶ。`create`（`:145`）の `refreshMinSize` が
    既に正しい `min_size` を焼いているので、Metal 側は **`self.min_size` をそのまま返せば idempotent**（§4.3・List/Table と同じ `measureOwnMinSize`）。

### 1.3 Label（`framework/src/Label.zig`）＝面を持たない素テキスト＝Metal で変える要素が無い

- **`background` field が無い**（struct fields・`:12-18`＝component/text/font/color/icon/icon_size/allocator）。
- `lookPaint`（`:172-199`）: アイコン無しなら `drawString`（テキストのみ・色 `label.color`・`:178-179`）、アイコン有りでも image＋テキストのみ（`:184-198`）。
  **背景塗りも外周枠も一切描かない**。`color` は前景（`:15`、`setColor` 可変・`:97`）。`lookPaintOver` no-op（`:201`）。
- → Label が描くのは **前景（テキスト/アイコン）だけ**で、Metal が触る chrome（well/枠/focus）が **存在しない**。
  Metal look に remap しても **ピクセルは 1 ドットも変わらない**（pass-through）。よって **Label は Metal 対象外**（§5・確定）。
  これは [laf_metal_container.md](laf_metal_container.md) で「素 Panel（background/border 未設定）は Metal でも何も描かない＝無害」とした判断軸の
  さらに強い版（Panel は set 時のみ描くが、Label はそもそも面を持たない）。

### 1.4 既存パレット・helper（再利用前提・確定事実）

`metal.zig` に既存（Group A〜C 実装済み）:

- `MetalPalette`（`:45-71`）/ `metal_palette`（`:73-99`）。本 Group で使うトークン:
  `well_bg`（#fff・`:90`）・`well_disabled`（`:91`）・`border`（#7A8A99・`:82`）・`focus_ring`（#6382BF・`:87`）・
  `bevel_light`（#fff・`:83`）・`bevel_dark`（#8494A8・`:84`）。
- helper: `drawRectBorder`（`:1115-1121`・4 本枠）／`drawInsetBevel`（`:1111-1113`＝dark 上左／light 下右＝沈み）／
  `drawBevelAt`（`:1101-1109`）。沈み井戸の地＋鋼枠は CheckBox の井戸（`:312-315`＝`well_bg`＋`drawInsetBevel`＋`drawRectBorder`）と同手順。
- 表: `metal_table`（`:185-242`・現 14 エントリ）／`metalTable()`（`:244-246`）／`buttonTable()`（`:248-250`）。

---

## 2. MetalPalette の拡張（確定提案・最小＝新トークン 0）

Group D は **新規トークンを足さない**（作者方針「本当に必要な新トークンだけ」に従い、結論はゼロ）。各 widget は既存トークンの再利用で表現できる:

| 用途 | 使う既存トークン |
|---|---|
| 沈み井戸の地（TextField / TextArea の field 面） | `well_bg`（#fff・`:90`）。CheckBox/ComboBox/List/Table の well と同じ白で統一 |
| 沈みベベル枠（TextField の鋼枠の内周＝沈み感） | `drawInsetBevel`（dark 上左／light 下右・`:1111`） |
| 鋼の外周枠（TextField・非 focus） | `border`（#7A8A99・`:82`）＋`drawRectBorder`（`:1115`） |
| focus 反応（TextField・focus 時の外周線色） | `focus_ring`（#6382BF・`:87`） |
| テキスト / キャレット / 選択 / IME（content・前景尊重） | **触らない**（`tf.color`/`ta.color`/`caret_color`/`theme.*` のまま・§0） |

→ **追加トークン 0**。TextField の沈み井戸の地は **既存 `well_bg`（#fff）で足りる**（CheckBox/ComboBox/List/Table の白井戸と揃え、別トークンは要らない）。
TextField の現 `background` 既定も白（`:119`）なので、既定状態では地色は不変。微調整したくなったら §8 の showcase 目視で詰める（§10）。

---

## 3. TextField Metal レシピ（確定提案・コントロール系＝自前枠を鋼へ）

`metal.zig` に `metal_textfield_look` を追加。`@fieldParentPtr("component", self)` で `*TextField` へ戻り
`background`・`has_focus`・content 描画に要る field（`text`/`caret_byte`/`font`/`color`/…）を読む。
**FlatLaf の `lookPaint`（`:281-377`）の構造（背景→枠→クリップ→content）をそのまま踏襲**し、**背景と枠だけ Metal 化**、content は不変。

### 3.1 paint（`metal_textfield_look.paint`）

`sz = self.size`、`p = palette`:

1. **沈み井戸の地（well）**: `{0,0,sz.width,sz.height}` を `well_bg` で `fillRect`（FlatLaf の `tf.background`・`:286-287` に対応・§3.5 で override 方針）。
2. **鋼の沈みベベル枠＋focus 反応（2px・overpaint）**: FlatLaf の 4 本枠（`:292-296`）を Metal 枠へ差し替え:
   - 外周 1px: `drawRectBorder(g, 0, 0, sz.width, sz.height, if (tf.has_focus) p.focus_ring else p.border)`
     ＝**focus で外周線が accent 相当（`focus_ring`）になる**。FlatLaf の `:292`（has_focus→accent / 非→border）を Metal トークンへ写したもの。
   - 内周 1px: `drawInsetBevel(g, 0, 0, sz.width, sz.height, p)`（上左 `bevel_dark`＝影／下右 `bevel_light`＝光）＝**沈み**。
   - → 内容が井戸に沈んで見え、focus は外周線の色（`border`↔`focus_ring`）で表現（ScrollPane Metal 枠・[laf_metal_container.md](laf_metal_container.md) §7.1 と同じ出し分けだが、**owner は当事者**＝§3.2）。
3. **content（FlatLaf と同一・触らない）**: `tf.ensureCaretVisible()`（`:301`）→ クリップ `cg = g.clip({PADDING_X,0,inner_w,height})`（`:308-310`）→
   選択ハイライト（`selectionColor`・`:314-326`）／テキスト（`tf.color`・`:329-331`）／IME（`:337-362`）／キャレット（`tf.caret_color`・`:367-376`）を
   **FlatLaf の算法・色のまま**描く（前景・content 尊重＝§0）。`metal.zig` から呼べない private fn（`glyphXAtByte`/`selectionStartByte`/`ensureCaretVisible` 等）は
   **同式を再実装**するか、可能なら content 描画ヘルパを framework 側で再利用できる形にする（§9 の実装メモ・命名は §10）。

`paintOver` は no-op（FlatLaf 同・`:379`）。

### 3.2 focus は `has_focus` を直接読む（確定・ScrollPane/Border 機構は使わない）

- TextField は **自分自身が focus owner**（フォーカスを持つのはコントロール当事者）。FlatLaf も `tf.has_focus`（`:53`・FocusEvent で更新・`:388`）を `:292` で直接読む。
- よって Metal も **`tf.has_focus` を直接読む**（FlatLaf と同型）。ScrollPane/Border のような `self.focusOwner()`＋`isSelfOrDescendant`
  （祖先が子孫フォーカスを見る機構・[laf_metal_container.md](laf_metal_container.md) §7.1）は **TextField には不要**＝使わない。
- ゴールデンの focus 版は **`tf.has_focus = true` を直接立てる**だけでよい（FocusController スタブ不要・§8a）。`has_focus` は struct field で
  scenes から代入できる（既存 `text_area_*_focused` が `area.has_focus = true` を立てている・`scenes.zig:797` と同型）。

### 3.3 content が 1px も動かないことの担保（確定）

§1.1 の通り content の座標は **すべて `PADDING_X`/`PADDING_Y` 基準**で `BORDER_WIDTH` を参照しない。Metal は **背景色と枠を差し替えるだけ**で
クリップ原点・テキスト・選択・キャレット・IME の式に一切触れない。Metal 枠は 2px（外周＋沈みベベル）だが `x=0,1` に収まり、
content は `x ≥ PADDING_X = 6` から描かれるので **重ならない**。→ content は **1px も動かない**（border-model §2.2 と同じ要領）。§8b で回帰ガード。

### 3.4 measure（`metal_textfield_look.measureMinSize`）＝FlatLaf 同式を再実装（必須）

§1.1 の通り TextField の measure は **vtable を経由**する（`applyMetrics`・`setText` が `ui.vtable.measureMinSize` を呼ぶ）。よって Metal は
`self.min_size` を返す手（List/Table の `measureOwnMinSize`）では **不可**で、FlatLaf の `lookMeasureMinSize`（`:217-230`）と **同式を再実装**する。
TextField の private 定数を Metal 定数として再定義（Slider の `THUMB_RADIUS` 写しと同型・[laf_metal_range.md](laf_metal_range.md) §3.4）:

| 定数 | Metal 値 | TextField（private） | 備考 |
|---|---|---|---|
| `TF_PADDING_X` | `6` | `PADDING_X = 6`（`:22`） | **据え置き必須**（content クリップ・measure と一致） |
| `TF_PADDING_Y` | `4` | `PADDING_Y = 4`（`:23`） | **据え置き必須** |
| `TF_DEFAULT_COLUMNS` | `20` | `DEFAULT_COLUMNS = 20`（`:25`） | **据え置き必須**（min width＝'M'×20＋PADDING_X×2） |

式（`:221-229` と同）: `setPixelSize` → `w = font.glyphAdvance('M') * TF_DEFAULT_COLUMNS + TF_PADDING_X*2`、`h = line_h + TF_PADDING_Y*2`。
TextField は true leaf なので enabler が `min_size` を焼く。**FlatLaf と同値＝layout 不変**。

### 3.5 背景 well の override 方針（確定・要承認）

FlatLaf は `tf.background`（field・既定白）を塗る。Metal は **`well_bg`（#fff）で塗る**（地は chrome＝Metal が所有・§0）。
既定では `tf.background` も白なので **既定状態は不変**。利用者が `setBackground` で**非既定の地色**を設定していた場合のみ Metal が `well_bg` で上書きする
（List/Table Metal が widget 背景を無視して `well_bg` を使うのと同じ・[laf_metal_container.md](laf_metal_container.md) §5.1）。
非既定背景を尊重するか否かは **未決**（§10-2）。v1 は `well_bg` で統一。

### 3.6 状態別

TextField に disabled 状態は無い（`enabled` field 無し）。rollover も枠に使わない。状態は **focus の有無のみ**:
通常＝白井戸＋鋼沈みベベル枠（外周 `border`）。focus＝外周 `focus_ring`。content は状態に依らず FlatLaf と同一。

---

## 4. TextArea Metal レシピ（確定提案・枠なし＝well のみ）

`metal.zig` に `metal_textarea_look` を追加。`*TextArea` へ戻り `background`・content 描画 field を読む。
**FlatLaf の `lookPaint`（`:552-640`）の構造をそのまま踏襲**し、**背景（well）だけ Metal 化**、content（行/選択/IME/キャレット）は不変。
**枠は描かない**（border-model §1.1/§2＝枠は enclosing ScrollPane/Border 所有・Group C で Metal 済み）。focus 反応枠も TextArea は持たない（§1.2）。

### 4.1 paint（`metal_textarea_look.paint`）

`sz = self.size`、`p = palette`:

1. **沈み井戸の地（well）**: `{0,0,sz.width,sz.height}` を `well_bg` で `fillRect`（FlatLaf の `ta.background`・`:556-557` に対応・§4.4 で override 方針）。
   井戸の沈み感（外周枠）は **enclosing ScrollPane/Border の Metal 沈みベベル枠**に委ねる（List/Table と同じ・[laf_metal_container.md](laf_metal_container.md) §5.1）。
2. **枠は描かない**（border-model §1.1/§2 で確定。素置き TextArea には枠が付かない＝[laf_metal_container.md](laf_metal_container.md) §11-6 と同じ「素置きに沈みベベルを足すか」は未決・§10-3）。
3. **content（FlatLaf と同一・触らない）**: 可視行クリップ（`:569-584`）／選択ハイライト（`selectionColor`・`:592-600`）／
   行テキスト（`ta.color`・`:604-609`）／IME（`:613-632`）／キャレット（`ta.caret_color`・`:635-639`）を FlatLaf の算法・色のまま。
   private fn（`measureRange`/`caretGeom`/`rangeSlice` 等）は `metal.zig` から呼べないので **同式を再実装**するか framework 側で再利用できる形に（§9・命名 §10）。

`paintOver` は no-op（FlatLaf 同・`:642`）。

### 4.2 状態別

TextArea に disabled は無い。focus は枠を持たないので演出しない（キャレット点滅・IME は content として従来どおり）。well は常に `well_bg`。

### 4.3 measure（`metal_textarea_look.measureMinSize`）＝`self.min_size`（List/Table と同）

§1.2 の通り TextArea の動的 re-measure（reflow / height-for-width）は **look vtable を経由しない**（自前関数 `lookMeasureMinSize`・`reflowAt` を直接呼ぶ・`:342`/`:240`）。
よって Metal が `look_vtable.measureMinSize` を差し替えても reflow は不変。差し替え後の `measureMinSize` を呼ぶのは **enabler の bake（applyLook 時 1 回）だけ**で、
その時点で `create`（`:145`）の `refreshMinSize` が正しい `min_size` を焼き済み。→ Metal は **`self.min_size` をそのまま返す**（List/Table と同じ `measureOwnMinSize`・`metal.zig:639-641`）＝idempotent・**layout 不変**。

### 4.4 背景 well の override 方針（確定・TextField §3.5 と同）

Metal は `ta.background` を無視して **`well_bg`（#fff）で塗る**（地は chrome）。既定背景は白（`:129`）なので既定状態は不変。
**ただしテスト/showcase 注意**: `scenes.zig` の `textArea` helper は `ta.background = surface_input` を設定する（`scenes.zig:122`）。
Metal 下では `well_bg`（#fff）で塗られるので、Metal ゴールデンの well は **`surface_input` でなく `well_bg`** になる（§8a で意図的に固定）。非既定背景尊重は未決（§10-2）。

---

## 5. Label＝Metal 対象外（確定・理由を明記）

§1.3 の調査結果に基づき、**Label は Metal 対象に含めない**（`metalTable()` に Label エントリを足さない）。理由:

- Label は **背景 field を持たず**（`:12-18`）、`lookPaint`（`:172-199`）は **テキスト/アイコン（前景）しか描かない**（背景塗り・外周枠ともに無い）。
- Metal が触る chrome（well の地・鋼枠・沈みベベル・focus 反応）が **Label には一切存在しない**。前景（`label.color`）は §0 で尊重（Metal 化対象外）。
- よって Label を Metal look に remap しても **ピクセルは 1 ドットも変わらない**（純 pass-through）。**remap する意味が無い**ので加えない。
- これは [laf_metal_container.md](laf_metal_container.md) で素 Panel（background/border 未設定）を「remap しても何も描かない＝無害」とした判断軸の **さらに強い版**
  （Panel は set 時のみ描くので remap 対象に含めて無害、Label はそもそも面を持たないので含める価値が無い）。
- **将来 Label に背景/枠を持たせる**（Swing JLabel に `setOpaque`/`setBorder` 相当を足す）要望が出たら、その時に Metal 対象化を再検討（§10-4）。

→ 本 Group の Metal 対象は **TextField / TextArea の 2 種**（Label を除く）。

---

## 6. metalTable() の拡張（確定提案）

現状 `metal_table`（`metal.zig:185-242`）は 14 エントリ（Button＋選択 4＋レンジ 2＋コンテナ 7）。これに **Group D の 2 エントリを追加**:

```zig
// ...既存 14 エントリ...
    .{ .from = &TextField.look_vtable, .to = .{ .vtable = &metal_textfield_look, .ctx = &metal_palette } },
    .{ .from = &TextArea.look_vtable,  .to = .{ .vtable = &metal_textarea_look,  .ctx = &metal_palette } },
```

- `metal.zig` 冒頭に import 追加: `TextField`/`TextArea`（`metal.zig:3-15` のアルファベット順に挿入＝`Table` の後・`TabbedPane` の前後）。
- ctx は全エントリ共通 `&metal_palette`。`buttonTable()`（`metal_table[0..1]`・`:248-250`）は不変。
- **Label は追加しない**（§5）。よって新規エントリは **2 件**（TextField＋TextArea）。
- framework 側の公開化・署名変更は **不要**（両 look_vtable は既に pub・§1.0）。Table ヘッダのような壁は無い。

---

## 7. showcase（確定提案・コード変更不要を確認）

`examples/widget_showcase/main.zig` は `const Laf = enum{flatlaf, metal}`（`:9`）＋ `const LAF: Laf = .flatlaf`（`:10`）＋
switch で `metalTable()` を frame 全体へ当てる構成（`:377`＝`applyLook(&frame.window.container.component, metalTable())`）。
本フェーズは **表の拡張だけで Group D も自動 Metal 化**（showcase 側コード変更は不要）。

- showcase の既存 TextField/TextArea: Form タブの入力行（`textField(...)`・`:158-161`）／Text タブのフィールド（`:218`）＋複数行 TextArea（`:223`・`:233`）。
  これらは frame 配下にあるので `applyLook` 全体適用で remap が届く（automation walk が `container.children` を辿る・[laf_enabler.md](laf_enabler.md) §3.3.3）。
- **既定は `.flatlaf`**（変えない）。目視時に作者が一時的に `.metal` へ。
- 目視対象: Form タブ（TextField の沈み井戸＋鋼枠／フォーカスを入れて枠が `focus_ring` に光ること）／Text タブ（TextField／TextArea の well・
  ScrollPane 入り TextArea は ScrollPane 側 Metal 枠＝Group C で済／素 TextArea の well）。Label は変化しないことも確認（対象外の裏取り）。

---

## 8. テスト / デモ計画（確定提案）

### 8a. Metal ゴールデン（snapshot・意図的に新ピクセル）

各 Metal scene を `framework/tests/scenes.zig` に追加（`nimbus.laf.applyLook(root, metalTable())` を paint 前に当てる）。
tolerance はグローバル `TOLERANCE = 1`（`framework/tests/snapshot_test.zig`・整数構図＋縦グラデは決定的）。

- **TextField**: `metal_text_field`＝1 行 TextField（テキスト入り・**非フォーカス**）。well（#fff）＋鋼沈みベベル枠（外周 `border`）＋テキストを固定。
- **TextField（focus）**: `metal_text_field_focused`＝**`tf.has_focus = true` を直接立てた**版（FocusController スタブ不要・§3.2）。
  外周枠が `focus_ring`（accent 相当）になる絵。非フォーカス版との差で focus 反応を固定。
- **TextField（選択）**: `metal_text_field_selection`（推奨）＝`caret_byte`/`mark_byte` を立てて選択ハイライト（content・FlatLaf のまま）＋well＋鋼枠。
  content が枠 Metal 化で動いていないことを目視（§8b の純ロジックと合わせて二重ガード）。
- **TextArea**: `metal_text_area`＝複数行 TextArea（素置き）。well（#fff）＋行テキスト＋キャレット。**枠が無い**ことを固定（border-model 整合）。
  既存 `text_area_plain`（`scenes.zig:756`）の Metal 版に相当（ただし well が `well_bg` になる・§4.4）。
- **TextArea（ScrollPane 入り・任意）**: 既存 `text_area_framed_in_scroll_pane`（`:742`）に `applyLook(metalTable())` を当てた版。
  TextArea の well＋ScrollPane の Metal 沈みベベル枠（Group C 済）が同時に出る絵。Group D 単独では新規性が薄いので任意。

### 8b. メトリクス＋表遷移の純ロジックテスト（GPU 非依存）

[laf_enabler.md](laf_enabler.md) §5.0 の通り **`Device.init` ゲート下に置かない**（`awt.Font.init(...)` を直接使う）。

- **measure 不変**:
  - TextField: `metal_textfield_look.measureMinSize` が FlatLaf 同式（§3.4・'M'×20＋PADDING）で計算した既知値を返すこと。
    **特に `applyLook` 後に `setText` を呼んでも `min_size` が FlatLaf と同値**であること（measure が vtable 経由なので再実装の正しさを突く・§1.1/§3.4）。
  - TextArea: `metal_textarea_look.measureMinSize` が `self.min_size`（reflow 焼き済み）と一致すること（§4.3）。
- **表遷移**: 小ツリーへ `applyLook(root, metalTable())` 後、`tf.asComponent().ui.vtable == &metal_textfield_look`／
  `ta.component.ui.vtable == &metal_textarea_look` を assert。
- **Label が remap されない（§5 の裏取り）**: ツリーに Label を含め `applyLook` 後、`label.component.ui.vtable == &Label.look_vtable`（**元のまま**）であること
  を assert（Label が表に無い＝remap されない証拠。素 Panel が remap されても無害だったのと違い、Label は remap 自体されない）。
- **TextField content 不動（§3.3）**: 同じ TextField を FlatLaf と Metal で paint し（または座標式を assert）、クリップ原点・キャレット x（`glyphXAtByte` 再実装が
  FlatLaf と同値）・選択矩形が **PADDING 基準で一致**することを境界（空/中間/末尾キャレット）で assert。さもないと枠差し替えで content がずれる（Slider thumb 位置一致ガードと同型）。
- **TextArea reflow が vtable 非依存（§1.2/§4.3）**: `applyLook` 後に `setText` / `setLineWrap(true)` を呼んでも reflow（`lines` / `min_size`）が
  FlatLaf と同じ結果になること（measure 差し替えが reflow を壊さない回帰ガード）。
- `error.SkipZigTest` 経路を踏まないこと。

### 8c. showcase 目視

`widget_showcase` を一時的に `.metal` にして `run`。§7 の各タブを目視。Label が変化しないことも確認。確認後 `.flatlaf` に戻す。

---

## 9. 実装の分割可否（pm 向け提案）

3 widget だが **Label は対象外**（§5）なので実装は **TextField／TextArea の 2 widget**。自然な継ぎ目:

- **継ぎ目 A＝TextField（枠あり・focus 反応・measure 再実装）**: 唯一「鋼枠＋focus 反応＋vtable 経由 measure の再実装（§3.4）」を含む。
  focus を `has_focus` 直読みで実装する点・content private fn の再実装・setText 後の measure 一致ガード（§8b）が集中する。**やや重い**ので単独コミットが安全。
- **継ぎ目 B＝TextArea（枠なし・well のみ・measure は self.min_size）**: well 塗り替え＋content 再実装のみ。枠も focus も無く、measure は `measureOwnMinSize` 流用で軽い。
- **Label**: 実装作業 **無し**（表に加えない・§5）。doc に「対象外」を残すだけ。

推奨: **A → B の 2 コミット**（A は TextField の枠/focus/measure を隔離、B は TextArea の well のみで軽い）。
1 委譲でまとめても通る（2 widget・framework 改変ゼロ・公開化不要）。content 描画の private fn 再実装が両者で重複するなら、
**framework 側に content 描画ヘルパを切り出して metal.zig から再利用する**案もある（命名・露出は §10／[laf_metal_selection.md](laf_metal_selection.md) §2.1 の
「private fn を metal.zig へ再実装」と同じ判断＝再実装でも可・共有でも可）。pm が分割粒度を決める材料とされたい。

---

## 10. 未決（解決しない・列挙のみ）

1. **パレット微調整**: §2 は新トークン 0。TextField の沈み井戸を CheckBox 井戸と違えたい（例えば一段くすませる）なら専用 well トークン追加の余地（showcase 目視で判断）。
2. **背景 well の override 承認**: TextField/TextArea とも Metal は `well_bg` で塗り、非既定の `setBackground` を上書きする（§3.5/§4.4）。
   非既定背景を尊重すべき（利用者の地色 opt-in を残す）かは未決。v1 は `well_bg` 統一。
3. **素置き内容系の沈みベベル**: TextArea を ScrollPane/Border 無しで素置きした時、well 地のみで沈み枠は付かない（§4.1）。
   素置きに沈みベベルを足すかは未決（[laf_metal_container.md](laf_metal_container.md) §11-6 の List/Table 素置きと同じ論点）。
4. **Label の将来 Metal 化**: Label に背景/枠（`setOpaque`/`setBorder` 相当）を足したら Metal 対象化を再検討（§5）。現状は対象外で確定。
5. **content 描画の共有 vs 再実装**: TextField/TextArea の content（テキスト/選択/キャレット/IME）描画で使う private fn を metal.zig へ再実装するか、
   framework 側に共有ヘルパを切るか（§9）。命名・露出の細部は実装判断。
6. **IME 下線・選択色の Theme 依存**: content として `theme.ime_preedit_*`／`selectionColor`（theme.accent 由来）を Metal でもそのまま読む（§0 の content 尊重）。
   これを Metal パレット由来に寄せるか（Theme 完全非依存にするか）は未決。v1 は content＝Theme/前景尊重のまま。
7. **命名**: `metal_textfield_look`／`metal_textarea_look`／`TF_PADDING_X` 等の Metal 定数は仮（`laf_design.md` §6-1 の命名未決の延長）。

---

## 11. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | スコープ＝**TextField / TextArea の 2 種**（Label は対象外・§5）。見た目のみ・振る舞い/layout/寸法/hit-test/IME 不変・前景尊重・bumps 無し（§0） |
| 確定 | chrome（well/枠/focus）を Metal 化・content（テキスト/キャレット/選択/IME）は FlatLaf のまま触らない（§0） |
| 確定 | 新トークン **0**。`well_bg`/`border`/`focus_ring`/`bevel_*` と `drawRectBorder`/`drawInsetBevel` を再利用（§2） |
| 確定 | TextField: well（`well_bg`）＋鋼沈みベベル枠＋focus 反応。**focus は `tf.has_focus` を直接読む**（当事者が owner・ScrollPane/Border 機構は使わない）（§3.1/§3.2） |
| 確定 | TextField の content は `PADDING` 基準で `BORDER_WIDTH` 非依存＝枠を鋼へ差し替えても **1px も動かない**（§3.3） |
| 確定 | TextField の measure は **vtable 経由**（applyMetrics/setText）＝Metal は FlatLaf 同式を再実装（`TF_PADDING_X=6`/`TF_PADDING_Y=4`/`TF_DEFAULT_COLUMNS=20`）。layout 不変（§3.4） |
| 確定 | TextArea: well（`well_bg`）＋content のみ。**枠は描かない**（枠は ScrollPane/Border 所有・Group C 済）。focus 反応枠も持たない（§4.1/§4.2） |
| 確定 | TextArea の measure は **vtable 非依存**（reflow/height-for-width が自前関数直呼び）＝Metal は `self.min_size` を返す（`measureOwnMinSize`）。layout 不変（§1.2/§4.3） |
| 確定 | 背景 well は両者とも `well_bg` で塗り、非既定 `setBackground` を上書き（既定白なので既定状態は不変）。尊重可否は未決（§3.5/§4.4/§10-2） |
| 確定 | **Label は Metal 対象外**: 面（背景/枠）を持たず前景しか描かない＝remap しても 1 ドットも変わらないので表に加えない（素 Panel の判断軸の強版）（§5） |
| 確定 | `metalTable()` に **2 エントリ追加**（TextField＋TextArea）。import 2 件。両 look_vtable は既に pub＝framework 公開化・署名変更は不要（§6） |
| 確定 | showcase は表拡張だけで自動 Metal 化（コード変更不要・既定 `.flatlaf`・Form/Text タブで目視）（§7） |
| 確定 | テスト: (a) Metal golden（TextField 沈み井戸＋鋼枠＋focus 版＋選択／TextArea well＋キャレット・tol=1）（b）measure 不変（TextField は setText 後も一致／TextArea は self.min_size）＋表遷移＋**Label が remap されない**＋TextField content 不動＋TextArea reflow 非依存を GPU 非ゲートで assert（c）showcase 目視（§8） |
| 確定 | 実装分割は A＝TextField（枠/focus/measure 再実装を隔離）／B＝TextArea（well のみで軽い）の 2 継ぎ目を推奨。Label は実装作業なし。1 委譲も可（§9） |
| 未決 | パレット微調整／背景 override 承認／素置き沈みベベル／Label 将来 Metal 化／content 共有 vs 再実装／IME・選択の Theme 依存／命名（§10） |
</content>
</invoke>
