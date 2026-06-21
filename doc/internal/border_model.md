# 枠（Border）モデル リファクタ設計 spec

枠（外周フレーム）の **所有を作者の規則で整理する** リファクタの設計 spec。
コントロール系・スクロール内容系・ScrollPane・Border デコレータで枠の扱いを **意図的に変える**（統一はしない）。
FlatLaf レベル（細線 `theme.border`）の所有整理までを対象とし、Metal の沈みベベル枠は Group C へ橋渡しする。
枠を持つ側（Border / ScrollPane）は **子孫フォーカスで枠色を accent に変える focus 反応枠** を持つ（§5）。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。

このリファクタはスパイク `feat/border-spike`（`framework/src/Border.zig`）で「ラッパが枠を固定できる」を検証済み。
本 doc はその検証結果を踏まえ、スパイクを **正式版として本ブランチへ取り込む** 方針も含めて確定提案する。
スパイク branch（およびそのメモ `border_spike_notes.md`）は本 doc に置き換えて破棄する。

関連: [laf_enabler.md](laf_enabler.md)（`applyLook` / `RemapEntry` / automation walk が `container.children` を辿る §3.3.3）、
[laf_metal_range.md](laf_metal_range.md)（§1.3 ScrollBar は ScrollPane の通常 child・Group C で ScrollPane/バーを Metal 化）、
[optimize.md](optimize.md)（描画の部分更新＝dirty rect は別軸・未実装＝§5.2 の前提）、
`framework/src/TextArea.zig`・`framework/src/List.zig`・`framework/src/Table.zig`・`framework/src/ScrollPane.zig`（枠の現状）、
`framework/src/Window.zig`・`framework/src/Component.zig`（focus 機構）、
`framework/src/Border.zig`（スパイク実装）、`framework/tests/scenes.zig`（ゴールデン）。

---

## 0. 背景・確定方針（作者と合意済み・再議論しない）

枠の所有を **統一しない**。意図的に、コントロール系とスクロール内容系で扱いを変える。

- **コントロール系（Button / TextField 等）**: 自前で枠を描く（**現状維持・変えない**）。
  ScrollPane の単一 view にはならないので、枠が中身としてスクロールして消える問題は起きない。
- **スクロール内容系（TextArea / List / Table）**: **自前で枠を描かない**（focus 枠も持たない）。
  背景塗り・padding・カーソル位置・選択ハイライト・ヘッダは維持し、**外周線だけ除去** する。
- **ScrollPane**: **自前で枠を描く**（FlatLaf＝細線 `theme.border`）。
  現在 ScrollPane の `lookPaint`/`lookPaintOver` は no-op（`ScrollPane.zig:497-499`）なので、ここに外周フレームを足す。
- **Border デコレータ**: 素の TextArea/List/Table を枠付きにしたい時や任意グループを囲む時に使う **任意の sugar**。
  単一子・inset 0・`paintOver` で外周線・`PaddingLayout` 流用。スパイクで「ラッパが枠を固定できる」を検証済み。
- **focus 反応枠（作者合意済み・本改訂で格上げ）**: 枠を持つ側（Border / ScrollPane）が **自分の子孫が今フォーカスを持つか** を見て
  枠色を変える（子孫フォーカス時 `theme.accent`／それ以外 `theme.border`）。TextArea から外したフォーカス表示を、
  枠所有側で正しく復活させる（前回 doc が「未決・カーソルのみ」と後回しにした分の格上げ）。機構は §5。

狙い: スクロール内容系が自前枠を持つと、ScrollPane の view になったとき枠が中身と一緒にスクロールして消える。
枠所有を「内容＝持たない／ScrollPane・Border＝持つ」に寄せれば、固定枠が viewport の外側に乗り、この破綻が構造的に消える。
フォーカス表示も枠所有側へ一緒に移すことで、「枠と focus 表示は枠を持つ側が一括して担う」と責務が揃う。

---

## 1. 現状調査の結果（重要・確定事実）

調査の結果、**作業前提と実装の食い違い** が見つかった。`laf_design.md` の流儀に従い取り繕わず明記する。
これによりリファクタの実作業量は当初想定より小さい（枠を実際に持つのは TextArea と、新規追加する ScrollPane だけ）。

### 1.1 TextArea＝唯一、自前で外周枠を描くスクロール内容系（`framework/src/TextArea.zig`）

- `lookPaint`（`:553`）が **4 本の `fillRect` で外周枠** を描く（`:561-564`）。
  色は `:560` で **`has_focus` なら `theme.accent`、非フォーカスなら `theme.border`**（`BORDER_WIDTH = 1`・`:29`）。
- → **TextArea の枠は同時にフォーカス表示でもある**（フォーカスで枠色が accent に変わる）。独立した focus ring は無い。
  枠を除去するとフォーカスの視覚表現が枠から消えるので、**枠所有側（Border / ScrollPane）の focus 反応枠（§5）へ移管** する。
