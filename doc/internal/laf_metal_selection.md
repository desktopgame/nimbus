# Metal Look（Group A＝選択系: CheckBox / RadioButton / ComboBox）設計 spec

LAF Step 3 横展開の **Group A＝選択系**（CheckBox / RadioButton / ComboBox）を Metal Look へ差し替える **設計 spec**。
Button Metal（[laf_metal_button.md](laf_metal_button.md)・develop マージ済み、`framework/src/laf/metal.zig` 実在）で確立した
レシピを踏襲・再利用する。実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。

関連: [laf_metal_button.md](laf_metal_button.md)（MetalPalette・`metal_button_look`・外枠全面塗り→縦グラデ→ベベル レシピ）、
[laf_enabler.md](laf_enabler.md)（`applyLook` / `RemapEntry` / **detached_look_roots facet** §3.7・GPU 非ゲート §5.0）、
[awt_primitives_laf.md](awt_primitives_laf.md)（`fillGradientRect`）。

---

## 0. 大前提とスコープ（確定・再議論しない）

- **Metal は縦グラデ＋ベベル・角丸なし・Theme 非依存の自前パレット**。既存 `metal.zig` の `MetalPalette`／
  `metal_button_look`／helper（`bodyGradient`・`drawBevel`・`paintContent`）を **踏襲・再利用**する。
- 各 widget の Metal look は `Component.LookVTable{paint, paintOver, measureMinSize}`。`@fieldParentPtr` で具象型へ戻り
  状態を読む（**振る舞い不変**）。**text / 前景色は利用者指定を尊重**（`cb.color` 等。Button と同じ方針）。
- enabler `nimbus.laf.applyLook(root, table)` で **init 時 1 回**当てる（`laf.zig`）。
- **スコープは CheckBox / RadioButton / ComboBox の 3 種**。他 widget は部分 LAF で FlatLaf のまま（`laf_enabler.md` §4）。

参照スクショ（`tmp/`）から読み取った Metal Ocean の特徴:

- **CheckBox**（`swingset_metal5.png` / `_metal21.png`）: 小さな四角＋**沈んだ白い井戸**（ベベル反転）・選択でチェックマーク。
- **RadioButton**（`swingset_metal4.png` / `_metal20.png`）: 円＋沈んだ井戸・選択で**中央ドット**。
- **ComboBox**（`swingset_metal9.png` / `_metal15.png`）: 白フィールド＋**右端の独立したベベル矢印ボタン**（鋼グラデ＋▽）。
  ドロップダウンは白リスト＋hover 行ハイライト。

---

## 1. MetalPalette の拡張（確定提案・RGBA）

既存 `MetalPalette`（`metal.zig:13-49`）に **選択系トークンを追加**する。鋼系で既存値と整合させ、矢印ボタンの body は
**既存 `body_*` グラデ＋`bevel_*`＋`border` を再利用**（新グラデトークンは足さない）。追加トークン:

| トークン | RGBA | 用途 |
|---|---|---|
| `well_bg` | `(255, 255, 255, 255)` | チェック四角／ラジオ円／combobox フィールドの白い沈み井戸の地 |
| `well_disabled` | `(224, 225, 228, 255)` | 同・disabled 時 |
| `indicator_border` | `(122, 138, 153, 255)` | インジケータ枠（鋼）。既存 `border` と同値だが独立に持つ（個別調整余地） |
| `indicator_mark` | `(51, 51, 51, 255)` | check / radio dot / combobox chevron 共通の濃色マーク |
| `indicator_mark_disabled` | `(153, 153, 153, 255)` | 同・disabled（既存 `text_disabled` と同値・別名で明示） |
| `select_bg` | `(99, 130, 191, 255)` | ドロップダウンの hover / 選択行の地（Ocean 系の青） |
| `select_text` | `(255, 255, 255, 255)` | 同・文字色 |

