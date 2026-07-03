# framework バックログ
framework 層（Component / Container / Window / 各ウィジェット）で後回しにした項目。
書き方は [backlog.md](backlog.md) を参照。

由来: #1〜#3 は 2026-06-07 の doc↔実装 追従監査（CLAUDE.md「doc と実装の追従関係」基準）で、
「doc にあるのに実装に無い」genuine な欠落として検出され、実装するか doc から落とすか作者判断が要るもの。
#4〜#5 は 2026-06-11 のプロジェクト全体評価で構造リスクとして指摘されたもの。
#6 はキーバインディング実装 (2026-06-11) 後の作者の動作確認で出た実需。

---

## #1 MenuBar.remove の実装 or doc からの削除
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `MenuBar`（`MenuBar.zig` / `menu_bar.md`）
- 更新日: 2026-06-07
- 依存: なし

### 何
`menu_bar.md`「Menu の削除」が `pub fn remove(self: *MenuBar, menu: *Menu) void` を定義しているが、
`MenuBar.zig` に実装が無い（実体は `create` / `setWindow` / `add` / `count` / `at` / `relayout` のみ）。
doc 自身が「remove はあまり使わない想定（メニュー構成は起動時に組んで以降固定）」と注記しており、
未実装のまま doc にだけ存在している。`機能要望` ではなく通常の関数定義セクションに居るため、追従基準上は NG。

### なぜ（保留理由）
実需が薄い（メニュー構成は通常起動時に固定）。即「直す」に倒さず、実装するか doc から落とすかを作者が選ぶべき項目。

### 候補アプローチ
- 案A: doc から `remove` 節を削除 — 現状の実装（固定メニュー）に doc を合わせる。
  メリット: 追従基準を即満たす・実装ゼロ・point-of-need に忠実。デメリット: 将来 remove が要るとき再記述。
- 案B: `MenuBar.remove` を実装 — doc に実装を合わせる。`add` の逆で、所有権を放棄するだけで `Menu` 自体は解放しない（利用者責任）。
  メリット: doc が示す API が揃う。デメリット: 実需の無いコードを足す（先回り）。
- 判断軸: point-of-need を優先するなら A、API の完全性を優先するなら B。
- 推奨: 案A。CLAUDE.md「実装の名前に寄せて doc を更新する」「先回りで作り込まない（point-of-need）」と整合。最終判断は作者。

### 決めること
A（doc から削除）か B（実装）か。

### 完了条件
A なら `menu_bar.md`「Menu の削除」節を削除し、追従基準（doc にあるのに実装に無い）を解消。
B なら `MenuBar.remove` を実装し、必要なら remove 連鎖のテストを追加。

## #2 テスト網羅の拡充（snapshot scene + 純ロジック単体テスト）
- 状態: 未着手
- 優先度: 低
- 影響範囲: `awt/tests/scenes.zig`（snapshot scene 追加）、`framework/src/*.zig` の test ブロック、一部 `awt/src/*.zig`。新設するなら `framework/tests/`
- 更新日: 2026-06-07
- 依存: なし

### 何
旧 `doc/audit-2026-05-23.md` §3 から移送。回帰検出が薄い箇所が 2 系統ある。

snapshot scene の未カバー（現行 scene は box / border / toggle 系のみ）:
- Slider（水平 / 垂直の thumb 配置）
- Label 単体（現状 Button 経由でしかフォント経路を踏まない）
- 開いた状態のメニュー（チェック付き / 無効 MenuItem の見た目）
- PopupMenu のサブメニュー展開
- BorderLayout で領域が一部欠けるケースの境界配置
- Button の icon-only / icon+text
- 無効状態（`!model.enabled`）の Button / Slider / Menu

純ロジック単体テスト（高リスク順）:
- `BoundedRangeModel.setRange` の extent 縮小 / `setExtent` の `value > max` 不整合（`BoundedRangeModel.zig`）
- `Slider.posToValue` のゼロ / 負レンジ（`Slider.zig`）
- `ChangeListenerList.fire` 中の add/remove（reentrance、`len` スナップショット + 直接参照の誤読、`listener.zig` / `ChangeListenerList.zig`）
- `Container.remove` の連鎖 remove（リスナー経由で index がずれる、`Container.zig`）
- `EventQueue.drain` の reentrance（「drain 中の invokeLater は次回 drain」の不変条件、`awt/src/EventQueue.zig`）
- `Window.dispatchInput` の overlay / mouse_capture 優先順（状態空間が広い、`Window.zig`）
- `PopupMenu.show` の画面外クランプ（`PopupMenu.zig` / `Menu.zig`）
- 純粋計算系: `Graphics.clip` の交差（`awt/src/Graphics.zig`）、`GlyphAtlas.alloc` のシェルフパッキング（`awt/src/GlyphAtlas.zig`）

加えて `doc/internal/test.md`:92-118 が予定する framework のレイアウトテスト基盤（`framework/tests/`）はレイアウト系（`border_layout_test` / `box_layout_test` / `snapshot_test`）が入って一部実現済み。上記の純ロジック系をどこに置くか（各 `src` の test ブロック or `framework/tests/`）も決める。

### なぜ（保留理由）
TextField 着手を止めるほどの実害は無い（描画は snapshot で間接カバー、致命的なロジックバグは未報告）。一方で Window.dispatchInput / TextField 周りは focus / IME / blink timer の追加で状態空間が再構築されるため、いま固めても上書きされる。設計が安定した領域から順に足したい。

### 候補アプローチ
- 案A: 高リスクな純ロジック（`BoundedRangeModel` / `ChangeListenerList` / `Container.remove`）を先に単体テスト化。snapshot scene は後追い。
- 案B: snapshot scene を一括追加して見た目の回帰網を張ってから、純ロジックを足す。
- 判断軸: ロジックバグの早期検出を取るなら A、見た目回帰の網羅を取るなら B。

### 決めること
着手順（A/B）。純ロジックテストの置き場所（各 `src` test ブロック or `framework/tests/`）。`Window.dispatchInput` を今やるか TextField 後に回すか。

### 完了条件
未カバー項目のうち着手対象を決め、テストを追加して緑。`doc/internal/test.md` の予定との対応を更新。

## #3 binding.md の `Component.getVTable()` 未実装の扱い
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `Component`（`Component.zig` / `binding.md`）、他言語バインディング方針
- 更新日: 2026-06-07
- 依存: バインディング全体方針（[[project_bindings_codegen]]: C ABI は apigen 生成のテキスト spec 駆動）

### 何
旧 `doc/audit-2026-05-23.md` (a) から移送。設計文書 `binding.md` が `Component.getVTable()` を「コアに必要」としているが `Component.zig` に未実装。doc 追い越し（doc にあるのに実装に無い）だが、`binding.md` は設計文書（未来形の記述を許す性質）なので即 NG とはしにくい。

### なぜ（保留理由）
バインディング方針が apigen による C ABI コード生成（GObject 風の vtable 露出ではない）に固まっている。その方針下で `getVTable()` を露出する必要があるのか自体が再検討対象で、他言語バインディングの実装に着手するまで判断を遅らせたい。

### 候補アプローチ
- 案A: codegen 方針では vtable 露出が不要と判断し、`binding.md` から `getVTable()` の記述を削除（doc を実装＝未露出に寄せる）。
- 案B: 実際に必要と判断し `Component.getVTable()` を実装。
- 判断軸: apigen 経由で完結するなら A、ネイティブ拡張で vtable 直叩きが要るユースケースがあるなら B。

### 決めること
A（doc から削除）か B（実装）か。バインディング着手時に判断。

### 完了条件
A なら `binding.md` の `getVTable()` 記述を削除。B なら `Component.getVTable()` を実装し doc と一致。

## #4 既定 LAF のスタイルを public な Theme テーブルから引く
- 状態: 完了
- 優先度: 中
- 影響範囲: framework の全ウィジェットの paint（`Button.zig` / `CheckBox.zig` / `Slider.zig` / `Menu.zig` / `TextField.zig` ほか約 20 種）、`Theme` 型の新設と公開、`Application` への theme 保持
- 更新日: 2026-06-11
- 依存: なし

### 2026-06-20 追記（委譲機構の方針を一点改訂）
`laf_design.md`（ブランチ `feat/laf-design`）で、本項目の確定事項のうち
「**新しい委譲機構は作らない**（差し替えは `setVTable` 一本／Swing ComponentUI 風は却下）」の一点を、
**作者承認のもと改訂した**。理由は、本項目が **LAF 固有の measure（最小サイズ計算）を予見していなかった**こと:
Swing Metal の bevel・JTattoo の 9-slice は `paint` だけでなく寸法計算も LAF 固有になり、
`setVTable`（paint コピー差し替え）では表現できない（`measure` はそもそも現 `VTable` に無い）。
そこで `paint` / `measure` を構造 vtable から切り出し、別 vtable（`LookVTable`）へ隔離する。
本項目の他の決定（Theme＝公開データ・LAF は起動時固定・ファクトリ DI）はすべて維持する。
完了状態は変えない（本追記で矛盾を解消）。詳細は `laf_design.md` §2.11。

### 何
各ウィジェットの paint に直書きされている色・メトリクス（例: `Button.zig` の
`Color.rgb(0.78, 0.82, 0.92)`、フォーカスリングの `0.25, 0.45, 0.85` 等）を、
public な `Theme` テーブルから引くようにする。テーマ値の差し替えだけで
ライト / ダーク等の切り替えがコードなしで成立する状態にする。

### 確定済みの枠組み（2026-06-11 作者決定）
- **LAF とは vtable 一式の差し替え**である。座席は既存の `Component.setVTable`
  （component.md「個別の差し替えと一斉差し替え（ルックアンドフィール）」）のみで、
  **新しい委譲機構は作らない**。フル LAF の実務は「既定 vtable をコピーして paint を
  差し替える」既存のデコレーションパターン（widget_listdnd 等で実証済み）。
- **Theme は既定 LAF のパラメータであり、かつ public な公開型**。自前 LAF（vtable を
  書く者）も同じ Theme を読んでよい（読めば配色がアプリのテーマ切替に追従する）し、
  **読まない LAF も存在できる**（Theme は公開基盤であって契約ではない）。
- 旧案B（Swing ComponentUI 風の委譲機構新設）は**却下** — 差し替えの座席は vtable として
  既にあり、二つ目の差し替え機構は作らない。Zig コードでしか触れない拡張機構を
  これ以上厚くしない。
- 旧案C（何もしない）は**却下** — 直書き色はウィジェット追加のたびに増え続けており
  （キーバインディング実装でフォーカスリング色 ×6 が追加された）、繰り延べコストが
  単調増加する型。

### 確定済みの参照方式（2026-06-11 作者決定）
- **ファクトリ DI**: `Application` がテーマを 1 個所有し、各生成メソッド（ファクトリ）が
  生成時にウィジェットへ注入する。lazy walk や Graphics 経由の都度取得はしない。
- **実行中のテーマ切り替えは非対応（再起動前提）**。根拠: 色だけなら repaint で済むが、
  メトリクスは `applyMetrics` が **min_size を生成時に焼き込む**設計のため、実行中の
  差し替えには全ツリーの re-metrics + 再レイアウト（Swing `updateComponentTreeUI` 相当の
  無効化プロトコル）が必要になり、それこそが「実行中の LAF 更新で描画が壊れる」の正体。
  起動時固定と宣言することでこの設計問題ごと消す。実行中切り替えは実需が出たときに
  別項目として起票する（その時はこの無効化プロトコルが本体）。
- 注入の形（実装方針）: `Component.theme: *const Theme = &Theme.default` —
  既定値は comptime 定数（immutable データなので「グローバルを選ばない」原則に抵触しない）。
  ファクトリが `&app.theme` を差す。ファクトリを通らない直接 `create()` は既定テーマで
  描かれるだけで、create シグネチャの churn も呼び順の罠も生まれない。自前 LAF
  （vtable 差し替え）も `component.theme` を読めば公開基盤として機能する。

### 追加決定（2026-06-11 作者決定）
- テーマの渡し方は**案ア**: `init` のオプション引数（または `initWithTheme`）。
  Application は渡された Theme を**値でコピーして保持**する（`app.theme: Theme`。
  借用にすると init に渡した一時変数が先に死ぬ罠が生まれるため）。
  各コンポーネントは Application 内のコピーを指す（`&app.theme`）。Application は
  全ウィジェットより長生きなのでダングリングは構造的に起きない。
- **各コンポーネントは単一の `*const Theme` 参照を 1 本持つだけ**。
  不採用: per-component の差分テーマ / カスケード（CSS 的継承）— 無駄に複雑になるだけ。
  点の上書きは既存の per-widget フィールド（Button の `color` / `font` 等）の仕事であり、
  サブツリー単位の別テーマも `theme` が public フィールドである以上、利用者が自分で
  差し替えれば機構ゼロで可能（フレームワークはカスケード規則を持たない）。

