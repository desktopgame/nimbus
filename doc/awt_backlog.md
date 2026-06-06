# awt / awt-c バックログ
awt（描画バックエンド抽象）・awt-c（GLFW / FreeType / DX12 / Metal の薄いラッパー）層で後回しにした項目。
書き方は [backlog.md](backlog.md) を参照。

由来: 旧 `todo.md`（backlog 規約より前のフラットな TODO）の "Later" のうち、CLAUDE.md の目標と重複しない
ものをここへ移した。`todo.md` の Now/Next は実装済み、Done は git 履歴、宣言的レイアウト / Linux /
Python・JS バインディングは CLAUDE.md に目標として記載済みのため移送せず。

---

## #1 ビルド時シェーダーコンパイルへの移行
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: awt-c（`nmCompileShader`）、ビルド（DXC / Metal compiler 導入）
- 更新日: 2026-06-02
- 依存: なし

### 何
現状シェーダーは実行時コンパイル（awt-c の `nmCompileShader` 経由）。これをビルド時コンパイル
（Windows: DXC、Mac: Metal compiler）に移す。起動コスト削減・配布時のドライバ依存低減が狙い。

### なぜ（保留理由）
実行時コンパイルで動いており、ビルド時化はツールチェーン導入（DXC/metal）とクロスコンパイルへの影響を
要検討。実需（起動コスト・配布要件）が出てから。

---

## #2 `nmAwtInit` / `nmTerminateAwt` の命名最終確認
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt-c 公開 API 名
- 更新日: 2026-06-02
- 依存: なし

### 何
awt 初期化/終了の API 名を最終確認する（`nmInit` だと汎用すぎる懸念。`nmAwtInit` 等に寄せるか）。
公開 ABI 名なので決めたら早めに固定したい。

---

## #3 vendor/glfw の大きいバイナリ資産の整理
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: リポジトリ（vendoring）
- 更新日: 2026-06-02
- 依存: なし

### 何
`vendor/glfw-3.4/` の `glfw.ico` 等のバイナリ資産を Git LFS に流すか、不要なら除外するか整理する。
リポジトリ肥大の抑制。

## #4 buffer bind 系の診断情報と実装のズレ (offset 境界 / 256 アライン)
- 状態: 未着手
- 優先度: 中
- 影響範囲: awt-c の `nmBindVertexBuffer` / `nmBindIndexBuffer` / `nmBindConstantBuffer`（`dx12_buffer.c` / `metal_buffer.m`）、`awt-c/doc/buffer.md`
- 更新日: 2026-06-07
- 依存: なし

### 何
2026-06-07 の doc↔実装 追従監査で検出。`buffer.md` の `### 診断情報` が以下の検査を約束しているが、実装に該当チェックもログも無い:
- `nmBindVertexBuffer`（doc:79）: `offset` が buf サイズ以上で `[ERROR] ... offset out of bounds`。実装（`dx12_buffer.c:80-88`）は無条件に `buf->size - offset` で view 作成（offset > size で負値ラップの危険）。
- `nmBindIndexBuffer`（doc:93）: 同上（`dx12_buffer.c:90-98`）。
- `nmBindConstantBuffer`（doc:132）: `offset` が 256 の倍数でないとき `[ERROR] ... not aligned to 256`。実装（`dx12_buffer.c:100-132`）に 256 アラインチェック無し。なお doc:125 は既に「256 の倍数であること。違反は UB」と事前条件で書いており、診断情報と二重・矛盾している。

診断情報を信じて呼ぶ利用者が、実際にはチェックされず壊れうる。

### なぜ（保留理由）
「ガードを実装する」か「doc を UB 事前条件に寄せて診断行を削除する」かは、awt-c のバインド系 API の安全契約の選択であり作者判断。即 doc 削除に倒すと runtime の安全網を下げる方向なので一旦保留。

### 候補アプローチ
- 案A: 実装にチェック + ログを足す — doc に実装を合わせる。メリット: 約束どおりの安全網。デメリット: bind ホットパスに分岐追加。
- 案B: doc を UB 事前条件に寄せ、診断情報行を削除 — 実装に doc を合わせる（追従基準のデフォルト）。`nmBindConstantBuffer` は既に UB 事前条件があるので診断行を消すだけ。vertex / index は事前条件「`offset` は buf サイズ以内。違反は UB」を足して診断行削除。メリット: ホットパスを増やさない・即追従。デメリット: 安全網は無いまま。
- 判断軸: bind 系のホットパス性能を取るなら B、デバッグ時の安全網を取るなら A（debug ビルドのみ assert にする折衷も可）。
- 推奨: 折衷（debug で assert、release はノーチェック、doc は「debug で検出 / release は UB」に統一）。最終判断は作者。

### 決めること
A / B / 折衷 のいずれか。3 関数で揃える。

### 完了条件
選んだ方針で実装 or doc を更新し、`buffer.md` の `### 診断情報` と実装が一致する状態。

## #5 EventQueue.invokeAndWait の UI スレッド呼び出し診断（release でログ無し）
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt の `EventQueue.invokeAndWait`（`EventQueue.zig`）、`awt/doc/event_queue.md`
- 更新日: 2026-06-07
- 依存: なし

### 何
`event_queue.md`:93 が「UI スレッドから `invokeAndWait` を呼ぶと release ビルドでは `[ERROR] [event_queue] invokeAndWait called from UI thread (would deadlock)` を出して return」と書くが、実装（`EventQueue.zig:87-93`）は `std.debug.assert(false); return;` のみ。release（ReleaseFast / Small）では assert が no-op になり、**何のログも出さず黙って return** する。

### なぜ（保留理由）
release でデッドロック回避の sentinel return をするとき、診断を出すか黙るかは設計判断。doc は「ログを出す」前提で書かれているので、ログを足すか doc を「release は無診断 return」に直すか作者が選ぶ。

### 候補アプローチ
- 案A: 実装に release でも出る `nm_log`（ERROR）相当を足す — doc に実装を合わせる。誤用が静かに握り潰されないメリット。
- 案B: doc:93 を実装に合わせ「debug: panic / release: 無診断で即 return」に書き換え。追従基準のデフォルト。
- 推奨: 案A 寄り（静かなデッドロック回避は気付けないと厄介）。ただし最終判断は作者。

### 決めること
A（ログ追加）か B（doc を無診断 return に修正）か。

### 完了条件
選んだ方針で実装 or doc を更新し、`event_queue.md`:90-93 と実装が一致。