沈み井戸のベベル（凹み）は **既存 `bevel_dark`（上・左＝影）／`bevel_light`（下・右＝光）を反転利用**する
（Button の凸ベベル `drawBevel` の light/dark を入れ替えるだけ。§2.1）。矢印ボタンの凸ベベルは Button と同じ向き。
これらは **提案値**で、showcase 目視（§7c）で作者が微調整してよい（§8）。

---

## 2. CheckBox の paint / measure レシピ（確定提案）

既存 FlatLaf 実装（`CheckBox.zig`：`look_vtable` `:44`・`lookPaint` `:190`・`lookMeasureMinSize` `:161`・
`drawCheck` `:248`・`drawBoxBorder` `:237`）に倣い、**インジケータの描き方だけ Metal 化**。ラベル配置・focus ring は踏襲。

`metal.zig` に `metal_checkbox_look`（`LookVTable`）を追加。`@fieldParentPtr("component", self)` で `*CheckBox` へ戻り、
`model.isSelected()` / `model.button.enabled` / `model.button.rollover` / `text` / `color` / `focused` を読む。

### 2.1 paint（`metal_checkbox_look.paint`）

`sz = self.size`、`box = 16`（FlatLaf の `BOX_SIZE`。§2.3 で Metal 定数として再定義）、
`box_x = PADDING_X`、`box_y = (sz.height - box) / 2`、`p = palette`:

1. **井戸の地**: enabled なら `well_bg`、disabled なら `well_disabled` で `fillRect({box_x, box_y, box, box})`。
2. **沈みベベル（凹み・1px リング）**: 上・左＝`bevel_dark`（影）、下・右＝`bevel_light`（光）の 1px セグメント
   （Button の `drawBevel`（`metal.zig:161`）と **light/dark を反転**した向き）。インジケータ矩形の縁に描く。
3. **外枠**: `indicator_border`（disabled は `border_disabled`）で四角の最外周 1px（`drawBoxBorder` 同型・`CheckBox.zig:237`）。
4. **チェックマーク（selected のとき）**: `indicator_mark`（disabled は `indicator_mark_disabled`）で、
   `CheckBox.drawCheck`（`CheckBox.zig:248-267`）と **同じ矩形ストローク算法**を `metal.zig` 内に再実装して描く
   （`drawCheck` は private fn ＝他ファイルから呼べない。**fields は読めるが file-private fn は呼べない** Zig の仕様）。
5. **ラベル**: FlatLaf と同一配置（`text_x = box_x + box + BOX_GAP`、`text_y = (sz.height - m.height)/2`）。
   色は enabled なら `cb.color`（利用者指定・尊重）、disabled なら `text_disabled`。
6. **focus ring**（`cb.focused`）: `focus_ring` で `drawRect({1,1,sz.w-2,sz.h-2})`（FlatLaf と同じ・`CheckBox.zig:227-230`）。

`paintOver` は no-op。

### 2.2 状態別

- 通常（未選択）: 白井戸＋凹みベベル＋鋼枠。
- 選択: 上記＋濃色チェック。
- rollover: 枠を `bevel_light` 寄りに一段明るく（任意・Metal Ocean のホバー枠ハイライト）。必須でない（§8）。
- disabled: `well_disabled` 地＋枠 `border_disabled`＋マーク `indicator_mark_disabled`、ベベル省略。

### 2.3 measure（`metal_checkbox_look.measureMinSize`）

FlatLaf と **同式**（`CheckBox.zig:161-169`）。Metal 定数（`metal.zig` 内 private const）:

| 定数 | Metal 値 | FlatLaf 値 | 備考 |
|---|---|---|---|
| `CB_BOX_SIZE` | `16` | `16` | 同じ（沈み井戸の四角） |
| `CB_BOX_GAP` | `6` | `6` | 同じ |
| `CB_PADDING_X` / `CB_PADDING_Y` | `4` / `4` | `4` / `4` | 同じ |

min: `width = box + gap + text_w + PADDING_X*2`、`height = max(box, text_h) + PADDING_Y*2`。
CheckBox は true leaf（container/tree_children なし）なので enabler が `min_size` へ焼く（`laf.zig`）。

---