- **content の位置は `PADDING_X = 6` / `PADDING_Y = 4`（`:23-24`）に依存し、`BORDER_WIDTH` に依存しない**。
  行テキストは `PADDING_X` / `PADDING_Y + i*line_h`（`:596,615`）、カーソルは `caretGeom`（`PADDING_X + measureRange` / `PADDING_Y + li*line_h`・`:448-449`）で置かれる。
  → 枠の 4 本（`:561-564`）と色設定（`:560`）を消しても **行位置・カーソル位置・選択・IME は 1px も動かない**（§2.2 の担保根拠）。
- 背景塗り（`:557-558`・`ta.background`）は枠とは別。**残す**。

### 1.2 List＝そもそも自前枠を描いていない（`framework/src/List.zig`）

- `lookPaint`（`:622`）は **背景塗り（`:626-627`・`surface_input`）＋選択ハイライト（`:630-638`・`selection_bg`）＋セル描画（`:640-642`）のみ**。
  外周枠の `fillRect`/`drawRect` は **無い**。
- → **List は枠除去の作業対象にならない**（既に枠なし）。選択ハイライトは枠とは別物で、従来どおり残る。

### 1.3 Table＝そもそも自前枠を描いていない（`framework/src/Table.zig`）

- `lookPaint`（`:794`）は **背景塗り（`:799-800`）＋選択ハイライト（`:802-810`）＋セル描画（`:812-816`）のみ**。外周枠は **無い**。
- ヘッダ（`paintHeader`・`:825`）は **列区切り線（`:842-843`・`border_soft`）とヘッダ下線（`:847-848`・`border_soft`）** を描くが、
  これは **ヘッダ内部の構造線であって外周枠ではない**。枠とは別＝**残す**。
- → **Table も枠除去の作業対象にならない**（既に枠なし）。選択ハイライト・ヘッダは従来どおり残る。

### 1.4 ScrollPane＝枠 look は no-op・レイアウトは viewport とバーを排他矩形に置く（`framework/src/ScrollPane.zig`）

- `lookPaint`（`:497`）・`lookPaintOver`（`:499`）はともに **no-op**＝現在 ScrollPane は枠を一切描かない。
- レイアウト（`layoutDoLayout`・`:366`）: viewport は `{left, top, center_w, center_h}`（`:416`）、
  vbar は右端 `{left+center_w, top, T, center_h}`（`:423`）、hbar は下端 `{left, top+center_h, center_w, T}`（`:427`）。
  `T = ScrollBar.THICKNESS`（14）。**バーはペイン bounds の右端・下端に接して置かれる**（外側に余白は無い）。
- → 外周枠 `{0,0,W,H}` を上描きすると、viewport の外周 1px とバーの右下端 1px に **重なる**（§4.2 で扱う）。
- view（TextArea 等）は viewport の子＝`view.parent = viewport.component`、`viewport.parent = ScrollPane component`。
  → ScrollPane から見て **focus owner（典型は view）は子孫**になり、§5.3 の子孫判定で拾える。

### 1.5 コントロール系（TextField）は枠を維持（`framework/src/TextField.zig`・参考・変更なし）

- `lookPaint`（`:281`）が TextArea と同型の 4 本枠（`:293-296`・色は `:292` で focus→accent / 非 focus→border）を描く。
- これは **現状維持**（コントロール系は自前枠を持つ＝§0）。本リファクタでは触らない（focus 反応も自前のまま）。

### 1.6 focus 機構の現状（focus 反応枠の前提・`Window.zig` / `Component.zig`）

- フォーカス保持者は `Window.focus_owner`（`Window.zig:93`）。**変更は全経路が `Window.requestFocusFor`（`:495`）を通る**
  （初期フォーカス `:418`／クリック `:787`／プログラム要求 `:566,636`）。`requestFocusFor` は old/new owner へ FocusEvent を配り、
  両者を `repaint()` する（`:499-508`）。
- `Component.FocusController`（`Component.zig:542`）は Window が root に property として設置する橋渡し（framework↔Window の循環回避）。
  **現状は `request_focus_for`（設定）だけで、現 owner を引く getter が無い**＝任意 component から現フォーカスを知る口が無い（§5.1 で足す）。
- **描画は全ツリー再描画**: `Window.redraw`（`:379`）は `paint_dirty` が立てば `container.component.paintAt(&g)`（`:447`）で **ツリー全体を描く**。
  `Component.repaintRect` は矩形を捨てて `paint_dirty` を立てるだけ（`Component.zig:596-599`）＝**部分再描画（dirty rect）は未実装**
  （`optimize.md:106`「描画の部分更新はレイアウトとは別軸」）。これが §5.2 の「祖先 repaint は今は不要」の根拠。

---

## 2. TextArea の枠除去（確定提案）

### 2.1 除去箇所

`TextArea.lookPaint`（`:553`）から **外周枠の描画だけ** を消す。

