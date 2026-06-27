# メニュー項目の表示まわり 設計 spec

メニュー項目（`MenuItem` / `CheckBoxMenuItem` / `Menu` item モード）の **表示** を前進させる設計 spec。
扱うのは次の 3 点（ユーザー ＋ pm で合意済み・この spec で 1 本にまとめる）:

- **#1 ニーモニック下線の明示 index 指定** — 対象ラベル内の任意位置を下線できる API を足す。
- **#2 アクセラレータのラベル表示** — `KeyStroke` を `"Ctrl+O"` 等へ整形し、項目右にアクセラレータを描く。
- **#3（起票のみ・実装しない）** — `KeyStroke` のパース（`"Ctrl+O"` → `KeyStroke`）を framework バックログへ。

加えて、#1 に付随する framework ギャップ（`CheckBoxMenuItem` にニーモニック API と下線描画が無い）も同時に埋める。

実装はしない（コードは書かない＝Codex 担当）。`border_model.md` / `cursor_shape.md` の流儀に倣い
**「確定」と「未決」を分ける**。load-bearing な主張には実ファイルの行番号を引用する。

関連:
[framework_backlog.md](framework_backlog.md)（#3 を起票）、
`{REPO_ROOT}/framework/src/MenuItem.zig`（`setMnemonic` / `accelerator` / `lookPaint` / `lookMeasureMinSize`）、
`{REPO_ROOT}/framework/src/CheckBoxMenuItem.zig`（ニーモニック API 不在・下線描画不在）、
`{REPO_ROOT}/framework/src/Menu.zig`（item モードの行・`drawMnemonicUnderline` / `show` のポップアップ採寸）、
`{REPO_ROOT}/framework/src/keybinding.zig`（`KeyStroke` / `Mods` / `letterOf`・整形系は不在）、
`{REPO_ROOT}/awt/src/Event.zig`（`KeyCode` enum）、
`{REPO_ROOT}/examples/app_texteditor/main.zig`（Save As / Word Wrap の現状配線）、
`{REPO_ROOT}/framework/tests/app_texteditor_smoke_test.zig`（`expectItemMnemonic` の追従）、
`{REPO_ROOT}/framework/doc/narrative/keybinding.md`（配送モデル・アクセラレータは保存のみ）。

---

## 0. 背景・確定方針（ユーザー ＋ pm 合意済み・再議論しない）

以下は決定済み。本 spec はこれに沿って表示を具体化するだけで、選択肢の再検討はしない。

1. **#1 明示 index 指定 API を足す**。現状 `MenuItem.setMnemonic(ch)`（`MenuItem.zig:161-165`）は
   `std.ascii.indexOfIgnoreCase(self.text, ch)` で **最初の一致**を下線位置にするため、
   `"Save As"` に `A` を割ると `"Save"` の `a`（index 1）に下線が乗り、`"As"` の `A`（index 5）に乗らない。
   ラベル内の任意位置を直接指定できる API（`setMnemonicAt(ch, index)`）を足す。既存 `setMnemonic(ch)` は
   自動 index の convenience として残す。
2. **#2 アクセラレータをラベルに表示する**。現状 `MenuItem` は `accelerator` フィールド（`MenuItem.zig:27`）を
   保持するだけで描画しない（`ACCEL_SLOT_WIDTH: f32 = 0` ＝ `MenuItem.zig:13` の `// v1: not rendered`、
   `lookPaint`（`MenuItem.zig:189-239`）は背景 → アイコン → ラベル → 下線のみでアクセラレータを描かない）。
   `KeyStroke` を `"Ctrl+O"` / `"Ctrl+Shift+S"` の表示文字列へ整形するヘルパーを `keybinding.zig` に足し、
   項目右にアクセラレータを右寄せ描画し、スロット幅を 0 から実測へ変え、min-size に算入する。
3. **表示は Windows 流の Ctrl 表記固定**（macOS の Cmd 記号は別件に依存ゆえ今回 platform 分岐しない・§2.5）。
4. **#3 は実装しない**。パース（表示の逆操作）は framework バックログに 1 項目起票するに留める（§3）。

---

## 1. 確定: #1 明示 index 指定ニーモニック ＋ CheckBoxMenuItem ギャップ

### 1.1 確定: `MenuItem.setMnemonicAt(ch, index)`

`setMnemonic(ch)`（`MenuItem.zig:161-165`）の隣に明示 index 版を足す。

