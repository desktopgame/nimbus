# Metal Look（Group C＝コンテナ/枠系: Panel / TabbedPane / List / Table / ScrollPane / SplitPane）設計 spec

LAF Step 3 横展開の **Group C＝コンテナ/枠系**（Panel / TabbedPane / List / Table / ScrollPane / SplitPane）を
Metal Look へ差し替える **設計 spec**。Button Metal（[laf_metal_button.md](laf_metal_button.md)）／選択系
（[laf_metal_selection.md](laf_metal_selection.md)）／レンジ系（[laf_metal_range.md](laf_metal_range.md)）で確立した
レシピ（外枠全面塗り→縦グラデ→ベベル・自前パレット・`@fieldParentPtr` で具象型へ戻る）を踏襲・再利用する。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。

関連: [laf_metal_range.md](laf_metal_range.md)（`metalTable()` 拡張方式・`paintSteelThumb`・`bodyGradient`・`drawBevel`/
`drawInsetBevel`/`drawRectBorder`・track 系トークン）、[laf_metal_selection.md](laf_metal_selection.md)（private fn を
metal.zig へ再実装する手・popup 到達のための pub 化）、[border_model.md](border_model.md)（**枠所有の整理＝本 Group C の前提土台**。
ScrollPane が focus 反応枠を `lookPaintOver` に持ち §4.3/§9 で Metal へ橋渡し／List・Table は枠を持たない §1.2/§1.3／
overpaint vs inset §4.2 の引き継ぎ §10）、[laf_enabler.md](laf_enabler.md)（`applyLook`／`RemapEntry`／automation walk が
`container.children` を辿る §3.3.3・GPU 非ゲート §5.0・detached/pub 化が要る popup 系）。

---

## 0. 大前提とスコープ（確定・再議論しない）

作者方針（合意済み）:

- **Metal は縦グラデ＋ベベルまで**。**bumps（点描テクスチャ/ディザ）は描かない**。SplitPane divider も無地ベベルで、
  矢印・バンプ・グリップ点描は無し。
- パレットは **Theme 非依存の自前ベイク**（既存 `framework/src/laf/metal.zig` の `MetalPalette`（`metal.zig:36-62`）拡張）。
  配置は framework 内蔵 Zig。
- スコープは **見た目のみ・振る舞い不変**（layout / イベント / 寸法は変えない）。
- **text / 前景色は利用者指定を尊重**（Metal 定数で上書きしない）。セル・ラベルの文字色は触らない。

参照スクショ（`tmp/`）から読み取った Metal Ocean のコンテナ/枠系の特徴:

- **ScrollPane**: 内容を **沈んだ井戸** に見せる外周の **沈みベベル枠**（lowered bevel・上左暗／下右明）。
- **Panel（枠付き）**: グループを囲む **etched/raised ベベル**（無地）。
- **TabbedPane**: 選択タブが **持ち上がった鋼**（raised・内容面と地続き）、非選択タブは **引っ込んだ鋼**。
- **List / Table**: 沈んだ井戸の地＋青い選択行。Table ヘッダは **鋼グラデ＋内部の溝線（列区切り）**。
- **SplitPane**: divider が **無地の鋼ベベル**（bumps 無し）。

スコープ外（確定）: 各 widget の **layout / hit-test / イベント / 寸法は一切変えない**。Metal は `look_vtable` の
`paint`/`paintOver` 差し替え（＋Table ヘッダのための framework 公開化 1 点・§5.2）のみ。

---

## 1. 既存構造の調査結果（重要・確定事実・行番号引用）

### 1.0 共通: 各 widget の look_vtable と paint 経路

`Component.paintAt`（`Component.zig:669-678`）は **`paint` → 子 `paintAt` → `paintOver`** の順。各 widget は
`g.clip(self.getBounds())`（`Component.zig:670`）でクリップされた Graphics を受ける。クリップは
`Graphics.clip`（`Graphics.zig:164-184`）で、結果幅・高さは `@max(0, ...)`（`Graphics.zig:182-183`）＝**0x0 の component は
スシザが 0x0 になり何も描かれない**（§1.4 TabbedPane 前提の根拠）。

| widget | look_vtable | 現 lookPaint | 現 lookPaintOver | 公開 |
|---|---|---|---|---|
| Panel | `Panel.zig:32-36` | 背景塗り（`:125-136`） | border（`:138-153`） | **pub** |
| TabbedPane | `TabbedPane.zig:49-53` | タブ strip（`:246-280`） | no-op（`:282`） | **pub** |
| List | `List.zig:215` | well＋選択＋セル（`:622-643`） | no-op（`:645`） | **pub** |
| Table | `Table.zig:247` | well＋選択＋セル（`:794-817`） | no-op（`:819`） | **pub** |
| Table ヘッダ | `Table.TableHeader.look_vtable`（`:145-149`） | `paintHeader`（`:166-168`→`:825-849`） | no-op（`:171`） | **private**（§5.2 で要公開化） |
| ScrollPane | `ScrollPane.zig:69-73` | no-op（`:497`） | focus 反応枠（`:499-512`） | **pub** |
| SplitPane | `SplitPane.zig:63-67` | divider strip（`:254-275`） | no-op（`:277`） | **pub** |

→ Table ヘッダ以外は **既に look_vtable が pub**＝`metalTable()` にエントリを足すだけで remap が効く（§5.1）。

### 1.1 ScrollPane（`framework/src/ScrollPane.zig`）＝枠は `lookPaintOver` に既存（border-model 済み）

- border-model（[border_model.md](border_model.md) §4）で **ScrollPane が自前枠を持つ** ことが確定・実装済み。
  `lookPaintOver`（`:499-512`）が **focus 反応の 1px 外周枠**を描く: `self.focusOwner()`（`:505`）で現フォーカス保持者を引き、
  `self.isSelfOrDescendant(o)`（`:506`）で子孫判定。子孫フォーカスなら `theme.accent`、それ以外 `theme.border`（`:507`）で
  上下左右 4 本 `fillRect`（`:508-511`）。`lookPaint`（`:497`）は no-op。
