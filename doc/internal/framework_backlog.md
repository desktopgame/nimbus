# framework バックログ
framework 層（Component / Container / Window / 各ウィジェット）で後回しにした項目。
書き方は [backlog.md](backlog.md) を参照。

由来: #1〜#3 は 2026-06-07 の doc↔実装 追従監査（CLAUDE.md「doc と実装の追従関係」基準）で、
「doc にあるのに実装に無い」genuine な欠落として検出され、実装するか doc から落とすか作者判断が要るもの。
#4〜#5 は 2026-06-11 のプロジェクト全体評価で構造リスクとして指摘されたもの。

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

## #4 ルックアンドフィール切り替えの土台（色・メトリクスの間接層）
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework の全ウィジェットの paint（`Button.zig` / `CheckBox.zig` / `Slider.zig` / `Menu.zig` / `TextField.zig` ほか約 20 種）、`Component` または `Application` への theme 参照の追加
- 更新日: 2026-06-11
- 依存: なし

### 何
CLAUDE.md「目指すゴール」が Swing から引き継ぐ特徴として「ルックアンドフィールの切り替え」を掲げているが、
現状 framework 層に theme / LAF に相当する概念が存在しない。
各ウィジェットの paint が色を直接リテラルで持っている（例: `Button.zig` の `Color.rgb(0.78, 0.82, 0.92)` 等）。
ゴールに向けた最初の一歩として、描画時に色・メトリクス（角丸半径、ボーダー幅、パディング等）を
「どこかから引く」間接層を入れるかどうか、入れるならどの形かを決めたい。

### なぜ（保留理由）
実需（テーマを切り替えたい利用者）はまだ無い。一方でウィジェットは既に約 20 種あり、
描画判断（色リテラル・ハードコードされたメトリクス）が各 paint に焼き込まれた状態が続くほど
レトロフィットの作業量が増える。「先回りで作り込まない」原則と「放置コストが単調増加する」性質が
衝突する項目のため、全実装ではなく土台だけ早めに入れるかを作者が判断すべき。

### 候補アプローチ
- 案A: テーマテーブル（色・メトリクスの値カタログ）だけ先に導入 —
  `Theme` 構造体（`button_bg` / `button_bg_hover` / `selection_bg` … の名前付き値の集合）を定義し、
  各ウィジェットの paint はリテラルの代わりにそこから引く。描画ロジック自体は各ウィジェットに残す。
  メリット: 変更が機械的（リテラル → テーブル参照の置換）で、ダーク化・配色変更程度の切り替えは即可能。
  デメリット: 形状や描画手順まで変えるフル LAF はできない（それは将来の拡張）。
- 案B: Swing の ComponentUI 風に描画を委譲オブジェクトへ分離 —
  ウィジェットごとに UI delegate（paint を担う vtable）を持ち、LAF はその差し替えとして表現する。
  メリット: 形状・挙動まで含む本格的な LAF 切り替えが最初から成立する。
  デメリット: 全ウィジェットの paint の移設という大工事で、API 安定化フェーズの今やるには重い。
  delegate の寿命・所有権の設計も新たに必要。
- 案C: 何もしない（v2 で一括対応） —
  メリット: 今のスコープ（テキスト・安定化）に集中できる。
  デメリット: ウィジェットが増えるほど移行コストが増え続ける。新ウィジェット追加のたびに負債も増える。
- 判断軸: 「ゴールへの布石を低コストで打つ」なら A、「LAF の最終形を最初から作る」なら B、
  「point-of-need の徹底」なら C。
- 推奨: 案A。リテラル排除は後からやるほど高くつく一方、テーブル参照化なら設計の後戻りがほぼ無い
  （案B に進む場合も Theme テーブルはそのまま使える）。最終判断は作者。

### 決めること
A/B/C のどれか。A の場合はさらに:
- `Theme` の置き場所と引き方（`Application` が 1 個持ち、paint 時に `Graphics` 経由か parent chain 経由で引く等）
- 切り替えの単位（アプリ全体のみか、ウィンドウ単位まで見据えるか）
- 値の命名規約（ウィジェット別 `button_bg` か、役割別 `surface` / `accent` か）

### 完了条件
A なら: `Theme` 構造体を定義し、全ウィジェットの paint から色リテラルが消えてテーブル参照になる。
テーマ値を 1 か所変えると全ウィジェットの見た目に反映されることを snapshot テストで確認。
spec doc（theme.md 等）を新設し型定義と引き方の契約を記述。

## #5 TextField / TextArea の編集コア共通化
- 状態: 未着手
- 優先度: 中
- 影響範囲: framework の `TextField.zig`（816 行）/ `TextArea.zig`（884 行）、`textfield.md` / `textarea.md`
- 更新日: 2026-06-11
- 依存: なし（ただし text#3「書記素クラスタ単位の編集」と同時にやると移行が 1 回で済む）

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
- 推奨: 案A。共通化単体では利用者に見える変化が無く、独立工程にする価値が薄い。最終判断は作者。

### 決めること
A/B のどちらか。共有コアのデータ構造（単一バッファか、TextArea の行構造を内包するか）と、
IME preedit を共有コアに含めるか各ウィジェット側に残すかの線引き。

### 完了条件
キャレット・選択・クリップボード・境界歩行のロジックが単一モジュールに存在し、
TextField / TextArea 双方がそれを使う。編集系の単体テストが共有コアに対して書かれ、
既存の snapshot テスト・examples（widget_textfield / widget_textarea）の挙動が変わらないこと。