```zig
/// Menu-local mnemonic with an explicit underline position. `ch` is the
/// activation letter (matched case-insensitively while the parent menu is
/// open); `index` is the BYTE index into `text` of the glyph to underline.
/// Use this when the same letter occurs more than once and the convenience
/// `setMnemonic` would underline the wrong one (e.g. "Save As" + 'A').
pub fn setMnemonicAt(self: *MenuItem, ch: u8, index: usize) void {
    self.component.mnemonic = std.ascii.toLower(ch);
    self.mnemonic_index = index;
    self.component.repaint();
}
```

- 既存 `setMnemonic(ch)` は **そのまま残す**（自動 index の convenience）。実装は
  `setMnemonicAt` を呼ぶ薄いラッパに畳んでよい（単一真実源化・任意）:
  `self.setMnemonicAt(ch, std.ascii.indexOfIgnoreCase(self.text, &[1]u8{ch}) orelse ???)`。
  ただし現 `setMnemonic` は `indexOfIgnoreCase` が `null` のとき `mnemonic_index = null`（不一致なら下線なし）に
  落とす挙動（`MenuItem.zig:163`）であり、`setMnemonicAt` は `?usize` ではなく `usize` を取る素直な形にしたい。
  → **確定**: `setMnemonicAt` のシグネチャは `(ch: u8, index: usize)`。`setMnemonic` の `null` フォールバックは
  ラッパ側（convenience）の責務として残し、`setMnemonicAt` は常に下線を立てる。畳むかどうかは実装裁量
  （畳むなら `setMnemonic` 内で `indexOf` の結果を分岐して `mnemonic_index` を直接代入する現状の構造を維持）。
- **`index` はバイト index**（`mnemonic_index` の既存契約 ＝ `MenuItem.zig:28` `Byte index into text`）。
  下線描画（`MenuItem.zig:227-238`）は `mi < item.text.len` をガードし `text[0..mi]` / `text[mi..mi+1]` を採寸するので、
  index がコードポイント境界をまたぐと不正スライスになる。ASCII ラベル前提の v1 では実害ゼロだが、
  **doc にこの前提（呼び出し側がコードポイント境界の index を渡す責任）を明記する**（マルチバイトラベルは将来）。

### 1.2 確定: `CheckBoxMenuItem` にニーモニック機構を移植する

現状 `CheckBoxMenuItem` は **ニーモニックの下線を一切描かない**。具体的には:

- `mnemonic_index` フィールドが無い（`CheckBoxMenuItem.zig:12-18` のフィールド群に不在）。
- `setMnemonic` / `setMnemonicAt` が無い。
- `lookPaint`（`CheckBoxMenuItem.zig:157-198`）は背景 → チェックマーク → ラベルのみで、
  `MenuItem.zig:226-238` に相当する下線描画ブロックが存在しない。

結果、`examples/app_texteditor` の Word Wrap は `component.mnemonic` を直書きするしかなく
（`main.zig:601` `editor.word_wrap_action.check_item.?.component.mnemonic = 'w';`）、
**下線が出ない**（`component.mnemonic` を立てても描画側が下線を引かないため）。
`MenuItem` と同等の `setMnemonic` / `setMnemonicAt` ＋ 下線描画を `CheckBoxMenuItem` にも生やす。

足すもの:

1. フィールド `mnemonic_index: ?usize`（init `null`・`MenuItem.zig:31` と同契約）。
   `createInternal`（`CheckBoxMenuItem.zig:70-78`）の初期化リストに `.mnemonic_index = null` を追加。
2. `setMnemonic(ch)` / `setMnemonicAt(ch, index)`（`MenuItem` と同じ本体）。
3. `lookPaint` のラベル描画直後（`CheckBoxMenuItem.zig:197` `g.drawString` の後）に
   `MenuItem.zig:227-238` と同じ下線描画ブロックを足す。`tx` / `ty` / `m`（`CheckBoxMenuItem.zig:187,195-196`）が
   既に算出済みなので、同じ式（`tx + prefix_w`, `ty + m.height - 1`）で引ける。

#### 単一真実源の共有（確定: ヘルパー関数に切り出す）

`MenuItem` / `CheckBoxMenuItem` / `Menu`（item モード）の 3 箇所に同一の下線描画ロジックが分散するのは
避けたい（既に `MenuItem.zig:227-238` と `Menu.zig:477-483` `drawMnemonicUnderline` で **2 重化**している）。
下線描画は次の純粋な入力だけに依存する: フォント・テキスト・`mnemonic_index`・`tx` / `ty` / `text_h`・色。