- 削除: 枠色の設定 `:560`（`g.setColor(if (ta.has_focus) accent else border)`）と、4 本の `fillRect` `:561-564`。
- 残す: 背景塗り `:557-558`（`ta.background`）／可視行のクリップ計算（`:571-591`）／選択ハイライト（`:599-608`）／
  行テキスト（`:610-616`）／IME preedit（`:619-639`）／カーソル（`:641-646`）。`lookPaintOver`（`:649`・no-op）も不変。
- measure（`lookMeasureMinSize`・`:321` 周辺）は枠と無関係＝不変。`min_size` は変わらない（layout 不変）。
- **`has_focus` フラグ自体は残す**（FocusEvent で更新・カーソル点滅に使う）。枠を消すだけで、フォーカス追跡はやめない。

### 2.2 content がずれないことの担保

§1.1 の通り行・カーソル・選択・IME の座標は **すべて `PADDING_X`/`PADDING_Y` 基準**で、`BORDER_WIDTH` を参照しない。
枠 4 本は描画専用で、レイアウトにも座標計算にも寄与していない。よって除去で **content は 1px も動かない**。
回帰ガードは §8 の新規ゴールデン（枠ありの旧版が無いため、新規 fixture で「枠なし＋カーソル位置」を固定）で行う。

### 2.3 フォーカス表示は枠所有側へ移管（確定・前回からの方針変更）

TextArea のフォーカスは現状 **枠色（accent）でのみ** 表現される（§1.1）。前回 doc は「v1 はカーソルのみ・focus 追従枠は未決」としたが、
本改訂で **focus 反応枠（§5）として枠所有側で正しく復活させる** 方向に格上げ（作者合意済み）。

- 素の TextArea を **Border で包めば**、フォーカスで Border 枠が accent になる（§5.3 / §6）。
- TextArea を **ScrollPane に入れれば**、フォーカスで ScrollPane 枠が accent になる（§5.3 / §4.1）。
- TextArea 自身は枠も focus 枠も持たない（所有を Border / ScrollPane に完全移管）。カーソル点滅は従来どおり残る（補助表示）。

---

## 3. List / Table＝変更なし（確定）

§1.2 / §1.3 の通り List・Table は **既に外周枠を描いていない**。よって枠除去の作業は **無い**。

- 選択ハイライト（`selection_bg`）は枠とは別＝そのまま。
- Table のヘッダ内部線（列区切り・ヘッダ下線・`border_soft`）は枠ではない構造線＝そのまま。
- これらを ScrollPane に入れたとき、外周枠は ScrollPane が描く（§4）。素置き（ScrollPane 無し）では枠は付かない＝
  素の List/Table に枠が欲しければ Border デコレータで囲む（§6）か ScrollPane に入れる。

---

## 4. ScrollPane の枠追加（確定提案）

### 4.1 描く場所＝`lookPaintOver`・色は focus 反応（確定）

外周フレームは **`ScrollPane.lookPaintOver`（`:499`）に実装** する（現在の no-op を置き換える）。理由:

- `Component.paintAt` は **`paint` → 子描画 → `paintOver`** の順（`laf_enabler.md` §0・`Component.zig` の 2 フェーズ paint）。
  枠は「viewport・バーの **外周を囲む固定フレーム**・子の上に 1px」なので、**子の後に描く `paintOver` が素直**。
- `lookPaintOver` は ScrollPane 自身の座標系（`{0,0,W,H}`）で描く。viewport のスクロールクリップは viewport の **子**にしか効かないため、
  ScrollPane の `paintOver` で描く枠は **クリップされず・スクロールで動かない**（Border デコレータが固定枠を出せるのと同じ原理）。
- **色は focus 反応**（§5.3）: 子孫にフォーカスがあれば `theme.accent`、無ければ `theme.border`。4 本の `fillRect`（上・下・左・右）。
  TextArea が消したのと同じ枠＋focus 表示を、所有者を ScrollPane に移して再現する。

### 4.2 枠とバー/viewport の重なり＝**1px overpaint・レイアウト inset しない**（確定判断・理由を明記）

外周枠 `{0,0,W,H}` は viewport の外周 1px とバーの右下端 1px に重なる（§1.4）。2 案を比較し **overpaint を採る**:

- **採用＝overpaint（レイアウト変更なし）**: `paintOver` で `{0,0,W,H}` に 1px 枠を上描きするだけ。
  viewport・バーの bounds は不変＝**scroll extent / view measure / バー幾何が一切変わらない**。枠はバー右下端の 1px に重なるが、
  バーは 14px 幅なので外端 1px の被りは装飾上無視できる。これは **スパイクの Border デコレータが採った inset 0（同サイズ＋外周上描き）と同じ判断**で、最小破綻。
- **不採用＝レイアウト inset（Swing 忠実）**: `layoutDoLayout` を枠太さぶん inset し、viewport・バーを枠の内側に収める。
  Swing JScrollPane は枠が最外周・バーは内側でこちらが忠実だが、**viewport が 2px（各軸）縮み、extent・view 再measure・バー thumb 長が変わって全 ScrollPane ゴールデンの構図が動く**。
  破綻が大きく、FlatLaf レベルの枠所有整理という今回の目的に対して過剰。
