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
- 状態: 一部 unblock（折り返し Label が着手可能）
- 優先度: 中
- 影響範囲: Label / TextArea、テキストレイアウト
- 更新日: 2026-06-22
- 依存: zg（Words / Graphemes・vendor/zg-v0.16.2・feat/zg-graphemes で配線済み）

### 何
plan.md #2/#3/#4（文字単位 / 単語境界 / CJK 禁則の折り返し）・#5（省略 `Long fil...`）・#29（TextArea の
word wrap）。省略と TextArea の word wrap は「確実にいずれ必要」。

棚上げ理由が 2 つとも解消した。
- 消費先が出現: メッセージ / 確認ダイアログの長文折り返し（ユーザー要望 2026-06-22）で、
  Label に「一行のみ許容＝消費先なし」だった保留が解けた。折り返し Label が着手可能。
- 前提だった line break iterator は zg で足りる: フル UAX#14 は不要で、
  Words（単語境界）＋ Graphemes（クラスタ非分割）＋ 禁則の小テーブルで GUI 折り返しは賄える。

影響範囲から Button を外した（ユーザー判断 2026-06-22＝ボタンに長文を入れるべきでない）。Label と TextArea に絞る。

### 実装メモ
測定は既存プリミティブを流用（`Font.glyphAdvance` / `Font.measureString` が per-codepoint advance を
FreeType から積算。Noto Sans JP プロポーショナル・カーニング/シェイピング無し）。
TextArea には既に折り返し機構（`reflowAt` / `wrapPoint` / `VisualLine` / `setLineWrap`）があるが、
現状の `wrapPoint` は貪欲・コードポイント単位で単語の途中で割る（コメント "Greedy character wrap"）。
これを共有ヘルパへ上げ、Words + Graphemes + 禁則で底上げすれば、TextArea の折り返しと新規の折り返し Label が同時に良くなる。
DisplayWidth は使わない（プロポーショナルでは実 advance が唯一正。East-Asian-wide=2 列はモノスペース端末の話）。

---

## #3 書記素クラスタ単位の編集・カーソル移動
- 状態: 着手可能（unblock 済み）
- 優先度: 中
- 影響範囲: TextField / TextArea、テキストモデル
- 更新日: 2026-06-22
- 依存: zg（Graphemes・vendor/zg-v0.16.2・feat/zg-graphemes で配線済み）

### 何
plan.md #11（Backspace/Delete）・#12（矢印移動）を codepoint 単位から grapheme cluster 単位へ。
CLAUDE.md「書記素クラスタ」のとおり v1 は codepoint で、**バイト位置に直接依存しない実装**にしてあるので
差し替え可能な前提。

棚上げ理由（ziglyph メンテ停止・[[project-emoji-grapheme-deferred]]）が解消した。後継の zg
（codeberg.org/atman/zg・Ziglyph 後継）を vendored し、feat/zg-graphemes で Graphemes を配線済み。
「バイト位置に直接依存しない実装」という前提は維持。ユーザーが次に着手したい意向（2026-06-22）。

### 実装メモ
中央化済みの境界ヘルパ（TextField の `prev/nextCodepointBoundary`・TextArea の `prev/nextBoundary`）を
`Graphemes.iterator` / `reverseIterator` へ差し替える（局所変更）。backspace/delete もクラスタ単位へ。
ただし caret x のドリフト（結合マークが per-codepoint advance でフル幅算入されてズレる。`glyphXAtByte`）は
境界差し替えだけでは直らず、クラスタ単位の advance 測定が別途要る。

---

## #4 単語境界・行頭行末のナビゲーション
- 状態: 一部 unblock（word break が供給可能に）
- 優先度: 低
- 影響範囲: TextField / TextArea
- 更新日: 2026-06-22
- 依存: zg（Words・vendor/zg-v0.16.2・feat/zg-graphemes で配線済み）

### 何
plan.md #13（Home/End）・#14（Ctrl+矢印 word jump）・#18（ダブルクリックで単語選択）。#14/#18 は
word break 判定が前提で、ともに現状未実装（net-new）。Home/End は zg 非依存で安価だが優先度低。

#14/#18 の word break は zg の Words（UAX#29 単語境界）で供給可能になった。
空白判定だけの簡易版に頼らず本物の境界が使える。

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