- **確定**: 下線描画を `(font, text, mnemonic_index, tx, ty, text_h)` を取る共有ヘルパー関数に切り出し、
  3 箇所がそれを呼ぶ。置き場所は実装裁量だが、`Menu.zig:477-483` の `drawMnemonicUnderline` が既に
  ほぼこの形（`menu` を取る版）なので、**`menu` 依存を外して引数化したものをどこか共有モジュール
  （例: メニュー共通の `menu_paint.zig` 相当、または `MenuItem` の `pub fn`）に置く**のを推奨。
  色は呼び出し側で `g.setColor` 済み前提にする（`Menu.zig:476` のコメント「Uses the color currently set on g」と同流儀）。
- 下線描画ヘルパーは GPU 非依存の幾何計算（`fillRect` 1 回ぶんの座標算出）であり、`g` への描画呼び出しだけが副作用。
- **ニーモニックの状態フィールド自体（`component.mnemonic` ＋ `mnemonic_index`）は各ウィジェットが個別に持つ**
  （`Component.mnemonic` は既に全 Component 共通だが、`mnemonic_index` は `MenuItem` / `Menu` がそれぞれ持つ実体で、
  `CheckBoxMenuItem` にも同型を足す）。set 系メソッド本体（`component.mnemonic = toLower(ch); mnemonic_index = ...`）も
  3 ウィジェットで同型になるが、これは 3 行の単純コードで、共有のための間接化はかえって読みにくい
  → **set 系は各ウィジェットに重複させてよい**（共有するのは描画ヘルパーのみ）。

### 1.3 確定: `Menu` 側（item モード ＝ サブメニュー）の扱い

`Menu` は既に `setMnemonic`（`Menu.zig:225-229`）と `mnemonic_index`（`Menu.zig:44`）と下線描画
（`Menu.zig:477-483`）を持つ。明示 index 版が要るか:

- **確定: `Menu.setMnemonicAt(ch, index)` も足す**（API の対称性。サブメニュー名にも重複文字はありうる）。
  実装は `MenuItem.setMnemonicAt` と同型。`Menu` は #1 の主対象ではないが、3 ウィジェットで
  `setMnemonic` / `setMnemonicAt` のペアを揃えておくほうが利用者の心象モデルが単純になる（コスト極小）。
- `Menu` item モードの行はアクセラレータを持たない（サブメニューは和音で起動しない）。よって **#2 の
  アクセラレータ表示は `Menu` には入れない**（item モードの右端は既にサブメニュー矢印 ＝ `ARROW_SLOT_W`・
  `Menu.zig:24,137,466-468`）。#2 の対象は `MenuItem` と `CheckBoxMenuItem` のみ。

---

## 2. 確定: #2 アクセラレータのラベル表示

### 2.1 確定: `keybinding.zig` の整形ヘルパー

現状 `keybinding.zig` に `toString` 系は無い（`KeyStroke`・`Mods`・`letterOf`（`keybinding.zig:87-92`）のみ）。
`KeyStroke` を Windows 流の表示文字列へ整形するヘルパーを足す。

```zig
/// Format `stroke` as a Windows-style accelerator label (e.g. "Ctrl+O",
/// "Ctrl+Shift+S") into `buf`, returning the written slice. Modifier order is
/// fixed Ctrl → Shift → Alt. The `command` bit always renders as "Ctrl" in v1:
/// there is no macOS Cmd glyph yet (that depends on the deferred macOS Cmd
/// modifier work — see framework_backlog), so this does NOT branch on platform.
/// `buf` must be large enough for the longest label ("Ctrl+Shift+Alt+" + key);
/// a 32-byte stack buffer is ample for the named keys.
pub fn formatAccelerator(stroke: KeyStroke, buf: []u8) []const u8 { ... }

/// Human-readable name of the base key for an accelerator label
/// ("O", "F5", "Enter", "Delete", "Left", ...). Returns null for keys that
/// have no sensible accelerator label (modifiers themselves, `unknown`).
pub fn keyLabel(code: awt.Event.KeyCode) ?[]const u8 { ... }
```

- **修飾の順序は Ctrl → Shift → Alt 固定**（`Mods` のフィールド順 `command, shift, alt` ＝ `keybinding.zig:19-23` と
  一致。`command` を `"Ctrl"` と綴る）。区切りは `"+"`。
