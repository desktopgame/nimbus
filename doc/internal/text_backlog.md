# テキスト機能バックログ
テキスト関連（Label / TextField / TextArea / フォント / IME）で v1 から外した・後回しにした機能。
書き方は [backlog.md](backlog.md) を参照。

由来: v1 テキストスコープの決定記録 [plan.md](../../plan.md) の「初版ではやらない／いずれ必要」項目を、
実装で追える backlog に移したもの（`plan.md #N` は plan.md の機能番号）。v1 でやる決定の多くは既に実装済み
（TextField / TextArea / キャレット点滅 / クリック位置決め / ドラッグ選択 / クリップボード / IME 確定 等）。

---

## #1 IME 変換中の inline 表示（composition string）
- 状態: 未着手
- 優先度: 高
- 影響範囲: TextField / TextArea、awt-c の IME 連携（win32_ime.c / cocoa_ime.m）
- 更新日: 2026-06-02
- 依存: なし

### 何
未確定文字を TextField 内に下線付きで直接表示する（plan.md #32）。CLAUDE.md「文字コード」で
**優先度高で取り組みたい**と明記（Swing も対応）。plan.md 段階では「初版ではやらない」だったが、
CLAUDE.md の方針が上書きする。

---

## #2 テキスト折り返し・省略
- 状態: 棚上げ
- 優先度: 中
- 影響範囲: Label / Button / TextArea、テキストレイアウト
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #2/#3/#4（文字単位 / 単語境界 / CJK 禁則の折り返し）・#5（省略 `Long fil...`）・#29（TextArea の
word wrap）。Label/Button は v1 で一行のみ許容のため消費先が無く保留。省略と TextArea の word wrap は
「確実にいずれ必要」。line break iterator が前提。

---

## #3 書記素クラスタ単位の編集・カーソル移動
- 状態: 棚上げ
- 優先度: 中
- 影響範囲: TextField / TextArea、テキストモデル
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #11（Backspace/Delete）・#12（矢印移動）を codepoint 単位から grapheme cluster 単位へ。
CLAUDE.md「書記素クラスタ」のとおり v1 は codepoint で、**バイト位置に直接依存しない実装**にしてあるので
差し替え可能な前提。ziglyph メンテ停止等の事情は [[project-emoji-grapheme-deferred]] 参照。

---

## #4 単語境界・行頭行末のナビゲーション
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: TextField / TextArea
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #13（Home/End）・#14（Ctrl+矢印 word jump）・#18（ダブルクリックで単語選択）。#14/#18 は
word break 判定（空白判定だけの簡易版でも可）が前提。Home/End は安価だが優先度低。

---

## #5 Undo / Redo
- 状態: 棚上げ
- 優先度: 中
- 影響範囲: TextField / TextArea、編集モデル
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #21。実装は重め。利用者側でも実装可能だが、一般的なユースケースなので提供したい。

---

## #6 TextField 補助機能（placeholder / max length / その他）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: TextField
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #23（placeholder）・#24（max length 制約）。どちらも安価だが優先度低。placeholder は
「確実にいずれ必要」。

---

## #7 リッチテキスト・インライン画像・タブストップ
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 新 widget / テキストレイアウト（v2+ 想定）
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #7（1 Label 内で色/太字/サイズ混在）・#8（インライン画像）・#6（tab stops）。別 widget が要る
重い機能で v2+。tab stops は当面「等幅相当の挙動だけ」で割り切り可。

---

## #8 フォント装飾（bold / italic / underline / strikethrough / shadow）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: フォント / テキスト描画
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #36（bold/italic: 別ファイルロード or freetype 合成）・#37（underline/strikethrough: 線描画）・
#38（shadow/outline: v2+）。#36/#37 は「確実にいずれ必要」、#38 は優先度低。

---

## #9 テキストの drag & drop
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: TextField / TextArea、DnD 基盤
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #41。汎用 DnD 基盤は実装済み（[[project-dnd-design]]）。テキスト固有の D&D（選択範囲のドラッグ移動
等）が未。

---

## #10 カーソル変化機構（I-beam / リサイズ / スプリットペイン）
- 状態: 未着手
- 優先度: 中
- 影響範囲: awt（GLFW SetCursor）、framework（hover でのカーソル切替）
- 更新日: 2026-06-02
- 依存: なし

