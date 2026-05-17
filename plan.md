# nimbus 進行中の計画

このファイルは進行中の検討事項を一時的にまとめる場所。
確定して長期的に残す価値があるものは `CLAUDE.md` へ、具体的なタスクに落ちたものは `todo.md` へ流す。

## v1 テキスト機能スコープ

[2026-05-17 整理]

GUI フレームワークとして v1 で提供するテキスト関連機能の方針。

### v1 でやる

#### 表示
- 単一行テキスト描画

#### TextField (単一行入力)
- 文字挿入 / Backspace（codepoint 単位）
- 矢印キー（1 文字単位 ＝ codepoint）
- クリックでカーソル位置決め
- ドラッグで選択
- Shift+矢印で選択拡張
- Ctrl+A で全選択
- Cut / Copy / Paste（Ctrl+X / C / V）
- Read-only モード

#### TextArea (複数行入力)
- 複数行表示 + ↑↓ で行移動（明示的 `\n` のみ、auto-wrap なし）
- Page Up / Page Down
- Ctrl+Home / Ctrl+End（文書頭 / 末）
- 横スクロール

#### IME / システム連携
- IME 確定文字の受信（GLFW char callback 経由）
- システムクリップボード（UTF-8）

#### 描画
- キャレット点滅

### v1 ではやらない、将来確実に必要

- テキスト省略表示（`Long fil...`）
- Tab stops
- リッチテキスト（1 Label 内で色 / 太字 / サイズ混在）
- Home / End（行頭 / 行末。優先度高くないがいずれ）
- Ctrl+矢印（word jump）
- ダブルクリックで単語選択
- Placeholder text
- Max length 制約（優先度低いがいずれ）
- Bold / Italic
- Underline / Strikethrough
- ドラッグ&ドロップ（テキスト限定ではなく汎用機能として設計）
- I-beam カーソル（汎用 SetCursor 機構はウィンドウリサイズ / スプリットペイン用に v1 で必要、TextField への配線が v1 外）

### v1 ではやらない、優先度低

- Undo / Redo（ユーザー側で実装可能だが一般的なので提供したい）
- Text shadow / outline
- TextArea 内の自動 word wrap

### v1 ではやらない、将来やるか不明

- 折り返し全般（Label / Button も v1 は一行のみ許容）
  - 文字単位の自動 wrap
  - 空白で break（Latin 単語境界）
  - CJK 禁則処理
- インライン画像（リッチテキストの一部）
- IME 変換中の inline 表示（プラットフォーム API 直叩き必要）
- スクリーンリーダ統合

### やらない（永続的）

- BiDi（Hebrew / Arabic 右→左）
- Password モード
- スペルチェック

### 設計上の補足

v1 でやらないが、API 設計時に将来を見越して抽象を整えるもの:

- **codepoint → grapheme cluster 移行**: TextField の Backspace / カーソル移動 API は v1 では codepoint 単位だが、将来 grapheme cluster 単位に差し替え可能な抽象 (`countCharacters` / `deleteBackward` 等) で設計する。バイト index を直接公開しない。
- **メニュー類は自前描画**: コンテキストメニュー / メニューバー含めて nimbus 内で描画する方針。ただし将来 native メニュー（Windows: `TrackPopupMenu` / Mac: `NSMenu`）に切り替えられる抽象を残す。
- **ドラッグ&ドロップは汎用機能**: テキスト D&D 専用ではなく、widget 全般の D&D を扱う仕組みとして設計する（v1 では未実装）。
- **スクロールバーは汎用 widget**: Swing の `JScrollBar` / `JScrollPane` 同様、テキスト専用ではない汎用部品として設計する。TextArea の横スクロールはこれを使う。