## 3. RadioButton の paint / measure レシピ（確定提案）

FlatLaf（`RadioButton.zig`：`look_vtable` `:41`・`lookPaint` `:187`・`lookMeasureMinSize` `:158`）に倣う。
`metal.zig` に `metal_radio_look` を追加。`*RadioButton` へ戻り CheckBox と同じ状態フラグを読む。

### 3.1 paint

`circle = 16`、`circle_x = PADDING_X`、`circle_y = (sz.height - circle)/2`:

1. **井戸の地**: `fillCircle({circle_x, circle_y, circle, circle})` を `well_bg`／`well_disabled` で。
2. **枠**: `drawCircle` を `indicator_border`（disabled は `border_disabled`）で。
   ※円弧では Button のような per-edge ベベルが描けない（awt に弧の部分描画なし）。Metal の沈み感は
   **枠色のみで近似**する（中身が白＋細い鋼枠＝スクショの見え方と一致）。3D を弧で表現する案は未決（§8）。
3. **中央ドット（selected のとき）**: `fillCircle` を inset 4 で `indicator_mark`（disabled は `indicator_mark_disabled`）。
   FlatLaf の dot（`RadioButton.zig:208-219`）と同じ inset。
4. **ラベル / focus ring**: CheckBox と同じ（色は `rb.color` 尊重）。

`paintOver` は no-op。

### 3.2 measure

FlatLaf 同式（`RadioButton.zig:158-165`）。Metal 定数 `RB_CIRCLE_SIZE=16` / `RB_CIRCLE_GAP=6` / `RB_PADDING=4`（同値）。
`width = circle + gap + text_w + PADDING_X*2`、`height = max(circle, text_h) + PADDING_Y*2`。true leaf。

---

## 4. ComboBox の paint / measure レシピ（確定提案・**ドロップダウン到達が要設計**）

FlatLaf（`ComboBox.zig`：`look_vtable` `:60`・`lookPaint` `:290`・`drawBorder` `:317`・`drawChevron` `:328`・
`measureMinSize` `:208`・**popup**＝`popup_look_vtable` `:73`・`popupLookPaint` `:438`）に倣う。

### 4.1 閉じたフィールド（`metal_combobox_look`）

`*ComboBox` へ戻り `enabled` / `has_focus` / `getSelectedItem()` / `color` / `font` を読む。`sz = self.size`、
矢印スロット幅 `chev = COMBO_CHEVRON_W`（§4.4）:

1. **フィールド地**: `fillRect({0,0,sz.w,sz.h})` を `well_bg`（disabled は `combo` 用 `well_disabled`）。
2. **フィールド枠**: `drawBorder`（4 strip・`ComboBox.zig:317`）を `indicator_border`（focus 時は `focus_ring` 寄せも可）。
3. **選択テキスト**: 左寄せ・縦中央、`cb.color` 尊重（`ComboBox.zig:303-309` と同じ）。
4. **右端のベベル矢印ボタン**（Metal の肝）: スロット矩形 `{sz.w-chev, 0, chev, sz.h}` を **小さな凸ボタン**として描く:
   - `fillGradientRect` を **既存 `body_enabled_*`／`body_disabled_*`**（`bodyGradient` 再利用）で塗る。
   - `drawBevel` 相当の凸 1px リング（上・左 `bevel_light`／下・右 `bevel_dark`）をスロット内に。
   - フィールド本体との境に 1px 区切り（`indicator_border`）。
   - `drawChevron`（`ComboBox.zig:328`）と同じ矩形ストローク▽を `indicator_mark`（disabled は `_disabled`）で中央に。
5. **focus ring**（`has_focus`）: `focus_ring` で `drawRect({1,1,sz.w-2,sz.h-2})`（任意・FlatLaf は枠 tint。§8）。

`paintOver` は no-op。

### 4.2 ドロップダウン（`metal_combobox_popup_look`）＝ **enabler 到達に facet 追加が必須**

