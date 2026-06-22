# テキスト折り返し 設計 spec（text_backlog #2）

TextArea の折り返しを VS Code 級に底上げし、あわせて **折り返し Label** を新設する変更
（[text_backlog.md](text_backlog.md) #2）の設計 spec。実装はまだ＝**今回は doc のみ**（コードは書かない・Codex 担当）。
[grapheme_edit_design.md](grapheme_edit_design.md)（#3）の流儀に倣い **「確定」と「未決」を分ける**。未決は §10 にまとめる。

**UAX#14 のフルライン分割ライブラリは使わない。** zg に line-break モジュールは無い（pm 確認済み・`DisplayWidth.wrap` は
モノスペース列幅 wrap で GUI の比例フォントには不適）。代わりに VS Code 級の **「文字テーブル＋貪欲詰め＋クラスタ安全＋禁則」**
で実現する。前提（grapheme 境界・実 advance 測定）は #3 で既に awt 側に揃っている（§1）。

関連: [text_backlog.md](text_backlog.md)（#2 本体・#3 編集・#11 シェイピング）、[backlog.md](backlog.md)（起票規約）、
`{REPO_ROOT}/framework/src/TextArea.zig`・`{REPO_ROOT}/framework/src/Label.zig`（現状）、
`{REPO_ROOT}/awt/src/grapheme.zig`・`{REPO_ROOT}/awt/src/Font.zig`（#3 で入った継ぎ目）。

---

## 0. スコープ（確定）

この変更が触る実体は **3 つ**。

1. **共有 wrap ヘルパを新設**（文字テーブル＋貪欲詰め＋クラスタ安全＋禁則＝single source of truth）。
2. **TextArea の折り返しをその共有ヘルパ経由へ**。現状の `wrapPoint`（`{REPO_ROOT}/framework/src/TextArea.zig:363`・
   コメント "Greedy character wrap"・貪欲・コードポイント単位・mid-word で割る）を置換。
3. **折り返し Label**（読み取り専用の複数視覚行テキスト）。メッセージ／確認ダイアログの長文折り返しが元の動機。

この 3 つが **同じ wrap ヘルパを共有**するのが本 spec の主眼。測定式・描画・座標系は #3 の継ぎ目をそのまま使い、
新規に per-codepoint 加算を散らさない（§7）。対象外（UAX#14 フル準拠・シェイピング・省略・両端揃え・bidi）は §9。

---

## 1. 現状調査（確定事実・行番号付き）

### 1.1 前提は #3 で awt 側に揃っている

- **grapheme 境界**: `awt.grapheme.prevGraphemeBoundary(bytes, from)` / `nextGraphemeBoundary(bytes, from)`
  （`{REPO_ROOT}/awt/src/grapheme.zig:8,19`・連続 `[]const u8` ＋ byte offset・`{REPO_ROOT}/awt/src/root.zig:27` で公開）。
  折り位置は必ずこれでクラスタ境界に揃える。
- **実 advance 測定**: `Font.advanceOfRange(bytes, start, end)`（`{REPO_ROOT}/awt/src/Font.zig:95`）が byte 範囲の
  per-codepoint advance を積算。`Font.byteAtX(bytes, x)`（`:120`）が x→byte（half-advance split・コードポイント境界を返す）。
  → 幅測定は唯一この継ぎ目を経由する。生の per-codepoint ループを wrap で新たに書かない。
- `DisplayWidth` は使わない（比例フォントでは実 advance が唯一正・モノスペース列幅は無関係）。これは text_backlog.md #2 の判断どおり。

### 1.2 TextArea には折り返し機構が既にあるが、break 判定が貪欲・コードポイント単位

- `reflowAt(inner_w)`（`{REPO_ROOT}/framework/src/TextArea.zig:288`）が論理行を視覚行へ分割し
  `lines: ArrayList(VisualLine)` を組む。`VisualLine{ start, end, has_newline }`（`:43`）は論理 byte offset。
- 1 論理行内の分割は `wrapPoint(start, le, wrap_w)`（`:363`）が担う。現状は **貪欲・コードポイント単位**で、
  break opportunity（空白・区切り）も禁則も見ず **単語の途中で割る**。最低 1 コードポイントは進める（無限ループ防止）。
- `setLineWrap(wrap)`（`:178`）が wrap/no-wrap を切替え、wrap 時は `scrollable.tracks_viewport_width` と
  `size_query`（height-for-width）を立てる。スクロール連動はこの機構で既に動く。
