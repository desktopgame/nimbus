# 書記素クラスタ単位の編集 設計 spec（text_backlog #3）

TextField / TextArea の caret 移動と削除を、コードポイント単位から **書記素クラスタ単位** へ上げる
変更（[text_backlog.md](text_backlog.md) #3）の設計 spec。実装はまだ＝**今回は doc のみ**（コードは書かない・Codex 担当）。
zg（`{REPO_ROOT}/vendor/zg-v0.16.2`・`feat/zg-graphemes` で配線済み・`Graphemes` モジュール）を使う。
`border_model.md` / `laf_design.md` の流儀に倣い **「確定」と「未決」を分ける**。未決は §11 にまとめる。

関連: [text_backlog.md](text_backlog.md)（#3 本体・#2 折り返し・#4 単語境界・#11 シェイピング）、
[backlog.md](backlog.md)（起票規約）、`framework/src/TextField.zig`・`framework/src/TextArea.zig`・`framework/src/GapBuffer.zig`（現状）、
`framework/tests/grapheme_smoke_test.zig`（zg が配線済みで動く実証）。
棚上げ経緯（ziglyph メンテ停止 → zg 後継）は text_backlog.md #3 を参照。

---

## 0. スコープ（小さく保つ・確定）

#3 が変えるのは実体 **2 つだけ**。

1. **caret 移動**（←→ と Shift+←→ の選択伸長）をクラスタ境界単位に。
2. **Backspace / Delete** をクラスタ単位に。
   現状「é の結合マークだけ消える／ZWJ 家族絵文字の最後の 1 人だけ消える」を、**クラスタ丸ごと削除**へ。

これだけ。挿入・IME・描画・測定式・x 座標の算出は **変えない**（§1・§6）。
対象外（単語選択・シェイピング・カラー絵文字・bidi）は §9。

---

## 1. 冒頭の不変条件 — caret の x 座標・描画・測定式は変えない（確定）

**これが #3 の設計の土台。** クラスタ対応が変えるのは『caret が**止まってよい位置**（境界集合）』だけで、
**どこに何ピクセルで描くか（x 座標）には一切触らない**。理由は、触らない方が正しいから。

- caret の x は「text 先頭から byte 位置までの per-codepoint advance 総和」で出している
  （TextField `glyphXAtByte` `{REPO_ROOT}/framework/src/TextField.zig:768`、
  TextArea `measureRange`→`measureSlice` `{REPO_ROOT}/framework/src/TextArea.zig:424,403`）。
- 描画も**同じ advance 源**（`font.face.glyphAdvance(cp)`）で各グリフを置く。
  → caret x と描画は常に同じ式から出るので **構造的に一致**する。新規ドリフトは出ない。
- #3 は境界集合を変えるだけ＝caret は「これまで止まれた位置の部分集合」にしか止まらなくなる。
  止まれる各位置の x は従来式そのままなので、**ズレようがない**。

視覚の崩れ（é の結合マークが per-cp advance でフル幅算入されて重なる・ZWJ 家族絵文字が 3 つに割れて見える・
tofu）は **シェイピングの問題**であって境界の問題ではない。これは #11（シェイピング＋カラー絵文字）の領分で、
**#3 では直らない**（§10 に正直に明記）。#3 が直すのは**操作の壊れ**（半分食う・途中で止まる）だけ。

> したがって本 spec は「クラスタ単位の advance 測定」を **導入しない**。それが要るのは #11 以降
> （caret をクラスタ中央でなく境界に置いたうえで、グリフを合成幅で描くようになって初めて）。

---

## 2. 現状調査（確定事実・行番号付き）

### 2.1 境界ヘルパは既に caret 移動・削除の単一の漏斗（funnel）

←→・Backspace・Delete はすべて境界ヘルパ経由で、editing ロジックは byte stepping をハードコードしていない。