- レイアウト（`layoutDoLayout`・`:366-435`）: viewport `{left, top, center_w, center_h}`（`:416`）、vbar 右端
  `{left+center_w, top, T, center_h}`（`:423-426`）、hbar 下端 `{left, top+center_h, center_w, T}`（`:427-430`）。
  `T = ScrollBar.THICKNESS`（14）。**バーはペイン bounds の右端・下端に接して置かれる**。
- → 外周枠 `{0,0,W,H}` は viewport 外周とバー右下端に重なる。border-model §4.2 は **overpaint（1px・レイアウト inset しない）** を確定。
- `focusOwner`/`isSelfOrDescendant` は **Component メソッド**（`:505-506` で使用済み）＝Metal の `paintOver` も `self` から直接呼べる
  （`@fieldParentPtr` 不要）。
- **重要**: `metalTable()`（現状・`metal.zig:134-163`）は **ScrollPane を remap しない**。よって現 Metal LAF 下でも ScrollPane は
  この FlatLaf 枠を描く（[laf_metal_range.md](laf_metal_range.md) §1.3／border-model §4.3）。Group C で **この `look_vtable` を Metal 沈みベベル版へ差し替える**。

### 1.2 List（`framework/src/List.zig`）＝枠を持たない・well＋選択＋セルのみ

- `lookPaint`（`:622-643`）: 背景塗り `surface_input`（`:626-627`）＋選択ハイライト `selection_bg`（`:630-638`）＋
  プール済みセル描画（`pc.cell.component.paintAt(g)`・`:640-642`）。**外周枠は無い**（border-model §1.2 確定）。
- `lookPaintOver` no-op（`:645`）。`lookMeasureMinSize` は `self.min_size`（`:647-649`）＝look は寸法を作らない。
- → Metal は **well の地・選択ハイライト・（セルは子描画のまま）** だけ差し替える。**枠は足さない**（枠は enclosing ScrollPane 所有）。
  セル文字色は子 component のもの＝**触らない**（前景尊重）。

### 1.3 Table（`framework/src/Table.zig`）＝枠を持たない・ヘッダは別 component

- `lookPaint`（`:794-817`）: 背景 `surface_input`（`:799-800`）＋選択 `selection_bg`（`:802-810`）＋
  列ごとのプールセル描画（`:812-816`）。**外周枠は無い**（border-model §1.3 確定）。`lookMeasureMinSize` は `self.min_size`（`:821-823`）。
- **ヘッダは独立 component**: `TableHeader`（private nested struct・`:134-214`）が `paintHeader`（`:825-849`）を `lookPaint` から呼ぶ（`:166-168`）。
  ヘッダは enclosing ScrollPane の **column header view** として設置される（`headerView`・`:346-348`／test `:1161`）。
  `paintHeader` の中身: ヘッダ地 `surface_window`（`:827-828`）＋列タイトル `text`（`:835-836`）＋ソート標 `accent`（`:838-839`）＋
  **列区切り線 `border_soft`（`:842-843`）＋ヘッダ下線 `border_soft`（`:847-848`）**。この 2 本が「ヘッダ内部線」（枠ではない構造線）。
- `TableHeader.look_vtable` は **private const**（`:145-149`）かつ `TableHeader` 型も private＝**Metal で remap するには framework 公開化が要る**（§5.2・ComboBox popup と同型）。

### 1.4 TabbedPane（`framework/src/TabbedPane.zig`）＝**load-bearing 前提の確認結果（最重要）**

**確認した前提**: LAF 移行時の latent 注記＝「非選択タブを layout が 0x0 化＋zero-clip で早期 return（laf-impl-core 由来）」。
実コードを Read して検証した結果を **取り繕わず** 記す（border-model §8a の教訓）。

- **タブ strip は TabbedPane 自身の `look_vtable.paint` が自前で描く**（`:246-280`）。`tp.tabs`・`tp.selected`・`tp.font` を読み、
  `x` を進めながら各タブ矩形を **TabbedPane 自身の座標系で `fillRect`/`drawString`**（`:255-276`）。
  **タブヘッダは独立した子 component ではない**（タブごとの Component は内容＝`tab.content` だけ）。
- **layout は内容（content）だけを動かす**（`layoutDoLayout`・`:211-224`）。選択タブの content は
  `{0, DEFAULT_TAB_HEIGHT, W, content_h}`（`:219`）、**非選択タブの content は `{0, DEFAULT_TAB_HEIGHT, 0, 0}`**（`:221`）。
  この 0x0 が `paintAt` のクリップ（`Component.zig:670`→`Graphics.clip` の 0x0 スシザ・`Graphics.zig:182-183`）で **描画スキップ**される＝
  注記の「zero-clip 早期 return」。
- **帰結（前提は崩れない）**: Metal のタブ描画も **同じ `look_vtable.paint` 内**で TabbedPane 座標系に描く。これは
  **非選択タブの content（0x0）に一切依存しない**。0x0 化は *content* の話で、*タブヘッダ* は常に strip paint が全タブぶん描く。
  よって「選択/非選択タブのベベル・選択タブの強調」を乗せても **0x0＋zero-clip 前提は崩れない**。回避策は不要。
- **崩さないための正しさ制約（Slider の THUMB_RADIUS 一致と同型）**: hit-test（`tabAt`・`:198-207`）と layout（`:215,219,221`）は
  private const `DEFAULT_TAB_HEIGHT=26`（`:19`）と `TAB_HPAD=12`（`:21`）、private fn `tabWidth`（`:188-190`＝`measureString+2*TAB_HPAD`）に依存する。
  振る舞いは不変なので、**Metal の strip 描画はこれら定数・式と完全一致**させる（private なので metal.zig 内へ再実装＝[laf_metal_range.md](laf_metal_range.md) §3.3 と同手）。
  さもないと「描かれるタブ位置」と「クリックできる領域」がずれる。§4.4 で固定値として明記。

