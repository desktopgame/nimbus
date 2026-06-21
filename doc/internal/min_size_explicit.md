# 明示 min_size を LAF の re-measure から守る（explicit-set フラグ）設計

LAF enabler の `applyLook` が **true-leaf を無条件に re-measure する**ために、アプリが明示設定した `min_size` を
derived 値で潰してしまうバグの解決設計。`laf_design.md` §6（未決 4）と `laf_enabler.md` §7（`setMinSize` 衝突）で
「実需が出たら explicit-set フラグを入れる」と保留していた、その実需に対する **確定提案**。

この doc は `laf_design.md` / `laf_enabler.md` の流儀を継ぎ、**「確定」と「未決」を明確に分ける**。
実装はしない（コードは書かない＝Codex 担当）。

関連: [laf_design.md](laf_design.md)（§2.5 measure 配線・§6 未決 4）、[laf_enabler.md](laf_enabler.md)（§3.4 true-leaf re-measure・§7 未決）、
`framework/src/laf.zig`（`applyLook` / `walk`）、`framework/src/Component.zig`（`setMinSize` / `min_size`）。

---

## 1. バグの実体（確定・pm 裏取り済み）

`applyLook` の `walk` は **true-leaf（`container == null` かつ `tree_children == null`）を、remap 対象か否かに関わらず
無条件で re-measure する**（`laf.zig:28-30`）:

```zig
if (node.container == null and node.tree_children == null) {
    node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx);
}
```

このとき、アプリが公開 `Component.setMinSize`（`Component.zig:341`）で明示設定した `min_size` も、この re-measure が
delegate 由来の intrinsic 値で **上書きして消す**。

- 実害: `examples/widget_showcase` の Slider タブの縦スライダーが `setMinSize(height=180)`（`widget_showcase/main.zig:248`）で
  トラック長を与えているが、LAF=`.metal`（`applyLook` 実行）時だけ height が delegate の intrinsic（約 32）に潰れ、
  トラックが消える。FlatLaf（`applyLook` 非実行）時は明示値が保たれるため正常。
- これは `laf_design.md` §6 未決 4「外部 `setMinSize` と delegate 自動計算の潰し合い」そのもの。
  Swing の `isMinimumSizeSet` 流の **explicit-set フラグ**で解決する。

---

## 2. 設計の前提＝「公開 setMinSize だけがフラグを立てる」（要訂正・監査結果あり）

### 2.1 狙う分離

解決の肝は **2 種類の `min_size` 書き込みを区別する**ことにある:

- **明示（explicit）**: アプリ（利用者）が「この leaf はこの寸法で固定したい」と公開 API で宣言する。
  ＝ `applyLook` の re-measure に **勝つ**べき。
- **派生（derived）**: widget が自分の content・Look メトリクスから intrinsic 最小を算出して焼く。
  ＝ `applyLook` の re-measure で **焼き直してよい**（LAF が変われば寸法も変わるべき）。

理想は「**公開 `setMinSize` 経由＝明示＝フラグを立てる／widget 内部の派生書き込み＝フラグを立てない**」という分離。

### 2.2 監査結果（pm 想定「内部に setMinSize 利用は無い」は**部分的に誤り**）

タスクの前提は「派生 min は widget の **直接フィールド書き込み**（`self.component.min_size = ...`）で入れており、
公開 `setMinSize` を経由しない」だった。**ソースを洗い出した結果、これは半分しか正しくない**
（`laf_design.md` の流儀に従い取り繕わず訂正する）。

直接フィールド書き込みで派生を入れている（＝フラグが立たず、想定どおり re-measure 可能なまま）widget:

- `Button.zig:123` / `Slider.zig:95,101` / `CheckBox.zig:157` / `ComboBox.zig:205` / `RadioButton.zig:154` /
  `Label.zig:51,148` — すべて `self.component.min_size = ...` の直接書き込み。**想定どおり**。

ところが **公開 `setMinSize` を内部の派生 min に使っている** widget が実在した:

| 箇所 | leaf 種別 | 用途 |
|---|---|---|
| `List.zig:432`（`syncContentHeight`） | **true-leaf** | 行数 × row_height の content 高さを焼く |
| `TextArea.zig:338`（`refreshMinSize`） | **true-leaf** | `measureMinSizeFromLook` の結果を焼く（wrap 対応の派生） |
| `Table.zig:158`（`TableHeader.create`） | **true-leaf** | header の `totalWidth × HEADER_HEIGHT` |
| `Table.zig:561,563,1168` | **true-leaf** | body / header の content 寸法 |
| `ScrollPane.zig:537,633` | **container（非 leaf）** | viewport / row_header の寸法 |

→ つまり **List / TextArea / Table / TableHeader は true-leaf なのに公開 `setMinSize` で派生 min を入れている**。
ここで「公開 `setMinSize` がフラグを立てる」だけを実装すると、**これらの派生書き込みまで `explicit` と誤認**し、
`applyLook` の re-measure から外れてしまう。

帰結（なぜ放置できないか）:

- 現状は List / TextArea / Table 用の Metal delegate がまだ無い（Metal 表は Button 系・選択系のみ）ので、
  re-measure を外しても **当面は無害**（remap されない leaf を re-measure しても idempotent なため）。
- だが **潜在バグ**: 将来これらに Metal Look を足して remap 表へ載せた瞬間、フラグのせいで re-measure が走らず、
  Metal メトリクスを反映しない FlatLaf 寸法のまま凍結する。§1 と同じ「LAF で寸法が古いまま潰れる」事故を
  別 widget で再生産する。
- ScrollPane の 2 箇所は **container**（`ScrollPane.zig:86,114` で `container` を持つ）なので `applyLook` の
  re-measure 対象外（§3.4 true-leaf 限定）。フラグが立っても re-measure には影響しないが、**意味としては派生**なので
  下記の派生経路へ寄せておくのが一貫する（必須ではない・§4.3）。

### 2.3 解決＝派生 min は非フラグ経路に分離する（確定）

「公開 `setMinSize` ＝明示」を成立させるため、**widget 内部の派生 min 書き込みをフラグの立たない経路へ移す**。

- 新設する内部ヘルパ（名前は仮 `setMinSizeDerived` / `setMinSizeInternal`）は **`min_size` 更新＋`markLayoutDirty`**
  だけ行い、**フラグは立てない**。公開 `setMinSize` が持つ通知副作用（`Component.zig:342-344` の dirty 伝搬）を
  保ったまま、explicit マークだけ外す。
- 上記監査表のうち **true-leaf の派生呼び出し**（List / TextArea / Table / TableHeader）を、この内部ヘルパへ置換する。
  これで「公開 `setMinSize` を呼ぶのは利用者だけ＝フラグは明示にのみ立つ」が成立する。
- 直接フィールド書き込み勢（Button / Slider 等）は **元から非フラグ**なので変更不要。
- 代替案として「直接フィールド書き込み＋手動 `markLayoutDirty`」でも良いが、派生 min を入れる箇所が複数あるため
  **専用ヘルパに集約する方が意図が明示的**で、将来の派生書き込みも自然に非フラグへ誘導できる（こちらを推奨）。

---

## 3. 確定提案

### 3.1 フラグ（確定）

`Component` に boolean フィールドを 1 つ足す。

```zig
// 名前は仮。Component の他の opt-in 状態と同じ並びに置く。
min_size_explicit: bool,   // default false（Component.init で false 初期化）
```

- `Component.init`（`Component.zig:257-`）で `false` 初期化。
- 公開 `Component.setMinSize`（`Component.zig:341`）で `true` を立てる（§3.2）。
- 派生経路（§2.3 の内部ヘルパ・直接フィールド書き込み）では触らない＝`false` のまま。

### 3.2 setMinSize の変更（確定）

```zig
pub fn setMinSize(self: *Component, s: Size) void {
    self.min_size_explicit = true;          // ← 追加：公開 API 経由は常に明示
    if (Size.eql(self.min_size, s)) return; // 既存の早期 return は値の更新分のみ
    self.min_size = s;
    self.markLayoutDirty();
}
```

