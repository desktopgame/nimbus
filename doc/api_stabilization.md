# api-stabilization（計画 / 裁定）
難関機能（IME / セルレンダラー / セルエディター / DnD）が一通り実装できたので、API を固める安定化フェーズに入った。破壊的変更は許容する。
このドキュメントは、`examples/widget_*` のブラインドレビュー（前提知識ゼロの新規利用者視点 = 公開 API の窓口としての評価）で出た横断的指摘に対する**作者の裁定**を記録する。個別に計画が膨らむものは別ドキュメントへ切り出す。

## triage の原則
ブラインドレビューの指摘は 2 種類に分けて扱う。

* **(a) 本物の自己矛盾 / 揺れ** — API が自分自身と食い違う。→ **直す**。
* **(b) 最小プリミティブ哲学を知らない新規者の期待** — 他フレームワークにある機能が無いことを「穴」と誤判定したもの。→ **プリミティブは増やさず、便利層で和らげるか据え置く**。

新規レビュアーは他フレームワーク基準で (b) を「API の穴」と言いがちなので、額面どおり受け取らない。

## 裁定一覧

### 1. 型付きコールバック — (a) / 着手保留
全コールバックの `@ptrCast(@alignCast(user_data))` 定型 + 型非安全（`widget_dialog` は同一 `*anyopaque` を 2 型に取り違えうる）。
**裁定**: C_ABI 層は `void*` 死守、Zig ネイティブ層に comptime サンクの型付き玄関を被せる（保存形は `fn(*anyopaque)+*anyopaque` のまま → C_ABI codegen 無変更）。**いつかやる**。詳細 `doc/typed_callbacks.md`。

### 2. `add` の意味 / 引数形がバラバラ — accept（現状維持）
`Container.add`（`*Component` メソッド）/ `BorderLayout.add`（静的関数 + region）/ `bar.add(menu)`（`*Menu` 直）。
**裁定**: 問題なし。`add` の形が違うのは**入れる対象が実際に違う**から（Menu はレイアウト上の Component ではない、BorderLayout は region 引数が要る）で、本質的な矛盾ではない。
MenuBar が Container と別経路で Menu を保持する件も、Menu / MenuBar は通常のレイアウト階層から逸脱した特殊コンポーネントなので別経路で妥当。
残り火は「`BorderLayout.add` だけ静的関数」だが据え置き。

### 3. リスナー登録経路の不統一 → 真の項目は SelectionModel — (a)
症状: Button は `getModel().addActionListener`、ComboBox / List は widget 直 `addChangeListener` とバラつく。
**裁定**: 登録経路のバラつき自体は問題ではない（widget にリスナーがあってよい）。**原因は選択系 widget に SelectionModel 相当が無いこと**。Button→`ButtonModel`、Slider→`BoundedRangeModel` と「モデルを持つ widget」はリスナーがモデル側にあって統一的だが、List / ComboBox は選択状態が場当たり的なフィールドでモデルが無い。
→ **`SelectionModel`（Swing の `ListSelectionModel` 相当）を導入**し、List / ComboBox / 将来の Table / Tree の選択を観測可能・共有可能にする。リスナーがモデル側に乗るので経路も自然に揃い、複数選択もそこに乗る（`framework/doc/list.md` の機能要望「複数選択 (SelectionModel)」を単一選択にも広げる形）。設計が膨らむなら別ドキュメント化。
別件（小）: TextField に変更リスナーが無く `widget_textfield` がタイマー polling している。SelectionModel とは無関係の単純な実欠落なので、変更リスナーを足すだけ。

### 4. 「Component を取り出す」が 3 形態 — park
leaf は `.component`（フィールド）、Container / List / ScrollPane は `asComponent()`（メソッド）、Panel は `.container.component`。
**裁定**: 保留。安いユニファイ手段が無く（全 widget に `asComponent()` を手で生やすのは面倒、leaf の `.component` フィールドと噛み合わない）、コスメティックな割に直すコストが高い。実際に困ったら再考。