- TextField: `prevCodepointBoundary` / `nextCodepointBoundary`（`{REPO_ROOT}/framework/src/TextField.zig:792,802`・**free 関数**・引数 `buf: []const u8, from: usize`）。
  呼び出しは arrow_left `:494`、arrow_right `:500`、backspace `:521`、delete `:535`。
- TextArea: `prevBoundary` / `nextBoundary`（`{REPO_ROOT}/framework/src/TextArea.zig:496,503`・**メソッド**・`self` + `from: usize`）。
  呼び出しは arrow_left `:726`、arrow_right `:731`、backspace `:759`、delete `:770`。
- 両ファイルのヘッダ／コメントに「将来クラスタへ移行するときはこの 2 関数を差し替えるだけ」と既に書かれている
  （`{REPO_ROOT}/framework/src/TextArea.zig:6-8,489-494`、`{REPO_ROOT}/framework/src/TextField.zig:788`）。

→ **§0 の実体 2 つは、この 2 組のヘルパの中身を差し替えるだけで両方とも実現する。** 漏斗は既に正しい。

### 2.2 同じ UTF-8 walk が 2 か所に重複している

両者の中身はまったく同じ「継続バイト（`0xC0 == 0x80`）をスキップ／`utf8ByteSequenceLength` で前進」ロジック。
TextField は `buf: []const u8` を直接歩き、TextArea は `self.text.byteAt(i)` でバイト単位アクセスするだけの差。
**これを 1 つの純関数群に統合して両者が呼ぶ**（§3）。

### 2.3 測定／ヒットテストの per-codepoint 加算が 6 か所に散在

いずれも `glyphAdvance(cp)` を直接 while ループで積算している（クラスタ非対応・将来 #11 で run 由来へ差し替えたい箇所）。

- TextField: `hitTestByteAt` `{REPO_ROOT}/framework/src/TextField.zig:715`、`measureUtf8` `:743`、`glyphXAtByte` `:768`。
- TextArea: `measureSlice` `{REPO_ROOT}/framework/src/TextArea.zig:403`、`measureRange` `:424`、`byteAtXInLine` `:454`。
- 上下矢印（`moveVertical` `:833`）と マウス click（`pointToCaret` `:478`）は `byteAtXInLine` 経由で caret 位置を決める。
  ヒットテストは**現状クラスタ境界に丸めていない**＝クラスタ中央でクリックすると caret がクラスタ内に入りうる（§5・§11 で扱う）。

### 2.4 GapBuffer は既に「連続スライス」を渡す手段を持っている（重要）

`{REPO_ROOT}/framework/src/GapBuffer.zig` は内部に gap を持ち、論理範囲が gap を跨ぐと**生ポインタは不連続**になる。
だが TextArea は既に `rangeSlice(start, end)`（`{REPO_ROOT}/framework/src/TextArea.zig:396`）で
論理範囲を `self.scratch`（連続バッファ）へコピーして返している。`GapBuffer.copyRange`（`GapBuffer.zig:63`）が
gap straddle を 2 回の memcpy で処理する。**＝連続スライス契約は新規発明不要で、既存の `rangeSlice` で満たせる**（§4）。
TextField は `text: ArrayList(u8)` で `.items` が元から連続（自明）。

### 2.5 build 配線 — `Graphemes` は今 awt にだけ可視

`Graphemes` モジュールは `awt_mod` の imports に入っている（`{REPO_ROOT}/build.zig:133`）が、
`framework_mod`（`:139-146`・imports は `awt` のみ）には入っていない。TextField / TextArea は framework。
framework は `pub const awt = @import("awt")`（`{REPO_ROOT}/framework/src/root.zig:3`）で awt を再公開し、
両ウィジェットも `const awt = @import("awt")` 済み。Font も awt（`awt/src/Font.zig`・`root.zig:17`）。
→ ヘルパ置き場の選択（§3.2）はこの配線が起点。

### 2.6 zg `Graphemes` の API（vendored・確定）