### Theme ドラフト（2026-06-11 起案、作者了承済み・非確定）
直書き色の全棚卸し（約 28 種）に基づくハイブリッド命名。フィールドの増減程度の変更は
あり得る前提だが、基本設計（固定 struct / 役割別トークン基本 + 畳めない箇所のみ
ウィジェット別）はこれで確定。実装時はこのドラフトを正本として置換を行う。

棚卸しで判明した重要事実（命名が単なる値の重複排除でない理由）:
- 同じ RGB が別の意味で使われている: `(1,1,1)` = 入力欄背景 **かつ** アクセント上の白文字、
  `(0.55³)` = disabled テキスト **かつ** 入力欄ボーダー。ダークテーマで挙動が分かれるため
  値が同じでも別トークンに分離する。
- 意図的に accent から外れた色がある: Button の押下背景 `(0.55, 0.65, 0.85)` は
  メニューの `(0.30, 0.55, 0.95)` より意図的に淡い → ウィジェット別フィールドが正当。

```zig
pub const Theme = struct {
    // ── 役割トークン（複数ウィジェット横断。テーマ作者が主に触る面）──
    accent:           Color = rgb(0.30, 0.55, 0.95), // 選択・チェック・focus border・slider thumb 等 ×12
    accent_soft:      Color = rgb(0.90, 0.93, 0.99), // メニュー hover 背景 ×3
    selection_bg:     Color = rgb(0.80, 0.87, 0.98), // List 選択行
    focus_ring:       Color = rgb(0.25, 0.45, 0.85), // フォーカスリング ×5
    text:             Color = rgb(0.10, 0.10, 0.10), // 通常テキスト
    text_disabled:    Color = rgb(0.55, 0.55, 0.55),
    text_on_accent:   Color = rgb(1.00, 1.00, 1.00), // 選択中メニュー文字・チェックマーク
    surface_window:   Color = rgb(0.94, 0.94, 0.94), // ウィンドウ / メニューバー / Panel 背景
    surface_input:    Color = rgb(1.00, 1.00, 1.00), // TextField / List / popup / ComboBox 背景
    surface_disabled: Color = rgb(0.93, 0.93, 0.93),
    border:           Color = rgb(0.55, 0.55, 0.55), // 入力欄・popup の枠（text_disabled と同値だが別トークン）
    border_soft:      Color = rgb(0.78, 0.78, 0.82), // メニューバー下線等
    separator:        Color = rgb(0.75, 0.75, 0.78),
    indicator_border: Color = rgb(0.50, 0.50, 0.50), // CheckBox 四角 / RadioButton 円の枠

    // ── ウィジェット別（役割に畳むと意味が変わる面）──
    button_bg:            Color = rgb(0.85, 0.85, 0.90),
    button_bg_hover:      Color = rgb(0.92, 0.92, 0.97),
    button_bg_armed:      Color = rgb(0.55, 0.65, 0.85), // 意図的に accent より淡い
    button_bg_disabled:   Color = rgb(0.75, 0.75, 0.78),
    button_flat_hover:    Color = rgb(0.88, 0.88, 0.92),
    button_flat_armed:    Color = rgb(0.78, 0.82, 0.92),
    scrollbar_track:      Color = rgb(0.88, 0.88, 0.90),
    scrollbar_thumb:      Color = rgb(0.62, 0.62, 0.66),
    scrollbar_thumb_hover: Color = rgb(0.48, 0.48, 0.52),
    slider_track:         Color = rgb(0.70, 0.70, 0.75),
    ime_preedit_underline: Color = rgb(0.40, 0.40, 0.40), // TextField / TextArea 共有
    ime_preedit_target:    Color = rgb(0.20, 0.20, 0.20),
};
```

実装時に snapshot 差分が出る統一判断（差分画像を見て個別に承認 / 却下する）:
- 黒テキスト 2 種（`0,0,0` と `0.1³`）→ `text` へ統一
- ウィンドウ系背景 2 種（`0.94³` と `0.94,0.94,0.96`）→ `surface_window` へ統一
- ComboBox chevron `0.30³` → `text` へ寄せ
- popup 枠 `0.55,0.55,0.60` → `border` へ寄せ
- Button disabled 文字 `0.5³` → `text_disabled (0.55³)` へ寄せ
- CheckBoxMenuItem チェック色 `0.20,0.50,0.90` → `accent` へ寄せ

メトリクス（角丸・パディング等）は v1 では Theme に**含めない**（色のみ）。
実需が出たら additive にフィールドを足す（テーマ起動時固定なので min_size 焼き込みとも矛盾しない)。
rgba 系・グラデーション等 `Color.rgb` 以外のコンストラクタ経由の色は実装時の置換で拾う。

### 決めること（実装着手前の残り）
- なし（命名はドラフト正本で進め、増減は実装中の snapshot 確認で調整）。
- 切り替え単位: アプリ全体のみ（ウィンドウ単位テーマは実需待ち）— 確定済み。

### 結果（2026-06-11 実装完了）
`theme.zig`（ドラフトどおり 26 フィールド + `Theme.default`）、`Component.theme`、
`Application.initWithTheme` + 全ファクトリの DI（composite は再帰注入。`Menu.addSeparator` /
`PopupMenu.addSeparator` の内部生成セパレータは親の theme を継承）。全ウィジェット paint から
色リテラルが消滅。テキスト選択ハイライトはトークンではなく accent 40% アルファの**導出**
（`selectionColor`、accent に自動追従）。テスト 92/92 緑（`theme_test.zig` 新設: DI / 再帰注入 /
直接 create の既定 / 値コピー契約）。
snapshot 差分は予告どおり統一判断 2 件のみ（fixtures 再生成済み、差分画像は
`tmp/snapshot_failures/` に保存。作者が却下する場合は該当箇所を専用トークンに分離して再生成）:
- `menu_bar_closed` — メニューバー背景 `0.94,0.94,0.96` → `surface_window (0.94³)`（最大差分 5/255）
- `toggle_combobox_closed` — chevron `0.30³` → `text (0.10³)`（最大差分 51/255）
残りの統一判断 4 件（黒テキスト→text、popup 枠→border、disabled 文字→text_disabled、
チェック色→accent）は既存 scene に現れず差分ゼロ。ダークテーマの実機での見た目確認は未実施
（例: widget_keyboard を `initWithTheme` に変えて起動すれば確認できる）。

### 完了条件
`Theme` 型が public（root.zig から export、spec `theme.md` 新設: 型定義・既定値・引き方の契約）。
全ウィジェットの paint から色リテラルが消えテーブル参照になる。テーマ値を変えると
全ウィジェットに反映されることを snapshot / Robot テストで確認。
「LAF = vtable 差し替え / Theme = 公開データ」の用語の線引きを doc（binding.md または
narrative）に記載。C ABI への Theme 露出は capi バックログで別途（struct 引数対応に依存）。

## #5 TextField / TextArea の編集コア共通化
- 状態: 完了
- 優先度: 中（テキストエディターのドッグフーディング着手で「高」に昇格する）
- 影響範囲: framework の `TextField.zig` / `TextArea.zig`、`textfield.md` / `textarea.md`
- 更新日: 2026-07-03
- 依存: なし（text#3 完了済み。旧「text#3 と同時実施」前提は失効。関連: #31 汎用 UndoStack / text#13 IME util）
- 設計: [edit_core_design.md](edit_core_design.md)（#31 と共同設計・applyEdit / ReplaceRange / coalescing 継ぎ目）

### 何
TextField と TextArea が編集操作層（キャレット移動、選択範囲、クリップボード連携、編集操作、将来の
undo/redo）をそれぞれ独立に実装している。境界歩行そのものは既に `awt/src/grapheme.zig`
（prev/nextGraphemeBoundary）で両ウィジェット共有済みで、IME preedit の保持は text#13 の IME util へ
分離する。いま #5 に残る重複はその上の編集操作層（キャレット移動・選択・クリップボード・編集操作・
undo 連携）。片方で直したバグがもう片方に残る古典的リスクがあるため、共有可能な編集コアを抽出するかを
検討する。Swing が Document モデルの共有で解いていた問題に相当する。

### なぜ（保留・現状）
旧保留理由「text#3（書記素クラスタ移行）が codepoint 歩行を書き直すので、いま抽出してもすぐ上書き
される。抽出を text#3 と揃えるのが効率的」は失効した。事実: text#3 は完了し、TextField と TextArea の
両方へ別々にマージ済み（commit fda8100）。つまり書記素移行を 2 回実施した＝#5 が警告していた
「片方で直したバグがもう片方に残る」重複が現実化しており、抽出の動機はむしろ強まった。残る論点は
表面化したバグが未報告である点（実害より構造リスクの段階）と、共有コアのデータ構造をどこまで決めるか
（＝Document モデルの線引き）だったが、後者は 2026-06-24 の作者方針で解除された（下記「スコープ」）。

### スコープ（plain テキスト前提・2026-06-24 作者決定）
Document を今ちゃんと決めるのは難しい（どこまでリッチコンテンツを扱うかに依存する）。よって
TextField / TextArea と TextPane で別モデルを持ってよい — Swing の PlainDocument と StyledDocument の
分離に相当する。帰結として #5 の共有コアは plain テキスト前提でスコープし、データ構造は plain buffer
（PlainDocument 相当）とする。styled / rich モデル（StyledDocument 相当）は将来の TextPane の別項目とし、
#5 をその決定でブロックしない（リッチコンテンツ自体は text_backlog #7（v2+）に既出）。これにより #5 は
「Document 問題が未解決でも plain 編集コアは抽出できる」形でブロック解除された。

### 候補アプローチ
抽出は「既に書記素移行済みのコードを 1 つに畳む」作業になる。境界歩行は grapheme.zig 共有済みのため、
編集操作層（キャレット・選択・クリップボード・編集操作・undo/redo）を、描画／イベント処理を含まない
共有モジュール（例: `text_edit.zig`）へ切り出し、TextField / TextArea 双方をそこへ載せ替える。
IME preedit の plumbing は text#13 の IME util へ分離するが、IME 確定 → 挿入の統合はコア側に残し、
util の onCommit を受けて applyEdit する。undo/redo はこの共有コアに実装する（エディターに必須で、
編集コアに住む機能）。
（歴史: 起票時は text#3 と同時実施する案A／先に共通化する案B を比較していたが、text#3 完了で
このタイミング論争は moot になった。）

### applyEdit チョークポイントとバッファ構造
- applyEdit チョークポイント: 全 edit を 1 経路に通す。各 edit を ReplaceRange command（pos・旧バイト・
  新バイト・caret / 選択の before-after）として表現し、framework の汎用 UndoStack（#31）へ積む。抽出時に
  TextArea の散在した insert / delete（現状 8 箇所）をこのチョークポイントへ畳む ＝ undo を 1 回で載せ
  られる前提を作る。
- バッファ構造は案A 確定: 単一フラットな GapBuffer ＋ バイトオフセットを共有コアが持ち、行は widget が
  派生する（コアは行構造を持たない）。行ルックアップはコア内の継ぎ目にして（走査 now・行頭索引 later で
  差し替え可能）、コア API をバッファ非依存に保てば piece table / rope への将来差し替えも 1 点で済む。

### 決めること
バッファ構造（案A・単一 GapBuffer ＋ 行は widget 派生）は確定。残りを着手時に決める。
- applyEdit / ReplaceRange command の正確な形（caret / 選択の before-after の持ち方）と、TextArea の散在
  insert / delete をチョークポイントへ畳む移行手順。
- 行ルックアップの継ぎ目の初版（走査でよいか・行頭索引をいつ入れるか）。
- IME preedit plumbing は text#13 の IME util へ出し、確定挿入だけコアに残す。その継ぎ目の線引きを確定する。
- undo/redo の粒度（coalescing policy）は text#5 で決める（#31 は tryMerge / group の継ぎ目だけ用意する）。
styled / TextPane モデル（StyledDocument 相当）は #5 のスコープ外＝将来項目とする。

### 完了条件
キャレット・選択・クリップボード・編集操作のロジックが単一モジュールに存在し、TextField / TextArea
双方がそれを使う。編集系の単体テストが共有コアに対して書かれ、既存の snapshot テスト・examples
（widget_textfield / widget_textarea）の挙動が変わらないこと。

### 完了メモ（2026-07-03）
共有編集コア `framework/src/EditableText.zig` を新設し（`835e6d6`、OOM 経路の不可分化は `f882a15`）、
TextField（`3ca5eb7` で載せ替え）・TextArea（`9dd4eaf` / `4212499` で公開編集 API と状態同期）双方を
そこへ載せ替えた。キャレット移動・選択・クリップボード・編集操作・undo/redo が `EditableText` に集約され、
両 widget が `root.zig` 経由で同一モジュールを使う。undo は #31 の汎用 `UndoStack` を消費する形で編集コアに
実装（applyEdit → ReplaceRange command）。境界歩行は `awt/src/grapheme.zig` の grapheme boundary を共有。
バッファ構造は確定どおり単一フラットバッファ ＋ 行は widget 派生。styled / TextPane（StyledDocument 相当）は
スコープどおり将来項目のまま。