- **`keyLabel` の網羅範囲**: アクセラレータに使う実用キーをカバーする。`KeyCode`（`Event.zig:72-172`）から:
  - 英字 `a`〜`z`（`Event.zig:96-121`）→ 大文字 1 文字 `"A"`〜`"Z"`。
  - 数字 `digit_0`〜`digit_9`（`Event.zig:82-91`）→ `"0"`〜`"9"`。
  - ファンクション `f1`〜`f12`（`Event.zig:145-156`）→ `"F1"`〜`"F12"`。
  - 名前付き: `enter`→`"Enter"`、`tab`→`"Tab"`、`delete`→`"Delete"`、`insert`→`"Insert"`、
    `backspace`→`"Backspace"`、`escape`→`"Esc"`、`space`→`"Space"`、
    `arrow_left/right/up/down`→`"Left"/"Right"/"Up"/"Down"`、`home/end/page_up/page_down`→`"Home"/"End"/"PageUp"/"PageDown"`。
  - それ以外（修飾キー単体・記号キー・`unknown`）は v1 ではアクセラレータ実需が無いので `null`
    （`null` の場合 `formatAccelerator` はキー名を空にするか、修飾だけ綴って終わる＝実装裁量。実害が出る前に
    呼ばれないので最小実装でよい）。網羅キーは実需（エディターの Ctrl+英字 / Ctrl+Shift+英字）を起点に絞る。
- **置き場所の確定**: `keybinding.zig`（`KeyStroke` の定義と同じファイル。整形は `KeyStroke` の表示なので近接が自然）。
  `keyLabel` は `awt.Event.KeyCode` を引数に取るので `keybinding.zig` の既存 `letterOf`（`keybinding.zig:87-92`）の
  隣に並べる。`formatAccelerator` を `KeyStroke` のメソッド（`pub fn format(self, buf)`）にするか自由関数にするかは
  実装裁量（`KeyStroke.cmd` 等のコンストラクタ群と並べるならメソッドが自然）。
- **`command` の表記が Ctrl 固定である根拠と将来**: §2.5 参照。

### 2.2 確定: `MenuItem` / `CheckBoxMenuItem` の右寄せ描画

`lookPaint` のラベル描画後に、`accelerator` が非 `null` ならアクセラレータ文字列を **行の右端へ右寄せ**で描く。

- `MenuItem.lookPaint`（`MenuItem.zig:189-239`）: 下線描画ブロック（`:227-238`）と並べて、`item.accelerator` が
  非 `null` のとき `formatAccelerator` で文字列化し、`x = sz.width - PADDING_X - accel_w` に `drawString`。
  色はラベルと同じ `text_color`（`MenuItem.zig:215-219`）を流用、`y` はラベルと同じ `ty`。
- `CheckBoxMenuItem` は現状 `accelerator` フィールド自体を持たない（`CheckBoxMenuItem.zig:12-18`）。
  **#2 の対象に含めるなら `accelerator: ?keybinding.KeyStroke` フィールド ＋ `setAccelerator` も足す**
  （`MenuItem.zig:27,155-157` と同型）。
  - ただしエディターの Word Wrap（唯一の実需 CheckBoxMenuItem）はアクセラレータを持たない
    （`main.zig:220` `Action.init(..., null, onWordWrap)` ＝ KeyStroke が `null`）。
  - → **確定: `CheckBoxMenuItem` にも `accelerator` ＋ `setAccelerator` ＋ 右寄せ描画を足す**
    （#1 で下線描画を移植するついでに表示機構を `MenuItem` と揃え、両ウィジェットの行レイアウトを
    単一の振る舞いにする）。実需が無くても、`MenuItem` だけ表示できて `CheckBoxMenuItem` はできない非対称を
    今 埋めておくほうが後の利用者の驚きが少ない（コストは小・描画ヘルパー共有で重複も避けられる）。
- **右寄せ描画も §1.2 と同じく共有ヘルパーに切り出せる**: `(g, font, accelStr, sz, color)` を取り
  `sz.width - PADDING_X - measure(accelStr)` に描く関数を `MenuItem` / `CheckBoxMenuItem` が呼ぶ。

### 2.3 確定: スロット幅 ＝ ポップアップ最大幅で自然整列（固定スロットを置かない）

「スロット幅をポップアップ内の最大アクセラレータ幅で揃えるか、固定幅か」を実コードで詰めた。

**結論: 固定スロット定数（`ACCEL_SLOT_WIDTH`）を撤去し、各項目が自分のアクセラレータ幅を min-size に算入する。
列の整列は既存のポップアップ採寸機構（最大幅）と右寄せ描画で自然に揃う。**