**重要・調査結果**: ComboBox の `popup_root` は **standalone Component**（`ComboBox.zig:40`）で、show 時に
`w.overlays.add(&self.popup_root, ...)` で overlay へ遅延 attach される（`:241`）。これは Menu の popup_root と同型
（`laf_enabler.md` §3.7）。だが **ComboBox は `detached_look_roots` を設定していない**（Menu は `Menu.zig:109` で設定済み）。
よって **現状の `applyLook` walk は popup_root に届かず、ドロップダウンは Metal 化されない**（FlatLaf のまま残る）。

→ ドロップダウンまで Metal を届けるには **framework 側に小さな追加が要る（Codex 実装指示）**:

1. **`ComboBox.create` で `detached_look_roots` を設定**する。`Menu.zig:109` と同型:
   `cb.component.detached_look_roots = .{ .count = detachedLookRootCount, .at = detachedLookRootAt };`
   （`count` は常に 1、`at(0)` は `&cb.popup_root` を返す private fn を `ComboBox.zig` に追加）。
   これで enabler walk が `ComboBox.component → popup_root` へ降りる（§3.7 の (a) 静的エッジ方式）。
2. **`popup_look_vtable` を `pub` にする**（現状 private const・`ComboBox.zig:73`）。表が
   `&ComboBox.popup_look_vtable` を鍵に引くため公開が必須（vtable ポインタが型タグ。`laf_enabler.md` §2.2）。
3. これらは **FlatLaf の挙動を変えない**: `detached_look_roots` は LAF walk だけに効き（automation 木・描画経路は不変）、
   vtable を pub にするのは無害。

popup の Metal 描画（`*ComboBox` へ `@fieldParentPtr("popup_root", self)` で戻る。`ComboBox.zig:439` と同型）:

- **地**: `well_bg` で全面 `fillRect`。
- **項目**: `itemHeight`（＝`line_height + ITEM_PADDING_Y*2`。private なので `metal.zig` で定数再実装）ごとに、
  hover 行（`cb.hovered_index == idx`）は `select_bg` で塗り `select_text`、非 hover は `cb.color`。`ComboBox.zig:448-459` と同型。
- **外枠**: `indicator_border` の 1px リング（`ComboBox.zig:461-466` と同型）。

`paintOver` は no-op。**`measureMinSize` は `{0,0}` を返す**（popup サイズは `show` が手で決める。`ComboBox.zig:471` と同じ）。
enabler walk は popup_root を true leaf 扱いして re-measure するが、`{0,0}` 書き込みは show が上書きするため無害。

### 4.3 状態別

- 閉じ通常: 白フィールド＋鋼枠＋右端 凸グラデ矢印ボタン＋濃▽。
- focus: focus ring（任意）。
- disabled: `well_disabled` フィールド＋矢印ボタン disabled グラデ＋`indicator_mark_disabled` ▽。
- 開（ドロップダウン）: 白リスト＋hover 行 `select_bg`/`select_text`＋鋼外枠。

### 4.4 measure（`metal_combobox_look.measureMinSize`）

FlatLaf 同式（`ComboBox.zig:208-220`）。Metal 定数:

| 定数 | Metal 値 | FlatLaf 値 | 備考 |
|---|---|---|---|
| `COMBO_PADDING_X` / `COMBO_PADDING_Y` | `8` / `4` | `8` / `4` | 同じ |
| `COMBO_CHEVRON_W` | `18` | `16` | 矢印ボタンをやや太く（鋼ボタン感） |

`width = max_item_w + PADDING_X*2 + CHEVRON_W`、`height = line_height + PADDING_Y*2`。ComboBox.component は true leaf。

---

## 5. 表（table）の拡張（確定提案）

現状 `metal.zig` は `button_table`（Button 1 件）＋ `buttonTable()`（`metal.zig:57-66`）。これを **`metalTable()` に拡張**して
Button＋CheckBox＋RadioButton＋ComboBox（フィールド＋ドロップダウン）を含める。