`{REPO_ROOT}/vendor/zg-v0.16.2/zg/src/Graphemes.zig`：

- `iterator(string: []const u8) Iterator` / `reverseIterator(string: []const u8) ReverseIterator`（`:39,44`）。
- `Iterator.next() ?Grapheme` / `ReverseIterator.prev() ?Grapheme`。
- `Grapheme{ offset: uoffset, len: uoffset }`（`:77`）＋ `bytes(src) []const u8`（`:83`・`src[offset..][0..len]`）。
- `grapheme_smoke_test.zig` が é（結合）・ZWJ 家族絵文字でクラスタ非分割を実証済み（forward 3 個・reverse 同一境界）。

---

## 3. 設計その 1 — 共有境界ヘルパ（single source of truth）

### 3.1 API（確定方針・offset ベース）

§2.2 の重複を解消し、両ウィジェットが呼ぶ**純関数 2 つ**へ統合する。**iterator を返さず offset を返す**
（両ウィジェットの caret モデルが byte-offset なので、iterator を返すより呼び出し側が素直）。

```zig
/// 次のクラスタ境界の byte offset。from が末尾なら text.len。
fn nextGraphemeBoundary(text: []const u8, from: usize) usize

/// 前のクラスタ境界の byte offset。from が 0 なら 0。
fn prevGraphemeBoundary(text: []const u8, from: usize) usize
```

- 引数は `[]const u8`（連続スライス）＋ byte offset。返りも byte offset。Font 非依存・純ロジック。
- 実装は zg `iterator` / `reverseIterator` で**全文走査ではなく境界 1 つ**を求める（§4 の窓と非対称を参照）。
- 現行 free 関数 `prev/nextCodepointBoundary`（TextField）とメソッド `prev/nextBoundary`（TextArea）は
  この 2 関数の薄いラッパへ縮退するか、呼び出しを直接差し替える（どちらにするかは実装時の軽微な判断）。

### 3.2 置き場所と build 配線（**要判断・§11**）

`Graphemes` 依存をどこに置くかで 2 案。**推奨は (a)**。

- **(a) awt に置く（推奨）**: 新規 `awt/src/grapheme.zig`（または既存 text 系へ追加）にヘルパを置き、
  `awt/src/root.zig` で公開、framework は `awt.grapheme.nextGraphemeBoundary(...)` で呼ぶ。
  - 利点: `Graphemes` は既に `awt_mod` のみに配線済み（§2.5）＝**Unicode 依存を awt（テキスト／フォント層）に閉じ込められる**。
    §5 の測定継ぎ目は Font を要し、Font も awt にあるので、境界＋測定を同じ層に揃えられる。
  - 欠点: 純粋な caret 境界ロジックが「プラットフォーム抽象層」に乗る違和感。ただし awt は既に Font／測定を持つので許容範囲。
- **(b) framework に置く**: `framework_mod` の imports に `Graphemes` を 1 行足し（`build.zig:143-146`）、
  ヘルパも framework（ウィジェットの隣）に置く。
  - 欠点: Unicode 依存が awt と framework の 2 モジュールに分散する。

> 純境界ヘルパ（§3.1・Font 非依存）と 測定継ぎ目（§5・Font 依存）は**依存が違う**。
> (a) なら両方 awt に置けて素直。(b) を採るなら測定継ぎ目だけ awt 側に残す折衷もありうる。

---

## 4. 設計その 2 — GapBuffer の連続スライス契約

クラスタ分割は**連続バイト窓**を要求し、軽く文脈依存（ZWJ・地域指示子の旗の偶奇）＝直前のコードポイント列を
見ないと境界が決まらないことがある。よって境界ヘルパには連続スライスを渡す必要がある。

### 4.1 連続窓は `rangeSlice` で供給する（確定方針）