- 幅測定は `measureRange`→`measureSlice`→`font.face.advanceOfRange`（`:403-411`）＝既に §1.1 の継ぎ目経由。
- ヒットテスト `byteAtXInLine`（`:439`）は `Font.byteAtX` の結果を `snapByteToGraphemeBoundary`（`:478`）で
  クラスタ境界に丸める。**ただし視覚行境界そのもの（`wrapPoint` の戻り）はクラスタ境界に丸めていない。**

> **follow-up ④ の回収**: `wrapPoint` がコードポイント単位で割るため、視覚行の折り位置がクラスタの**途中**に来うる。
> すると click（`byteAtXInLine`）や ↑↓（`moveVertical` `:810`）でクラスタを跨ぐとき caret が飛ぶ。
> 折り位置を必ずクラスタ境界にすれば（§2）この壊れも同時に消える。本 spec でそれを直す旨を明記する。

### 1.3 Label は単一行・折り返し無し

- `lookPaint`（`{REPO_ROOT}/framework/src/Label.zig:172`）は text-only パスで `g.drawString(label.text, 0, 0)`（`:179`）。
  `\n` は描画も測定もされない（`Font.measureString` が `\n` を読み飛ばす・`{REPO_ROOT}/awt/src/Font.zig:148,162`）。
- 測定は `contentMinSize`（`:135`）→ `font.measureString` の単一行。`min_size` を直接 publish（`size_query` は使わない）。
- アイコン左置きに対応（`icon` / `icon_size` / `ICON_TEXT_GAP`）。no-wrap text-only パスは
  「既存レイアウト／スナップショットを壊さない」よう意図的に温存されている（`:174-175` コメント）。
- **Component は折り返し Label を既に見越している**: `size_query: ?SizeQuery` のコメントに
  "wrapping TextArea, **future wrapping Label**"（`{REPO_ROOT}/framework/src/Component.zig:217-220`）。

### 1.4 build 配線 — `Graphemes` は awt にだけ可視

`Graphemes` モジュールは `awt_mod` の imports（`{REPO_ROOT}/build.zig:133`）のみ。`framework_mod` は awt だけを import
（`:139-146`）。framework は `awt.grapheme` 経由で境界へ到達できる（TextArea が #3 で既にそうしている）。
→ ヘルパ置き場（§4.2）はこの配線が起点で、#3 と同じく awt 側が素直。

---

## 2. 設計その 1 — break opportunity の文字テーブル（VS Code 級・確定方針）

折り候補（break opportunity）は **文字テーブル**で決める。UAX#14 の全クラス機械を持たず、GUI に要る分だけの 2 集合で近似する。
判定は**クラスタ境界でのみ**行い、テーブルは各クラスタ先頭／末尾のコードポイントで引く（クラスタ内部は決して割らない・§2.3）。

### 2.1 2 つの集合（VS Code 既定を出発点に・最終集合は §10 で要確認）

VS Code（monaco）の既定 `wordWrapBreakBeforeCharacters` / `wordWrapBreakAfterCharacters` を出発点とし、
GUI 折り返しに不要な記号を間引いた部分集合を採る。**break-after なクラスタの直後**と
**break-before なクラスタの直前**を折り候補とする。

- **break-after（この文字の後ろで折れる）** 出発点:
  半角空白 `U+0020`・タブ `U+0009`・`)` `]` `}` `?` `|` `/` `&` `.` `,` `;`・ハイフン `-`・
  和文の区切り `、` `。` `，` `．` `・` `：` `；` `？` `！`・長音/中点類 `ー` `…` `‥` 等。
- **break-before（この文字の前で折れる）** 出発点:
  `(` `[` `{`・和文開き約物 `（` `［` `｛` `「` `『` `【` `〔` `《` 等。

### 2.2 CJK は空白が無いのでクラスタ境界が原則すべて候補（確定）

和文・漢字には単語間空白が無い。よって **break-before/after テーブルに当たらない CJK クラスタ境界も折り候補**とする
（VS Code が CJK で文字単位に折るのと同じ挙動）。Latin は空白／区切り後にしか折らない（mid-word を避ける）。
判定順は「テーブルで明示的に許可された境界」∪「両隣が CJK（または一方が CJK）なクラスタ境界」。
**ASCII の英単語内部（letter↔letter）は候補にしない**＝これが mid-word 分割を防ぐ本体。

### 2.3 クラスタは絶対に割らない（確定・follow-up ④ の本体）