```zig
const metal_table = [_]laf.RemapEntry{
    .{ .from = &Button.look_vtable,            .to = .{ .vtable = &metal_button_look,        .ctx = &metal_palette } },
    .{ .from = &CheckBox.look_vtable,          .to = .{ .vtable = &metal_checkbox_look,      .ctx = &metal_palette } },
    .{ .from = &RadioButton.look_vtable,       .to = .{ .vtable = &metal_radio_look,         .ctx = &metal_palette } },
    .{ .from = &ComboBox.look_vtable,          .to = .{ .vtable = &metal_combobox_look,      .ctx = &metal_palette } },
    .{ .from = &ComboBox.popup_look_vtable,    .to = .{ .vtable = &metal_combobox_popup_look, .ctx = &metal_palette } }, // 要 pub 化（§4.2）
};
pub fn metalTable() laf.LookTable { return &metal_table; }
```

- **`buttonTable()` は残す**。重複を避けるため `button_table` を別途持たず、`buttonTable()` は
  `metal_table[0..1]` を返す（Button エントリは配列先頭。1 つの backing 配列を共有）。
  既存利用（`widget_metalbutton` 例・Button spec）が壊れない。
- ctx は全エントリ共通で `&metal_palette`（単一パレット）。

---

## 6. showcase の enum 化（確定提案・Codex 実装）

`examples/widget_showcase/main.zig` の `const USE_METAL = false;`（`:9`）＋ `if (USE_METAL) { applyLook(..., buttonTable()) }`
（`:364-365`）を、**enum 選択**へ変える:

```zig
const Laf = enum { flatlaf, metal };
const LAF: Laf = .flatlaf;
// ...
switch (LAF) {
    .flatlaf => {},
    .metal => nimbus.laf.applyLook(&frame.window.container.component, nimbus.laf.metal.metalTable()),
}
```

- **enum は example ローカル**（Zig コアに named-LAF を焼かない。`laf_design.md` §1.2）。
- 既定は `.flatlaf`（applyLook を呼ばない＝現状の見た目）。`.metal` で Group A が Metal になる
  （Button は前段で既に Metal、本フェーズで CheckBox / RadioButton / ComboBox が加わる）。

---

## 7. テスト / デモ計画（確定提案）

### 7a. Metal ゴールデン（snapshot・意図的に新ピクセル）

各 widget の Metal scene を `framework/tests/scenes.zig` に追加（`nimbus.laf.applyLook(root, metalTable())` を paint 前に当てる）。
ゼロピクセル不変は適用されない（FlatLaf と別物の絵＝新規 fixture を意図的に作る）。tolerance はグローバル `TOLERANCE = 1`
（`framework/tests/snapshot_test.zig`。グラデは決定的。Button spec §5a と同じ）。

- **CheckBox**: 未選択 / 選択 / disabled（各 1 枚）。
- **RadioButton**: 未選択 / 選択 / disabled。
- **ComboBox（閉じ）**: 通常 / focus / disabled。
- **ComboBox（開・検討）**: ドロップダウンの Metal 化を突くゴールデン。overlay 機構を起こさず、
  `applyLook` 後に `combobox.popup_root.size` を与えて **`combobox.popup_root.paintAt(&g)` を直接呼ぶ** scene で
  hover 行の `select_bg` まで描く（§4.2 の facet 経由 remap が効いていることを目視で確認）。任意だが推奨。

### 7b. メトリクス＋表の純ロジックテスト（GPU 非依存）

`laf_enabler.md` §5.0 の教訓どおり **`Device.init` ゲート下に置かない**（`awt.Font.init(noto_ttf, 0)` を直接使う）。

- 各 widget を `create`（stub/headless フォント）し、`metal_*_look.measureMinSize` の戻りが Metal 定数（§2.3/§3.2/§4.4）から
  計算した既知値に一致することを assert。
- **表の遷移を assert**: 小さなツリーへ `applyLook(root, metalTable())` し、各 widget の `component.ui.vtable` が
  対応する Metal look に化けたことを確認。
