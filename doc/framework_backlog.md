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
