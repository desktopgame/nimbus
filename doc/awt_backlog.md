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