### 5. spacing / 固定サイズが冗長 — (b) / 便利層のみ
`widget_textfield` は spacer 自作、`widget_scroll` は min==max。
**裁定**: 穴ではなく**意図した設計**（少ないプリミティブで合成できている方が良い）。修正は**上の便利層のみ**（`setFixedSize` = min==max の糖衣、`padded` ヘルパ等）。**`preferredSize` / `Insets` をプリミティブとして足すのは却下**（Insets はコンテナ合成で代替、唯一の代償はツリー肥大 = 性能の話）。詳細 `doc/layout_helpers.md`。**冗長が痛くなってから足す**（先回りしない）。

### 6. caller 所有の 2 段階破棄 — 小改善（単一 `destroy()`）
ButtonGroup / Dialog だけ `defer { x.deinit(); gpa.destroy(x); }` が要る。Frame は不要。
**理由**: 両者は **widget ツリーの外にいるヒープオブジェクト**。ButtonGroup は複数 radio の model を借用して束ねるだけで Component でなく、どのコンテナも所有しない。Dialog は再利用前提（close で破棄せず hide）で app の所有ウィンドウツリーにも入れていない。だからどこも自動破棄せず caller 所有になる。2 段階は Zig の定石（`deinit`＝内部リソース解放 / `allocator.destroy`＝struct 本体の解放）で、tree 所有の widget はコンテナ / app がこれを代行しているだけ。引っかかりの正体は「**Frame は不要なのに Dialog / Group は必要**」という非対称。
**裁定**: 単一の `destroy()`（中で `deinit` + free）を Dialog / ButtonGroup に生やして **1 呼び出し**にする。便利層、プリミティブ非増加、破壊的でもない。
（別案: app 所有にして後始末を消す。今回は採らない。）

### 7. カスタム挙動に vtable コピー — メカニズムは維持 / グローバルは撤去
**裁定（メカニズム）**: vtable コピー（`paint` 等だけ差し替え、他は元へ委譲）は **ScrollPane でも使う正式なエスケープハッチ**として維持する。「祝福された event/paint フックを足せ」というレビュアー推奨は**却下**（新 API を増やさず全制御できる利点が大きい）。詳細は `reference: vtable decoration`（メモリ）。
**裁定（グローバル）**: `widget_menu` の `ContextPanel.instance`（file-scope `var ... = undefined` の singleton）は **CLAUDE.md の anti-global 方針に反する**ので**撤去する**。同じことはグローバル無しで書ける — `widget_listdnd` が既に `putProperty`/`getTyped` + スタック変数でやっている。グローバルは古い書き方なだけで何も追加で買っていない。→ **`widget_menu` を property パターンへ書き換える**（vtable コピーの利点は保ったまま矛盾が消える）。

## 維持すべき良い点（安定化で壊さない）
* `Application` のファクトリ群（`app.button` / `app.label` / `app.comboBox(&items)` / `app.icon(.save)`）。便利層を増やす良い手本（`app.filler` / `app.toolBar`）。
* `Dialog.showModal()` が結果 enum を返し `switch` できる形。
* `app.init` / `app.deinit` の対称性と `app.run` 単一ループ入口。
* 各 example ヘッダのテストレシピ込みコメント（学習者に有用、規約として維持）。
* model / view 分離（問題は露出の不統一だけで概念は健全）。
* List を非変更のまま DnD が乗る合成性。

## 直近のアクション候補
* **`widget_menu` のグローバル撤去**（#7、合意済み・小さく具体的）。
* **TextField に変更リスナー**（#3 別件、小）。
* **単一 `destroy()` を Dialog / ButtonGroup に**（#6、小）。
* **SelectionModel の設計**（#3 本体、大きめ。別ドキュメント化の候補）。
* 型付きコールバック（#1）/ layout helper（#5）は別 doc に計画済み・据え置き。
* #2 accept、#4 park。
