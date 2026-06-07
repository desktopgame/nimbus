# framework バックログ
framework 層（Component / Container / Window / 各ウィジェット）で後回しにした項目。
書き方は [backlog.md](backlog.md) を参照。

由来: 2026-06-07 の doc↔実装 追従監査（CLAUDE.md「doc と実装の追従関係」基準）で、
「doc にあるのに実装に無い」genuine な欠落として検出され、実装するか doc から落とすか作者判断が要るもの。

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

加えて `doc/test.md`:92-118 が予定する framework のレイアウトテスト基盤（`framework/tests/`）はレイアウト系（`border_layout_test` / `box_layout_test` / `snapshot_test`）が入って一部実現済み。上記の純ロジック系をどこに置くか（各 `src` の test ブロック or `framework/tests/`）も決める。

### なぜ（保留理由）
TextField 着手を止めるほどの実害は無い（描画は snapshot で間接カバー、致命的なロジックバグは未報告）。一方で Window.dispatchInput / TextField 周りは focus / IME / blink timer の追加で状態空間が再構築されるため、いま固めても上書きされる。設計が安定した領域から順に足したい。

### 候補アプローチ
- 案A: 高リスクな純ロジック（`BoundedRangeModel` / `ChangeListenerList` / `Container.remove`）を先に単体テスト化。snapshot scene は後追い。
- 案B: snapshot scene を一括追加して見た目の回帰網を張ってから、純ロジックを足す。
- 判断軸: ロジックバグの早期検出を取るなら A、見た目回帰の網羅を取るなら B。

### 決めること
着手順（A/B）。純ロジックテストの置き場所（各 `src` test ブロック or `framework/tests/`）。`Window.dispatchInput` を今やるか TextField 後に回すか。

### 完了条件
未カバー項目のうち着手対象を決め、テストを追加して緑。`doc/test.md` の予定との対応を更新。

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