---

## #12 テキスト折り返しのリサイズ性能
- 状態: 完了（解決済み・実装は develop へマージ済み）
- 優先度: 中
- 影響範囲: `awt/src/textwrap.zig`・`awt/src/Font.zig`・`awt/src/grapheme.zig`（と examples/wrap_perf）
- 更新日: 2026-06-24
- 依存: なし（#2 折り返しの上に乗る）

### 何
#2 折り返し（実装済み）をユーザーが実機で試したところ、折り返し有効な TextArea / 折り返し Label を
含む窓のリサイズが目に見えて重いと判明した（felt need、2026-06-23）。リサイズは幅変化 → reflow →
再描画を頻繁に起こすため、reflow 経路のコストがそのまま体感に出る。本項目で改善し、develop（b4afce8）
へマージ済み。以下は事後記録（post-mortem）。

### 原因の訂正
起票時の見立て（原因#1: `wrapSegment` が O(n^2) を主因）は、後述ベンチ（ReleaseFast）の
プロファイルで**不正確だった**と判明した。実際の構成は次のとおり。

- 段落長に対する reflow は既にリニアだった。`wrapSegment` の O(L^2) は L=1 視覚行のクラスタ数で、
  L は wrap 幅により頭打ちになる。よって段落全体としては O(n) に落ち、主因ではなかった。
- 真の支配項は起票時の原因#2 だった。`nmGetGlyphAdvance` が毎回 `FT_Load_Char` を叩く未キャッシュ
  経路で、1 コールあたり約 2206〜2888ns を要していた。
- 定数項を潰すと、起票時のリストに無かった第 4 の原因が露出した。`awt/src/grapheme.zig` の
  `nextGraphemeBoundary` が毎回スライス先頭から走査する O(from) で、`wrapSegment` が走査中の絶対
  位置で呼ぶため合計 O(n^2) になっていた。advance の大きな定数項に隠れて見えなかった。

### 実施した修正
ベンチ先行でプロファイルしてから、測定の定数項・累積測定・前方走査を順に潰した。

- ベンチ先行: examples/wrap_perf（CPU 専用・ウィンドウ / GPU 不使用）でプロファイル（コミット f7fe8f9）。
- (b) Zig 側 advance キャッシュ: `awt/src/Font.zig` の `Font` に、値コピー間で共有する `AdvanceCache`
  ポインタを持たせた（init で確保・deinit で解放）。キーは (pixel_size, codepoint) で、ambient pixel
  size の混線を構造的に排除する。direct-mapped 16K・フルキー照合。awt-c（`nmGetGlyphAdvance` /
  `nmFont`）は不変で薄いまま。advance 約 2206ns → 1.3ns（コミット b399d2d）。
- (a) `wrapSegment` を増分幅へ: 行頭から測り直すのをやめ、running width に切り替えた（コミット b399d2d）。
- (d) `wrapSegment` の per-cluster 前方走査を、s 起点の再開可能な `Graphemes.iterator` に置換した。
  禁則 / break 判定の次クラスタ確認も、境界先頭 codepoint の局所読みにした。残差 O(n^2) → O(n)。
  返す折り位置は不変で、既存の textwrap_test 7 本が回帰ガードになる（コミット b4afce8）。

### 不採用: 案c（Label の per-paint reflow キャッシュ）
起票時の候補 (c) は不採用。プロファイルで、リサイズ中は幅が毎フレーム変わるためキャッシュが効かないと
判明し、(a)+(b)+(d) で per-paint reflow 自体が十分安く（サブ ms）なったため不要になった。静的再描画
向けの micro-opt としてのみ将来余地がある。

### 結果
4096 クラスタの単一行で 174.56ms → 0.121ms（約 1440 倍）。スケーリングは O(n^2) の露出からリニア
（直前比 約 2.0 倍）へ移った。典型 UI 文（数百クラスタ）はサブ ms。検証は 3-way 合議（pm backstop ＋
correctness ＋ test-genuineness の独立パネルで、vacuous テスト 1 件と設計上の MINOR を捕捉して是正）と、
ユーザー実機（examples/widget_textarea のリサイズ）での体感確認による。

### 完了条件
測定・reflow 所要時間で改善が確認できること。examples/wrap_perf がこれを満たし、回帰ベンチとして残置する。