- → **overpaint を確定**。バーが枠に 1px 重なる点は許容（doc 明記）。Swing 忠実な inset は §10 の未決に残す（Group C の Metal 沈みベベルで枠が太くなるなら、そこで inset を再検討する）。

### 4.3 Metal（Group C）との関係（確定・橋渡し）

- ここで足す枠は **ScrollPane 自身の `look_vtable.paintOver`**。`metalTable()`（`laf_metal_range.md` §5）は ScrollPane を remap **しない**ため、
  Metal LAF 適用下でも ScrollPane は **この FlatLaf 枠（focus 反応・`theme.border`/`accent`）をそのまま描く**（バーだけ Metal 化される）。これは現段階では正しい挙動。
- Group C で ScrollPane を Metal 化する際は、`metalTable()` に ScrollPane エントリを足して **この `look_vtable` を Metal 沈みベベル版へ差し替える**。
  枠を `paintOver` に置いたことで、Group C は vtable 差し替えだけで枠の見た目を Metal にできる（§9）。

---

## 5. focus 反応枠の機構（Border / ScrollPane 共通・確定提案）

枠を持つ側が「自分の子孫が今フォーカスを持つか」を見て枠色を変える。必要なのは
**(1) 現フォーカス owner を引く口**（§5.1）と **(2) 子孫判定**（§5.3）。
**(3) フォーカス変化での再描画は現状の全描画モデルで既に成立**（§5.2）＝今は追加機構が要らない。

### 5.1 現フォーカス owner を引く口＝`FocusController` に getter を足す（要・新規追加）

現状 `Component.FocusController`（`Component.zig:542`）は設定側 `request_focus_for` だけで getter が無い（§1.6）。確定提案＝**getter を 1 つ足す**（既存パターンの最小拡張）:

```zig
pub const FocusController = struct {
    user_data: *anyopaque,
    request_focus_for: *const fn (*anyopaque, ?*Component) void,
    current_owner: *const fn (*anyopaque) ?*Component,   // ← 追加
};
```

- Window が install 時（`Window.zig:476` 付近の FocusController 設置）に `current_owner` を **`self.focus_owner` を返す関数**で埋める。
- component 側ヘルパ `pub fn focusOwner(self: *Component) ?*Component` を足す。`requestFocus`/`releaseFocus`（`Component.zig:525`/`:484`）と
  **同型**に parent 鎖を root（`parent == null`）まで辿り、`getTyped(FocusController)` の `current_owner` を呼ぶ。未接続ツリーでは null。

なぜ FocusController 拡張か（他案比較）:

- **案: component→window 直ポインタ helper**: framework↔Window の依存サイクルを避けるための property-bridge（FocusController / DirtyNotify）設計を壊す。不採用。
- **案: root に owner を持つ別 property を新設**: FocusController の getter が実質それ＝重複。不採用。
- **採用＝FocusController 拡張**: `request_focus_for`（write）と対になる `current_owner`（read）が既存の橋渡し 1 個に揃うだけ。最小で一貫。

### 5.2 フォーカス変化時の再描画＝現状の全描画で既に成立（確定・取り繕わず明記）

要件「フォーカス変化で枠所有の祖先が repaint される」を実装にあたり調べた結果、**現状の描画モデルでは追加機構なしで既に成立する**:

- **描画は常に全ツリー再描画**: `Window.redraw`（`Window.zig:379`）は `paint_dirty` が立てば `container.component.paintAt(&g)`（`:447`）でツリー全体を描き直す。
  `repaintRect` は矩形を捨てて `paint_dirty` を立てるだけ（`Component.zig:596-599`）＝**部分再描画（dirty rect）は未実装**（`optimize.md:106`）。
- **フォーカス変化は必ず repaint を起こす**: 全経路が `Window.requestFocusFor`（`:495`）を通り、old / new owner へ `o.repaint()` / `n.repaint()`（`:502,507`）を呼ぶ。
  これが `paint_dirty=true` を立て、次フレームで **全ツリーが再描画**される。
- 帰結: フォーカスが TextArea へ移れば、その変化で `paint_dirty` が立ち、**祖先の ScrollPane / Border の `paintOver` も新しいフォーカス状態（§5.3）で描き直される**。
  当事者だけ repaint しても、レンダラが全描画なので祖先枠は正しく更新される。**v1 では祖先 repaint の追加配線は不要**。
- フォーカス変化ごとに全描画になるが、フォーカス変化は **入力起点・低頻度**（クリック / Tab）なので、`CLAUDE.md` イベントループ方針が禁ずる「毎フレーム全画面描画」には当たらない。許容する。

### 5.3 子孫フォーカス判定（lookPaintOver・確定提案）

Border / ScrollPane の `lookPaintOver` で枠色を決める:

```
const owner = self.focusOwner();                       // §5.1
const lit = owner != null and isSelfOrDescendant(self, owner.?);
g.setColor(if (lit) self.theme.accent else self.theme.border);
// 上下左右 4 本を fillRect で外周に描く
```

- `isSelfOrDescendant(self, owner)`＝owner の `parent` 鎖を辿り `self` に一致するかを見る（`scrollIntoView`/`requestFocus` と同じ parent 走査）。
  一致＝自分の内側にフォーカスがある。helper は `Component` に 1 つ足す（名前は仮 `isAncestorOf` / `containsInTree`・§10 未決）か各 `lookPaintOver` に inline。
- ScrollPane では owner（典型は view の TextArea）が viewport 経由で子孫になる（§1.4）。ScrollBar は focusable でないので「どの focusable 子孫か」は実質 view に一致。
- 色は `accent`（`Theme.zig:21`「focus border」）／`border`（`:31`）。light/dark 両定義あり。TextArea が枠色でやっていた出し分けを、そのまま枠所有側へ移しただけ。

### 5.4 将来 dirty-rect 描画が入ったら（橋渡し・未決送り）

`optimize.md` の「部分再描画（dirty rect）」が実装されると、§5.2 の前提（全描画）が崩れ、owner だけの dirty rect は
**祖先枠（owner の bounds 外の外周 1px）をカバーしない**。そのとき初めて祖先 repaint 機構が要る。2 案を比較し **案A 推奨**:

- **案A（推奨・最小）**: `requestFocusFor` で old / new owner の **parent 鎖を辿り各祖先を `repaint()`**。新型不要。focus 変化時のみ・深さ O(depth)。
- **案B（購読機構）**: `DirtyNotify` 流の focus-change 購読を足し、Border / ScrollPane が購読して自分の枠だけ repaint。配線は surgical だが registry ＋ install/uninstall の購読ライフサイクルが要る。
- v1 は §5.2 の全描画で足りるので **どちらも今は実装しない**。dirty-rect 導入時に案A を入れる（`optimize.md` の部分再描画タスクと一緒に起票）。

### 5.5 Codex 向け実装メモ（触る箇所）

- `Component.FocusController` に `current_owner` フィールド追加（`Component.zig:542`）。
- `Component.focusOwner()` ヘルパ追加（`requestFocus` 近傍・`Component.zig:525`）＋子孫判定 helper（`isAncestorOf` 等）追加 or 各 `lookPaintOver` に inline。
- `Window` の FocusController 設置で `current_owner` を `self.focus_owner` 返却関数で埋める（`Window.zig:476` 付近）。
- `ScrollPane.lookPaintOver`（`:499`）に focus 反応の外周枠（§4.1 / §5.3）。
- `Border.zig` の `lookPaintOver` を focus 反応色に（スパイクは固定色だったので accent/border 出し分けに変更・§6）。
- `TextArea.lookPaint`（`:560-564`）の枠 4 本＋枠色設定を除去（§2）。`has_focus` 追跡は残す。
- `requestFocusFor` の祖先 repaint は **今は触らない**（§5.2 で不要）。dirty-rect 導入時に案A（§5.4）。

---

## 6. Border デコレータの正式化（確定提案）

スパイクの `framework/src/Border.zig` を **本ブランチへ正式に取り込む**（コピー＋整理）。役割は **素のスクロール内容系・任意グループの枠付け**（任意・sugar）。

### 6.1 取り込む実装（スパイク `Border.zig` 準拠＋focus 反応の追加）

- **単一子・inset 0**: `PaddingLayout`（`Insets.zero`）の上に子を 1 つ持ち、子を自分と同サイズに置く。
- **`paintOver` で外周線・focus 反応色**: 上・下・左・右の 4 本を `fillRect`（`thickness` 既定 1）。`lookPaint` は no-op（背景は持たない）。
  **色は §5.3 の focus 反応**（子孫フォーカスで `accent`／それ以外は `setColor` 指定色 or `theme.border`）。
  スパイクは固定色だったので、ここを focus 反応に変えるのが本改訂の追加点。枠は子の上に乗る（子と同サイズ＝外周 1px の重なり。ScrollPane の overpaint と同じ割り切り）。
- **measure パススルー**: `lookMeasureMinSize` は `{0,0}`。inset 0 の `PaddingLayout` が「子サイズ＋inset(=0)」を返すので min/max は実質パススルー。
- **grow 伝播**: `create` 時に子の `getGrowX/Y` を Border 自身へ写す（スパイク実装済み・`Border.create`）。
  これで Border は親レイアウト内で子と同じ伸び方をし、子は inset 0 の content 領域いっぱい（＝Border と同サイズ）に伸びる。

### 6.2 公開（確定提案）

- ヘルパ `Application.border(child) -> *Border`（スパイクで `Application.zig:684` に試作済み）を正式 API とする。
  既定色は `self.theme.border`。利用は `const framed = try app.border(child); try root.add(framed.asComponent());`。