§2.4 のとおり TextArea は既に `rangeSlice(start, end)`（`TextArea.zig:396`）で gap straddle を吸収した
連続コピーを返せる。**生ポインタを渡さず、`rangeSlice` のコピー越しに境界ヘルパへ渡す。**
gap を読み取りのために動かす（`moveGap`）案は**採らない**（読み取りでバッファを mutate するのは副作用が大きい）。
TextField は `text.items` をそのまま渡す（連続・自明）。

### 4.2 前方／後方の非対称（確定）

- **次境界（nextGraphemeBoundary）**: caret 自体が常に境界なので、**caret から前方**の窓
  `rangeSlice(caret, end)` を `iterator` で 1 歩 → 境界 = `caret + first.len`。caret 以降の文脈だけで決まり安全。
- **前境界（prevGraphemeBoundary）**: 末尾の 1 クラスタを `reverseIterator.prev()` で得るには
  **caret から後方**の連続窓が要る。文脈依存（旗の偶奇など）は理論上いくらでも遡りうるので、
  **窓は安全側に `[0, caret)`（行頭でなく文書頭から）を採る**＝完全文脈で誤分割しない。
  境界 = `window_start + last.offset`（`window_start = 0` なら `last.offset`）。
  - コスト: TextField は `items[0..caret]` でゼロコピー。TextArea は `rangeSlice(0, caret)` が O(caret) コピー。
    1 キーストロークあたり 1 回で、v1 のテキスト長では許容。窓を有界化する最適化は **未決**（§11）。

---

## 5. 設計その 3 — 測定の継ぎ目を 1 か所に寄せる（保険 2・確定方針）

これは **将来シェイピング #11 を後付けするための必須ヘッジ**で、追加コストはほぼ 0。
#3 で測定を触る**ついでに**、新規／触る箇所だけ 1 か所へ寄せる。

- 境界ヘルパの隣（§3.2 と同じ層）に、測定の継ぎ目を**各 1 関数**として定義する方針：
  - `advanceOfRange(font, text, a, b) f32` — text の byte 範囲 A→B の advance を返す（caret x・選択幅）。
  - `byteAtX(font, text, x) usize` — x → byte offset を返す（ヒットテスト）。
- **新コードで生の per-codepoint 加算ループを散らさない**ことを #3 の要件とする。
  将来 #11 で run のグリフ位置由来へ差し替えるとき、この 1〜2 関数を直せば済む。
- **粒度の明示**: §2.3 の既存 6 か所を**全部畳む完全リファクタまでは #3 では求めない**。
  #3 で新規に書く／実際に触る箇所だけを継ぎ目に寄せる範囲でよい。既存の散在は #11 の作業として残す。
- ヒットテスト（`byteAtXInLine` / `hitTestByteAt`）と上下移動（`moveVertical`）が caret を
  **クラスタ中央に落としうる**問題は、`byteAtX` の結果を境界ヘルパで丸めれば直る。これを #3 に含めるかは **未決**（§11）。

---

## 6. 設計その 4 — 選択のクラスタ化・挿入／IME 不変（確定）

- **選択（Shift+←→）**: §2.1 のとおり Shift は「mark を caret に追従させるか」を切るだけで、
  caret 自体は同じ境界ヘルパで動く。よって**境界をクラスタ化すれば選択伸長も自動でクラスタ単位**になる。
  選択側に追加処理は要らない。
- **挿入・IME は不変**: テキスト挿入は常にクラスタ境界（= caret 位置・既に境界）で起きるので boundary 処理は不要。
  IME 確定（commit）も境界で起き、変換中の preedit は別経路（preedit バッファ・`{REPO_ROOT}/framework/src/TextField.zig:487` 等で
  composition 中はキー処理を bail out）。**#3 は挿入／IME には触れない。**

---

## 7. 段取り（確定）

- ブランチ `feat/text-grapheme-edit`（本 doc はその上の**先行コミット**・実装は別コミット）。
- 実装は 2 段。pm に制御が戻る単位で各 1 コミット想定。
  1. **TextField 先行**（`ArrayList`・連続・単純）でパターン確定。境界ヘルパ＋測定継ぎ目をここで固める。
  2. **TextArea**（`GapBuffer`・折り返しと絡む）へ展開。`rangeSlice` 窓（§4）・`reflow` との順序に注意。