根拠（既存のポップアップ採寸が「最大項目幅」で全行を同幅にしている）:

- `Menu.show`（`Menu.zig:233-274`）は `popup_w = max(item.min_size.width)`（`:240-244`）を取り、
  全項目に `setBounds(width = popup_w)`（`:261-270`）を与える。つまり **全行は同じ `sz.width` で描かれる**。
- 各 `lookPaint` がアクセラレータを `sz.width - PADDING_X - accel_w` に右寄せすれば、全行の `sz.width` が
  共通なので **アクセラレータの右端が自動的に同一列に揃う**（Windows メニューの右寄せそのもの）。
  ラベル左端も `PADDING_X + ICON_SLOT_WIDTH` で共通（`MenuItem.zig:222`）なので、左寄せラベル列 ＋ 右寄せ
  アクセラレータ列になる。**項目間で幅をブロードキャストする「共有スロット幅」は要らない**
  （`measureMinSize` は兄弟を見られない ＝ `MenuItem.zig:111` のシグネチャが単一 Component 前提。だが
  ポップアップ採寸が最大を取るので、各項目が自分のぶんを申告すれば十分）。

`lookMeasureMinSize` の式（`MenuItem.zig:111-118`・現状 `ICON_SLOT_WIDTH + m.width + ACCEL_SLOT_WIDTH + PADDING_X*2`、
`ACCEL_SLOT_WIDTH = 0`）を次へ変える:

```
width = ICON_SLOT_WIDTH + label_w + accel_term + PADDING_X * 2
accel_term = if (accelerator) |a| GAP + measure(formatAccelerator(a)) else 0
```

- `GAP` はラベルとアクセラレータの間の最小間隔（新規定数。例 24px 程度。実装裁量）。
- `accel_term` は **項目ごとに異なる**（`"Ctrl+O"` と `"Ctrl+Shift+S"` で幅が違う）。これが「アイコンスロットは
  固定なのにアクセラレータは固定にしない」理由: アイコンは 16×16 固定描画で内容非依存（`MenuItem.zig:205-211`）
  だが、アクセラレータは内容で幅が変わり、かつポップアップ採寸が最大を吸うので、固定予約より per-item 算入が
  正しい。
- `ACCEL_SLOT_WIDTH: f32 = 0`（`MenuItem.zig:13`）は **撤去**（`accel_term` に置き換わる）。
  `CheckBoxMenuItem.lookMeasureMinSize`（`:94-101`）も `MenuItem.ICON_SLOT_WIDTH`/`PADDING_X` を参照しつつ
  同じ `accel_term` を足す形に揃える。
- 文字列の採寸は `font.measureString(formatAccelerator(a, &buf))`。`buf` はスタックの固定長
  （`updateTitle` の `bufPrint` ＝ `main.zig:245-246` と同流儀）。`measureMinSize` と `lookPaint` で 2 回
  整形するが、いずれも短い文字列の純計算で安い（キャッシュは実需が出るまで不要・point-of-need）。

**却下した代替（固定スロット）**: `ACCEL_SLOT_WIDTH` を `"Ctrl+Shift+S"` が入る固定値にする案。
メリットは式が単純。デメリットは (a) アクセラレータ無しメニューでも右側に空白を予約して間延びする、
(b) 固定値を超える長いアクセラレータでクリップする、(c) ポップアップ採寸が既に最大幅を取る機構を持つのに
二重に幅を決めることになる。→ per-item 算入を採る。

### 2.4 確定: min-size 算入の経路

`MenuItem` / `CheckBoxMenuItem` は `create` 時に `applyMetrics`（`MenuItem.zig:104-109` /
`CheckBoxMenuItem.zig:87-92`）で `measureMinSize` を呼び `min_size` を焼き込む。
アクセラレータは `create` 後に `setAccelerator` で後付けされる（`main.zig:124`・app 側は項目生成後に設定）ため、
**`setAccelerator` で `applyMetrics` を再実行して `min_size` を更新する**必要がある。

- 現状 `setAccelerator`（`MenuItem.zig:155-157`）は `self.accelerator = stroke;` のみで再採寸しない
  （`ACCEL_SLOT_WIDTH = 0` だったので不要だった）。今後は **`setAccelerator` の末尾で `self.applyMetrics();`
  を呼ぶ**（`setText`（`MenuItem.zig:124-129`）が `applyMetrics` を呼ぶのと同じ流儀）。`repaint` も足してよい。
