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
- 状態: 未着手
- 優先度: 中（テキストエディターのドッグフーディング着手で「高」に昇格する）
- 影響範囲: framework の `TextField.zig`（816 行）/ `TextArea.zig`（884 行）、`textfield.md` / `textarea.md`
- 更新日: 2026-06-12
- 依存: なし（text#3 との同時実施は推奨から外れた — 下記「推奨の変更」参照）

### 何
TextField と TextArea がテキスト編集の核ロジック（キャレット移動、選択範囲、クリップボード連携、
codepoint 境界の歩行、IME preedit の保持）をそれぞれ独立に実装している。
片方で直したバグがもう片方に残る古典的なリスクがあるため、共有可能な編集コアを抽出するかを検討する。
Swing が Document モデルの共有で解いていた問題に相当する。

### なぜ（保留理由）
現時点で両者の挙動差として表面化したバグは未報告で、実害より構造リスクの段階。
また text#3（書記素クラスタ移行）で codepoint 歩行のロジックは書き直しになる予定なので、
いま抽出してもすぐ上書きされる。抽出のタイミングを text#3 と揃えるのが効率的。

### 候補アプローチ
- 案A: text#3 着手時に同時実施 — 書記素クラスタ対応の境界歩行・編集操作を最初から共有モジュール
  （例: `text_edit.zig`: バッファ + キャレット + 選択 + 境界歩行。描画・イベント処理は含まない）として書き、
  TextField / TextArea 両方をそこへ載せ替える。
  メリット: 書き直しが 1 回で済む。クラスタ対応のテストが共有コアに 1 セットで済む。
  デメリット: text#3 の作業がその分大きくなる。
- 案B: 先に現行 codepoint 実装のまま共通化し、text#3 は共通化後のコアに対して行う —
  メリット: 共通化と クラスタ対応を別々に検証できる（一度に変える量が小さい）。
  デメリット: 工程が 2 回になる。
- 判断軸: 1 回の大きな変更を許容するなら A、段階的検証を優先するなら B。
- 推奨: 旧推奨は案A だったが案B寄りに変更（下記「推奨の変更」）。最終判断は作者。

### 推奨の変更（2026-06-12、ドッグフーディング目標による）
当面の目標が「ファイラー / テキストエディターをドッグフーディングで作る」に決まり、前提が変わった。
旧推奨の案A（text#3 書記素クラスタ移行と同時に抽出）は「共通化単体では利用者に見える変化が無い」
ことを根拠にしていたが、エディターには **undo/redo** が必須で、これは編集コアに住む機能である。
重複した 2 実装の上に undo を載せると「片方で直したバグがもう片方に残る」リスクがいきなり
倍の面積で現実になるため、エディターが先に編集コアの書き直しを強制する。

新推奨: **エディター着手の頭で、codepoint 単位のまま編集コアを抽出し（案B寄り）、
undo/redo はその共有コアに実装する**。text#3（書記素クラスタ）は後からコア内の境界歩行関数を
差し替えるだけにする。旧案Aの利点（書き直し 1 回）は「コアが 1 つなら歩行関数の差し替えは局所」
で実質保たれる。

### 決めること
A/B のどちらか（推奨は上記のとおり案B寄り＋undo/redo をコアに含める）。
共有コアのデータ構造（単一バッファか、TextArea の行構造を内包するか）と、
IME preedit を共有コアに含めるか各ウィジェット側に残すかの線引き。
undo の粒度（キーストローク毎か、単語/連続入力のまとめか）も着手時に決める。

### 完了条件
キャレット・選択・クリップボード・境界歩行のロジックが単一モジュールに存在し、
TextField / TextArea 双方がそれを使う。編集系の単体テストが共有コアに対して書かれ、
既存の snapshot テスト・examples（widget_textfield / widget_textarea）の挙動が変わらないこと。

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
- 状態: 実装中（コア実装済み・111/111 緑。詳細表示の example/ファイラー組み込みが残）
- 優先度: 高
- 影響範囲: framework 新規モジュール（Table / TableModel / 列定義）、theme、example、FileChooser 設計
- 更新日: 2026-06-12
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
共有モデルで List⇄Table 切替を実証。M5 で出た Table への追加要望 (実機フィードバック):
* **列の自動フィル** — 実機で要否を見る対象 (作者確認待ち)。
* **DnD 用の y→行アクセサ** — Table への drag&drop には行ヒット判定が要るが、ヘッダーオフセットが内部 const のため
  外部 (アプリの Mover) が行を割り出せない。`rowAtLocalY(y) ?usize` 的な公開アクセサか header height 公開が要る
  (List は y/row_height で済んでいた)。M5 では詳細ビューの DnD を見送り。
* **セル編集** — 詳細ビューのインプレースリネームに必要 (M5 はリストビューへ切替で回避)。

### 完了条件
ファイラーの詳細表示が Table で動き、ヘッダーソートと列幅ドラッグが操作できる。doc + テスト + example。

## #10 List / Table の複数選択
- 状態: 未着手
- 優先度: 中
- 影響範囲: List（selected の型変更 or 選択モデル分離）、Table（#9）、app_filer（一括削除 / 移動）
- 更新日: 2026-06-12
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
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework 新規モジュール、example
- 更新日: 2026-06-12
- 依存: なし

### 何
Swing `JTabbedPane` 相当。タブバー + 中身の切り替え、タブの追加 / 削除、閉じるボタン。
実需はファイラーの複数ディレクトリタブ、およびテキストエディターの複数ファイル（こちらが本命の見込み）。

### 完了条件
タブの追加 / 切り替え / 削除が動き、どちらかのドッグフーディングアプリで実用されている。doc + テスト。

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