## #6 開いたメニューのキーボード操作の完結

テーマ見出し。ニーモニック (Alt+F) でメニューを**キーボードから開ける**ようになった結果、
「開いた後をキーボードで完結できない」半端さが実需化した (作者が現行 Windows メモ帳の挙動と
比較して確認: Alt+F → Ctrl+N は発火してメニューが閉じる、矢印 + Enter で項目選択できる)。
現行 nimbus は開いたメニュー (モーダルオーバーレイ) がキーを受けて非伝播するため、
和音キーは黙って飲み込まれ、矢印 / Enter は何もしない。

## #6a メニュー開放中のアクセラレータ発火 (閉じて遂行)
- 状態: 完了
- 優先度: 高
- 影響範囲: `Window.dispatchInput` のモーダルオーバーレイ分岐 (`.key`)、`framework/tests/focus_test.zig`、`narrative/keybinding.md` の配送節
- 更新日: 2026-06-11
- 依存: なし (#6b と独立。ただし同じ箇所を触るので同時実装が楽)

### 結果 (2026-06-11)
実装・検証済み。アクセラレータ走査を find (副作用なし) / fire に分離し、モーダル分岐では
「`dismissAll` → `doClick`」(作者決定: 閉じる→発火の順)。非一致の和音は従来どおり飲み込む。
回帰テスト: focus_test「accelerator while menu open: closes the menu, then fires」。
確定仕様は `menu.md`「キーボード操作」と `narrative/keybinding.md`「確定済みの方針」に記載。

### 何
メニュー開放中に未消費の和音キー (修飾付き) が来たら、非伝播で捨てる代わりに
アクセラレータ走査 (配送の段 4 相当) にかけ、一致したら**メニューを閉じてから発火**する。
原理はオーバーレイ中 Tab の案B と同じ「明確な別意図のキーは transient UI を閉じて遂行する」。
現行 Windows (メモ帳で実機確認済み)・macOS とも同挙動。

### 候補アプローチ
- 走査対象は修飾付き和音のみ (素の文字キーはメニューローカルニーモニックの領分のまま)。
  モーダルオーバーレイ分岐の最後の `return` の手前に判定を足すだけで、配送モデル本体は不変。

### 決めること
- 閉じる→発火 の順でよいか (発火ハンドラがダイアログを開く場合に
  メニューが残らないよう、先に閉じるのが自然と思われる)。

### 完了条件
widget_keyboard で Alt+F → Ctrl/Cmd+S が Save を発火しメニューが閉じる。
focus_test に回帰テストを追加。narrative の配送節に挙動を追記。

## #6b メニュー内キーボードナビゲーション (矢印 / Enter / ESC 段階クローズ)
- 状態: 完了
- 優先度: 高
- 影響範囲: `Menu.zig` (popupProcessEvent + ハイライト状態 + paint)、`OverlayManager` (ESC 段階クローズ用 API)、`Window.dispatchInput` の ESC 処理、`menu.md` / `narrative/keybinding.md`、テスト
- 更新日: 2026-06-11
- 依存: なし

### 結果 (2026-06-11)
実装・検証済み。作者決定: 案A (rollover 共用)、disabled は止まって Enter 無効、端で wrap、
`OverlayManager.dismissTop` 新設 (ESC は 1 押下 1 段、外クリック / Tab は dismissAll のまま)。
追加で確定した挙動: `←` はサブメニューを 1 段戻る (最上段 popup では no-op)、`→` / Enter で
開いたサブメニューは先頭ハイライト、ニーモニックで開いた popup も先頭ハイライト
(マウスで開いたら無し)。hover / mnemonic / → / Enter のサブメニュー展開は `openSubmenu` に統一。
回帰テスト: focus_test「menu keyboard navigation」「submenu: right opens / left closes / ESC staged」。
仕様は `menu.md`「キーボード操作」へ記載し、機能要望から削除。メニューバー上の ←/→ 切替と
Alt 単独タップは menu.md 機能要望に残置。

### 何
menu.md 機能要望の「キーボードナビゲーション」を実装する:
- `↓` / `↑` でハイライト移動 (separator はスキップ)
- `Enter` でハイライト項目を発火 (MenuItem / CheckBoxMenuItem)、サブメニューなら展開
- `→` でハイライト中のサブメニューを展開して 1 項目目へ、`←` で 1 段戻る
- `ESC` は**1 段だけ**閉じる (現行の dismissAll から変更。最上段なら全体が閉じる。
  外クリックは引き続き dismissAll)
- ニーモニック (Alt+F) で開いた直後は先頭項目をハイライト、マウスクリックで開いたときは
  ハイライトなし (Windows 流)

### 候補アプローチ
ハイライト状態の持ち方:
- 案A: `ButtonModel.rollover` を流用 — キー操作で該当項目の rollover を立て、他を落とす。
  メリット: 描画変更ゼロ (hover と同じ見た目)、状態の真実が 1 つ、Robot スナップショットも不変。
  デメリット: 「マウスが乗っていないのに rollover が立つ」状態が生まれ、マウス move が来ると
  上書きされる (これは「最後に動かした入力が勝つ」として望ましい挙動とも言える)。
- 案B: `Menu` に `highlight_index: ?usize` を持ち、paint で rollover 同等の背景を描く —
  メリット: キーボードとマウスの状態が独立で追いやすい。デメリット: 同じ見た目の状態が
  2 系統になり、切替規則 (マウス move でキーボードハイライト解除等) を別途決める必要。
- 判断軸: 状態の真実を 1 つにするか、入力系統ごとに分けるか。
- 推奨: 案A (rollover 一本化)。既存の合成 mouseExited 機構とも自然に整合する。最終判断は作者。

### 決めること
- 案A / 案B。
- disabled 項目をハイライトが**スキップ**するか**止まるが Enter 無効**か (Windows は後者)。
- 端で wrap するか (Windows は wrap する)。
- ESC 段階クローズの API 形 (`OverlayManager.dismissTop` 追加等)。

### 完了条件
widget_keyboard で Alt+F → ↓↓ → Enter による項目発火、→ / ← のサブメニュー出入り、
ESC の段階クローズが動く。メニューナビゲーションの Robot テストを追加。
menu.md 機能要望から該当行を削除し、操作仕様を spec へ記載。

## #7 作者起点のテストケース記述の仕組み
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: テスト運用全般（置き場所未定。`framework/tests/` ほか各層のテスト、ドキュメント規約）
- 更新日: 2026-06-12
- 依存: なし（#2 テスト網羅の拡充と関連。実需はドッグフーディング開始後に出る見込み）

### 何
作者が「こういうケースのテストが欲しい」をドキュメントとして書き、実装者（AI）がそれを
テストコードに翻訳して緑にする流れを作る。作者由来のテストはどこか専用の置き場
（フォルダ分け or フロントマター等のマーキング）にまとめ、AI が日常的に量産するテストと
**出自を分離**する。

### なぜ（保留理由・動機）
現状テストは全量 AI 起筆で、実装者とテスト起筆者が同一なため**盲点を共有する**
（実装の誤解はテストも同じ誤解で緑になる。実例: メニュー開放中アクセラレータの飲み込みは
92 本のテストが「正しさ」として守っており、壊したのは作者の実機比較 → #6a/#6b）。
作者が期待値の供給源になるテスト（受け入れテスト / spec-by-example 相当）はこの対策になる。
出自が分離されていれば「実装変更時に AI がテストを実装に合わせて書き直す」という
最悪の動きを構造的に防げる。

形を決めるのは実需が出てから（point-of-need）。ドッグフーディング（ファイラー / エディター）で
作者が実機を触る機会が増えると「この挙動を固定したい」が自然に出てくる見込みで、
最初の 1 件が出たときに形式を決めるのが安い。

### 候補アプローチ
- 案A: 専用フォルダにテスト仕様ドキュメントを置く（例: `doc/acceptance/` のような場所に
  1 ケース 1 節で期待挙動を書く）。AI が対応するテストコードへ翻訳し、相互参照を残す。
- 案B: 既存テストファイル内にマーキングする（作者由来テストにコメント / 命名規約で出自を刻む。
  ドキュメントは書かず、作者は口頭 / issue 的な指示のみ）。
- 判断軸: 作者がどこまで書きたいか（文書として残したいなら A、指示だけなら B）。
  どちらでも「AI が勝手に書き換えない」線引きが明示されることが本質。
- 推奨: 実需の最初の 1 件が出たときに決める（いまは決めない）。

### 決めること
置き場所と形式（案A/B）、マーキング方法、作者由来テストの変更手順
（実装側の仕様変更で期待値が変わるときは作者の承認を要する、等）。

### 完了条件
作者由来のテストケースが最低 1 件、決めた形式で記述され、対応するテストが緑。
運用ルール（AI が変更してよい範囲）がどこかのドキュメントに 1 段落で明文化されている。

## #8 コンテキストメニュー機構のコンポーネント横断の汎用化
- 状態: 棚上げ
- 優先度: 中（実需2件目 = エディターの TextField / TextArea 貼り付けメニューで着手判断）
- 影響範囲: Component（API 追加の可能性）、List（現 `addContextMenuListener` の去就）、PopupMenu、各ウィジェット
- 更新日: 2026-06-12
- 依存: なし（app_filer M3 で入れた List.addContextMenuListener が暫定実装）

### 何
「右クリックでコンテキストメニューを出す」をコンポーネント横断の 1 機構にする。
app_filer M3 では List 専用の `addContextMenuListener`（右プレスで行選択 + フォーカス取得を済ませてから
`{ row, x, y }` を通知、表示はアプリ）を入れたが、このままだと TextField / TextArea / Tree…と
コンポーネントごとに専用リスナーが増殖する。

整理すると、各ウィジェット固有で正当なのは**右プレス時の前処理**（List なら「ヒット行を先に選択」）だけで、
「右プレスをアプリに通知してポップアップを出させる」部分は全コンポーネント共通の関心。

### なぜ（保留理由）
実需がまだ 1 件（app_filer の List）しかない。2 件目（エディターの貼り付けメニュー）が
ほぼ確実に来るので、その時点で形を決めるのが安い。いま決め打ちすると 1 ユースケースに
過剰適合する恐れがある。List の現リスナーは利用者が app_filer のみの今なら安く廃止 / 移行できる。

なお list.md の旧記述「生のマウスリスナーを公開 API にしない方針のため」は実装者の推測を
方針と書いた誤りで、現状記述（「現状公開していない」+ 本項目への参照）に訂正済み。
生のマウスリスナーを公開するか否か自体も未決定であり、本項目の検討範囲に含めてよい。

### 候補アプローチ
- 案A: `Component.setComponentPopupMenu(?*PopupMenu)`（Swing 同型、借用）。未消費の右プレスで
  framework が自動表示。各ウィジェットは前処理（選択など）だけ実装し、消費せず流す。
  メリット: 利用者の手数が最小（popup を 1 個セットするだけ）、API が Component に 1 つ増えるのみ。
  デメリット: 対象によってメニュー内容を変える（ファイル / フォルダで項目を変える等）には
  表示前フックの追加が将来必要。
- 案B: per-widget リスナーを増やしていく（現状路線）。
  メリット: ウィジェット固有の文脈（List の row 等）を型付きで渡せる。
  デメリット: コンポーネント数ぶん API が増殖し、アプリ側の表示コードも毎回書く。
- 案C: Component 共通の ContextMenuEvent リスナー（opt-in、発火タイミングは各ウィジェットが決定、
  表示はアプリ）。
  メリット: 機構は 1 つで動的メニューも自然に書ける。デメリット: アプリは popup.show を毎回書く。
- 判断軸: 利用者の手数（A 最小）vs 表示直前の柔軟性（B / C）vs Component の API 表面積。
- 推奨: 実需 2 件目が出た時点で A を本命に検討（A 採用時、List の前処理ロジックはそのまま生き、
  `addContextMenuListener` は廃止候補）。最終判断は作者。

### 決めること
案 A / B / C の選択。A の場合: 動的メニュー（表示前フック）を初版に含めるか、
List の `addContextMenuListener` を廃止するか並存させるか。
生のマウスリスナーを公開 API にするか否かの明文化（する / しない / 保留のどれかを決めて記録する）。

### 完了条件
選択した機構で List と TextField（またはその時点の実需 2 件）が同じ仕組みで
コンテキストメニューを出せる。list.md / component.md 等の関連 doc が追従。
廃止 API があれば利用箇所（app_filer 等)も移行済みでテスト緑。