### 何
plan.md #42。I-beam（テキスト hover）自体は v1 で配線しないが、**カーソル変化機構そのものはウィンドウ
リサイズ／スプリットペインで必須**（テキスト専用ではない汎用機構）。GLFW の SetCursor は安価。

---

## #11 テキストシェイピング（カーニング / 合字 / マーク配置 / 文脈依存形）
- 状態: 棚上げ
- 優先度: 未定（判断保留 — 後述「決めること」）
- 影響範囲: awt のテキストレイアウト層、`awt/src/Font.zig`、`awt-c/src/nm_font.c`、
  vendor 依存・`build/third_party.zig`（HarfBuzz を導入する場合）、awt-c のプラットフォーム分岐
  （プラットフォームシェイパーを使う場合）
- 更新日: 2026-06-13
- 依存: なし（#2 テキスト折り返しと同じ「Font の上のレイアウト層」に乗る見込み。設計を共有しうる）

### 何
文字列→配置済みグリフ列の変換を、フォントの GSUB/GPOS を使ったシェイピングに拡張する。
対象はカーニング・合字（`fi`、プログラマフォントの `->`→`→` 等）・マーク配置（アクセント合成）・
文脈依存形。現状は**ノーシェイピング基線**：`nm_font.c` の `FT_Load_Char(codepoint)` で cmap を
1コードポイント=1グリフで直引きし、`Font.zig` の `measureString` が per-codepoint の advance を加算するだけ。
GSUB/GPOS には一切触れていない。

シェイピングは `Font`（per-glyph ラスタライズに限定。冒頭コメント「layout は caller の責任」）には
足さず、その上のレイアウト層に差し込む。出力は cluster→glyph 対応（書記素/カーソル用）を含む必要がある。

### なぜ（保留理由）
意図的な非対応。現状の日本語（CJK はほぼ 1:1）+ 素の Latin UI（ファイラー等）では破綻しない。
LTR のみ宣言済みのため複雑スクリプトの mandatory shaping は当面不要。実需は **コード / markdown エディタ**で
合字・カーニングが felt need になった時、または Latin のアクセント合成が要る時に出る。

### 候補アプローチ
- 案A: HarfBuzz を vendor に追加し FreeType と組む。
  メリット: 業界標準・最も完全（全スクリプト・全 OpenType 機能）。
  デメリット: 依存増・バイナリ肥大。**クロスコンパイル（`-Dtarget=`）を壊す構成（CMake 必須化等）は
  却下という既存制約に抵触しない vendoring 方式が必須**（[[project-crosscompile-priority]]）。
- 案B: プラットフォームシェイパー（Windows=DirectWrite / Mac=CoreText）。
  メリット: OS 標準で高品質・追加 vendor 不要。描画バックエンドが既にプラットフォーム分岐している方針と整合。
  デメリット: awt-c にプラットフォーム別実装が増える・挙動差。
- 案C: ノーシェイピング継続 + 限定的な自前対応（kern テーブル / GSUB の簡易サブセットだけ手で読む）。
  メリット: 依存ゼロ・必要な機能だけ。
  デメリット: font table を自前解釈する保守コスト・完全性が出ない。
- 不採用: HarfBuzz 相当の汎用シェイパー完全自作（規模的に非現実的）。
- 判断軸: 完全性・全スクリプトを取るなら A、依存最小 + OS 品質 + プラットフォーム分岐許容を取るなら B、
  必要最小機能を依存ゼロで取るなら C。A はクロスコンパイル維持が最重要の制約。

### 決めること
- **本項目の優先度**（現在未定）。コード / markdown エディタ着手時に「合字・カーニングが felt need か」で判断する。
  それまでは判断材料が出ないため保留。
- 案A / B / C のどれを採るか。特に案A は「クロスコンパイルを壊さない vendoring が成立するか」を先に検証。
- シェイピングを差し込むレイヤーの位置と、#2 折り返し（line break iterator）と同じ層になる見込みを踏まえ
  一緒に設計するか。

### 完了条件
（優先度・案が未定のため暫定）対象スクリプト（初期は Latin + 日本語）でカーニングと基本合字が効き、
レイアウト層がシェイピング結果（cluster→glyph 対応を含むグリフ列）を返す。
スナップショットテストで合字・カーニングの差分が確認できる。