折り位置は必ず `awt.grapheme` のクラスタ境界。テーブル判定もクラスタ単位（先頭/末尾コードポイントで引く）。
これにより é／ZWJ 家族絵文字／旗が視覚行を跨いで割れることはなく、§1.2 の caret 飛びも消える。

### 2.4 貪欲詰め＋最低 1 クラスタ前進（確定）

1 視覚行に入るだけクラスタを貪欲に詰め、最後に通過した break opportunity で折る。候補が 1 つも無いまま幅を超えたら
**直近のクラスタ境界で強制改行**する（CJK 長文・空白無し URL 等）。いずれの経路でも **最低 1 クラスタは必ず前進**させ、
無限ループを防ぐ（現 `wrapPoint` の `i > start` ガード `{REPO_ROOT}/framework/src/TextArea.zig:370` の精神を引き継ぐ）。

---

## 3. 設計その 2 — 禁則テーブルと追い出し（確定方針・集合は §10 で要確認）

禁則は **formatter ではなく linter** として実装する＝行のリズムは諦め、約物の孤立だけを消す。2 つの集合を持つ。

### 3.1 2 つの禁則集合（JIS X 4051 基本セットを出発点に）

- **行頭禁則（行頭に来てはいけない）**: 閉じ約物・小書き仮名・長音/反復記号・句読点。
  例: `、` `。` `，` `．` `・` `：` `；` `？` `！` `）` `｝` `】` `』` `」` `》` `〕` `］`・
  小書き仮名 `ぁぃぅぇぉっゃゅょゎ` `ァィゥェォッャュョヮ`・`ー` `…` `‥` `ヽ` `ヾ` `々`。
- **行末禁則（行末に来てはいけない）**: 開き約物。
  例: `（` `［` `｛` `「` `『` `【` `〔` `《` `(` `[` `{`。

### 3.2 追い出し（oidashi・確定方針・上限付き）

貪欲で出た折り位置が禁則に触れたら、折りを **1 つ手前のクラスタ境界へ戻して**再チェックする。

- **行頭禁則**: 次行の先頭クラスタが行頭禁則集合なら、その文字を現在行に残せないので折りを 1 つ手前へ戻す
  （＝禁則文字を 1 つ前のクラスタと一緒に下げる「追い出し」）。
- **行末禁則**: 現在行の末尾クラスタが行末禁則集合なら、その開き約物を次行へ送るため折りを 1 つ手前へ戻す。
- **上限で暴走させない**: 連続禁則で何クラスタも戻りうるが、**戻りは上限クラスタ数まで**（`MAX_OIDASHI` のような定数）。
  上限に達したら追い出しを諦めてその位置で折る（孤立を許す方が、行が極端に短くなるより無難）。
  上限の具体値は §10 で要確認（小さい定数想定・禁則文字が密集するのは稀）。
- 追い出しで戻した結果が break opportunity でなくても、クラスタ境界であれば折ってよい（禁則回避が優先）。

---

## 4. 設計その 3 — 共有 wrap ヘルパ（single source of truth）

### 4.1 API（確定方針・1 論理行内の次の折り位置を返す）

両消費先（TextArea の `reflowAt`・折り返し Label の行組み）が呼ぶ **純関数 1 つ**を中心に据える。
現 `wrapPoint` と同じ「1 論理行スライス内で次の折り位置を返す」契約で、中身を §2・§3 に差し替える。

```zig
/// 論理行スライス text の [start, end) 内で、wrap_w に収まる最大の折り位置を返す。
/// 折り位置は必ず grapheme クラスタ境界。break opportunity（文字テーブル＋CJK）で折り、
/// 禁則に触れたら上限付きで追い出す。候補が無ければ最低 1 クラスタ進めて強制改行。
pub fn wrapSegment(font: Font, text: []const u8, start: usize, end: usize, wrap_w: f32) usize
```

- `font` は測定用（§1.1 の `advanceOfRange` を内部で使う）。`text` は連続 UTF-8 スライス（TextArea は `rangeSlice`、
  Label は所有スライスをそのまま渡す）。返りは byte offset（`start < ret <= end`）。
- 文字テーブル（§2.1）と禁則テーブル（§3.1）は**この同じモジュールの const データ**として持ち、両消費先が共有する。
  テーブルの真実源を 1 か所に保つ（複製しない）。
- クラスタ前進は `awt.grapheme.nextGraphemeBoundary`、追い出しの後退は `prevGraphemeBoundary` を使う。

### 4.2 置き場所と build 配線（**要判断・§10**）

依存は grapheme 境界（`awt.grapheme`）＋文字テーブル＋測定（`Font`）＝**全部 awt 側にある**。よって **(a) awt 推奨**。