- **フラグ立ては早期 return より前**に置く。同値で値更新を省く場合でも「明示した」事実は記録する
  （`setMinSize(現在値)` を明示の宣言として使うケースを取りこぼさない）。

### 3.3 applyLook の変更（確定）

`laf.zig` の `walk` の re-measure を、**明示済みならスキップ**する条件へ変える（`laf.zig:28-30`）:

```zig
if (node.container == null and node.tree_children == null and !node.min_size_explicit) {
    node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx);
}
```

- remap（vtable 差し替え）は **明示の有無に関わらず行う**（見た目は LAF に従う）。スキップするのは
  re-measure（寸法の焼き直し）だけ。これで「Metal の絵にはなるが、寸法はアプリ指定を保つ」が両立する。

### 3.4 セマンティクス＝明示は「絶対勝ち」（確定）

明示は **re-measure を丸ごとスキップ**する＝ derived 値との `@max` 合成（floor）ではなく、**完全に明示値を採る**。

- 根拠: leaf には container のような layout 合成が無く、`Component.getMinSize` は `min_size` をそのまま返す
  （`Component.zig:337-339`）。leaf の `min_size` は「最終値」であって floor ではない。よって明示＝上書き禁止が素直。
- **container は無改修**: container の `getMinSize` は元々 `@max(component.min_size, layout 由来)` で
  明示 floor と layout を同居させる（`Container.zig:148-152`、`laf_enabler.md` §3.4）。かつ container は
  true-leaf でないため re-measure 対象外。**フラグが要るのは leaf だけ**という `laf_design.md` §6-4 の見立てどおり。
- **両軸が固定される点（既知の帰結）**: `setMinSize` は `Size`（幅・高さ両軸）を取るため、明示＝両軸とも凍結。
  showcase の縦スライダー（`widget_showcase/main.zig:248`）は `width = getMinSize().width`（applyLook 前の
  FlatLaf 派生幅）・`height = 180` を渡すので、re-measure スキップにより **幅も applyLook 前の派生値で固定**される。
  Slider の幅は LAF でほぼ不変なので実害は無いが、「片軸だけ明示・他軸は LAF 追従」は表現できない。
  per-axis フラグは将来課題（§6）。

---

## 4. 影響範囲（確定）

### 4.1 framework コア

- `Component`: フィールド 1 つ追加（§3.1）＋`setMinSize` 1 行追加（§3.2）。
- `laf.zig`: `walk` の re-measure 条件に `!min_size_explicit` を足す（§3.3）。

### 4.2 派生 min を公開 setMinSize で入れている true-leaf（**要置換**）

§2.2 の監査で出た以下を、非フラグ経路（§2.3 の内部ヘルパ）へ置換する:

- `List.zig:432`（`syncContentHeight`）
- `TextArea.zig:338`（`refreshMinSize`）
- `Table.zig:158,561,563,1168`（`TableHeader.create` 他）

置換しないと §2.2 の潜在バグ（将来 Metal 化で寸法凍結）が残る。

### 4.3 派生だが re-measure 対象外（任意・一貫性のため）

- `ScrollPane.zig:537,633`: container 上の派生なので re-measure には影響しないが、意味は派生。
  内部ヘルパへ寄せると「公開 `setMinSize` ＝利用者専用」が完全になる（必須ではない）。

### 4.4 明示として正しい呼び出し（**変更不要・フラグが立つのが正**）

利用者（example / アプリ）の `setMinSize` はすべて明示。フラグが立つのが正しい挙動:

- `widget_showcase/main.zig:30,50,91,248`、`widget_keyboard/main.zig:115,178`、`widget_scroll/main.zig:32`、
  `widget_layoutcost/main.zig:70` 等。これらは re-measure に勝つべき明示なので、§3.2 の変更で自動的に守られる。
- `BoxLayout.zig:227,232` は **テスト fixture 内**の `setMinSize`。明示扱いで問題なし（テストの leaf を固定したい意図と一致）。

---

## 5. テスト方針（確定）