- これにより、アクセラレータを付けた項目の `min_size.width` が広がり、`Menu.show` の `popup_w` 採寸
  （`Menu.zig:240-244`）が自動的にその幅を吸う。アクセラレータが項目の最小幅に算入されることを
  純ロジックで assert できる（§5）。

### 2.5 確定: platform 分岐しない（Ctrl 表記固定）

表示は **Windows 流の `"Ctrl"` 固定**で、macOS でも `"Ctrl"` と綴る（`⌘` 記号にしない）。

- 根拠: `Mods.command`（`keybinding.zig:19-23`）は match 時に platform 解決される（`satisfies` ＝
  `keybinding.zig:56-65`・macOS は `meta`、その他は `ctrl`）が、**表示用の macOS Cmd 記号は別 backlog の
  「macOS Cmd 修飾ビット」に依存する**。その整備前に表示だけ `⌘` を出すと、修飾の意味体系と表記が
  ズレる。よって今回は platform 分岐を入れず `command → "Ctrl"` 固定にする。
- **doc にこの割り切りを明記する**（`menu_item.md` / `keybinding.md` の該当節）。macOS で `⌘` 表記にするのは
  Cmd 修飾ビット整備後の別項目（`formatAccelerator` に platform 分岐 ＋ 記号テーブルを足すだけの additive 変更で済む形に
  しておく ＝ §2.1 のヘルパーを 1 点で差し替え可能に保つ）。

---

## 3. 確定: #3 は framework バックログへ起票（実装しない）

`KeyStroke` のパース（`"Ctrl+O"` 文字列 → `KeyStroke`・将来のキーバインド設定 UI / 設定ファイル用）は
**この spec では実装しない**。`framework_backlog.md` **#33** として起票済み（この spec と同時）。起票内容の骨子:

- **何**: `formatAccelerator`（§2.1）の逆操作。`"Ctrl+Shift+S"` のような文字列を `KeyStroke` へパースする。
  実需はキーバインドのカスタマイズ（設定ファイル / 設定ダイアログ）。
- **なぜ（保留理由）**: 現状アクセラレータはコードで `KeyStroke.cmd(.s)` 等を直書きしており
  （`main.zig:209-219`）、文字列からの構築は実需が無い（point-of-need 待ち）。
- **依存**: #2 の表示形式（修飾順序 Ctrl→Shift→Alt・キー名テーブル `keyLabel`）に整合させる
  ＝ パースは整形の逆で、両者が同じキー名テーブルを共有する形が望ましい。
- **優先度**: 中。**状態**: 未着手。

---

## 4. app 側の追従（doc に明記・実装段で Codex が行う）

framework の API 追加に伴い `examples/app_texteditor` を追従させる。**framework/src は触らない**この spec の段では
書かないが、実装段の作業として doc に残す。

### 4.1 Save As の下線を `"As"` の `A`（index 5）へ

- 現状 `main.zig:574` `editor.save_as_action.item.?.setMnemonic('A');` は `indexOfIgnoreCase("Save As", 'A')` ＝
  index 1（`"Save"` の `a`）に下線を乗せる。
- → `editor.save_as_action.item.?.setMnemonicAt('A', 5);` に変える（`"Save As"` の `S`(0)`a`(1)`v`(2)`e`(3)
  ` `(4)`A`(5)`s`(6) ＝ `"As"` の `A` は index 5）。
- これに伴いスモークテスト `app_texteditor_smoke_test.zig:221`
  `try expectItemMnemonic(editor.save_as_action.item.?, 'a', 1);` を **index 5 へ更新**する
  （`expectItemMnemonic`（`:153-156`）は `component.mnemonic`（小文字 `'a'`）と `mnemonic_index` を検査する。
  mnemonic 文字は `'a'` のまま、index だけ `1 → 5`）。

### 4.2 Word Wrap を `CheckBoxMenuItem.setMnemonic` 経由へ

- 現状 `main.zig:601` `editor.word_wrap_action.check_item.?.component.mnemonic = 'w';` は `component.mnemonic` 直書きで、
  `CheckBoxMenuItem` が下線を描かないため **下線が出ない**（§1.2）。
- → `editor.word_wrap_action.check_item.?.setMnemonic('w');`（新 API）に変える。これで `mnemonic_index` が
  立ち（`indexOfIgnoreCase("Word Wrap", 'w')` ＝ index 0 ＝ 先頭 `W`）、§1.2 で足した下線描画が効いて
  **下線が出るようになる**。