- **(a) awt に置く（推奨）**: 新規 `{REPO_ROOT}/awt/src/textwrap.zig`（または `grapheme.zig` に同居）にヘルパとテーブルを置き、
  `awt/src/root.zig` で公開。framework は `awt.textwrap.wrapSegment(...)` で呼ぶ。
  - 利点: #3 と同じ配置（Unicode 依存と測定を awt のテキスト/フォント層に閉じ込める）。`Graphemes` は既に awt にだけ配線済み
    （§1.4）で追加配線が要らない。テーブル＝Unicode 知識を framework に漏らさない。
- **(b) framework に置く**: `framework_mod` に `Graphemes` を 1 行足し（`{REPO_ROOT}/build.zig:143-146`）、
  ヘルパもウィジェットの隣に置く。
  - 欠点: Unicode 依存が awt と framework に分散。#3 の前例（境界ヘルパは awt）と不整合。

> 補足: `wrapSegment` は `Font` を要する。Font は awt（`{REPO_ROOT}/awt/src/root.zig:17`）。(a) なら境界・テーブル・測定・wrap が
> すべて awt に揃い、依存が一方向（framework → awt）で素直。作者判断が要る（§10-1）。

---

## 5. TextArea 統合（確定方針）

- `wrapPoint`（`{REPO_ROOT}/framework/src/TextArea.zig:363`）の中身を `awt.textwrap.wrapSegment(self.font.face, slice, ...)` 呼び出しへ置換。
  `reflowAt`（`:288`）が `VisualLine` リストを組む構造・`setLineWrap`（`:178`）・スクロール連動はそのまま活かす。
- `wrapSegment` には連続スライスを渡す。TextArea は GapBuffer なので、論理行 `[ls, le)` を `rangeSlice`（`:396`）でコピーしてから
  渡す（#3 と同じ連続スライス契約）。`wrapPoint` 内部の `decodeAt` ベース走査は不要になり、テーブル判定は共有側へ移る。
- これで折り位置がクラスタ境界＋break opportunity＋禁則になり、§1.2 の **follow-up ④（wrap mid-cluster で caret 飛び）も解消**する。
  その旨を本 spec の成果として明記する。
- 測定は引き続き §1.1 の継ぎ目（`advanceOfRange`）。新規の per-codepoint 加算は足さない（§7）。

---

## 6. 折り返し Label（新規）

### 6.1 mode か新 widget か（**設計判断・推奨は Label にモード追加**）

**推奨: Label に折り返しモードを足す**（別 widget は作らない）。理由:

- Component が既に "future wrapping Label" を見越している（`{REPO_ROOT}/framework/src/Component.zig:217-220`）。
  框組みは折り返し Label を Label の延長として設計済み。
- font / color / a11y / icon を再利用できる。新 widget はこれらを丸ごと再実装することになる。
- no-wrap 既定パスを温存できる: `line_wrap: bool` で分岐し、false のときは現 `drawString(text,0,0)`（`:179`）と
  単一行 measure をそのまま通す＝**既存レイアウト/スナップショットを壊さない**（Label が今守っている不変条件・`:174-175`）。
  TextArea の `setLineWrap`（`{REPO_ROOT}/framework/src/TextArea.zig:178`）と同じガード方式。

別 widget 案（例 `WrapLabel`）の利点（単一行 Label を一切触らない・責務分離）も認めるが、上記 3 点（特に Component の先見と
no-wrap ガードで温存可能なこと）から **モード追加を推奨**。最終判断は作者（§10-2）。アイコン併用時の折り返し挙動は未決（§10-5）。

### 6.2 折り返しモードの構造（mode 採用時・確定方針）

TextArea の縮小版として組む（編集・caret・focus は無し＝読み取り専用）。

- `setLineWrap(true)` で: `\n` で論理行に分け、各論理行を `awt.textwrap.wrapSegment` で視覚行へ分割し、
  行ごとに `g.drawString(slice, 0, y)`（y は `line_height` 刻み）。TextArea の per-line drawString パターン（`:568-591`）に倣う。
- measure は **複数視覚行の高さ**を返す。幅が要るので `size_query`（height-for-width・`{REPO_ROOT}/framework/src/Component.zig:217`）を
  wrap 時のみ立て、`scrollable.tracks_viewport_width` で親 viewport 幅に追従させる（TextArea `setLineWrap` `:181-185` と同型）。
- これで メッセージ／確認ダイアログに「幅を与えると勝手に複数行へ折れる静的テキスト」を素直に置ける（元の動機）。