- `nimbus` ルートからの型公開（`pub const Border`）は実装時に既存 widget と同じ流儀でよい（露出の細部は実装判断）。

### 6.3 `Panel.setBorder` との関係（確定・役割分担を明記）

既存の `Panel.setBorder`（showcase の Form/Split タブで使用・`main.zig:105,297,304`）と Border デコレータは **別物**。混同しない:

- `Panel.setBorder`: Panel が **inset = thickness** で子を内側に寄せ、枠と中身が重ならない（枠ぶん content が縮む）。背景も持つ汎用コンテナの装飾。focus 反応は無い。
- Border デコレータ: **inset 0**（子は同サイズ・枠は外周に上描き）。背景を持たない薄いラッパ。focus 反応枠を持つ（§6.1）。
  ScrollPane を包んでも viewport が枠ぶん縮まないため、**既存レイアウトに割り込ませても content 幾何が動かない**のが利点。
- → 「枠ぶん中を詰めたい」＝`Panel.setBorder`、「枠だけ足して中は動かしたくない／focus で光らせたい」＝Border デコレータ、と使い分ける。

---

## 7. showcase の置き換え（確定提案・Codex 実装）

### 7.1 Text タブ＝Border 包みをやめ、ScrollPane の自前枠に置き換え（確定）

スパイクの `buildTextTab` は ScrollPane を Border で包んでいた（`feat/border-spike:examples/widget_showcase/main.zig:230`）。
本番では **ScrollPane が自前で枠を描く（§4）ので Border 包みは不要＝二重枠になるので外す**。

- 変更: `const sp = try app.scrollPane(&area.component);`（grow 設定）→ **そのまま `root` に add**。`app.border(...)` 包みを削除。
  app コードは `scrollPane(area)` のままで、枠は ScrollPane が付ける。TextArea にフォーカスが入れば ScrollPane 枠が accent に光る（§5.3）。

### 7.2 Border の使い方デモ（任意・推奨）

Border の用途を示すため、**素の TextArea（ScrollPane に入れない）を Border で囲むデモ** を Text タブに 1 つ足すとよい。

- 例: 短い 1〜2 行の TextArea を `app.border(area2.asComponent())` で囲んで add。
  「ScrollPane に入れずに枠が欲しい素の内容系は Border で囲む」使い分け（§6.3）＋「フォーカスで Border 枠が accent に光る」（§5.3）を showcase で見せられる。

### 7.3 既定 LAF は変えない

showcase の既定は `.flatlaf` のまま（develop の正しい状態）。Metal 目視は作者が一時的に `.metal` へ切り替える運用（§9・[laf_metal_range.md](laf_metal_range.md) §6）。

---

## 8. ゴールデン更新方針（重要・純加算でない）

これは FlatLaf の **見た目変更**。ゼロピクセル不変（`laf_design.md` §5.1）は **この変更には適用されない**（意図的変更）と明記する。
ただし §1 の調査で判明した通り、**当初想定よりゴールデンの動きは小さい**。実態を正直に列挙する。

### 8a. 既存ゴールデンの実際の動き（調査結果に基づく確定）

`framework/tests/scenes.zig` の全シーンを精査した結果:

| シーン | 構図 | 枠の動き | 判定 |
|---|---|---|---|
| `scroll_pane_bars`（`:576`） | ScrollPane（view＝Panel・**非 focusable**） | 新規に ScrollPane 外周枠が付く。view が focusable でないので色は **`theme.border` 固定**（accent にはならない） | **動く** |
| `metal_scroll_pane_bars`（`:498`） | ScrollPane＋`metalTable()` | 同上（ScrollPane は metal で remap されない＝FlatLaf 枠が付く・§4.3）。色は `theme.border` | **動く** |
| `list_selection`（`:675`） | **素の List**（ScrollPane 無し） | List は元々枠なし（§1.2）＝変化なし | 不変 |
| `table_header_grid`（`:702`） | **素の Table**（ScrollPane 無し） | Table は元々枠なし（§1.3）＝変化なし | 不変 |
| 上記以外 | TextArea を含むシーンは **存在しない** | TextArea 枠除去はどのゴールデンにも影響しない | 不変 |

- **当初の作業前提との差**: 「素置きの TextArea/List/Table を含むゴールデンの枠が消えて動く」は **当てはまらない**。
  TextArea のゴールデンは無く、List/Table は元々枠なし。**動くのは ScrollPane 枠追加による 2 枚だけ**で、いずれも変化は「外周に 1px の `theme.border` 枠が増える」ことのみ（無関係な回帰でない）。
- **focus accent は既存 2 枚には出ない**: view が非 focusable な Panel なので枠は border 色のまま。focus accent の検証は §8b の新規 focus 付きシーンで行う。

### 8b. 変更の意図をカバーする新規 fixture（確定提案）