- スモークテスト `app_texteditor_smoke_test.zig:231`
  `try std.testing.expectEqual('w', editor.word_wrap_action.check_item.?.component.mnemonic.?);` は
  `component.mnemonic` を見るだけなので **そのまま緑**（`setMnemonic` 経由でも `component.mnemonic = 'w'` になる）。
  追加で `mnemonic_index`（= 0）も検査するなら `expectItemMnemonic` 相当を `CheckBoxMenuItem` 版で足してよい（任意）。

### 4.3 アクセラレータ表示は配線済み経路に自動で乗る

エディターの各 Action は既にアクセラレータを `setAccelerator` 済み（`main.zig:124` で Action から項目へ適用、
KeyStroke は `main.zig:209-219` で `cmd(.n)` 等）。§2 の表示を framework に入れると、**app 側の追加配線なしで**
Open に `"Ctrl+O"`、Save As に `"Ctrl+Shift+S"` 等が表示される（`setAccelerator` が `applyMetrics` を再実行する
ようになる ＝ §2.4 ので、min-size も自動で広がる）。app 側で必要なのは Save As / Word Wrap の下線 2 点だけ。

---

## 5. テスト計画（framework 変更ゆえ必須）

純ロジックは GPU 非依存で書き、視覚契約だけ snapshot を狭く 1 枚。
**純ロジックを `initHeadless` で実 DX12 を引く形にしない**（`focus_disabled` / `fc-swing` の教訓 ＝
`cursor_shape.md` §4.3 と同じ・build 緑でも `--listen` 下で test.exe 非ゼロ終了を踏む）。手組みで完結させる。

### 5.1 純ロジック: `formatAccelerator` / `keyLabel`（`keybinding.zig` の test ブロック）

`keybinding.zig` には既に test ブロックがある（`keybinding.zig:146-197`）。そこへ追加:

- `formatAccelerator(KeyStroke.cmd(.o))` → `"Ctrl+O"`。
- `formatAccelerator(KeyStroke.cmdShift(.s))` → `"Ctrl+Shift+S"`。
- `formatAccelerator(KeyStroke.alt(.f4))` → `"Alt+F4"`（修飾単独 alt ＋ ファンクションキー）。
- 修飾順序: 仮に `command + shift + alt` 全部 → `"Ctrl+Shift+Alt+<key>"`（Ctrl→Shift→Alt 固定の検証）。
- 無修飾キー: `formatAccelerator(KeyStroke.of(.f5))` → `"F5"`（修飾なし）。
- `keyLabel`: 英字 `.o`→`"O"`、数字 `.digit_1`→`"1"`、`.enter`→`"Enter"`、`.delete`→`"Delete"`、
  `.arrow_left`→`"Left"`。網羅キーの代表を 1 つずつ。

### 5.2 純ロジック: `setMnemonicAt` / `CheckBoxMenuItem.setMnemonic`

手組み（`Application.initHeadless` でなく、`MenuItem.create` / `CheckBoxMenuItem.create` を直接 ＝
ただしフォント等が要るなら最小の手組み Application）で:

- `MenuItem.setMnemonicAt('A', 5)` 後、`component.mnemonic == 'a'` かつ `mnemonic_index == 5`
  （指定 index がそのまま入る ＝ 下線描画の前提が立つ）。
- `MenuItem.setMnemonic('A')`（convenience）後、`mnemonic_index == indexOfIgnoreCase`（最初一致）で従来挙動が不変。
- `CheckBoxMenuItem.setMnemonic('w')` 後、`component.mnemonic == 'w'` かつ `mnemonic_index == 0`
  （新フィールドが立つ）。
- `CheckBoxMenuItem.setMnemonicAt('p', 3)` で任意 index が入る。

### 5.3 純ロジック: min-size へのアクセラレータ算入（§2.4）

- アクセラレータ無しの `MenuItem` の `min_size.width` を採り、`setAccelerator(KeyStroke.cmdShift(.s))` 後に
  **`min_size.width` が増える**ことを assert（`measure` がアクセラレータ幅を加算する ＝ §2.4 の経路が
  効いている）。`setAccelerator` が `applyMetrics` を呼ぶ回帰ガードになる。
- `setAccelerator(null)` で元の幅に戻ることも見れる（任意）。

### 5.4 視覚契約: snapshot を狭く 1 枚