---

## 7. 測定の継ぎ目を死守する（確定）

#3 が `Font.advanceOfRange` / `byteAtX`（§1.1）に測定を寄せた。本 spec の新コードも **この継ぎ目だけ**を使い、
wrap・Label 描画・Label measure のどこにも生の per-codepoint 加算ループを新設しない。将来 #11（シェイピング）が
run のグリフ位置由来へ差し替えるとき、継ぎ目を直せば折り返しも追随する。既存の散在を畳む完全リファクタは #2 では求めない
（#3 同様、新規／実際に触る箇所だけ継ぎ目に寄せる）。

---

## 8. テスト計画（GPU 非依存・純ロジック）

`{REPO_ROOT}/build.zig:327-336` の `grapheme_smoke_test` と同型の独立テストモジュールに倣う（GPU/Application 非依存）。
ヘルパが awt 配置（§4.2-a）なら awt 単体テスト（`{REPO_ROOT}/awt/src/grapheme.zig` のインラインテスト方式）でも書ける。
幅 W で文字列を折り、期待する折り位置を assert する。最低限:

1. **Latin が空白で折れ mid-word で割らない**（`"hello world ..."` が単語境界で折れる）。
2. **CJK がクラスタ境界で折れる**（空白無しの和文が任意のクラスタ境界で折れる・§2.2）。
3. **クラスタを割らない**（é＝`e\u{0301}`／ZWJ 家族絵文字／旗を視覚行跨ぎで割らない・§2.3）。
4. **行頭禁則**（閉じ約物 `）` `、` 等が視覚行の**先頭に来ない**＝追い出される・§3.1/§3.2）。
5. **行末禁則**（開き約物 `（` `「` 等が視覚行の**末尾に来ない**・§3.1/§3.2）。
6. **追い出しの上限**（連続禁則で `MAX_OIDASHI` を超えたら諦めてその位置で折る・§3.2）。
7. **折り返し Label の measure が複数視覚行の高さを返す**（幅を狭めると高さが増える）。

**真正性ガード**: コードポイント単位 wrap（現 `wrapPoint` 相当）へ差し戻すと **3・4・5 が落ちる** mutation ガードにする
（クラスタ途中で割れる／約物が孤立する）。独立レビューで真正性まで確認する前提。

---

## 9. 対象外（混ぜない・確定）

- **UAX#14 フル準拠**（全 line-break クラスの厳密実装）。テーブル近似で代替（本 spec の前提）。
- **省略（ellipsis・`Long fil...`）**: backlog #2 が束ねるが**折り返しとは別モード**。今回は折り返しのみ。省略は follow-up。
- **シェイピング／カラー絵文字**（#11・atlas RGBA 化）。wrap の幅は per-codepoint advance のまま（§7）。
- **ハイフネーション辞書**（`com-` `puter` のような語中ハイフン挿入）。
- **両端揃え（justification）／bidi**（LTR-only 宣言済み・CLAUDE.md「文字コード」）。
- **Button への折り返し**（影響範囲から除外済み・text_backlog.md #2・ボタンに長文を入れない）。

---

## 10. 未決・要判断リスト

1. **ヘルパ置き場 (a) awt / (b) framework**（§4.2）。推奨は (a)（Unicode 依存と測定を awt に閉じ込め・#3 と整合）。作者判断が要る。
2. **折り返し Label は mode か新 widget か**（§6.1）。推奨は Label にモード追加（Component が見越し済み・no-wrap ガードで既存温存可）。
   別 widget（`WrapLabel`）案との最終判断は作者。
3. **break opportunity テーブルの最終集合**（§2.1）。VS Code 既定を出発点に、GUI 折り返しへ間引いた具体集合を確定する。
   特に `/` `.` `-` を Latin で折り候補にするか（URL・パス・ハイフン語の挙動が変わる）。
4. **禁則テーブルの最終集合**（§3.1）。JIS X 4051 基本セットのどこまでを採るか（小書き仮名・長音・連数字・分離禁止など）。
5. **追い出し上限 `MAX_OIDASHI` の具体値**（§3.2）。何クラスタ戻して諦めるか（小さい定数想定）。
6. **アイコン併用 Label の折り返し挙動**（§6.1）。アイコン左置きのまま残幅で text を折るか、wrap モードは text-only に限るか。
7. **wrapSegment の戻り契約の細部**（§4.1）。break opportunity が無い CJK 強制改行と、追い出し後退が衝突する境界ケースの優先順位。
</content>
</invoke>