`laf_enabler.md` §5.0 の **GPU 非ゲート純ロジック**作法を踏襲する。

### 5.1 純ロジック回帰（主・GPU 非依存・真正ガード）

`framework/tests/laf_test.zig` のフェイク Look 作法で、**既知サイズを返す `measureMinSize`** を持つフェイク delegate を用意し、
true-leaf を 2 つ（明示済み・未明示）並べて `applyLook` を当て、次を assert する:

- **明示した leaf**: `setMinSize(X)` 済みの leaf が、`applyLook` 後も `min_size == X` を保つ（re-measure されない）。
- **未明示の leaf**: 同じフェイク表で remap される未明示 leaf は、`applyLook` 後に `min_size ==` フェイク既知サイズ
  （従来どおり re-measure される）。
- **真正ガード**: §3.3 の `!min_size_explicit` を外すと **前者の assert が落ちる**こと（フラグが効いている証拠）を
  担保する。GPU 非依存（`error.SkipZigTest` 経路を踏まない・`laf_enabler.md` §5.0）。

加えて、§2.2 の監査回帰として **派生経路が非フラグであること**も突けるとなお良い:
内部ヘルパ（§2.3）で min を入れた true-leaf は `min_size_explicit == false` のままで、`applyLook` で re-measure される。

### 5.2 showcase の縦スライダー（従・統合確認）

`widget_showcase` の縦スライダーが LAF=`.metal`（`applyLook` 実行）でも **height=180 を保つ**ことを確認する。
Metal ゴールデン（あれば）での目視、または既存 showcase の目視で足りる。GPU をゲートに純ロジックの主検証を縛らない。

---

## 6. 未決（解決しない・列挙のみ）

- **解除（unset）**: `setMinSize(null)` 相当でフラグを下ろし「LAF に再委譲する」操作は **今回スコープ外**。
  nimbus の `setMinSize` は `Size` を取り null を持たないため、解除 API の形（別メソッド `clearMinSize` 等）も含め未決。
- **per-axis 明示**: §3.4 のとおり明示は両軸を凍結する。「幅は LAF 追従・高さだけ固定」のような片軸明示は
  v1 では表現しない（フラグを軸別 2 bit に拡張するか等は未決）。
- **色 override への横展開**: 本件は `min_size` フィールドに対する explicit-set フラグ。pm メモの
  「LAF による色 override と origin マーカー」も **同じパターン（フィールド別フラグ）**で将来解ける見込み
  （アプリが明示設定した色を LAF が上書きしない）。ただし color は `min_size` と違い container/leaf 双方に効くため、
  フラグの置き場・floor か上書きかの選択は本件と別途。今回は **min_size のみ**確定し、色は将来（§7 のパターン再利用）。
- **命名**: `min_size_explicit` / 内部ヘルパ名（`setMinSizeDerived` 等）は仮。確定不要で進めてよい。

---

## 7. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | バグ＝`applyLook` の true-leaf 無条件 re-measure が明示 `min_size` を delegate 値で潰す（§1） |
| 訂正 | pm 想定「内部に公開 `setMinSize` 利用なし」は誤り。List / TextArea / Table / TableHeader が true-leaf で公開 `setMinSize` を派生に使用（§2.2） |
| 確定 | `Component.min_size_explicit: bool`（default false）を追加。公開 `setMinSize` で true（§3.1-3.2） |
| 確定 | `applyLook` の re-measure を `... and !min_size_explicit` でガード。remap は明示の有無に関わらず行う（§3.3） |
| 確定 | 明示は「絶対勝ち」＝re-measure スキップ（floor ではない）。container は従来どおり floor 同居で無改修（§3.4） |
| 確定 | 派生 min は非フラグ内部ヘルパへ分離。true-leaf の List / TextArea / Table を置換（§2.3・§4.2） |
| 確定 | テストは GPU 非ゲート純ロジックで「明示は保持・未明示は re-measure」、フラグを外すと前者が落ちる真正ガード（§5.1） |
| 未決 | unset（解除）API ／per-axis 明示 ／色 override への横展開 ／命名（§6） |
</content>
</invoke>