既存ゴールデンでは「枠所有の移動・除去」「focus 反応」の意図が十分カバーされない。回帰ガードのため **新規シーンを追加** する（`framework/tests/scenes.zig`）。
focus 付きシーンは、scene の root に **FocusController スタブ**（`current_owner` が指定 owner を返す）を設置し、対象 component を owner にしてから paint する（GPU 非依存・§8d）。

1. `text_area_framed_in_scroll_pane`（必須）: TextArea を ScrollPane の view にした構図・**非フォーカス**。
   枠が ScrollPane 外周に固定で付き（`theme.border`）、TextArea 本体には枠が無いことを固定。スクロール位置をずらしても枠が動かない（§4.1）担保。
2. `text_area_framed_in_scroll_pane_focused`（必須）: 同じ構図で **TextArea を focus owner にする**。ScrollPane 枠が **accent** になることを固定（§5.3 の focus 反応の絵）。
3. `text_area_plain`（推奨）: 素の TextArea を直接描く。**枠が無い・カーソルと行が PADDING 基準の位置にある**ことを固定（§2.2 の content 不動の回帰ガード）。
4. `text_area_in_border`（任意）: 素の TextArea を Border で囲む（§6）。Border 枠が固定で出ることを固定。focused 版を足せば Border の accent も押さえられる。

新規 fixture は意図的に新ピクセル（ゼロ不変は不適用）。tolerance はグローバル `TOLERANCE = 1`（`framework/tests/snapshot_test.zig`・整数構図で決定的）。

### 8c. 再生成手順とレビュー観点

- 再生成: シーン追加・描画変更後は `zig build update-snapshots`（awt / framework 両方の fixture を一括再生成・`test.md` §fixture ライフサイクル）。
- 確認: `git diff framework/tests/fixtures/` で差分を目視。**レビューで各変化が「枠の移動／除去／focus 色」だけであること**を確認:
  - `scroll_pane_bars` / `metal_scroll_pane_bars`: 差分は **外周 1px の `theme.border` 枠が増えただけ**（viewport 内容・バー位置・サイズは不変。overpaint なので幾何不変＝§4.2）。
  - 新規シーン: 初回は fixture が無いので現結果がそのまま書き込まれる（人間が目視確認してから commit・`test.md` §96-97）。focused 版は枠色が accent であることを目視。
- ゼロピクセル不変は **適用しない**（意図的な見た目変更）。ただし「動くのは上表の範囲＋新規シーンだけ・他シーンは 1px も動かない」ことは守る（無関係な回帰の検知）。

### 8d. focus 反応の純ロジックテスト（GPU 非依存・確定提案）

`laf_enabler.md` §5.0 の教訓どおり `Device.init` ゲート下に置かない。focus 色判定はフォントも GPU も要らない:

- 木を `Container` / `Border` / ScrollPane で組み、root に **FocusController スタブ**（`current_owner` が可変の owner を返す）を property 設置する。
- **子孫フォーカス判定**: owner を子孫（view）に設定 → `border.focusOwner()` が view を返し、`isSelfOrDescendant(border, view)` が true を assert。
  owner を null / 木の外の別 component に設定 → false を assert。これが「accent か border か」の分岐そのもの。
- **getter の経路**: `focusOwner()` が parent 鎖を root まで辿って `current_owner` に届くこと（未接続ツリーで null）を assert。
- フォーカス変化 → repaint（§5.2）は現状 Window の全描画依存で、Window は `Device.init` ゲート下。ここは純ロジックでは突かず、§8b の golden（focused / 非focused 2 枚の差）で担保する。

---

## 9. Group C への橋渡し（確定）

本リファクタは FlatLaf レベルで **枠所有と focus 表示を正す土台**。Metal の枠表現は Group C で乗せる:

- **ScrollPane の Metal 沈みベベル枠**: `metalTable()` に ScrollPane エントリを足し、§4 の `look_vtable`（FlatLaf 細線・focus 反応 paintOver）を
  Metal 沈みベベル版 `paintOver` へ差し替える。枠を `paintOver` に置いた（§4.1）ので vtable 差し替えだけで済む。focus 反応をベベル色でどう出すかは Group C で詰める。
  §4.2 の overpaint vs inset は、ベベルが太いなら inset を再検討（§10 未決）。
- **TextArea / List / Table の Metal look**: 枠なし前提（本リファクタで内容系から枠が外れている）で、背景・選択・セルだけ Metal 化する縦スライス。
- **Border デコレータの Metal ベベル**: 既定 FlatLaf 線（§6）を Metal ベベルに替える（任意）。

いずれも本リファクタが「内容系は枠なし・枠と focus 表示は ScrollPane / Border が所有」を確定させていることが前提になる。

---

## 10. 未決（解決しない・列挙のみ）