### 1.5 Panel（`framework/src/Panel.zig`）＝背景・border ともに利用者 opt-in

- `lookPaint`（`:125-136`）: `panel.background`（`?Color`・既定 null）が **set されている時だけ** 全面 `fillRect`。
- `lookPaintOver`（`:138-153`）: `panel.border`（`?{thickness, color}`・既定 null）が set されている時だけ、thickness 幅の 4 本帯 `fillRect`。
- **border と inset は連動**: `setBorder`（`:78-83`）→ `updatePaddingLayout`（`:103-112`）が `PaddingLayout` の inset を
  `thickness + padding` にする＝**content は thickness ぶん内側に寄る**（枠と中身が重ならない）。
- → Metal の border はこの **thickness 帯の中** に描けば inset と整合し layout 不変（§3.4）。background は利用者の地色＝**残す**。

### 1.6 SplitPane（`framework/src/SplitPane.zig`）＝divider strip を `lookPaint` で描く

- `lookPaint`（`:254-275`）: divider strip を `surface_window` で塗り（`:264-265`）、中央グリップ 1 本線を
  `if (drag or rollover) border else separator`（`:268`）で描く（`:269-273`）。**矢印・バンプは無い**（既に無地＋1 本線）。
- divider 位置 `dividerStart()`（private fn・`:177-179`＝`mainAxis(first.size)`）／`divider_size`（field・`:43`／既定 6・`:27`）／
  `orientation`・`drag`・`rollover`（fields）。private fn は metal.zig から呼べないので `sp.first.size` から **同式を再実装**（§6.1）。
- `lookPaintOver` no-op（`:277`）。`lookMeasureMinSize` `{0,0}`（`:279-281`）。

### 1.7 既存パレット・helper（再利用前提・確定事実）

`metal.zig` に既存（[laf_metal_range.md](laf_metal_range.md) 実装済み）:

- `MetalPalette`（`:36-62`）/ `metal_palette`（`:64-90`）。`body_enabled/rollover/pressed/disabled_*`・`border`・`border_disabled`・
  `bevel_light`(#fff)・`bevel_dark`(#8494A8)・`focus_ring`(#6382BF)・`well_bg`(#fff)・`well_disabled`・`select_bg`(#6382BF)・
  `select_text`(#fff)・`track_groove`・`scroll_track`・`indicator_border`・`indicator_mark`・`text_disabled` を保持。
- helper: `bodyGradient`（`:576-592`）／`drawBevel`（`:594-596`）＝`drawBevelAt`（`:598-606`）／
  `drawInsetBevel`（`:608-610`＝dark/light 反転＝沈み）／`drawRectBorder`（`:612-618`）／`paintSteelThumb`（`:519-537`）。
- 表: `metal_table`（`:134-163`・現 7 エントリ）／`metalTable()`（`:165-167`）／`buttonTable()`（`:169-171`）。

---

## 2. MetalPalette の拡張（確定提案・最小）

Group C は **新規トークンを足さない**（作者方針「本当に必要な新トークンだけ」に従い、結論はゼロ）。各 widget は既存トークンの再利用で表現できる:

| 用途 | 使う既存トークン |
|---|---|
| 鋼面（タブ選択・Table ヘッダ・SplitPane divider・Panel raised 帯） | `bodyGradient(p, enabled, rollover, false)`＋`border`＋`bevel_light`/`bevel_dark` |
| 非選択タブ（引っ込んだ鋼） | `bodyGradient` の **disabled 系**（`body_disabled_*`＝一段くすんだ鋼）＋`bevel_dark` で凹み |
| 沈みベベル枠（ScrollPane・Panel etched・列区切りの溝） | `drawInsetBevel`（dark 上左／light 下右）＋外周 `border` |
| 沈み井戸の地（List/Table の field） | `well_bg`（#fff・enabled）／`well_disabled`（disabled） |
| 選択行 | `select_bg`（#6382BF）／文字は触らない（前景尊重・§1.2） |
| focus 反応（ScrollPane 枠の子孫フォーカス時） | `focus_ring`（#6382BF・accent 相当） |
| ヘッダ列タイトル / ソート標 / ヘッダ内部線 | `indicator_mark`（濃 #333・文字/標）＋`bevel_dark`/`bevel_light`（溝線） |

→ **追加トークン 0**。微調整したくなったら §8 の showcase 目視で詰める（必要なら最小限の新トークンを起票・§10）。

---

## 3. Panel Metal レシピ（確定提案）

`metal.zig` に `metal_panel_look` を追加。`@fieldParentPtr` で `*Panel` へ戻り `background`・`border`・`padding` を読む
（Panel は `container.component` を露出するので `*Panel` へは `Container`→`Panel` の二段＝既存 `Panel.zig:126-127`/`:139-140` と同型）。

### 3.1 paint（`metal_panel_look.paint`）

FlatLaf（`Panel.zig:125-136`）と同じく **`panel.background` が set の時だけ** 全面 `fillRect`（**利用者の地色を尊重・上書きしない**）。
未設定なら何も描かない（透明・現状維持）。

### 3.2 paintOver（`metal_panel_look.paintOver`）＝Metal etched/raised ベベル枠

`panel.border` が set の時だけ描く。`t = border.thickness`、`sz = self.size`:

- **thickness 帯の中に Metal ベベルを描く**（§1.5 の inset と整合＝layout 不変）。**border.color は使わない**
  （Metal はパレット由来の鋼ベベルに置換＝§0 の Theme 非依存。chrome なので前景尊重の対象外。背景は別＝§3.1 で残す）。
- `t >= 2`: 外周 1px を `bevel_dark`（上・左）／`bevel_light`（下・右）＝etched（沈み）、内周 1px を逆向き＝合わせて溝。
  残りの帯（`t > 2` ぶん）は `border` 色で埋めて Metal 鋼枠の太さを出す。**raised にしたい場合は light/dark を反転**（§8 で選択）。
- `t == 1`: ベベルが描けないので 1px の `border` 線で近似（CheckBox 円弧近似と同型・[laf_metal_selection.md](laf_metal_selection.md) §3.1）。

### 3.3 状態別

Panel は enabled/focus 状態を持たない（汎用コンテナ）。border が無ければ no-op、有れば etched/raised ベベル（静的）。

### 3.4 measure（`metal_panel_look.measureMinSize`）

`{0,0}` を返す（FlatLaf 同値・`Panel.zig:155-157`）。inset は `PaddingLayout` が担うので look は寸法に関与しない＝**layout 不変**。

### 3.5 `Panel.setBorder` との役割分担（確定・border-model §6.3 の延長）

- `Panel.setBorder`（inset=thickness・背景あり・focus 無反応）: Metal 下では **etched/raised ベベル**で描かれる（本節）。
- Border デコレータ（border-model §6・inset 0・focus 反応）: Group C では **任意**で Metal ベベル化（border-model §9・§10-5 に送り）。
  本 spec のスコープは Panel まで。Border デコレータの Metal 化は未決（§10）。

---

## 4. TabbedPane Metal レシピ（確定提案・§1.4 の前提を守る）

`metal.zig` に `metal_tabbedpane_look` を追加。`@fieldParentPtr` で `*TabbedPane` へ戻り `tabs`・`selected`・`font` を読む。
**FlatLaf の `lookPaint`（`:246-280`）の strip 構造（左から `x` を進める・選択判定・下線）をそのまま踏襲**し、各タブの塗りだけ Metal 化。
**§1.4 の前提は守られる**（タブヘッダは strip paint が全タブぶん自前描画・非選択 content の 0x0 に非依存）。

### 4.1 paint（`metal_tabbedpane_look.paint`）

`sz = self.size`、`H = TP_TAB_HEIGHT`（§4.4＝26）、`p = palette`:

1. **strip 背景**: `{0,0,sz.width,H}` を非選択鋼（`body_disabled_top` 等の地）で `fillRect`（タブが無い余白部の地）。
2. **各タブ**（`x` を `TP_TAB_HPAD` 込みの `tabWidth` ぶん進める・§4.4）:
   - **非選択タブ**: 矩形 `{x,0,w,H}` を `bodyGradient(p, false, false, false)`（disabled 系＝くすんだ鋼）で塗り、
     上辺を `bevel_dark`（凹み）。タブ間の区切りは `bevel_dark`/`bevel_light` の溝 1px（FlatLaf は `border_soft` 1 本・`:263-264`）。
   - **選択タブ**: 矩形 `{x,0,w,H}` を `bodyGradient(p, true, false, false)`（明るい鋼）で塗り、`drawBevelAt`（上・左 `bevel_light`／下・右 `bevel_dark`）で **raised**。
     **下辺のベベル/区切りは描かない**（内容面と地続きに見せる＝Metal の選択タブ）。
   - タイトル: `drawString` を `indicator_mark`（濃・chrome 文字）。位置は FlatLaf 同式（`x + TP_TAB_HPAD`・縦中央・`:266-269`）。
3. **strip 下辺の境界線**: `{0, H-1, sz.width, 1}` を `border`（FlatLaf は `border_soft`・`:278-279`）。
   ただし **選択タブの幅ぶんは描かない or 鋼色**で地続き感を出す（§8 で詰める）。

`paintOver` は no-op（FlatLaf 同・`:282`）。**accent 下線（FlatLaf `:271-274`）は Metal では raised ベベルが選択を示すので省略可**（§8）。

### 4.2 状態別

- 選択: raised 鋼＋地続き。非選択: 引っ込んだ鋼。disabled/rollover タブ状態は TabbedPane に無い（FlatLaf も使わない）＝演出しない。

### 4.3 §1.4 前提を崩さないことの担保（確定）

- Metal strip 描画は **TabbedPane 座標系・自前 fillRect** のみ（子 content に触れない）。非選択 content の 0x0 化（`:221`）と
  zero-clip 早期 return（`Graphics.zig:182-183`）は **そのまま機能**（content 描画は従来どおりスキップ）。
- `DEFAULT_TAB_HEIGHT`/`TAB_HPAD`/`tabWidth` 式に一致させるので hit-test（`tabAt`・`:198-207`）とズレない（§4.4）。
- → **設計上の回避策は不要**。崩れる要素は無いことを確認済み（§1.4）。

### 4.4 Metal 定数（TabbedPane の private と一致必須）

| 定数 | Metal 値 | TabbedPane（private） | 備考 |
|---|---|---|---|
| `TP_TAB_HEIGHT` | `26` | `DEFAULT_TAB_HEIGHT=26`（`:19`） | **据え置き必須**（layout `:215,219,221`／hit-test `:199` と一致） |
| `TP_TAB_HPAD` | `12` | `TAB_HPAD=12`（`:21`） | **据え置き必須**（`tabWidth`＝`measureString+2*HPAD`・`:189` と一致） |

`tabWidth` 再実装（`metal.zig` 内 helper・`tp.font` 使用）: `font.measureString(title).width + 2*TP_TAB_HPAD`（`:188-190` と同式）。

### 4.5 measure（`metal_tabbedpane_look.measureMinSize`）

`{0,0}`（FlatLaf 同・`:284-286`）。strip/content の合算は `TabLayout`（`:226-238`）が担う＝look は寸法に関与しない・layout 不変。

---

## 5. List / Table Metal レシピ（確定提案）

### 5.1 List（`metal_list_look`）

`*List` へ戻り（`List.zig:623` と同型）`selection`・`row_height`・`pool` を読む。FlatLaf（`:622-643`）の構造を踏襲:

1. **沈み井戸の地**: `{0,0,sz.width,sz.height}` を `well_bg`（FlatLaf の `surface_input`・`:626-627` に対応）で `fillRect`。
   井戸の沈み感は **enclosing ScrollPane の沈みベベル枠**（§6.x→ §7 ScrollPane）で出す。List 自身は枠を足さない（border-model §1.2）。
2. **選択行**: `selection.indices()` 各行を `select_bg`（FlatLaf の `selection_bg`・`:630-638` に対応）で `fillRect`。
3. **セル**: `pc.cell.component.paintAt(g)`（`:640-642`）を **そのまま**（セルは子 component＝文字色等は触らない・前景尊重）。

`paintOver` no-op。`measureMinSize` は `self.min_size`（`:647-649` と同・**寸法不変**）。

### 5.2 Table（`metal_table_look`＋`metal_tableheader_look`）＝**ヘッダの framework 公開化が必須**

#### 5.2.1 本体（`metal_table_look`）

List と同型。`*Table` へ戻り（`Table.zig:795`）`selection`・`row_height`・`columns` を読む:

1. **沈み井戸の地**: `well_bg`（FlatLaf `surface_input`・`:799-800`）。
2. **選択行**: `select_bg`（FlatLaf `selection_bg`・`:802-810`）。
3. **セル**: 列ごとのプールセル `paintAt`（`:812-816`）を **そのまま**。

`paintOver` no-op。`measureMinSize` は `self.min_size`（`:821-823` と同・**寸法不変**）。

#### 5.2.2 ヘッダ（`metal_tableheader_look`）＝framework 公開化（確定・ComboBox popup と同型）

**調査結果**: ヘッダは `TableHeader`（private nested struct・`:134-214`）の独立 component で、`look_vtable` も **private const**（`:145-149`）。
→ 現状の `applyLook` は **`&Table.TableHeader.look_vtable` を鍵に引けない**（型もポインタも非公開）。ComboBox の popup_look_vtable と同じ壁
（[laf_metal_selection.md](laf_metal_selection.md) §4.2）。**framework 側に最小の公開化が要る**（Codex 実装指示）:

1. `TableHeader` 型と `TableHeader.look_vtable` を **pub 化**（または `Table` から `pub const HeaderLook = TableHeader.look_vtable;` を公開）。
   表が `&...TableHeader.look_vtable` を鍵に引ける状態にする（vtable ポインタが型タグ・[laf_enabler.md](laf_enabler.md) §2.2）。
2. これは **FlatLaf 挙動を変えない**（pub 化は無害・automation 木/描画経路は不変）。
3. **到達性は OK**: ヘッダは ScrollPane の column header view＝`column_header_port`（ScrollPane の子）の子として automation 木に乗る
   （`ScrollPane.zig:321-329`・walk は `container.children` を辿る・[laf_enabler.md](laf_enabler.md) §3.3.3）。detached facet は不要。

ヘッダ Metal 描画（`*TableHeader` へ戻り `.table` で `*Table`・`paintHeader`（`:825-849`）の中身を `metal.zig` へ再実装。
`paintHeader` は private fn＝呼べないので `table.columns`/`header_font`/`sort_column`/`sort_direction` を読んで再実装）:

1. **ヘッダ地**: `bodyGradient(p, true, false, false)` の鋼グラデ＋`drawBevel`（raised）。FlatLaf の `surface_window`（`:827-828`）に対応。
2. **列タイトル**: `indicator_mark`（chrome 文字）。位置は FlatLaf 同式（`x + HEADER_PAD`・縦中央・`:834-836`）。
3. **列区切り線（内部線）**: 各列右端 1px を `bevel_dark`＋`bevel_light` の **溝**（FlatLaf の `border_soft` 1 本・`:842-843` に対応）。
4. **ソート標**: `indicator_mark`（FlatLaf `accent`・`:838-839`）。`paintSortIndicator`（`:853`）の算法を再実装（積み棒・三角プリミティブ無し）。
5. **ヘッダ下線**: 最下 1px を `border`（FlatLaf `border_soft`・`:847-848`）。

`HEADER_HEIGHT`/`HEADER_PAD` は `paintHeader` が使う private const＝metal.zig で同値再定義（**寸法不変**・`TableHeader.create` の `min_size`＝`:158` と一致）。

---

## 6. SplitPane Metal レシピ（確定提案）

`metal.zig` に `metal_splitpane_look` を追加。`*SplitPane` へ戻り（`SplitPane.zig:255`）`divider_size`・`orientation`・`first.size`・`drag`・`rollover` を読む。
FlatLaf（`:254-275`）の divider 矩形算出を踏襲し、塗りだけ Metal 化。**bumps・矢印・点描グリップは描かない**（§0）。

### 6.1 paint（`metal_splitpane_look.paint`）

`sz = self.size`、`ds = sp.divider_size`、`start = mainAxis(sp.first.size)`（`dividerStart` private fn の再実装・`:177-179` と同式）:

`sz` が正かつ `ds>0` のとき divider 矩形（`:260-263` と同式）:

- horizontal: `{start, 0, ds, sz.height}`／vertical: `{0, start, sz.width, ds}`。
- 描画: 矩形を `bodyGradient(p, true, false, false)` の鋼グラデで塗り、`drawBevelAt`（上・左 `bevel_light`／下・右 `bevel_dark`）で **raised 無地ベベル**。
- **中央の seam（1px）**: 無地の `bevel_dark`（溝）1 本を中央に。`drag or rollover` のとき一段濃く（`border`）＝FlatLaf の hover 強調（`:268`）相当。
  **これは 1 本線であって bumps ではない**（§0 の「無地ベベル」の範囲）。

### 6.2 状態別

- 通常: raised 鋼＋細い seam。hover/drag（`drag != null or rollover`）: seam を `border` で強調（FlatLaf 同挙動）。

### 6.3 paintOver / measure

`paintOver` no-op（`:277` と同）。`measureMinSize` `{0,0}`（`:279-281` と同）。divider 幾何・hit-test は `processEvent`（`:283-329`・不変）＝**振る舞い不変**。

---

## 7. ScrollPane Metal レシピ（確定提案・border-model から橋渡し）

`metal.zig` に `metal_scrollpane_look` を追加。**`metalTable()` に ScrollPane エントリを足し、
border-model §4 の FlatLaf 枠（focus 反応・`lookPaintOver`）を Metal 沈みベベル版へ差し替える**（border-model §4.3/§9）。
`paint` は no-op（FlatLaf 同・`:497`）。バーは別エントリ（`ScrollBar`・既存）で Metal 化済み＝ScrollPane エントリは枠だけ担う。

### 7.1 paintOver（`metal_scrollpane_look.paintOver`）＝Metal 沈みベベル枠＋focus 反応

`self`（ScrollPane の container.component）から `w/h = self.size`、`p = palette`。`w<=0 or h<=0` で return（FlatLaf 同・`:503`）:

1. **focus 判定**（border-model §5.3 と同）: `owner = self.focusOwner()`（Component メソッド・`:505`）／
   `focused = owner!=null and self.isSelfOrDescendant(owner.?)`（`:506`）。
2. **沈みベベル枠（lowered・2px overpaint）**:
   - 外周 1px: `drawRectBorder(g, 0, 0, w, h, focused ? focus_ring : border)`（focus で accent 寄り＝focus 反応）。
   - 内周 1px: `drawInsetBevel(g, 0, 0, w, h, p)`（上左 `bevel_dark`＝影／下右 `bevel_light`＝光）＝**沈み**。
   - → 内容が井戸に沈んで見える。focus 反応は **外周線の色**（border↔focus_ring）で表現（沈みベベルは保つ）。

### 7.2 overpaint vs inset（border-model §4.2/§10 の引き継ぎ）

- border-model は **overpaint（1px・レイアウト inset しない）** を確定（§4.2）。Metal 枠は **2px**（外周線＋沈みベベル）。
- バーは 14px 幅（`T=14`・`ScrollPane.zig:370`）なので **外端 2px の被りは装飾上無視できる**＝overpaint を維持（layout・extent・thumb 幾何すべて不変）。
- Swing 忠実な inset（viewport/バーを枠ぶん内側へ）は **採らない**（全 ScrollPane ゴールデンの構図が動く・破綻大）。border-model §10-3 の通り **未決に残す**（§10）。

### 7.3 focus 反応を golden で押さえる

border-model §8d の **FocusController スタブ**（`current_owner` が指定 owner を返す）を scene root に設置し、view を owner にして paint
→ 枠外周が `focus_ring`（accent）になることを golden 化（§8a の focused 版）。非フォーカス版（owner=null）と 2 枚で差を固定。

---

## 8. metalTable() の拡張（確定提案）

現状 `metal_table`（`metal.zig:134-163`）は 7 エントリ（Button＋選択 4＋レンジ 2）。これに **Group C の 7 エントリを追加**:

```zig
// ...既存 7 エントリ（Button / CheckBox / RadioButton / ComboBox×2 / Slider / ScrollBar）...
    .{ .from = &Panel.look_vtable,                  .to = .{ .vtable = &metal_panel_look,       .ctx = &metal_palette } },
    .{ .from = &TabbedPane.look_vtable,             .to = .{ .vtable = &metal_tabbedpane_look,  .ctx = &metal_palette } },
    .{ .from = &List.look_vtable,                   .to = .{ .vtable = &metal_list_look,        .ctx = &metal_palette } },
    .{ .from = &Table.look_vtable,                  .to = .{ .vtable = &metal_table_look,       .ctx = &metal_palette } },
    .{ .from = &Table.TableHeader.look_vtable,      .to = .{ .vtable = &metal_tableheader_look, .ctx = &metal_palette } }, // 要 pub 化（§5.2.2）
    .{ .from = &ScrollPane.look_vtable,             .to = .{ .vtable = &metal_scrollpane_look,  .ctx = &metal_palette } },
    .{ .from = &SplitPane.look_vtable,              .to = .{ .vtable = &metal_splitpane_look,   .ctx = &metal_palette } },
```

- `metal.zig` 冒頭に import 追加: `Panel`/`TabbedPane`/`List`/`Table`/`ScrollPane`/`SplitPane`（`metal.zig:3-10` の並びに足す）。
- ctx は全エントリ共通 `&metal_palette`。`buttonTable()`（`metal_table[0..1]`・`:169-171`）は不変。
- **Panel remap の波及に注意（確定・安全）**: Panel は汎用コンテナとして多数存在するが、Metal Panel look は
  **background/border が set の時だけ**描く（§3.1/§3.2）＝null 既定の素 Panel は FlatLaf と同じく**何も描かない**。よって remap しても素 Panel は不変。
  枠付き Panel（`setBorder` 済み・showcase Form/Split タブ等）だけ Metal ベベルになる。
- **ScrollPane エントリ 1 件で全 ScrollPane/List/Table 周りの枠が Metal 化**（バーは別エントリで既に Metal・[laf_metal_range.md](laf_metal_range.md) §1.3）。
- **Table ヘッダは framework 公開化が前提**（§5.2.2）。公開化前はこの 1 エントリだけコンパイルが通らない＝公開化とセットで入れる。

---

## 9. showcase（確定提案・Codex 実装）

`examples/widget_showcase/main.zig` は既に `const Laf = enum{flatlaf, metal}`＋switch で `metalTable()` を当てる構成
（[laf_metal_selection.md](laf_metal_selection.md) §6／border-model §7.3）。本フェーズは **表の拡張だけで Group C も自動 Metal 化**
（showcase 側コード変更は不要）。

- **既定は `.flatlaf`**（変えない）。目視時に作者が一時的に `.metal` へ。
- 目視対象: Form タブ（Panel border の etched/raised）／タブ strip 自体（TabbedPane）／Lists タブ（List well＋選択＋ScrollPane 沈み枠）／
  Table タブ（well＋選択＋ヘッダ鋼＋列溝）／Split タブ（divider 鋼ベベル）。フォーカスを TextArea/List に入れて ScrollPane 枠が accent に光ること。

---

## 10. テスト / デモ計画（確定提案）

### 10a. Metal ゴールデン（snapshot・意図的に新ピクセル）

各 Metal scene を `framework/tests/scenes.zig` に追加（`nimbus.laf.applyLook(root, metalTable())` を paint 前に当てる）。
tolerance はグローバル `TOLERANCE = 1`（`framework/tests/snapshot_test.zig`・整数構図＋縦グラデは決定的）。

- **Panel**: `metal_panel_border`＝`setBorder` 済み Panel の etched/raised ベベル（既存 `panel_paint_over_child`・`:583-606` を Metal 化した構図）。
- **TabbedPane**: `metal_tabbed_pane`＝2〜3 タブ・1 つ選択（既存 `tabbed_pane`・`:931` の Metal 版）。選択 raised／非選択凹みの差を固定。
- **List**: `metal_list_selection`＝well＋選択行（既存 `list_selection`・`:830` の Metal 版）。
- **Table**: `metal_table_header_grid`＝well＋選択＋ヘッダ鋼＋列溝（既存 `table_header_grid`・`:857` の Metal 版）。ヘッダ remap が効くことを 1 枚で押さえる。
- **SplitPane**: `metal_split_pane_divider`＝divider 鋼ベベル＋seam（既存 `split_pane_divider`・`:611` の Metal 版）。
- **ScrollPane（沈み枠・focus 反応）**:
  - 既存 `metal_scroll_pane_bars`（`:552-579`）は **構図が変わる**: 従来 ScrollPane は remap されず枠が FlatLaf（border-model §8a）だったが、
    Group C で **Metal 沈みベベル枠に変わる**＝この golden は更新される（差分は外周枠が Metal 化されるだけ・viewport/バー幾何は overpaint で不変・§7.2）。**`zig build update-snapshots` で再生成**。
  - 追加 `metal_scroll_pane_focused`＝§7.3 の FocusController スタブで view を owner にし、枠外周が `focus_ring`（accent）になる絵。
    非フォーカス版（`metal_scroll_pane_bars`）との差で focus 反応を固定。

### 10b. メトリクス＋表遷移の純ロジックテスト（GPU 非依存）

[laf_enabler.md](laf_enabler.md) §5.0 の通り **`Device.init` ゲート下に置かない**（`awt.Font.init(...)` を直接使う）。

- **measure 不変**: 各 Metal look の `measureMinSize` が FlatLaf 同値を返すこと:
  Panel/TabbedPane/SplitPane/ScrollPane＝`{0,0}`、List/Table＝`self.min_size`。**寸法不変＝layout 不変**の回帰ガード。
- **表遷移**: 小ツリーへ `applyLook(root, metalTable())` 後、各 widget の `component.ui.vtable` が対応 Metal look に化けたことを assert
  （`panel.asComponent().ui.vtable == &metal_panel_look` 等）。
- **ScrollPane 波及**: ScrollPane を含むツリーへ `applyLook` 後、`sp.asComponent().ui.vtable == &metal_scrollpane_look`、
  バーは `sp.vbar.component.ui.vtable == &metal_scrollbar_look`（[laf_metal_range.md](laf_metal_range.md) §7b の継続）を assert。
- **Table ヘッダ到達の回帰ガード（§5.2.2 の肝）**: Table を ScrollPane の view に、ヘッダを column header view に設置したツリーへ `applyLook` 後、
  **`table.header_view.?.component.ui.vtable == &metal_tableheader_look`** を assert（公開化＋automation walk でヘッダまで remap が届いた証拠。ComboBox popup 回帰ガードと同型）。
- **TabbedPane 前提の回帰ガード（§1.4/§4.3）**: TabbedPane に複数タブを add・layout 後、**非選択タブ content が 0x0**（`tab.content.size == {0,0}`）であることを assert
  （Metal remap 後も layout が崩れない＝前提維持）。さらに Metal の tab 幾何が hit-test と一致することを、`tabAt(metal が描く各タブ中心 x, H/2)` が当該 index を返すことで assert（§4.4 の正しさ制約）。
- **focus 反応の判定**（border-model §8d 流用）: FocusController スタブで owner を view に設定 → `sp.asComponent().focusOwner()` が view を返し
  `isSelfOrDescendant` が true（→ Metal 枠が `focus_ring`）、owner=null で false（→ `border`）を assert。色そのものの差は §10a の golden で担保。
- `error.SkipZigTest` 経路を踏まないこと。

### 10c. showcase 目視

`widget_showcase` を一時的に `.metal` にして `run`。§9 の各タブを目視。確認後 `.flatlaf` に戻す。

---

## 11. 未決（解決しない・列挙のみ）

1. **パレット微調整**: §2 は新トークン 0 を提案。タブ非選択鋼に `body_disabled_*` を流用するが、もっと差をつけたいなら
   専用トークン（`tab_unselected_*` 等）を最小限追加する余地（showcase 目視で判断）。
2. **Panel border の etched vs raised**: §3.2 は etched（沈み）を既定提案。raised（持ち上がり）に寄せるかは目視で選択。border.color を Metal が無視する点も要承認。
3. **TabbedPane の選択強調**: accent 下線（FlatLaf）を Metal で残すか、raised ベベルだけにするか（§4.1-3）。
4. **ScrollPane 枠の overpaint vs inset**: v1 は overpaint（2px・§7.2）。Metal 沈みベベルで枠が太く感じるなら Swing 忠実 inset を再検討（border-model §10-3 の継続）。
5. **Border デコレータの Metal ベベル**: 本 spec のスコープは Panel まで。Border デコレータ（border-model §6）の Metal 化は別途（border-model §9/§10-5）。
6. **List/Table 井戸の沈みベベル**: v1 は地塗りのみで沈み感は enclosing ScrollPane 枠に委ねる（§5.1/§5.2.1）。素置き（ScrollPane 無し）List/Table に沈みベベルを足すかは未決。
7. **Table ヘッダ公開化の形**: `pub const TableHeader` か `Table.HeaderLook` 別名か（§5.2.2）。命名・露出の細部は実装判断。
8. **命名**: `metal_panel_look`/`metal_tabbedpane_look`/`metal_list_look`/`metal_table_look`/`metal_tableheader_look`/
   `metal_scrollpane_look`/`metal_splitpane_look`／各 Metal 定数は仮（`laf_design.md` §6-1 の命名未決の延長）。

---

## 12. 実装の分割可否（pm 向け提案）

設計から見た自然な継ぎ目は **3 つ**。1 委譲でまとめても通るが、framework 公開化と load-bearing 前提を分離する切り方を推奨:

- **継ぎ目 A＝枠/ベベル系（ScrollPane / Panel / SplitPane）**: いずれも「鋼ベベルの枠/divider を描く」だけ。
  既存 helper（`drawBevel`/`drawInsetBevel`/`drawRectBorder`/`bodyGradient`）と `focusOwner`（既存・Component）で閉じ、**framework 改変ゼロ**。
  最もリスクが低く、ScrollPane の Metal 沈み枠（border-model からの橋渡しの本丸）をまとめて入れられる。
- **継ぎ目 B＝コレクション系（List / Table ＋ Table ヘッダ）**: well＋選択＋セル＋ヘッダ内部線。
  **唯一 framework の公開化（`TableHeader`/`look_vtable` の pub 化・§5.2.2）を含む**ので、署名変更を 1 コミットに隔離できる。
  ヘッダ到達の回帰ガード（§10b）もここに同梱。
- **継ぎ目 C＝TabbedPane（単独）**: §1.4 の **load-bearing 前提（0x0＋zero-clip）** が関わる唯一の widget。
  golden（選択/非選択）と前提の回帰ガード（§10b）を独立にレビューできるよう単独コミットが安全。

推奨: **A → B → C の 3 コミット**（A はリスク最小で土台、B は framework 署名変更の隔離、C は前提検証の隔離）。
1 委譲で進める場合も、この 3 ブロックを別コミットに割れば差分レビューが追いやすい。pm が分割粒度を決める材料とされたい。

---

## 13. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | スコープ＝Panel/TabbedPane/List/Table/ScrollPane/SplitPane の 6 種。見た目のみ・振る舞い/layout/寸法不変・前景尊重・bumps 無し（§0） |
| 確定 | 新トークン **0**。既存 `body_*`/`bevel_*`/`border`/`well_bg`/`select_bg`/`focus_ring` 等を再利用（§2） |
| 確定 | Panel: 背景は利用者尊重（set 時のみ塗る）。border は thickness 帯内に Metal etched/raised ベベル（border.color は無視・layout 不変）（§3） |
| 確定 | **TabbedPane の前提確認＝崩れない**: タブ strip は look.paint が自前描画（子 content 非依存）。非選択 content 0x0（`:221`）＋zero-clip（`Graphics.zig:182-183`）はそのまま機能。回避策不要（§1.4/§4.3） |
| 確定 | TabbedPane: 選択 raised 鋼＋地続き／非選択 凹み鋼。`TAB_HEIGHT=26`/`TAB_HPAD=12`/`tabWidth` 式を一致必須（hit-test とズレ防止）（§4） |
| 確定 | List/Table: well（`well_bg`）＋選択（`select_bg`）＋セル（子描画のまま）。**枠は足さない**（ScrollPane 所有）。measure＝`self.min_size`（§5） |
| 確定 | Table ヘッダ: 鋼グラデ＋bevel＋列溝（`bevel_*`）＋下線（`border`）。**`TableHeader`/`look_vtable` の pub 化が必須**（ComboBox popup と同型）。到達は column header view 経由で OK（§5.2.2） |
| 確定 | SplitPane: divider を鋼 raised ベベル＋中央 seam 1 本（hover で `border` 強調）。bumps/矢印/点描なし（§6） |
| 確定 | ScrollPane: `metalTable()` に ScrollPane エントリ追加し `lookPaintOver` を Metal 沈みベベル枠へ差し替え。focus 反応は外周線色（`border`↔`focus_ring`）。overpaint 維持（2px・layout 不変）（§7） |
| 確定 | `metalTable()` に Group C 7 エントリ追加（Panel/TabbedPane/List/Table/TableHeader/ScrollPane/SplitPane）。Panel remap は素 Panel に無害（set 時のみ描画）。import 6 件追加（§8） |
| 確定 | showcase は表拡張だけで自動 Metal 化（コード変更不要・既定 `.flatlaf`）（§9） |
| 確定 | テスト: (a) Metal golden（各 widget＋`metal_scroll_pane_bars` 更新＋focus 版・tol=1）（b）measure 不変＋表遷移＋ヘッダ到達＋TabbedPane 前提＋focus 判定を GPU 非ゲートで assert（c）showcase 目視（§10） |
| 確定 | 実装分割は A=枠/ベベル系（framework 改変ゼロ）／B=コレクション系（ヘッダ公開化を隔離）／C=TabbedPane（前提検証を隔離）の 3 継ぎ目を推奨（§12） |
| 未決 | パレット微調整／Panel etched vs raised・border.color 無視承認／タブ選択強調／overpaint vs inset 再検討／Border デコレータ Metal／井戸沈みベベル／ヘッダ公開化の形／命名（§11） |