アクセラレータ描画とスロット整列は純ロジックでは測れない（実際の右寄せ位置・列整列は描画結果）。
**アクセラレータ付きメニューのポップアップを 1 枚** `snapshotPng` で固定する（`framework_backlog.md` #2 の
「開いた状態のメニュー」snapshot 未カバーとも重なる ＝ 最小限の 1 シーン）。

- シーン: `MenuItem` 2〜3 個（`"Open"` ＝ Ctrl+O・`"Save As"` ＝ Ctrl+Shift+S・アクセラレータ無しの項目を 1 つ混ぜる）を
  持つポップアップ。下線（明示 index 含む）とアクセラレータ右寄せ、列の右端整列が 1 枚で確認できる。
- これは描画パイプライン（GPU）を通る唯一のテスト。純ロジック（5.1〜5.3）と分離し、snapshot 側だけが
  GPU ゲート下に乗る形を保つ（§5 冒頭の教訓）。

---

## 6. 未決事項

- **`GAP` 定数の値**（§2.3・ラベルとアクセラレータの最小間隔）。実機で間延び / 詰まりを見て決める
  （Windows メニューは概ね広め）。snapshot 1 枚で目視確認できる。
- **`keyLabel` の網羅範囲の最終確定**（§2.1）。v1 はエディター実需（Ctrl+英字 / Ctrl+Shift+英字 ＋ F キー）で
  足りるが、記号キー（`+` `-` 等のズーム系）を入れるかは実需が出てから additive に足す。
- **下線描画ヘルパーと右寄せ描画ヘルパーの置き場所**（§1.2 / §2.2）。`MenuItem` の `pub fn` にするか、
  メニュー共通の小モジュールを新設するか。3 ウィジェットが import しやすい場所を実装時に決める
  （先回りでモジュールを作らない ＝ 共有が 2 箇所で済むなら `MenuItem` に置くだけでよい）。
- **`setMnemonic` を `setMnemonicAt` のラッパに畳むか**（§1.1）。`null` フォールバックの扱いを変えない範囲で
  畳めるが、現状の分岐（`indexOfIgnoreCase` → `?usize`）を保ったままでも単一真実源は描画ヘルパー側で達成済み。
  畳むかは実装裁量。
- **macOS の `⌘` 表記**（§2.5）。Cmd 修飾ビット整備後の別項目。今回は Ctrl 固定。

---

## 7. 実装の段割り提案

**小物（#1 ＋ CheckBox ギャップ）を先・表示（#2）を後の薄い 2 スライス**を推奨する。理由: #1 は API 追加 ＋
既存下線描画の移植で完結し（描画パイプラインに新要素を足さない）、app の Save As / Word Wrap の下線が即 直る
＝ 観測しやすい。#2 はアクセラレータ整形 ＋ 新規描画 ＋ 採寸変更 ＋ snapshot 更新で、面が広い。分けると
各スライスが小さく緑を保てる。

**スライス 1（#1 ＋ CheckBox ギャップ）**:

1. `MenuItem.setMnemonicAt` を足す。下線描画を共有ヘルパーへ切り出し（`MenuItem` / `Menu` の 2 重を 1 本化）。
2. `CheckBoxMenuItem` に `mnemonic_index` ＋ `setMnemonic` / `setMnemonicAt` ＋ 下線描画（共有ヘルパー利用）を足す。
3. `Menu.setMnemonicAt`（対称性）。
4. app: Save As を `setMnemonicAt('A', 5)`、Word Wrap を `setMnemonic('w')` へ。スモークテスト index 1→5 更新。
5. テスト: §5.2 の純ロジック。

**スライス 2（#2 アクセラレータ表示）**:

6. `keybinding.zig` に `formatAccelerator` / `keyLabel`。§5.1 の純ロジックテスト。
7. `MenuItem` / `CheckBoxMenuItem` の `lookMeasureMinSize` を `accel_term` 算入へ（`ACCEL_SLOT_WIDTH` 撤去・
   `GAP` 新設）。`setAccelerator` で `applyMetrics` 再実行。`CheckBoxMenuItem` に `accelerator` ＋ `setAccelerator`。
8. `lookPaint` の右寄せアクセラレータ描画（共有ヘルパー）。
9. テスト: §5.3 の min-size 算入 ＋ §5.4 の snapshot 1 枚。

**スライス 3（doc のみ・このタスク外）**: §3 の `framework_backlog.md` 起票はこの spec と同時でよい
（実装ではないため段に依存しない）。

両スライスとも framework のテスト（`zig build test`）を緑のまま進める。app 追従（4・5 と 7 後の表示）は
それぞれのスライス内で閉じる。