## #9 Table ウィジェット（複数カラム + ヘッダー）
- 状態: 完了（app_filer 詳細ビューで実運用。コア + example + テスト緑）
- 優先度: 高
- 影響範囲: framework 新規モジュール（Table / TableModel / 列定義）、theme、example、FileChooser 設計
- 更新日: 2026-06-14
- 依存: なし（List の VirtualFlow 方式・CellFactory 資産を流用する想定）

### 何
Swing `JTable` 相当。列定義（名前 / 幅 / セル生成）、ヘッダー行、ヘッダークリックでのソート、
列幅のドラッグ変更、行の仮想化（List と同じ可視範囲 + recycle）。
実需はファイラーの詳細表示（名前 / サイズ / 更新日時）。FileChooser の詳細表示にも直結する。
ドッグフーディングのリッチ化（2026-06-12 作者表明「そこにあるやつは全部やりたい」）の本丸。

### 決めること
TableModel の形（行 = `*anyopaque` 借用は List 踏襲でよいか、列値の取り出し方）、
ソートの所在（モデルが並べ替えるか view が index 写像を持つか）、
選択モデルを List と共有するか（#10 と要調整）、行ヘッダー / セル単位選択をスコープ外にするか。

→ doc 提出 + コア実装完了 (2026-06-12): `framework/doc/table.md` + `narrative/table.md` (作者レビュー待ち unsafe)、
`framework/src/Table.zig` (埋め込みテスト7本)、`app.table` / `app.tableWithModel` ファクトリ、Component.Role に table。
確定した設計: Model = List.ListModel 同一型 / 列ごと CellFactory で値プロトコル無し /
ソートは view 写像を持たず「ヘッダークリック通知 (SortEvent) + インジケータのみ、並べ替えはアプリ」/
ヘッダーは Table 自身が上端固定描画 (スクロールオフセットを打ち消す) / 列幅ドラッグ (min_width クランプ・連続レイアウト) /
単一選択・行アクティベーション・コンテキストメニューは List と同形のリスナー。
v1 外 (機能要望): セル編集・複数選択 (#10)・列の自動フィル (←ファイラー詳細表示で最初に欲しがる見込み)・
列のドラッグ並べ替え。

→ ファイラー M5 で実戦投入済み (2026-06-12): app_filer の詳細ビュー (Name/Size/Modified、ヘッダソート、列幅ドラッグ)、
共有モデルで List⇄Table 切替を実証。M5 で出た Table への追加要望は作者が優先度付けして別項目に昇格:
**#14 セル編集 (優先度 高)** / **#15 列の自動フィル (中)** / **#16 DnD 用 y→行アクセサ (低)**。

### 完了条件
ファイラーの詳細表示が Table で動き、ヘッダーソートと列幅ドラッグが操作できる。doc + テスト + example。

### 完了メモ（2026-06-14）
app_filer 詳細ビューで実運用。`examples/app_filer/main.zig` が `app.tableWithModel` で
Name / Size / Modified の 3 列を構成し、ヘッダクリックでのソート（`addSortListener` +
`setSortIndicator`）・列幅ドラッグ・セル編集（Name 列のインプレースリネーム、#14）・
複数選択（`setSelectionMode(.multiple)`、#10）に対応。List ⇄ Table を共有モデルで切り替えて実証済み。
Table の埋め込みテスト 10 本を含め `zig build test` は緑（132/132）。M5 で出た追加要望は #14（完了）/
#15（自動フィル・未着手）/ #16（DnD 用 y→行アクセサ・完了）へ分離済み。

## #10 List / Table の複数選択
- 状態: 完了（独立 SelectionModel を List / Table で共有。 app_filer で一括削除 / 移動）
- 優先度: 中
- 影響範囲: List（selected の型変更 or 選択モデル分離）、Table（#9）、app_filer（一括削除 / 移動）
- 更新日: 2026-06-13
- 依存: #9 と選択モデルの共有方針を揃える（先行着手も可）

### 何
Ctrl+クリックのトグル、Shift+クリックの範囲選択、矢印 + Shift の範囲拡張。
実需はファイラーの一括削除 / 一括 DnD 移動。
現状の `selected: ?usize` 単一選択からの拡張で、Swing の ListSelectionModel 相当を
独立モデルにするか List 内に持つかが論点。

### 完了条件
app_filer で複数行を選択して一括削除 / 一括移動ができる。既存単一選択の API 互換性の決着込み。

## #11 Tree ウィジェット
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework 新規モジュール（Tree / TreeModel）、example
- 更新日: 2026-06-12
- 依存: なし（仮想化は List 方式の流用想定。展開状態の分だけ複雑）

### 何
Swing `JTree` 相当。階層モデル、展開 / 折りたたみ、インデント + 展開アイコン描画、キーボード操作。
実需はファイラーのフォルダツリーペイン（現在の場所一覧 List の置き換え候補）。
遅延読み込み（展開時に子を問い合わせる）が FS ツリーでは必須になる点が List との本質差。

### 完了条件
ファイラーの左ペインがツリーになり、展開 / 折りたたみ / クリック移動が動く。doc + テスト + example。

## #12 TabbedPane
- 状態: 完了
- 優先度: 中
- 影響範囲: framework 新規モジュール、example
- 更新日: 2026-07-03
- 依存: なし

### 何
Swing `JTabbedPane` 相当。タブバー + 中身の切り替え、タブの追加 / 削除、閉じるボタン。
実需はファイラーの複数ディレクトリタブ、およびテキストエディターの複数ファイル（こちらが本命の見込み）。

### 完了条件
タブの追加 / 切り替え / 削除が動き、どちらかのドッグフーディングアプリで実用されている。doc + テスト。

### 完了メモ（2026-07-03）
`framework/src/TabbedPane.zig` を新設（`57a509f`）。タブバー + 中身の切り替え・タブ追加 / 削除・
change listener（型付き化は `df154c1`）・実行例とスナップショット（`cff9c5b`）を実装。LAF 移行で default Look へ
統合（`39c36a9`）、Metal タブ枠（`a73a03f`）まで入っている。派生の繰り延べ機能（閉じるボタン #22 /
ドラッグ並べ替え #23 / キーボード・端配置・overflow・アイコン #24）は本項目から分離して個別起票済みで、
それらは本項目の完了に含めない（`be9e979`）。

## #13 グリッドビュー（アイコン / サムネイル表示）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: framework（グリッド仮想化。List の縦 1 列前提の一般化 or 別ウィジェット）、awt（画像縮小）、app_filer
- 更新日: 2026-06-12
- 依存: サムネイル読み込みが非同期の実需（io.async + invokeLater の初実戦）と表裏。検索 / サイズ集計（dogfooding バックログ）と並ぶ非同期起点候補

### 何
ファイラーのアイコンビュー / サムネイルビュー。固定セルサイズのグリッドに仮想化で並べ、
画像ファイルはサムネイルを非同期生成して差し込む。
List の「縦 1 列 × 行高固定」を「行 × 列」へ一般化するか、専用ウィジェットにするかが論点。

### 完了条件
ファイラーで表示モードをリスト / グリッドに切り替えられ、数千ファイルのフォルダでスクロールが滑らか。

## #14 Table のセル編集（インプレース）
- 状態: 完了（案A・113/113 緑。app_filer 詳細ビューのリネームに組み込み済み）
- 優先度: 高
- 影響範囲: framework の `Table.zig`（CellEdit 相当の追加）、`table.md`、app_filer（詳細ビューのリネーム）
- 更新日: 2026-06-12
- 依存: #9（Table コア）。List の CellEdit 機構を移植する想定

### 何
Table のセルに編集セッションを足す。List の `CellEdit`（start / commit / cancel + 編集中セルを
recycle しない + フォーカス喪失時の決着）と同形を移植する。実需はファイラー詳細ビューでの
インプレースリネーム（M5 ではリストビューへ切り替えて回避している）。

### なぜ（M5 で表面化）
ファイラー M5 で詳細ビュー（Table）にリネームが無く、Rename 操作はリストビューへ強制切替で
代替した。Table v1 でセル編集を外した（編集対象が 2 次元化する・Tab 移動の決め事が要る）ぶんの
付けが、詳細ビューを実用しようとした瞬間に出た。作者評価（2026-06-12）で自動フィル / DnD より
優先度が高い。

### 候補アプローチ
- 案A: List の CellEdit をそのまま列セルに適用（編集は単一セル、行内 Tab 移動は持たない）。
  メリット: 既存機構の移植で済む。ファイラーのリネーム（Name 列だけ編集）には十分。
- 案B: セル単位の 2 次元編集 + Tab で隣セル移動（スプレッドシート的）。
  メリット: 汎用。デメリット: 決め事が多く実需を超える。
- 判断軸: ファイラーのリネームに必要な範囲（A で足りる）か、表計算用途まで見るか。
- 推奨: 案A（実需に絞る）。最終判断は作者。

### 決めること
案A/B、編集開始トリガ（Table にも `EditTrigger` 相当を置くか）、どの列を編集可能とするか
（列定義に `editable` フラグを足すか）。

### 完了条件
ファイラー詳細ビューでセルを直接リネームできる（リストビューへ切り替えずに）。doc + テスト。

### 完了メモ（2026-06-12）
案A で実装。`Table.CellEdit`（start/commit/cancel）+ `Cell.edit: ?CellEdit` + `EditPos{row,col}` +
`edit(row,col)` / `commitEdit` / `cancelEdit` / `getEditing`。編集可能列はその列のセルが `edit` を
持つかで決まる（列定義に editable フラグは置かず、List と同じ「cell.edit が非 null」方式）。
開始トリガは持たず manual のみ（アプリが F2/メニューから `edit(row,col)` を呼ぶ）。
reconcile で編集セルを recycle 除外 + 行が可視域外なら commit、編集行の外 press / ヘッダ click で
commit（focus-lost=commit）。app_filer 詳細ビューの Name 列に組み込み（list/details 両ビューで
インプレースリネーム可能に）。table.md / narrative/table.md 追記。埋め込みテスト2本追加。

## #15 Table の列の自動フィル
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework の `Table.zig`（レイアウト + リサイズ方針）、`table.md`
- 更新日: 2026-06-12
- 依存: #9（Table コア）

### 何
現状の Table は固定列幅（合計が viewport を超えたら横スクロール、足りなければ右に余白＝
Swing `AUTO_RESIZE_OFF` 相当）。余り幅を列に配る自動フィルを足す。実需はファイラー詳細ビューで
Name 列がウィンドウ幅に追従して伸びてほしいこと。作者評価（2026-06-12）で「あった方がいいが中」。

### なぜ（保留理由）
手動の列幅ドラッグと自動フィルの相互作用が体感マターで、実機を見てから方針を決めるのが安い
（Swing が auto-resize モードを 5 つ持つのはこの相互作用の置き場）。M5 で実機投入済みなので
作者がいつでも判断できる状態。

### 候補アプローチ
- 案A: 列ごとの grow 係数（`Column.grow`、既定 0）。余り幅を grow 比で配る。固定幅は grow=0 の特殊形で
  現挙動の上位互換（additive）。
- 案B: テーブル全体の resize ポリシー（最後の列が吸う / 全列按分 等を enum で選ぶ。Swing 風）。
- 判断軸: 列ごとに制御したい（A）か、単純な 1 ポリシーで足りる（B）か。ドラッグとの相互作用の単純さ。
- 推奨: 案A（grow=0 既定なら現挙動を壊さず additive に入る）。最終判断は作者。

### 完了条件
ファイラー詳細ビューで Name 列がウィンドウ幅に追従し、手動列幅ドラッグと破綻なく両立する。doc + テスト。

## #16 Table の DnD 用 y→行アクセサ
- 状態: 完了
- 優先度: 低
- 影響範囲: framework の `Table.zig`（公開アクセサ 2 つ）、`table.md`、app_filer（詳細ビューの DnD）
- 更新日: 2026-06-12
- 依存: #9（Table コア）

### 何
Table への drag&drop を外部（アプリの DnD コントローラ）が実装できるよう、ローカル y 座標から
行番号を返す公開アクセサ（例: `rowAtLocalY(y: f32) ?usize`）か、ヘッダー高さの公開を足す。

### なぜ（M5 で表面化）
List では DnD コントローラが `y / getRowHeight()` で行を割り出せたが、Table はヘッダーオフセットが
内部 const のため外部から行ヒットを計算できず、M5 で詳細ビューの DnD を見送った。
作者評価（2026-06-12）で「使い道がいまいち不明、優先度低」。実需が薄いので point-of-need。

### 完了条件
ファイラー詳細ビューでも行を別フォルダ / 場所へ DnD 移動できる（リストビューと同等）。doc + テスト。

### 完了メモ（2026-06-14）
`rowAtLocalY(y)` と `getHeaderHeight()` を追加。DnD の行 hit は前者で行い、ハイライト描画には header offset が要るため後者も公開した。

## #17 narrative/dnd.md のセクション重複を除去
- 状態: 未着手
- 優先度: 低
- 影響範囲: `framework/doc/narrative/dnd.md`（ドキュメントのみ）
- 更新日: 2026-06-13

### 何
`narrative/dnd.md` で「挿入先インジケータ」の見出しと配下 3 項目が二重に記載されている。
片方を削除して一本化する。

### なぜ
unsafe:true doc の textlint 一括掃除の作業中にサブエージェントが発見した。
textlint の検出対象ではない内容バグなので、その場では触らず起票した。

### 完了条件
重複セクションが 1 箇所に統合され、記述に齟齬が無い。

## #18 Table のセル / 列選択 (Swing の cell selection 相当)
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `Table.zig`（列用 SelectionModel + セル選択モード + 投影 / 描画 / ジェスチャ）、`table.md` / `selection_model.md`
- 更新日: 2026-06-13
- 依存: #10（行選択 / SelectionModel）

### 何
行選択に加え、 セル単位 / 列単位の選択を持つ。 Swing JTable と同じく、 セル選択は
「行選択モデル × 列選択モデルの交差」で表す（任意の (row, col) 集合ではなく矩形交差）。
列用に `SelectionModel` をもう 1 つ持ち、 セル選択モード時は
`isSelected = rowSel.isSelected(row) and colSel.isSelected(col)` で投影する。

### ユースケース
スプレッドシート的な操作（セル / 列の選択、 列の値のコピー、 ブロック編集）。
現状のドッグフーディング（ファイラー）は行選択しか要らず、 実需は無い（point-of-need）。

### 追加コスト（additive と見込む）
`SelectionModel` は次元非依存（index 集合 + anchor + lead）なので列にもそのまま使える。
追加は Table 側に集中する: 列用 `SelectionModel` フィールド、 セル選択モードのフラグ、
セル投影 / 描画 / ジェスチャの列対応。
既定は行選択のままなので、 行 API と SelectionModel は無改修。
よって今は積むだけにし、 スプレッドシート的な実需が出てから着手する。

### 完了条件
セル / 列を選択して取得でき、 選択セルがハイライトされる。 doc + テスト。

## #19 レイアウトの便利ユーティリティ（上の層に薄く足す）
- 状態: 未着手
- 優先度: 低
- 影響範囲: `Application` ファクトリ or 自由関数（LayoutManager / Component のプリミティブは変えない）
- 更新日: 2026-06-13

### 何
冗長になりがちな用途を、 プリミティブを増やさず上の層の糖衣で楽にする。
* `setFixedSize(w, h)` — min == max の糖衣（ピン留めを 1 行に）。
* `spacer(size)` / strut・glue 相当 — `filler()` の固定サイズ版。
* `padded(child, insets)` — 内部で filler 余白の `Panel` を作って返す（`Insets` はプリミティブにしない）。

### 却下（プリミティブにはしない）
`setPreferredSize`（捨てた概念を戻す）、 `Component.insets`（全 LayoutManager に inset 解釈を強いる）。

### なぜ今やらない
冗長さが実際に痛くなってから足す（point-of-need）。 記録の目的は、 足すとき
「上の層に薄く足す・プリミティブは増やさない」判断を再議論しないため。 関連: `doc/internal/typed_callbacks.md`。
（旧 `doc/internal/layout_helpers.md` から移設）

## #20 メニューのはみ出し対応（別ウィンドウ化）
- 状態: 実装中（メニューバー起点のメニューチェーンは別ウィンドウ化済み。PopupMenu / コンテキストメニューは未対応）
- 優先度: 低
- 影響範囲: メニュー系（popup の backend）、awt-c（GLFW フラグ）、`menu.md` / `narrative/menu_bar.md`
- 更新日: 2026-07-03
- 依存: 既存のメニュー overlay 実装

### 何
v1 はメニュー矩形をクライアント領域内に reposition / clip で収める。
画面端ではみ出すケース向けに、 装飾無し（borderless / undecorated）の別ウィンドウで描く方向。
GLFW の `GLFW_DECORATED` / `GLFW_FOCUS_ON_SHOW` / `GLFW_FLOATING` でほぼまかなえる前提。 タスクバー除外は native handle 経由。
`Menu.show(anchor)` の利用者 API は backend（埋め込み / 別ウィンドウ）を意識せず使えるよう保つ。

### なぜ今やらない
通常の画面サイズでは reposition / clip で足りる。 実需（小さい画面 / 端での大きいメニュー）が出てから。
（旧 `doc/internal/menu-bar-requirements.md` の v2 記述から移設）

### 進捗メモ（2026-07-03・部分完了）
別ウィンドウ backend そのものは実装され、メニューバー起点のメニューチェーンは移行済み。装飾なし OS 子窓
プリミティブ `framework/src/PopupWindow.zig`（`4532f51`）を足し、トップレベルメニューを OS 子窓化して
hover-switch / stale open_menu を解消（Phase 2 A+B・`c6a1080`）、サブメニューまで含めたチェーン全体を
OS 子窓で統一（Phase 2 C・`4d326c5`、HiDPI 配置・stale 化の構造的解消 `f22078e`、最終 `eb7fced`）。
ComboBox ドロップダウンも同じ PopupWindow へ載せ替え済み（`9cc44af`）。OS 子窓はクライアント領域外へ
はみ出せるため、メニューバー系メニューについては本項目の狙い（別ウィンドウ化）を満たす。
残件: PopupMenu / コンテキストメニューは依然 in-window overlay（`PopupMenu.zig` の `w.overlays.add`）で、
別ウィンドウ化されていない。ここが移行するまで本項目は完了にしない。関連: #34（PopupWindow のプール化）。

## #21 RadioButtonMenuItem
- 状態: 完了（Codex ハンドオフ試行の初回題材）。実装・factory・export・テスト（doClick 冪等 / ButtonGroup 排他）入り、`zig build test` 緑
- 優先度: 低
- 影響範囲: `RadioButtonMenuItem.zig`（新規）、`Application.radioButtonMenuItem` + root.zig export、`Component.role` に `.radio_button_menu_item`、`radio_button_menu_item.md`（spec/narrative）
- 更新日: 2026-06-14

### 何
CheckBoxMenuItem はあるが Radio 版が無い。 ButtonGroup と組んで排他選択のメニュー項目を出す。

### なぜ今やらない
実需が無い（menu-bar-requirements の旧「未決事項」から移設）。 出たら CheckBoxMenuItem を雛形に足す。

## #22 TabbedPane のタブの閉じるボタン
- 状態: 未着手
- 優先度: 中（テキストエディターのドッグフーディングで複数ファイルタブを閉じる実需が出ると「高」に昇格する）
- 影響範囲: framework の `TabbedPane.zig`（タブの hit 領域 + 閉じる×の描画 + `removeTab` / 新設 `takeTab` の去就）、`tabbed_pane.md` / `narrative/tabbed_pane.md`、example
- 更新日: 2026-06-14
- 依存: なし（由来: #12 TabbedPane の `framework/doc/tabbed_pane.md`「機能要望」から起票）

### 何
タブ 1 枚ごとに閉じる×印を置き、クリックでそのタブを閉じる。実需はテキストエディターの複数ファイルタブ
（開いているファイルを 1 枚ずつ閉じる）。現行は `removeTab(index)` をアプリが呼ぶしか閉じる手段が無い。

### なぜ（保留理由）
point-of-need。現行の固定ページ用途（設定ダイアログ / 詳細ペイン等）では閉じる操作が要らない。
テキストエディターの複数ファイルタブ着手で実需化する見込みで、その時点で所有権の扱いを決めるのが安い。

### 候補アプローチ
閉じたときの内容コンポーネントの所有権の扱い（narrative/tabbed_pane.md の `removeTab` 節が
「外した内容を呼び出し元に返す API は v1 に置かない」と明記しており、本項目はその判断の再開地点）:
- 案A: 閉じる = `removeTab`（内容を破棄）。メリット: 既存 API のまま機構ゼロ。
  デメリット: 未保存バッファを閉じる前にアプリが拾えない（破棄が先に走る）。
- 案B: 内容を呼び出し元へ返す `takeTab(index) *Component` を新設し、TabbedPane は所有権を手放すだけにする。
  破棄 / 保持はアプリが決める。メリット: エディターの「未保存です、保存しますか？」を内容を生かしたまま挟める。
  デメリット: 公開 API が 1 つ増え、所有権の向きが 2 系統（destroy する removeTab と手放す takeTab）になる。
- 案C: 閉じる前フック（CloseListener / vetoable）でアプリが拒否でき、許可されたら removeTab する。
  メリット: 破棄の責任を TabbedPane に残したまま veto できる。デメリット: リスナー機構が増える。
- 判断軸: エディターの未保存バッファ保護をどう実現するか。所有権をアプリに渡す（B）か、veto で止める（C）か、
  単純破棄で十分（A）か。
- 推奨: 実需（エディター）着手時に B か C を判断。最終判断は作者。

### 決めること
- 閉じる時の所有権（案A/B/C）。特に `takeTab` を入れるか、CloseListener で veto させるか。
- 閉じる×の表示条件（常時 / ホバー時のみ / 選択タブのみ）。
- 閉じる×の hit 領域とタブ選択 hit の取り合い（×を押したときは選択を変えない等）。

### 完了条件
タブごとに閉じる操作ができ、エディター（または実需アプリ）で未保存バッファを失わずにタブを閉じられる。
doc + テスト + example。

## #23 TabbedPane のタブのドラッグ&ドロップ並べ替え
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: framework の `TabbedPane.zig`（タブ列のドラッグ追跡 + `tabs` の順序入れ替え + ドロップ位置インジケータ）、`tabbed_pane.md` / `narrative/tabbed_pane.md`、example
- 更新日: 2026-06-14
- 依存: なし（dnd 機構との関係は候補アプローチを参照。由来: #12 の「機能要望」から起票）

### 何
タブ列の中でタブをドラッグして順序を入れ替える。`tabs` 配列の要素を動かすだけで、内容コンポーネントの
所有や埋め込み `Container` の子集合は不変（並びだけ変わる）。選択中タブと内容の対応はドラッグ後も保つ。

### なぜ（保留理由）
point-of-need。現行用途で並べ替えの要望は出ていない。閉じる（#22）より後でよい。

### 候補アプローチ
並べ替えの実装座（既存 dnd 機構を使うか否か）:
- 案A: TabbedPane 内のローカルなマウス追跡で完結する。press でタブをつかみ、capture して move でドロップ位置を
  求め、release で `tabs.orderedRemove` + 挿入を行う。dnd 機構（`framework/doc/dnd.md` の `Transfer` /
  `DragSource` / `DropTarget`）は使わない。メリット: 同一ウィジェット内の純粋な並べ替えは index 操作で済み、
  型交渉も荷物も要らない（List の drag-to-reorder と同じ発想、`SplitPane` のディバイダーと同じ
  press→capture→move→release の自前ジェスチャ）。デメリット: 別の TabbedPane へタブを引き出す将来機能には伸びない。
- 案B: 既存 dnd 機構（`DragSource` / `DropTarget` / `Transfer` の `Flavor.object` + type_tag）に載せる。
  メリット: 将来「別タブグループへタブを移す」「ウィンドウ間移動」へ additive に拡張しやすい。
  デメリット: 同一ウィジェット内の並べ替えには過剰で、荷物の往復が要る。
- 判断軸: 並べ替えのスコープ。strip 内だけ（A）か、TabbedPane 間 / ウィンドウ間まで見据える（B）か。
- 推奨: まず案A（strip 内に閉じる）。TabbedPane 間移動の実需が出たら案B へ寄せる。最終判断は作者。

### 決めること
- 並べ替えのスコープ（同一 strip 内のみ / TabbedPane 間）。それにより案A/B を選ぶ。
- ドロップ位置インジケータの見せ方（挿入線 / タブのスライド）。
- ドラッグ中につかんだタブを選択へ切り替えるか。

### 完了条件
タブをドラッグして順序を入れ替えられ、選択と内容の対応が保たれる。
doc + テスト（並べ替え後の index / 選択の数値検証）+ example。

## #24 TabbedPane の残りの繰り延べ機能（キーボード / 端配置 / overflow / アイコン）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: framework の `TabbedPane.zig`（機能ごとに paint / layout / processEvent）、`tabbed_pane.md` / `narrative/tabbed_pane.md`
- 更新日: 2026-06-14
- 依存: なし（由来: #12 の「機能要望」の残り。実需が出たものは本項目から分離して個別番号で起票し直す）

### 何
TabbedPane の残りの繰り延べ機能をまとめて記録する（いずれも `framework/doc/tabbed_pane.md`「機能要望」に列挙済み）。
- キーボードによるタブ移動（Ctrl+Tab / Ctrl+PageUp・PageDown、フォーカス時の ← / →）。focus / keybinding 機構に載せる。
- 下端 / 左端 / 右端のタブ配置（現行は上端固定）。`TabPlacement` enum を足し、layout / paint を配置別に分岐する。
- タブ列のスクロールまたは overflow 表示（タブが strip 幅を超えたときのスクロールボタン / overflow メニュー。
  現行は全タブを左から並べるだけ）。
- タブアイコン（タイトル左にアイコン。Button の icon+text と同じ measure / 描画を流用）。

### なぜ（保留理由）
いずれも point-of-need。現行の固定ページ用途では不要。キーボード操作は #6b のメニューナビゲーションと同様、
ドッグフーディングで実機を触ると最初に要望が出る候補。

### 候補アプローチ
各機能は独立に additive で足せる（配置は `TabPlacement` 既定 top、アイコンは省略可能フィールド、
overflow は strip 幅超過時のみ作動）。着手時に該当機能だけを本項目から分離し、個別番号で起票する。

### 決めること
- どの機能から着手するか（実需順）。分離して個別起票するか本項目内で進めるか。
- 各機能のスコープ（例: キーボードは Ctrl+Tab だけか ← / → も含むか）。

### 完了条件
着手した機能が動き、doc + テストが付く。本項目には未着手分の記録を残す。

## #25 Table / 詳細ビュー DnD の堅牢化（低優先 follow-up まとめ）
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `Table.zig`（`rowAtLocalY` + 埋め込みテスト）、app_filer の詳細ビュー描画（`dndTablePaint`）
- 更新日: 2026-06-14
- 依存: #9（Table コア）/ #16（DnD 用 y→行アクセサ）

### 何
#9 / #16 完了後のセッションで出た、Table と詳細ビュー DnD まわりの細かい堅牢化をまとめて記録する。
いずれも実 DnD 座標では発生せず実害は無い段階の防御 / テスト拡充 / 装飾の修正で、過剰に細分化せず 1 項目に束ねる。
- `Table.rowAtLocalY` の非有限（NaN / 巨大）y 入力ガード。現状 `@intFromFloat(@floor((y - HEADER_HEIGHT) / rh))`
  の前に範囲チェックが無く、`rh <= 0` ガードはあるが y の有限性は見ていない。実 DnD 座標では到達しないが、
  非有限 y で `@intFromFloat` が未定義動作になり得る。
- `Table.rowAtLocalY` のテスト拡充。現行テスト「rowAtLocalY accounts for header and scroll」は
  `row_height <= 0` / 空モデル / 境界 `y == scroll_top + HEADER` のケースを踏んでいない。追加時は
  `HEADER_HEIGHT` リテラルでなく `getHeaderHeight()` 基準で書く（リテラル直書きを避ける）。
- 詳細ビューのドロップ先ハイライト（app_filer `dndTablePaint`）が、スクロール時に最上段付近の行で
  pinned ヘッダーへ 1px 重なり得る。ハイライト矩形の y を `scroll_top + getHeaderHeight()` でクランプするか
  クリップする。app_filer 側の装飾であり framework 本体の不具合ではない。

### なぜ（保留理由）
3 件とも実害が観測されておらず（DnD 座標は常に有限・正の範囲、ハイライトの重なりは最大 1px）、
point-of-need。Table コアが安定した今、まとめて記録だけ残す。

### 完了条件
着手した項目について、ガード追加 / テスト追加 / クランプが入り `zig build test` 緑。本項目には未着手分を残す。

## #26 オーバーレイの寿命・不変条件の堅牢化（低優先 follow-up まとめ）
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `OverlayManager.zig`（`dismissAll`）、`Window.zig`（ドラッグ ghost overlay の寿命）、`framework/tests/overlay_lifetime_test.zig`
- 更新日: 2026-06-14
- 依存: なし

### 何
overlay overlay-lifetime 関連の textlint / 回帰対応セッションで出た、オーバーレイの寿命・不変条件まわりの
細かい堅牢化をまとめて記録する。いずれも現状の利用範囲では到達しない理論上の懸念。
- `OverlayManager.dismissAll` の降順ループ不変条件。`while (i > 0) { i -= 1; orderedRemove(i); on_dismiss() }`
  という降順 + orderedRemove の形は、`on_dismiss` が自分より下位 index の modal を remove すると要素が
  シフトして 1 件スキップし得る。現状 `on_dismiss` は所有者の `open` フラグを倒すだけで他 overlay を
  remove しないため起きないが、その前提をコードコメントで明記するか、ループ前にスナップショットを取る。
- ComboBox の overlay-lifetime 回帰テスト追加。`overlay_lifetime_test.zig` は今回 PopupMenu 版
  （window deinit が caller-owned popup を overlay リスト解放前に dismiss する）のみ追加した。ComboBox も
  caller-owned overlay を持つので同型のテストを足す。
- ドラッグ中にウィンドウ破棄が起きた場合の passthrough(ghost) overlay の寿命。`Window.deinit` の
  `dismissAll` は `modal_popup` のみ畳み passthrough は触らないため、ドラッグ ghost を出したまま
  ウィンドウが死ぬと `onDragDone` が解放済み `window.overlays` を触る理論上の UAF がある。今回スコープ外。

### なぜ（保留理由）
3 件とも現状の呼び出し規約では到達せず実害が観測されていない（`on_dismiss` は他 overlay を消さない、
ドラッグ中のウィンドウ破棄は通常起きない）。point-of-need でまとめて記録だけ残す。

### 完了条件
着手した項目について、コメント明記 / テスト追加 / ライフタイム対処が入り `zig build test` 緑。
本項目には未着手分を残す。

## #27 小アイコン手組み（drawCheck / paintSortIndicator）の脱・階段描画
- 状態: 未着手
- 優先度: 低
- 影響範囲: framework の `CheckBox.drawCheck`（`CheckBox.zig`）/ `Table.paintSortIndicator`（`Table.zig`）/ `CheckBoxMenuItem.drawCheckmark`（`CheckBoxMenuItem.zig`）
- 依存: awt#9（ベクター描画プリミティブ or テクスチャ方式の小アイコン）
- 更新日: 2026-06-18

### 何
チェックマーク・ソート caret を軸並行 `fillRect` の階段で手組みしている consumer 側の移行を記録するクロス参照。
awt に線・三角・多角形のプリミティブが無いことが原因で、本体の検討は awt 側の [awt#9](awt_backlog.md) にある
（プリミティブを足す / テクスチャで済ませる / lucide アイコンへ置換、の 3 案とスナップショット脆化のトレードオフ）。
本項目は awt#9 で方針が決まったら、上記 3 関数を新プリミティブ or アイコンへ載せ替えるという framework 側の follow-up。
なお LAF（Metal / JTattoo）向けのグラデ / 9-slice プリミティブは別系統で `doc/internal/awt_primitives_laf.md` に
設計済み（本項目の小アイコンとは目的が別だが、awt の描画語彙拡張という点で隣接する）。

### 完了条件
awt#9 の方針に沿って 3 関数の階段描画が解消され、スナップショットテストが緑。awt#9 の完了条件と一体で達成される。

## #28 ScrollPane のヘッダー領域とコーナー（JScrollPane パリティ：columnHeader / rowHeader / corner）
- 状態: 完了
- 優先度: 中（columnHeader 部分は実バグ起点。rowHeader + corner は低・将来）
- 影響範囲: framework の `ScrollPane.zig`（領域モデルの刷新 + レイアウト + ヘッダーのスクロール同期 + ヘッダー/コーナー view の所有）/ `scroll_pane.md`、`Table.zig`（自前ヘッダー pin の廃止）、将来の text editor（行番号 gutter）
- 更新日: 2026-07-03
- 依存: なし（awt は既存の drawImage / clip / Container で組める見込み。不足が出たら awt_backlog.md にクロス参照）

### 何
Swing `JScrollPane` 相当の固定ヘッダー帯とコーナーを ScrollPane に持たせる。現状の ScrollPane は
container = [viewport, hbar, vbar] + viewport が `view` を 1 枚持つだけで、ヘッダー / コーナー領域の概念が無い
（`ScrollPane.zig` の `container` / `viewport` / `hbar` / `vbar`、`create` で `container.add` する 3 子）。
これを概念的に 3x3 グリッドの領域モデルへ刷新する。

```
[UL       ][columnHeader][UR  ]
[rowHeader ][viewport    ][vbar]
[LL       ][hbar        ][LR  ]
```

- columnHeaderView: viewport の上の固定バンド。横スクロールには content と同期、縦には固定。
  **vbar はこのバンドの下から始まる**（ヘッダー帯を跨がない）。
- rowHeaderView: viewport の左の固定バンド。縦スクロールに同期、横は固定。
  **hbar はこのバンドの右から始まる**。将来のテキストエディタの行番号 gutter にそのまま使える。
- corner: ヘッダー帯 / スクロールバーが交わる四隅（UL / UR / LL / LR）の静的セル。
- スクロールバーは viewport の行 / 列だけに跨る（ヘッダー帯を跨がない）。columnHeader は水平オフセットのみ追従、
  rowHeader は垂直オフセットのみ追従、viewport は両方。

API スケッチ（シグネチャは提案、nimbus 流に整える）:
`setColumnHeaderView(self: *ScrollPane, view: *Component) void` /
`setRowHeaderView(self: *ScrollPane, view: *Component) void` /
`setCorner(self: *ScrollPane, which: Corner, view: *Component) void`（`Corner` = `.upper_left` / `.upper_right` /
`.lower_left` / `.lower_right`）。ヘッダー / コーナー view は ScrollPane が所有する。

### 即時の動機（バグ）
app_filer の詳細ビュー（Table を ScrollPane に入れている）で、縦スクロールバーが Table の列ヘッダー帯に被る
（作者がスクショで発見）。根因:
- ScrollPane の vbar は container の全高に並ぶ（ヘッダー帯の概念が無いため）。
- app_filer は Table 全体（ヘッダー帯ごと）を ScrollPane の `view` にしており、Table は自前でヘッダーを pin
  している（`Table.zig` の `scroll_top = @max(0, -position.y)` で算出し `paintHeader` を最後に描く＝viewport 上端に貼り付く）。
  縦スクロールでヘッダーは消えないが、vbar がその pin したヘッダー帯の右端に被る。

columnHeaderView を入れると **vbar がヘッダーの下から始まる**ため、これがこのバグの正しい解になる。
Table は自前 pin をやめ、ヘッダーを columnHeaderView として出す。

### なぜ（保留理由 / 優先度の刻み）
columnHeader 部分は実バグ（vbar 被り）が背後にあるので相対的に上（中）。rowHeader + corner は
completeness / enabler（低・将来。行番号 gutter は file chooser → text editor のロードマップで効く）だが、
「どうせなら」一緒に設計したいので同一 item に捕捉する。段階導入なら columnHeader を先に入れられる。

### 候補アプローチ
- 案A: 3x3 領域モデルへ一括刷新（columnHeader / rowHeader / corner をまとめて入れる）。
  メリット: 設計が一度で揃い、領域の取り合い（スクロールバーがヘッダー帯を跨がない）を 1 回で固められる。
  デメリット: ScrollPane のレイアウト刷新 + 同期配線 + 所有が一度に乗り、変更が大きい。
- 案B: columnHeader だけ先に入れて実バグを解消し、rowHeader + corner は実需（text editor）で後追い。
  メリット: バグ修正を小さく刻める。デメリット: 領域モデルを 2 回触る（後で rowHeader / corner ぶんの再レイアウト）。
- 判断軸: 一度の大きな刷新を許容するか（A）、バグ修正を先に小さく出すか（B）。
- 推奨: 段階導入を取るなら案B（columnHeader を先に）。設計は 3x3 で見据えつつ実装を割る。最終判断は作者。

### 決めること
- 着手の刻み（案A 一括 / 案B columnHeader 先行）。
- API の形（`setColumnHeaderView` / `setRowHeaderView` / `setCorner` のシグネチャと `Corner` enum、view の所有移転の規約）。
- ヘッダー view のスクロール同期をどう配線するか（columnHeader は h_model に、rowHeader は v_model に従属）。
- Table の自前ヘッダー pin（`paintHeader` + `scroll_top` 打ち消し）を廃止して columnHeaderView へ載せ替える移行手順。

### 影響・consumer 移行
- Table: 自前 pin を廃し、ヘッダーを columnHeaderView として出す。
- 将来の text editor: rowHeaderView を行番号 gutter に。
- ScrollPane: container の [viewport, hbar, vbar] を 3x3 領域モデルへリファクタ + スクロールバーがヘッダー帯を
  跨がないレイアウト + ヘッダーのスクロール同期配線 + ヘッダー / コーナー view の所有。

### 完了条件
app_filer 詳細ビューで vbar が列ヘッダー帯に被らない（vbar がヘッダーの下から始まる）。
Table が自前ヘッダー pin をやめ columnHeaderView でヘッダーを出す。`scroll_pane.md` に領域モデルと API を記載。
rowHeader / corner を入れた場合はそのレイアウト・所有も doc + テストで確認。

### 設計メモ（2026-06-19、ブランチ `feat/scroll-headers`）
作者決定の案A（一括）で 3x3 領域モデルを最初から確定。設計の正本は
`doc/internal/scroll_pane_3x3_design.md`、公開 API スケッチ + 領域モデル要約は
`framework/doc/scrollpane.md`「機能要望」に記載（未実装なので spec の型定義 / 関数定義へは未昇格 ＝ 追従監査は緑）。
確定した要点:
- 領域寸法・各セル矩形・縮退（ヘッダー無し時に現行 `[viewport, hbar, vbar]` へ一致）・コーナー畳み（行帯 × 列帯がともに非ゼロのときだけ可視）。
- vbar は columnHeader の下（y=top, 高さ center_h）、hbar は rowHeader の右（x=left, 幅 center_w）。スクロールバーはヘッダー帯を跨がない。
- ヘッダーは viewport と同型の内部 `Container`（ポート）でクリップ。columnHeader view 幅 = `view_size.width`、rowHeader view 高 = `view_size.height`（本体と列 / 行が一致）。
- 同期: 初期サイズは doLayout、毎フレーム追従は `onScrollChange`（columnHeader は `position.x=-h`、rowHeader は `position.y=-v`）。新しい配線機構は作らない。
- API は `!void`（初回ポート確保が fallible）。ヘッダー / コーナー view は ScrollPane 所有・`container.deinit` 単一経路で解放。view の null 化（外す）は機能要望。
- Table 移行: `Table.headerView()` が Table を借用する薄い `TableHeader`（`paintHeader` / `handleHeaderPress` を委譲、top=0）を返し、本体から `HEADER_HEIGHT` オフセットを除去。app_filer が `tsp.setColumnHeaderView(try tbl.headerView())` を配線。
- awt は既存 `paintAt` / `drawImage` / `Container` で充足（追加プリミティブ不要・awt_backlog 起票なし）。
- テスト: 領域計算・同期オフセットは GPU 非依存の純ロジック（`ScrollPane.create` は device / フォント不要）、ヘッダー実描画のみ snapshot / Robot ゲート。
- リスク明記: `ScrollLayout` は埋め込み値なので deinit を付けない（invalid-free）、`TableHeader` は Table より長生きさせない、Table 移行で HEADER_HEIGHT 前提の既存テストは書き換え。

### 完了メモ（2026-07-03）
作者決定どおり案A（一括）で 3x3 領域モデルを実装済み。`ScrollPane.zig` に `setColumnHeaderView` /
`setRowHeaderView` / `setCorner`（`corners: [4]?*Component`）と 3x3 レイアウト（vbar は columnHeader 帯の下、
hbar は rowHeader 帯の右から始まりヘッダー帯を跨がない）が入り、ヘッダー / コーナー view は ScrollPane 所有。
公開 API と領域モデルは `framework/doc/scrollpane.md`（`setColumnHeaderView` ほか 3 本の関数定義 + 3x3 の
領域説明）へ昇格済み（機能要望からスペックへ移動）。Table は自前ヘッダー pin を廃し `Table.headerView()` /
`TableHeader` 委譲で columnHeaderView としてヘッダーを出す形へ移行、`app_filer` 詳細ビューの DnD ハイライトも
body-local 座標契約へ合わせた（移行後の欠陥修正 `8eb28f2`）。即時動機だったバグ（詳細ビューで縦スクロールバーが
列ヘッダー帯へ被る）は vbar が columnHeader の下から始まることで解消。rowHeader / corner も同時に入ったため
JScrollPane パリティ（columnHeader / rowHeader / corner）を満たし、本項目全体を完了とする。

## #29 フォーム整列用のレイアウトマネージャ（GridLayout / GridBagLayout 系）
- 状態: 完了（最小 GridLayout。GridBagLayout 相当は将来の additive 拡張として据え置き）
- 優先度: 中（FileChooser / 設定ダイアログ等のフォーム整列で実需化済み）
- 影響範囲: framework 新規 LayoutManager（GridLayout）、`Application` ファクトリ or 自由関数、`FileChooser.zig`（下部の整列箇所の書き直し）、`layout-design.md` / 新規 doc
- 更新日: 2026-07-03
- 依存: なし（関連: #30 LAF×min_size footgun ＝この hack が踏んだ罠 / #19 レイアウトの便利ユーティリティ）

### 何
行×列でラベル列をそろえる**グリッド系レイアウトマネージャ**を足す。最初は 2 列フォーム
（ラベル＋フィールドの行を縦に積み、ラベル列の幅をそろえる）が組める最小の `GridLayout` でよい。
列幅を**レイアウト時に算出**するのが肝で、各 widget の `min_size` には焼き込まない（＝LAF 非依存・#30 の罠を踏まない）。
GridBagLayout 相当（セルの結合・weight・anchor・fill）は将来の additive 拡張として見据えるだけにする。

### なぜ（保留理由 / 実需）
FileChooser 下部の `File Name:` / `Files of Type:` ラベルを等幅にそろえるのに、各ラベルの
`min_size.width` を手で最大自然幅へ合わせる hack を使った（ブランチ `feat/fc-swing`・79651ff〜81cd075）。
本来は列幅をレイアウト時に算出するレイアウトマネージャの仕事で、ラベルの寸法に直書きするのは筋が悪い
（LAF 再適用での再測定と相性が悪く #30 の footgun を踏む。short 側に右余白を足してフィールド左端をそろえる、
固定 104px の当て推量、といった逃げが必要になった）。nimbus には現状
`BorderLayout` / `BoxLayout` / `PaddingLayout` / `CardLayout`（FileChooser 私有）はあるが、
行×列でラベル列をそろえるグリッド系が無い。設定ダイアログ等フォーム整列の需要は今後も繰り返し出る。

### 候補アプローチ
- 案A: 最小 `GridLayout`（固定 N 列・各列幅 = その列セルの自然幅の最大）を足す。2 列フォームに必要十分。
  メリット: 実需（ラベル整列）に絞れて小さい。`min_size` 焼き込みをやめられる。
  デメリット: セル結合・weight・fill が無い（複雑なフォームには将来 GridBag が要る）。
- 案B: 最初から GridBagLayout 相当（weight / anchor / fill / 列スパン）を入れる。
  メリット: 汎用。デメリット: 決め事が多く実需（2 列フォーム）を大きく超える。先回り。
- 判断軸: 当面のフォーム整列（A で足りる）か、汎用グリッドまで一気に見るか。CLAUDE.md「目指すゴール」は
  GridBagLayout を将来像に挙げるが、point-of-need では最小から。
- 推奨: 案A（最小 GridLayout で実需を満たし、GridBag は additive に後追い）。最終判断は作者。

### 決めること
案A/B。列幅算出の規約（自然幅の最大か min_width 指定併用か）。行高の扱い（行内最大か固定か）。
セル間スペーシング / 整列の API 形（`BoxLayout.*Spaced` と揃えるか）。ファクトリで出すか自由関数か。

### 完了条件
FileChooser 下部を新レイアウトで書き直し、`min_size` 直書き hack（#30）を撤去。
LAF を後から当て直しても整列が崩れないことをテスト（列幅算出を GPU 非依存の純レイアウト計算で検証）。doc 追従。

### 完了メモ（2026-07-03）
推奨どおり案A の最小 GridLayout を実装（`ec98077`、`n_cols=0` UB 回避と回帰補強 `96671ec`）。
`framework/src/GridLayout.zig` が列を意識した非均等列（各列幅 = その列セルの自然幅の最大）を算出する。
FileChooser 下部の 2 列フォームをこの GridLayout へ移行し、ラベルの `min_size` 直書き hack を撤去
（`7d75242`「2列フォームを GridLayout へ移行し min_size ハックを撤去」）。列幅がレイアウト時算出になったため
#30 の footgun（LAF 再適用で非明示 min_size が消える）をフォーム整列側では踏まなくなった。GridBagLayout 相当
（セル結合・weight・anchor・fill）は本項目の完了スコープ外で、将来 additive 拡張として据え置く。

## #30 footgun＝LAF 再適用が min_size を上書きする / min_size は setMinSize 経由必須
- 状態: 実装中（機構・LAF 再測定ガード・回帰テストは実装済み。規約の明文 doc 化と既存直書きの監査が残件）
- 優先度: 中
- 影響範囲: framework の `laf.zig`（applyLook の再測定条件）/ `Component.zig`（`min_size` / `min_size_explicit` / `setMinSize`）、関連 doc（`laf.md` か component 周り）、`min_size` を直書きしている既存箇所の監査
- 更新日: 2026-07-03
- 依存: なし（関連: #29 ＝この罠の回避にレイアウトマネージャを使う本来解）

### 何
LAF 再適用が非明示の `min_size` を黙って上書きする footgun を doc 化し、規約（min_size は `setMinSize` 経由必須）を定める。
可能なら検知 / 回帰テストも添える。

### 現象（確定事実）
`laf.zig:28` の `applyLook` は「コンテナでない and `tree_children` 無し and `!min_size_explicit`」のノードを
**再測定して `min_size` を上書き**する。`component.min_size.width` を直書きすると `min_size_explicit` が立たないため、
後から LAF を当て直すと再測定で上書きされ、設定が黙って消える。

### 実例（feat/fc-swing で再現）
FileChooser 下部ラベルの等幅化を `min_size` 直書きでやったら LAF 再適用で崩れた（fc-layout で再現）。
`setMinSize`（`min_size_explicit=true`）に直したら `applyLook` が再測定をスキップして保たれた（81cd075）。

### なぜ罠が二重か
- (a) LAF 再適用で**非 explicit な `min_size` が消える**（再測定が黙って上書きする）。
- (b) `min_size` は**直書きできてしまう**（`pub` フィールド）。`setMinSize` より手軽に見えるので誤用しやすい。

### 候補アプローチ（どれを採るかは作者判断）
- 案①: 「`min_size` は必ず `setMinSize` 経由」という規約を doc 化（`laf.md` か component 周りの doc）。
  メリット: 低コストで効く。デメリット: 強制力は無い（規約頼み）。
- 案②: debug ビルドで `min_size` 直書きを検知する仕組み。
  メリット: 誤用を機械的に止められる。デメリット: フィールド直書きの検知は難しい（実装手段が無ければ見送り）。
- 案③: `applyLook` の再測定条件・`min_size_explicit` の意味を doc に明記する。
  メリット: 罠の所在が doc から辿れる。デメリット: 規約（①）と合わせないと「読めば分かる」止まり。
- 判断軸: 規約で足りる（①③）か、機械的な防御まで要る（②）か。①③は両立してよい。
- 推奨: まず①③（規約＋仕組みの明記）。②は実装手段があれば追加。最終判断は作者。

### 決めること
採る案（①/②/③ の組み合わせ）。規約 doc の置き場所（`laf.md` か component 周りか）。
`min_size` を触る既存箇所を `setMinSize` 経由へ寄せる監査をどこまでやるか。

### 完了条件
規約を doc 化し、`min_size` を触る既存箇所が `setMinSize` 経由かを監査。
可能なら回帰テスト（`setMinSize` したノードが `applyLook` 後も `min_size` を保つ・直書きは上書きされる、を純ロジックで）。

### 進捗メモ（2026-07-03・部分完了）
機構と回帰テストは実装済み（`e4f50e0`「明示 min size を LAF 再適用から守る」）。`Component.setMinSize` が
`min_size_explicit` を立て、`applyLook` の leaf 再測定は明示済み min_size を保持する。widget 内部の派生更新は
`setMinSizeDerived` へ寄せ、List / TextArea / Table などが将来の LAF 変更で寸法凍結しないようにした。
回帰は `laf_test`（GPU 非依存で `setMinSize` 済みノードが applyLook 後も残る・Metal 適用後も縦 Slider の
明示 height=180 が残る）で押さえている。FileChooser 下部フォームの min_size 直書き hack は #29（`7d75242`）で撤去済み。
残件（本項目を完了にしない理由）: (1) footgun の規約（「min_size は必ず `setMinSize` 経由。直書きは applyLook で
黙って上書きされる」）の明文 doc 化（現状 `component.md` は `setMinSize` の存在を書くが罠と規約は明文化していない）。
(2) `min_size` を直書きしている既存箇所の監査 — 少なくとも `FileChooser.zig` の `places_sp.container.component.min_size.width = 180`
（サイドバー幅）が `setMinSize` を経由しない直書きとして残存。案②（debug 検知）は実装手段があれば追加。

## #31 汎用 Undo/Redo スタック（Command プリミティブ）
- 状態: 完了
- 優先度: 中（テキストエディター地ならしで text#5 の土台として実需化）
- 影響範囲: framework 新規モジュール（Command インターフェイス + UndoStack）、root.zig export、最初の consumer は text 層
- 更新日: 2026-07-03
- 依存: なし（最初の利用者は text#5 テキスト編集 undo。#5 編集コアの applyEdit が Command を push する）
- 設計: [edit_core_design.md](edit_core_design.md)（#5 と共同設計・Command / UndoStack / 可否変更リスナー / bounded）

### 何
GUI 横断の汎用 Undo/Redo プリミティブを framework 側に置く（text 層でなく framework に置く理由 ＝
ドロー / フォーム / テキストなど領域横断で使うため）。構成:
- Command インターフェイス: redo / undo・任意の tryMerge（直前 Command との併合可否）・任意の表示名
  （例 Undo Typing）。
- UndoStack: Command のリスト + 現在 index・canUndo / canRedo・可否が変わったら発火する変更リスナー
  （ツールバー / メニューの活性更新に使う）・bounded（上限を設け古いものを破棄）。
- バッファ非依存。最初の consumer はテキストだが、ドロー / フォーム編集にもそのまま使える。

### なぜ
GUI は各所で Undo/Redo を欲しがる。汎用化のコストはテキスト特化版とほぼ同じ（command ＋ スタック ＋
通知の 3 点）で、最初の利用者（テキスト編集）が実在するため YAGNI には反しない。地ならしで土台を先に
固めれば text#5 はそれを消費するだけになる。

### スコープ外（Swing UndoManager 由来の過剰・採らない）
- Document から UndoableEditListener 経由で edit を集める間接層。nimbus はエディタが Command を直接 push する。
- isSignificant（些末な edit をスキップする仕組み）。
- UndoManager 自身が CompoundEdit でもあるという再帰構造。
- Swing の 2 種のリスナーのうち「可否が変わった通知」は採用し、「edit が起きた通知（Document → manager の
  配線）」は採らない。

coalescing / グルーピング（連続入力を 1 undo 単位に・複合操作を 1 単位に）は tryMerge と begin-end group の
継ぎ目だけ用意し、policy（何を 1 単位とみなすか）は後回しにする ＝ これはエディタ UX の判断であって command
抽象の難しさではない（policy は text#5 で決める）。

### 決めること
- Command の最小 API（redo / undo / tryMerge / 表示名のシグネチャ）。
- 可否変更リスナーの形（既存の typed_callbacks / ChangeListener に寄せるか）。
- bounded のキー（件数か総バイトか）。
- merge / group の継ぎ目の形（tryMerge を stack が叩くタイミング・begin/endGroup の API）。

### 完了条件
Command + UndoStack が framework から export され、bounded と可否変更リスナーが動く。
text#5 がこのスタックを消費して undo/redo を実装できる（最初の consumer で実証）。doc + テスト。

### 完了メモ（2026-07-03）
`framework/src/UndoStack.zig` を新設し（`30647e5`「汎用 UndoStack を追加」）、`root.zig` から `UndoStack` /
`Command` を export。`Command` は redo / undo ＋ 任意 `tryMerge`、`UndoStack` は `canUndo` / `canRedo`・可否変更
リスナー・bounded（`pushAssumeCapacity` + 上限）を備え、埋め込みテストで push / undo / redo / merge を検証。
最初の consumer は text#5（`EditableText`）で、`ReplaceRange` command を push して undo/redo と coalescing を実現
（本項目の「最初の consumer で実証」を満たす）。スコープ外とした間接層 / isSignificant / 再帰 CompoundEdit は
入れていない。

## #32 カーソル形状の機構（per-component cursor ＋ hit-test ＋ glfwSetCursor 配線）
- 状態: 完了
- 優先度: 中
- 影響範囲: framework（Component の cursor プロパティ、Window の mouse-move hit-test）、awt（Window へのカーソル設定 API）、awt-c（glfwSetCursor / glfwCreateStandardCursor の薄いラッパー）
- 更新日: 2026-07-03
- 依存: なし

### 何
マウスがどのコンポーネント上にあるかでウィンドウのカーソル形状を切り替える機構を入れる。現状 framework に
カーソル形状の機構そのものが無い（`glfwSetCursor` 系が awt / awt-c に出ていない）。構成:
- per-component の cursor プロパティ（例: `Component.cursor`。既定 = arrow、I-beam / リサイズ等を指定可能）。
- mouse-move のたびにポインタ下のコンポーネントを hit-test し、その cursor をウィンドウへ設定する。
- awt に「ウィンドウのカーソル形状を設定する」API を足し、awt-c で glfw の標準カーソル
  （`glfwCreateStandardCursor`）＋ `glfwSetCursor` を薄くラップする（glfw 型は .c からのみ include し、
  Zig 向けヘッダーには露出しない既存方針を踏襲）。

### なぜ（保留理由）
テキストエディタ v1 の実機確認で表面化したギャップだが、エディタ回帰そのものではない既存の欠落。
awt / awt-c まで縦に配線が要る大きめ feature で、フォーカス / 無効描画の修正（ブランチ feat/focus-disabled・
[focus_disabled_design.md](focus_disabled_design.md)）とはスコープが別。実需はテキストエリア上の I-beam と
SplitPane 分割線上のリサイズカーソルが初期需要。

### 候補アプローチ
- カーソルの種類は glfw の標準カーソル（arrow / ibeam / crosshair / hand / hresize / vresize）から必要分だけ
  enum で公開する想定。カスタムビットマップカーソルは初版スコープ外（実需が出たら別項目）。
- hit-test は既存の mouse-move 配送経路（`Window.dispatchInput`）に相乗りできるか、専用の walk が要るかを
  実装時に見る。

### 決めること
- cursor プロパティの持ち方（Component の素のフィールドか、SplitPane のように能力構造体側か）。
- カーソル種別の公開 enum と、初版で含める種類（最低 arrow / ibeam / hresize / vresize）。
- 標準カーソルオブジェクトの寿命（ウィンドウ単位でキャッシュするか、awt 側でシングルトン的に持つか
  ＝ CLAUDE.md「グローバルを選ばない」と整合する形）。
- mouse-move hit-test を既存配送に相乗りさせるか専用経路にするか。

### 完了条件
テキストエリア上で I-beam、SplitPane 分割線上でリサイズカーソルになる。doc（component / awt の該当 spec）＋
テスト（hit-test → cursor 種別決定は GPU 非依存の純ロジックで、実際のカーソル切替は実機確認）。

### 完了メモ（2026-07-03）
per-component cursor ＋ mouse-move hit-test ＋ glfwSetCursor 配線を実装（`251a9a0`「カーソル形状機構を実装」、
設計 doc `f39da44`、起票 `2c44c4e`）。その後テストとモーダル時のカーソル復帰を修正（`1e56f1f`）。awt / awt-c まで
縦に配線され（glfw 標準カーソルの薄いラッパー）、テキストエリア上の I-beam・SplitPane 分割線上のリサイズカーソルが
初期需要どおり動く。text#10（カーソル変化機構）はこの機構で解決済み（text_backlog #10 参照）。

## #33 アクセラレータ文字列のパース（`"Ctrl+O"` → KeyStroke）
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework の `keybinding.zig`（パース関数の追加）、将来のキーバインド設定 UI / 設定ファイル読み込み
- 更新日: 2026-06-27
- 依存: メニュー項目表示 spec（[menu_display.md](menu_display.md) §2.1）の `formatAccelerator` / `keyLabel`

### 何
`menu_display.md` #2 で足す整形器 `formatAccelerator`（`KeyStroke` → `"Ctrl+Shift+S"`）の **逆操作**。
`"Ctrl+O"` のような文字列を `keybinding.KeyStroke` へパースする。修飾（`Ctrl` / `Shift` / `Alt`）＋ キー名を
読み取り、`Mods` ＋ `KeyCode` を組み立てる。

### なぜ（保留理由）
現状アクセラレータはコードで `KeyStroke.cmd(.s)` 等を直書きしており（`examples/app_texteditor/main.zig:209-219`）、
文字列からの構築は実需が無い（point-of-need 待ち）。実需はキーバインドのカスタマイズ
（設定ダイアログ / 設定ファイル）で、それ自体がまだ無い。

### 候補アプローチ
- パースは整形の逆で、**両者が同じキー名テーブル（`keyLabel`）を共有する形が望ましい**
  （`"F5"` ⇄ `.f5`、`"Left"` ⇄ `.arrow_left` の対応を 1 か所に閉じる）。整形側が正本のテーブルを持ち、
  パース側はその逆引きにする。
- 大小文字・区切り（`+`）の正規化、未知トークンのエラー表現（`?KeyStroke` で null か `!KeyStroke` でエラーか）を
  着手時に決める。

### 決めること
- 表示形式（修飾順序 Ctrl→Shift→Alt・キー名テーブル）に整合させる（`menu_display.md` §2.1 と同一テーブル）。
- 失敗時の表現（null / error）と、`command` の解釈（`"Ctrl"` を常に `Mods.command` へ寄せるか、
  macOS Cmd 修飾ビット整備後に `"Cmd"` も受けるか）。

### 完了条件
`formatAccelerator` の逆変換が round-trip でき（`parse(format(s)) == s` を主要キーで満たす）、単体テストが緑。

## #34 PopupWindow のプール化（OS 子窓の共有・取得/返却で回す）
- 状態: 未着手（評価済み・後回し）
- 優先度: 低
- 影響範囲: framework の `ComboBox.zig` / `Menu.zig`（PopupWindow の生成・保持・再利用）、awt-c の `dx12_internal.h`（`NM_RTV_HEAP_SIZE` / `NM_DSV_HEAP_SIZE`）、awt の swapchain 寿命
- 更新日: 2026-06-27
- 依存: なし

### 背景
ComboBox / Menu は popup ごとに装飾なしの OS 子窓（PopupWindow）を遅延生成して保持し、hide / show で再利用する
（`ComboBox.zig` の `ensurePopupWindow` / `destroyPopupWindow`、`Menu.zig` も同型。サブメニューは別 `Menu` が各自 1 枚持つ）。
累積保持＝一度でも開いた distinct な popup の数になる。一方で同時可視は高々 メニューチェーン深さ ＋ tooltip ＝ 2〜4 枚にとどまる。
ユーザーが「少数しか同時に出ないのにプールできないか」と提起した。

### 評価結論（後回しでよい理由）
descriptor heap が律速。`NM_RTV_HEAP_SIZE` / `NM_DSV_HEAP_SIZE` は各 64 の別 heap（`dx12_internal.h:35-36`）で、
1 swapchain ＝ 2 RTV ＋ 2 DSV を消費する（`dx12_swapchain.c`）→ 天井は 約 32 窓（offscreen RT ぶん減る。以前の「~16」は RTV / DSV を合算した誤り）。
典型アプリは一桁〜十数枚で余裕がある。仮に枯渇しても `Swapchain.init` が error → popup の open が error で失敗する graceful な機能不全（ハードクラッシュではない）。
顕在化するのは 25 個超の distinct な combo / menu を各々開く密画面のみ。

### 当たった時の第一手（最安）
`NM_RTV_HEAP_SIZE` / `NM_DSV_HEAP_SIZE` を 64 → 256 へ引き上げる（天井 32 → 128。awt-c の `#define` 2 本・リスク極小）。
これがプール化・開閉ごと破棄を費用対効果で圧倒する。

### プール化の実装コスト（大・着手時の留意）
着手するなら以下の churn を伴う。
1. 中身（popup_root ＝ メニュー項目 / コンボリスト）を借りた窓へ毎回 re-parent する churn。`Menu` の `item.parent` 管理と detached_look_roots 依存に毎回触れる。
2. ComboBox は focus 取得・メニューは no-activate を生成時の ex-style で決めているため、共有するには実行時トグル（脆い）か activate / no-activate の別プールが要る。
3. チェーン深さぶん同時貸し出しが起きる ＝ プール最小サイズ＝最大同時数。
4. 「取得 1 ＝ 返却 1」という新しい不変条件（二重返却・借用中 teardown という新しいバグクラス）。

### 代替
開閉ごとの生成破棄も累積ゼロにできるが、毎回 swapchain 生成 ＋ `nm_device_wait_idle` の GPU フラッシュ（`dx12_swapchain.c:170`）でジャンクが出る ＝ 頻繁に開くメニューに不利。

### 着手判断
back buffer の GPU メモリがアイドル占有で実問題化する、または天井接近の兆候が出てから着手する。
まず heap 定数を引き上げ、それでも GPU メモリが問題なら プール化（頻繁な再オープン向き）か 開閉ごと破棄（稀な再オープン向き）を選ぶ。