1. **focus 反応の opt-out**: すべての ScrollPane / Border を focus 反応にするか、opt-out（focus で光らせない固定枠）を持たせるか。v1 は一律反応。要望が出たらフラグ追加を検討。
2. **dirty-rect 導入時の祖先 repaint**: v1 は全描画で成立（§5.2）。`optimize.md` の部分再描画が入ったら案A（祖先 parent 鎖 repaint・§5.4）を入れる。それまで保留。
3. **ScrollPane 枠の overpaint vs inset**: v1 は overpaint（§4.2）。Group C の Metal 沈みベベルで枠が太くなるなら、バー/viewport を枠ぶん inset する忠実版を再検討。
4. **命名**: `FocusController.current_owner` / `Component.focusOwner` / 子孫判定 helper（`isAncestorOf` 等）／`Application.border` / `nimbus.Border` は仮（`laf_design.md` §6-1 の命名未決の延長）。
5. **Border の Metal ベベル / focus accent のベベル表現**: §9 の通り Group C で詰める。
6. **素の List/Table に既定枠を付けるか**: 現状は付けない（枠が欲しければ ScrollPane か Border）。既定で枠付きにする要望が出たら別途。

---

## 11. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | 枠所有を統一しない。コントロール系＝自前枠維持／内容系＝枠なし／ScrollPane・Border＝自前枠＋focus 反応（§0） |
| 訂正 | スクロール内容系で **自前枠を描くのは TextArea だけ**。List/Table は元々枠なし＝枠除去の作業対象外（§1.2/§1.3） |
| 確定 | TextArea は枠 4 本（`:561-564`）＋枠色設定（`:560`）を除去。背景・content・選択・IME・カーソルは残す。content は `PADDING` 基準で **1px も動かない**。`has_focus` 追跡は残す（§1.1/§2） |
| 確定 | TextArea のフォーカス表示は枠所有側（Border / ScrollPane）の focus 反応枠へ移管（前回の「カーソルのみ・未決」から格上げ）（§2.3） |
| 確定 | List/Table は **変更なし**。選択ハイライト・Table ヘッダ内部線（`border_soft`）は枠と別＝残す（§3） |
| 確定 | ScrollPane の枠は `lookPaintOver`（`:499`）に 1px・**focus 反応色**（accent/border）の 4 本フレーム。paint→子→paintOver で固定枠が viewport クリップ外に乗る（§4.1） |
| 確定 | 枠とバー/viewport は **1px overpaint・レイアウト inset しない**（最小破綻）。バー右下端 1px の被りは許容。Swing 忠実 inset は未決（§4.2） |
| 確定 | focus owner を引く口＝`FocusController` に `current_owner` getter を追加＋`Component.focusOwner()` ヘルパ（parent 鎖を root へ）。他案（window 直参照／別 property）は不採用（§5.1） |
| 確定 | フォーカス変化での祖先 repaint は **現状の全ツリー再描画で既に成立**（`requestFocusFor`→`repaint`→`paint_dirty`→全描画）。v1 は追加配線不要（§5.2） |
| 確定 | 子孫フォーカス判定＝owner の parent 鎖に self があるか。あれば accent・なければ border を `lookPaintOver` で出し分け（§5.3） |
| 確定 | metal は ScrollPane を remap しない＝Metal 下でも ScrollPane は FlatLaf 枠（focus 反応）を描く。Group C で vtable 差し替えにより Metal 沈みベベル化（§4.3/§9） |
| 確定 | スパイク `Border.zig` を正式取り込み＋`lookPaintOver` を focus 反応色に。単一子・inset 0・grow 伝播。`Application.border(child)` を公開（§6） |
| 確定 | Border（inset 0・背景なし・focus 反応）と `Panel.setBorder`（inset=thickness・背景あり・focus 無反応）は役割分担。混同しない（§6.3） |
| 確定 | showcase Text タブは Border 包みを外し ScrollPane 自前枠へ（二重枠回避）。素 TextArea を Border で囲むデモを任意追加。既定 `.flatlaf`（§7） |
| 確定 | 動く既存ゴールデンは `scroll_pane_bars`・`metal_scroll_pane_bars` の 2 枚のみ（外周 1px 増・色は border 固定＝view 非 focusable）。List/Table/TextArea のゴールデンは不変 or 不在（§8a） |
| 確定 | 新規 fixture: `text_area_framed_in_scroll_pane`（非focus・必須）／`_focused`（accent・必須）／`text_area_plain`（推奨）／`text_area_in_border`（任意）。`zig build update-snapshots` で再生成。ゼロピクセル不変は不適用（§8b/§8c） |
| 確定 | focus 反応の純ロジックテストは GPU 非ゲートで子孫判定＋getter 経路を assert。repaint は golden（focused/非focused 差）で担保（§8d） |
| 確定（実装メモ） | 触る箇所＝`FocusController`+`focusOwner`+子孫 helper（Component）／`current_owner` 設置（Window）／ScrollPane・Border の `lookPaintOver`／TextArea 枠除去。`requestFocusFor` の祖先 repaint は今は触らない（§5.5） |
| 未決 | focus 反応 opt-out／dirty-rect 導入時の祖先 repaint（案A）／overpaint vs inset の Group C 再検討／命名／Border の Metal ベベル／素 List/Table の既定枠（§10） |