- **ドロップダウン到達の回帰ガード（§4.2 の肝）**: ComboBox を含むツリーへ `applyLook` 後、
  **`combobox.popup_root.ui.vtable == &nimbus.laf.metal.metal_combobox_popup_look`** を assert
  （`detached_look_roots` 経由で popup_root まで remap が届いたことを突く。`laf_enabler.md` のメニュー回帰ガードと同型）。
- `error.SkipZigTest` 経路を踏まないこと。

### 7c. showcase 目視

`widget_showcase` を `const LAF: Laf = .metal;` に切り替えて `run`。CheckBox / RadioButton / ComboBox（開閉とも）の
Metal 見た目を目視確認する。

---

## 8. 未決（解決しない・列挙のみ）

1. **追加パレットの最終 RGBA**: §1 は提案値。showcase 目視で作者が微調整しうる。
2. **rollover 枠ハイライト**: CheckBox/RadioButton の hover 時の枠強調（§2.2）を入れるか。任意演出。
3. **ラジオ円の 3D（沈み）表現**: awt に弧の部分描画が無く、現状は枠色のみで近似（§3.1）。同心円や陰影での沈み表現は将来課題。
4. **インジケータ寸法を Metal 用に縮める**: 本 spec は FlatLaf と同じ 16px（layout 不変重視）。Swing Metal の実寸（〜13px）へ
   寄せるかは未決（縮めると check/dot の inset 調整が要る）。
5. **ComboBox の focus 表現**: focus ring（drawRect）か枠 tint か（§4.1/§4.3）。
6. **トークンのエイリアス整理**: `indicator_border`＝`border`、`indicator_mark`＝combobox の▽色、`indicator_mark_disabled`＝
   `text_disabled` 等、同値トークンを別名で持つ方針（§1）。統合するかは将来のクリーンアップ判断。
7. **命名**: `metal_checkbox_look` / `metalTable` / 各 Metal 定数 / 追加トークン名は仮（`laf_design.md` §6-1 の延長）。

---

## 9. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | スコープ＝CheckBox / RadioButton / ComboBox の 3 種。既存 `metal.zig` のレシピ・helper を再利用（§0） |
| 確定 | MetalPalette に選択系トークン追加（well_bg/disabled・indicator_border/mark・select_bg/text）。矢印 body は既存 body_*+bevel 再利用（§1） |
| 確定 | CheckBox: 白井戸＋**ベベル反転（沈み）**＋鋼枠＋濃チェック（drawCheck 算法を metal.zig へ再実装）。ラベル/focus は FlatLaf 踏襲・色は利用者尊重（§2） |
| 確定 | RadioButton: 白井戸円＋鋼枠＋中央ドット。円弧ベベルは枠色で近似（§3） |
| 確定 | ComboBox 閉: 白フィールド＋鋼枠＋**右端の凸グラデ矢印ボタン**（body_*+bevel 再利用）＋濃▽（§4.1） |
| 確定 | ComboBox 開: **`detached_look_roots` を ComboBox に追加＋`popup_look_vtable` を pub 化**しないと dropdown に Metal が届かない（Codex 実装指示）。白リスト＋select_bg hover 行（§4.2） |
| 確定 | measure は各 FlatLaf 同式＋Metal 定数。全 widget true leaf（enabler が min_size 焼き）。ComboBox CHEVRON は 18 に（§2.3/§3.2/§4.4） |
| 確定 | 表を `metalTable()`（Button＋3 種＝5 エントリ）へ拡張。`buttonTable()` は `metal_table[0..1]` を返して維持（§5） |
| 確定 | showcase を `const Laf = enum{flatlaf,metal}` ＋ switch 化（enum は example ローカル）（§6） |
| 確定 | テスト: (a) Metal golden（各状態・dropdown 開は popup_root.paintAt 直叩きで検討）（b）metrics＋表遷移＋**dropdown 到達**を GPU 非ゲートで assert（c）showcase 目視（§7） |
| 未決 | 追加 RGBA 微調整／rollover 枠／ラジオ 3D／インジケータ縮小／combo focus 表現／トークン別名整理／命名（§8） |