---

## 8. テスト計画（確定方針）

- **GPU 非依存の純ロジック**。手組み `Component.init` 等で Application / GPU に依存させない
  （`grapheme_smoke_test.zig` と同様、`build.zig:327-336` の独立テストモジュールに倣う配線）。
- 検証文字列に é（結合 `e\u{0301}`）・ZWJ 家族絵文字（`\u{1F468}\u{200D}...`）・肌色修飾子・地域指示子の旗を含め、
  - ←→ が**クラスタ境界に着地**する、
  - Backspace / Delete が**クラスタ丸ごと削除**する（半分残らない）、
  - Shift+←→ の選択が**クラスタ単位**で伸びる、
  を assert。TextField（ArrayList）と TextArea（GapBuffer・gap straddle 込み）の両方で。
- **真正性**: zg 自体のクラスタ化は `grapheme_smoke_test.zig` が実証済み。ここでのテストは
  **「ウィジェットが実際に zg 経路を通るか」**を突く＝コードポイント実装に戻すと**落ちる** mutation ガードにする
  （codepoint walk へ差し戻したら é が 1 回で消えずテストが赤くなる、等）。独立レビューで真正性まで確認する前提。

---

## 9. 対象外（混ぜない・確定）

- 単語選択 / Ctrl+矢印 / ダブルクリック単語選択（#4・Words）。
- シェイピング・カラー絵文字（#11・atlas RGBA 化）。
- caret x の**クラスタ単位測定**（#11 後に初めて要る・§1）。
- bidi（LTR-only 宣言済み・CLAUDE.md「文字コード」）。

---

## 10. #3 が直さないことを正直に書く（確定）

**視覚は #3 では直らない。**

- 家族絵文字が今 3 つに割れて見える／結合マークが重なる／未対応字形が tofu になる、は
  **シェイピング（#11）＋カラー絵文字（atlas RGBA 化）**の別軸。#3 は字形を 1 つも変えない。
- #3 が直すのは**操作の壊れ**だけ＝「結合マークだけ食う」「絵文字の途中で caret が止まる」「半分削除される」。

つまり #3 の後でも、家族絵文字は**見た目は割れたまま**だが、←→ で**一発で飛び越え**、Backspace で**一発で全部消える**。
ここを混同しないこと。

---

## 11. 未決・要判断リスト

1. **ヘルパ置き場 (a) awt / (b) framework**（§3.2）。推奨は (a)（Unicode 依存を awt に閉じ込め・Font と同居）。
   作者判断が要る。
2. **後方窓の有界化**（§4.2）。前境界の窓を `[0, caret)` 全文脈で取るか、旗・ZWJ を考慮した有界窓に最適化するか。
   v1 は全文脈（正しさ優先）でよいと考えるが、TextArea の長文での O(caret) コピーを嫌うなら要検討。
3. **ヒットテスト／上下移動のクラスタ丸め**（§5 末尾）。マウス click・↑↓ が caret をクラスタ中央へ落としうる問題を
   #3 に含めるか、#11（測定）まで送るか。`byteAtX` の結果を境界ヘルパで丸めるだけなので #3 で安価に入れられるが、
   §0 のスコープ（←→ と削除）からは外。**作者がスコープに入れるか判断**。
4. **測定継ぎ目の畳み込み範囲**（§5）。#3 で新規／触る箇所だけ寄せる（推奨）か、既存 6 か所も今畳むか。
   後者は #3 を膨らませるので非推奨だが確認したい。
5. **テストの最小集合**（§8）。é・ZWJ 家族・肌色修飾子・旗の 4 種で足りるか、地域指示子の**奇数個**列
   （旗の偶奇境界）など意地悪ケースをどこまで入れるか。
