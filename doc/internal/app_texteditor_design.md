# app_texteditor 設計（テキストエディタ v1）

`examples/app_texteditor` は単一文書のドッグフーディングアプリ。
地ならし（`ImeSession` / `UndoStack` / `EditableText`）と既存ウィジェットの組み立てに、
エディタ固有ロジック（dirty 追跡・未保存プロンプト・改行コード検出・行:列表示）を載せる。

このドキュメントは実装着手前の設計のみ。`.zig` は含まない。
作者がハンドリングする層（やりたいこと・データ構造・シグネチャ・ライフタイム・制約）を確定し、
内部実装方針が自然に導ける状態にすることが目的。アルゴリズムやバックエンド構文はソースコメントの領分。

手本は `examples/app_filer/main.zig`（Frame / レイアウト / イベント配線 / Dialog / DnD の実例）。
関連バックログ: framework #5（編集コア共通化、本アプリが「高」へ昇格させる実需）、
framework #8（コンテキストメニュー汎用化、貼り付けメニューが 2 件目の実需になる）、
framework #12（TabbedPane、複数タブは v2 の本命）。

## 1. スコープ（作者確定）

v1 でやること:

- 単一文書。専用ウィジェット（Toolbar / StatusBar 型）は作らず、例アプリ内で `Panel` + `Button` /
  `Panel` + `Label` のアドホック組成にする。
- File メニュー: New / Open / Save / Save As / Exit（`FileChooser` 利用）。
- Edit メニュー: Undo / Redo / Cut / Copy / Paste / Select All。
- View メニュー: ワードラップ切替（`CheckBoxMenuItem` ↔ `TextArea` の wrap on/off）。
- ツールバー: アイコンボタン New / Open / Save + Undo / Redo。Undo / Redo の活性は `UndoStack` の
  可否変更リスナーで駆動。
- ステータスバー: 行:列 / dirty 表示 / ファイル名 / エンコーディング（UTF-8 固定表示）/ 改行コード（LF / CRLF、表示のみ）。
- dirty 追跡 + 未保存プロンプト（New / Open / Exit 時に `Dialog`）。
- 開いた時の改行コード検出（表示のみ・変換しない）。

v2 送り（今回やらない）:

- 検索 / 置換、複数タブ（TabbedPane: framework #12）。
- エンコーディング / 改行は表示のみで、文字コード変換はしない。

## 2. シェル構成

`Frame` の `MenuBar` は `Window.container` の外（上）に独立した帯として座る。
`Frame.setMenuBar` で取り付ける（`BorderLayout.north` ではない点に注意。
Window が `menu_bar` の高さを確保し、その下に container を置く）。
ツールバー・本文・ステータスは `Window.container`（`BorderLayout`）の各辺に載せる。

```
┌───────────────────────────────────────────────┐
│ MenuBar:  File   Edit   View                    │  ← Frame.setMenuBar(bar)
├───────────────────────────────────────────────┤
│ Toolbar Panel: [New][Open][Save] | [Undo][Redo] │  ← window.container .north
├───────────────────────────────────────────────┤
│                                                 │
│   ScrollPane                                    │  ← window.container .center
│     └─ TextArea (EditableText)                  │
│                                                 │
├───────────────────────────────────────────────┤
│ Status Panel:  Ln 1, Col 1 | * | name.txt | UTF-8 LF │  ← window.container .south
└───────────────────────────────────────────────┘
```

各領域のウィジェット割り当てと組み立て:

| 領域 | 取り付け | 中身 | ファクトリ |
| --- | --- | --- | --- |
| メニューバー | `Frame.setMenuBar(bar)`（所有を渡す） | `MenuBar` に File / Edit / View の 3 `Menu` | `app.menuBar()` / `app.menu(text)` |
| ツールバー | `BorderLayout.add(&window.container, .north, &panel.component)` | `Panel`（`BoxLayout.horizontalSpaced`）にアイコン `Button` | `app.panel()` / `app.button("")` + `setIcon` |
| 本文 | `BorderLayout.add(&window.container, .center, scroll.asComponent())` | `ScrollPane(&textArea.component)` | `app.scrollPane(view)` / `app.textArea("")` |
| ステータス | `BorderLayout.add(&window.container, .south, &panel.component)` | `Panel` に `Label` 群（行:列 / dirty / 名前 / エンコーディング） | `app.panel()` / `app.label("")` |

- メニューは `MenuBar.add(menu)`、項目は `Menu.add(&item.component)` / `Menu.addSeparator()`。
- アイコン: `app.icon(.file_plus)`（New）/ `app.icon(.folder_open)`（Open）/ `app.icon(.save)`（Save）/
  `app.icon(.undo)` / `app.icon(.redo)`（いずれも lucide。`framework/src/lucide/icons.zig` に存在を確認済み）。
- `TextArea` は `component` フィールドを直接持つ（`asComponent()` は無い）。`ScrollPane` には `&textArea.component` を渡す。

アプリ状態は `app_filer` の `Filer` 同様に単一構造体（仮称 `Editor`）へ集約し、
全ウィジェットポインタと文書状態を保持する。ライフタイムは Filer 踏襲:
UI 破棄（`deinitUi`）でアプリ所有のウィジェット（Dialog / FileChooser 等）を解放し、
`Editor` 自体は `gpa.destroy`。`TextArea` / `ScrollPane` は container 階層が所有・解放する。

## 3. アクション層

1 アクション = 1 ハンドラを、メニュー項目とツールバーボタンの両方から呼ぶ。
これを束ねる小さな Action ヘルパーを例アプリ内に置く（後述）。
ハンドラは `Editor` のメソッド（`fn(self: *Editor, _: *const ActionEvent) void` 形）で、
Action が生成 / バインドした `MenuItem` と `Button` の両方の activation から同じハンドラを呼ぶ（`app_filer` と同形）。

| アクション | メニュー | ツールバー | アクセラレータ | 実体 |
| --- | --- | --- | --- | --- |
| New | File>New | あり | Ctrl+N | dirty なら未保存プロンプト → `setText("")` + パス / dirty / EOL リセット |
| Open | File>Open | あり | Ctrl+O | dirty なら未保存プロンプト → `FileChooser` open → 読込 |
| Save | File>Save | あり | Ctrl+S | パス未確定なら Save As へフォールバック、確定済みなら上書き |
| Save As | File>Save As | なし | Ctrl+Shift+S | `FileChooser` save → 書込 + パス確定 |
| Exit | File>Exit | なし | （なし） | dirty なら未保存プロンプト → ウィンドウクローズ |
| Undo | Edit>Undo | あり | Ctrl+Z | `TextArea` の undo（§11） |
| Redo | Edit>Redo | あり | Ctrl+Y | `TextArea` の redo（§11） |
| Cut | Edit>Cut | なし | Ctrl+X | `TextArea` の cut（§11） |
| Copy | Edit>Copy | なし | Ctrl+C | `TextArea` の copy（§11） |
| Paste | Edit>Paste | なし | Ctrl+V | `TextArea` の paste（§11） |
| Select All | Edit>Select All | なし | Ctrl+A | `TextArea` の selectAll（§11） |
| Word Wrap | View>Word Wrap（CheckBox） | なし | （なし） | `textArea.setLineWrap(checked)`（§9） |

### Action ヘルパー（例アプリ内・framework に Action widget は新設しない）

ツールバー / ステータスバーと同じ方針で、framework に Action widget を新設せず、
`app_texteditor` 内に小さな Action ヘルパーを置く（決定済み・§14）。

データ構造（仮称 `Action`）:

```
Action（例アプリ内ヘルパー）:
  handler: *const fn(*Editor) void   // 呼ぶ実体
  enabled: bool                      // 現在の活性
  name: []const u8                   // メニュー / a11y 名
  icon: ?lucide.Icon = null          // ツールバー用（任意）
  accel: ?keybinding.KeyStroke = null // アクセラレータ（任意）
  item: ?*MenuItem = null            // 束ねたメニュー項目（任意）
  button: ?*Button = null            // 束ねたツールバーボタン（任意）
```

- 各 Action は対応する `MenuItem` と `Button` を生成 or バインドし、両方の `ActionListener` から同じ
  `handler` を呼ぶ。`accel` を持つ Action は対応する `MenuItem.setAccelerator(accel)` に適用する。
- `Action.setEnabled(bool)` で、束ねた全ウィジェット（`item.getModel()` と `button.getModel()`）の
  活性を一括更新する。1 回の `setEnabled` でメニュー項目とツールバーボタンが同時に追従する。
- 動的に活性が変わる Action は次の 3 系統:
  - Undo / Redo: `UndoStack` の可否（`textArea.canUndo()` / `canRedo()`）。
  - Cut / Copy: 選択がある時だけ有効。
  - Paste: クリップボードが非空の時だけ有効。
  これらは `TextArea.addChangeListener`（§11）の単一通知点から、毎回 `canUndo`/`canRedo`・選択有無・
  クリップボード状態を引き直し、各 `Action.setEnabled` を呼ぶ（§10）。
- 常時有効な Action（New / Open / Save / Save As / Exit / Select All / Word Wrap）は `enabled` 固定で、
  動的更新の対象外。
- framework への昇格（汎用 Action / ActionMap 機構）は再利用が見えてから判断する（YAGNI。
  ツールバー / ステータスバーを専用 widget にしないのと同じ判断）。

### アクセラレータの仕組みと二重発火

仕組みは存在する。`MenuItem.setAccelerator(?keybinding.KeyStroke)` で項目に和音を付け、
`Window.dispatchInput` の `.key` 段で配送される（`KeyStroke.cmd(.s)` 等。`framework/src/keybinding.zig`）。
配送順は `Window.zig` 実測で次のとおり:

1. Stage 1: フォーカス所有者（`TextArea`）が生キーを `processEvent` で受ける。消費したらそこで終了。
2. Stage 2–3: フォーカス所有者から root への `key_bindings` 走査。
3. Stage 4: メニューツリーのアクセラレータ走査（`findAcceleratorTarget` → `doClick`）。

帰結:

- File 系（Ctrl+N / O / S / Shift+S）は `TextArea` が処理しない和音なので Stage 1 を素通りし、
  Stage 4 で発火する。安全に `setAccelerator` してよい。
- Edit 系（Ctrl+Z / Y / X / C / V / A）は `TextArea` がフォーカス中に Stage 1 で自前処理して消費する。
  よってメニューのアクセラレータは「フォーカスが本文にある間は本文側が勝つ」=二重発火しない。
  本文外（ツールバーボタンにフォーカス等）にいるときだけ Stage 4 が発火する。
  どちらの経路でも最終的に同じ編集コア操作に落ちるので挙動は一致する。
- → 決定（§14）: File 系・Edit 系とも `setAccelerator` を設定する。Edit 系の `setAccelerator` は
  「メニューに和音を表示する / 本文外でも効かせる」ためのもので、二重発火しないことは上記の配送順で実測済み。

## 4. 文書 / ファイル束縛

モデルは `TextArea`（内部の `EditableText`）。`Editor` が文書メタを持つ:

```
Editor 文書状態（データ構造）:
  path: ?[]u8            // 現在ファイルの絶対パス。null = 無題（New 直後 / 未保存）
  dirty: bool            // 未保存変更あり
  eol: enum { lf, crlf } // 読込時に検出した元の改行コード（表示 & 保存方針に使用）
  baseline: []u8         // 最後に保存/読込した時点の本文スナップショット（dirty 判定用・§5 案B 決定済み）
```

- `path` は `allocator.dupe` で所有し、付け替え時に旧値を free。無題は null。
- 文書差し替え（New / Open / Save As 確定）のたびに `path` / `dirty` / `eol` / `baseline` を整える。
- 本文の真実は常に `TextArea`。`Editor` は本文バイトを二重に持たない（`baseline` は保存時点のコピーのみ）。

## 5. dirty 検出方式の比較と推奨

| 案 | 判定 | コスト | 正確さ |
| --- | --- | --- | --- |
| A: canUndo を dirty とみなす | `textArea.core.canUndo()` | O(1) | 不正確。保存後も undo 履歴が残れば dirty のまま。保存地点まで undo して内容が一致しても dirty を誤検出 |
| B: 保存ベースラインとの内容比較（決定） | `!mem.eql(getText(), baseline)` | 変更ごと O(n) | 正確。「編集→undo で保存内容に戻った」を clean と判定できる |
| C: 保存時 undo 深さとの比較 | `undo_depth != saved_depth` | O(1) | ほぼ正確（線形履歴前提）。ただし `UndoStack` が深さ/連番を公開していない（新規アクセサが要る） |

決定（§14）: 案 B（保存ベースライン比較）。
理由: 単一文書 v1 では正確さが最優先で、「保存→編集→undo で戻す」が clean になるのが自然。
`UndoStack` への新規アクセサ追加が要らず、`EditableText` / `TextArea` の現 API だけで成立する。
判定は §11 の変更通知の中で再計算し、結果が前回と変われば dirty 表示を更新する。

コスト注記: 案 B は変更ごとに本文全体比較で O(n)。大きな文書では割に合わなくなるため、
O(1) 化（案 C・`UndoStack` に単調増加の編集連番アクセサを足す）は v2 の後追いとする（決定済み）。
この移行は framework #5（編集コア）と相性が良い（連番はコア側に住む）。
v1 はあえて案 B で素直に作り、最適化は後追いとする。

## 6. 未保存プロンプト

New / Open / Exit で `dirty` なら、保存 / 破棄 / キャンセルの 3 択モーダルを出す。

- `app.dialog(window, "Unsaved changes", w, h)` で `Dialog` を 1 個作って使い回す
  （`app_filer` の confirm ダイアログと同形。`dialog.window.container` に本文と 3 ボタンを組む）。
- 3 つの結果は `Dialog.Result`（`enum(i32){ none, ok, cancel, _ }`、拡張可能）へ写像する:
  - Save = `.ok`
  - Cancel = `.cancel`
  - Discard = 拡張値（`@enumFromInt(3)` 等）。アプリ側で意味付けする小さな enum 変換を挟む。
- 各ボタンの `ActionListener` で `dialog.close(result)` を呼び、`showModal()` の戻りで分岐:
  - Save → 保存を実行し、成功したら元アクション続行 / 失敗ならアクション中止。
  - Discard → そのまま元アクション続行。
  - Cancel → 元アクションを中止。

呼び出し側の制御フローは「`if (!confirmDiscardIfDirty()) return;`」の形に畳む
（戻り bool = 続行してよいか）。3 アクション（New / Open / Exit）が同じヘルパを通る。

## 7. ステータスモデル

ステータス Panel に `Label` を並べ、変更通知（§11）のたびにまとめて更新する。

- 行:列: caret から算出。`TextArea` 内部の `EditableText` が真実を持つ。
  - 行番号 = caret より前の `'\n'` の個数 + 1。
  - 列番号 = `lineStartAtByte(caret)` から caret までのコードポイント数 + 1
    （v1 はコードポイント単位でよい。CLAUDE.md「初版はコードポイント単位」）。
  - 算出は走査でよい（framework #5 が「行ルックアップの継ぎ目は走査 now・行頭索引 later」と明言）。
    `EditableText.lineStartAtByte(byte)` / `byteAtLine(line)` が継ぎ目。caret は `EditableText.caret`。
- dirty 表示: `dirty` が真なら `*`（またはタイトル/ラベルに印）。保存で消える。
- ファイル名: `path` の basename。無題なら `untitled`。
- エンコーディング: 常に `UTF-8`（公開 API は UTF-8 固定。CLAUDE.md）。表示のみ。
- 改行コード: `eol` を `LF` / `CRLF` で表示（§8）。表示のみ。

caret は `TextArea` 内部状態なので、ステータスは `textArea.caretLineColumn()`（§11 で追加・決定済み）を呼んで
行:列を得る。算出アルゴリズム自体は純粋関数 `lineColumnOf(get_byte_fn, len, caret) -> {line, col}` として
切り出し、GPU 非依存に単体テストできる形にする（§12。`caretLineColumn` 実装はこれを内部利用）。

## 8. 改行コード検出と保存方針

`EditableText` は `initFromSlice` / `setText` で CRLF / CR を LF へ正規化する
（`normalizeLineEndings`、確認済み）。よってバッファに入った後では元の改行は判別できない。

- 検出: Open でファイルの生バイトを読んだ直後、`setText` に渡す前に走査する。
  - `"\r\n"` を含む → `crlf`。
  - 含まず `"\n"` を含む → `lf`。
  - 改行なし → 既定（New と同じ。LF 固定・決定済み）。
  - 検出結果を `Editor.eol` に記録（バッファとは別に保持）。`detectEol(bytes) -> Eol` は純粋関数として単体テスト可能。
- 表示: `eol` をステータスに出す。v1 では UI からの変更手段は持たない（表示のみ）。
- 保存方針（§14 で決定）: 案 P（元の改行を維持）。
  - `crlf` の文書は保存時に LF→CRLF へ展開して書く。`lf` はそのまま書く。
    「変換しない」（= 利用者の改行を勝手に書き換えない）の主旨に沿う。展開はバイト列の単純置換で安価。
  - 新規（無題）文書の既定改行は LF（決定済み）。
  - 不採用の案 Q（常に LF 固定）は CRLF だった文書を黙って LF に変えてしまうため却下。

## 9. ワードラップ切替の配線

- View>Word Wrap は `CheckBoxMenuItem`（`app.checkBoxMenuItem("Word Wrap")`）。
- トグルで `textArea.setLineWrap(item.isChecked())` を呼ぶ
  （`setLineWrap` は wrap 時に viewport 幅追従 + height-for-width クエリを有効化し、no-wrap 時は横スクロール）。
- 初期状態: wrap off（`TextArea` 既定 `line_wrap = false`、`CheckBoxMenuItem` 既定 unchecked）。
  両者の初期値が一致しているので追加の同期コードは不要。
- `ScrollPane` のスクロールポリシーは既定（`as_needed`）のままでよい。
  wrap on では `TextArea` が横方向に伸びないので横スクロールバーは自然に消える。

## 10. 動的活性連動（Action 経由・単一通知点）

活性が状態で変わる Action（Undo / Redo / Cut / Copy / Paste）は、§3 の Action ヘルパーと
§11 の `TextArea.addChangeListener` を組み合わせ、1 つの通知点から一括更新する。

- 駆動点は `TextArea.addChangeListener`（テキスト + caret 変更の単一通知）。
  個別の `UndoStack.addCanChangeListener` は使わず、変更通知のたびに状態を引き直す
  （caret だけ動いた時も選択有無が変わるため、可否専用リスナーでは不足）。
- コールバックで次を引き、対応する `Action.setEnabled` を呼ぶ:
  - Undo / Redo: `textArea.canUndo()` / `textArea.canRedo()`。
  - Cut / Copy: 選択がある時のみ有効（選択有無は `TextArea` のアクセサ / 通知から判定）。
  - Paste: クリップボードが非空の時のみ有効。
- `Action.setEnabled` が束ねた `MenuItem` と `Button` の `ButtonModel.setEnabled` を一括で叩く
  （`ButtonModel.setEnabled(bool)` / `isEnabled()` は確認済み。メニュー項目もツールバーボタンも同一に扱える）。
- 起動直後は Undo / Redo / Cut / Copy が disabled（履歴空・選択なし）、Paste はクリップボード状態次第。
- ステータス（行:列 / dirty）の更新も同じ通知点に相乗りする（§7）。

## 11. フレームワーク前提（TextArea への追加・採用決定）

本アプリの中核依存。`TextArea` の現公開 API は
`getText` / `setText` / `getLineWrap` / `setLineWrap` / 色設定のみで、次が無い:

1. 変更通知（テキスト変更・caret 移動を知る手段）が無い。
2. メニュー / ツールバーから undo / redo / cut / copy / paste / selectAll を駆動する公開メソッドが無い
   （現状これらは `handleKey` 内の Ctrl+Z/Y/X/C/V/A としてのみ実装され、外から呼べない）。
3. caret 行:列 / undo 可否のアクセサが無い（`core` フィールドは Zig の仕様上参照可能だが内部直叩き）。

なぜ通知が要るか: タイピングは `TextArea.handleChar` に直接入り、アプリは関与しない。
内部 Ctrl+Z も同様。よって変更通知が無いと、ステータス（行:列）と dirty・動的活性（§10）が
「タイピングや本文側 undo で更新されない」。ポーリングは毎フレーム描画を避ける方針（CLAUDE.md）に反する。
単一の変更通知点があれば、入力経路（キーボード内蔵・メニュー・ツールバー）すべてを 1 か所で拾える。

決定（§14・採用確定）。`TextArea` に次を追加する（ドラフト署名で確定。最終的な型詳細は実装時に整える）:

```
// 変更通知: テキスト変更 + caret 変更の両方で発火（dirty / 行:列 / 動的活性の単一駆動点）
pub fn addChangeListener(self: *TextArea, comptime T, comptime f: fn(*T, *const ChangeEvent) void, *T) !void

// アクション公開: 内部の handleKey 経路と同じ実体を呼び、reflow / repaint / 通知まで行う
pub fn undo(self: *TextArea) void
pub fn redo(self: *TextArea) void
pub fn cut(self: *TextArea) void
pub fn copy(self: *TextArea) void
pub fn paste(self: *TextArea) void
pub fn selectAll(self: *TextArea) void

// アクセサ: 行:列算出と動的活性連動のため
pub fn caretLineColumn(self: *const TextArea) struct { line: usize, col: usize } // 行:列算出を内蔵
pub fn canUndo(self: *const TextArea) bool
pub fn canRedo(self: *const TextArea) bool
```

- これらは内部実装の重複を増やさない: `handleKey` の各ケースを「公開メソッド → 通知」へ畳み直し、
  キーボード経路もメニュー経路も同じメソッドを通す（決定済みの実装方針）。
  framework #5（編集コア共通化・applyEdit チョークポイント）と方向が一致しており、
  本アプリがその実需（「高」昇格）を生む。
- 活性更新は `addChangeListener` の通知点に相乗りする（caret / テキスト変更のたびに `canUndo` / `canRedo`・
  選択有無を引き直す）ため、`UndoStack` の可否専用リスナーは使わない。
- Cut / Copy の選択有無と Paste のクリップボード状態は、この通知点で更新時に読む。
  選択有無は変更通知 / 小さなアクセサから判定する（同じ単一通知設計に沿う additive な細部で、
  上記の採用決定を変えるものではない）。

この追加は地ならし（編集コア）の延長線上の薄いもので、`handleKey` の畳み直し以上の新規ロジックを持たない。

## 12. テスト方針

アプリ機能テスト（Robot スモーク・ヘッドレス）:

- `app_filer` の `framework/tests/app_filer_smoke_test.zig` + `Driver` / `Robot` 方式を踏襲。
- 主要シナリオを `Driver` で駆動し、`snapshotTree`（または公開アクセサ）で状態の妥当性を確認:
  - 新規 → タイピング → dirty が立つ。
  - Save ダイアログ → パス確定 → dirty が消える。
  - 既存ファイルを開く → 本文・改行コード表示・dirty=false。
  - dirty 状態で New/Open/Exit → 未保存プロンプトが出て、Save/Discard/Cancel が期待どおり分岐。
  - undo/redo でメニュー/ツールバーの活性が連動。
  - Word Wrap トグルで `getLineWrap()` が反転。
- ファイル I/O はテスト用ディレクトリ（`std.testing` の tmp）を使うか、`FileChooser` の `DirSource`
  抽象（`app_filer` が使う `osDirSource` 同様の差し替え）でモック可能にする。

純ロジック単体テスト（GPU 非依存・`src` の test ブロックまたは `framework/tests/`）:

- `detectEol(bytes) -> Eol`: LF / CRLF / 改行なし / 混在の判定。
- `lineColumnOf(...)`: 行頭・行末・複数行・末尾改行・マルチバイト（コードポイント単位）での行:列。
- dirty 判定（案 B のベースライン比較）: 編集で true、保存で false、undo で戻すと false。

これらはアプリ内 free function として切り出し、`TextArea` / GPU 無しで直接呼べる形にする。

## 13. 実装段（pm が段ごとに観測できる分割）

各段の終わりに対応する Robot スモークを足し、段単位で緑にする。

1. シェル + メニュー骨組み: Frame / MenuBar(File/Edit/View) / ツールバー Panel / ScrollPane+TextArea /
   ステータス Panel を組み、Action ヘルパー（§3）で空アクションを配線。`build.zig` の
   `addExample(b, "app_texteditor", ...)` と `examples/readme.md` への項目追加、スモークの土台もここで。
   観測: ウィンドウが立ち上がり各領域が描画される / メニューが開く。
2. ファイル I/O + dirty: New / Open / Save / Save As / Exit と未保存プロンプト、`path` / `eol` 検出、
   §5 の dirty 判定。`TextArea` の framework 追加（変更通知 + 公開アクション + アクセサ・§11）をここで導入。
   観測: 開く→編集→保存→開き直しの往復、dirty の立ち消え、プロンプトの 3 分岐。
3. ステータス + 動的活性 + wrap: 行:列 / 名前 / エンコーディング / 改行コード表示、Word Wrap トグル、
   Action 経由の動的活性連動（Undo/Redo/Cut/Copy/Paste・§10）。
   観測: caret 移動で行:列が追従 / wrap トグル / 編集・選択でメニュー & ツールバーの活性が連動。
4. 仕上げ: Edit メニューのアクセラレータ整備（§3 で決めた範囲）、アイコン / ラベル文言、
   エッジケース（無題保存・空ファイル・巨大行）の確認。

## 14. 決定済み（作者確定）

すべて作者判断で確定済み。各節の本文はこの決定を反映済み。

1. TextArea への framework 追加（§11）＝採用。ドラフト署名で確定:
   `addChangeListener`（テキスト + caret 変更の単一通知点）/ 公開アクション
   `undo` / `redo` / `cut` / `copy` / `paste` / `selectAll` / アクセサ `caretLineColumn()` と
   `canUndo()` / `canRedo()`。実装は `handleKey` の各ケースを「公開メソッド → 通知」へ畳み直す形
   （重複を増やさない）。
2. dirty 検出（§5）＝案 B（保存ベースライン比較）。O(1) の案 C（`UndoStack` 連番アクセサ）は v2 後追い。
3. 保存時改行（§8）＝案 P（元改行を維持。`crlf` は保存時に LF→CRLF 展開）。
   新規（無題）文書の既定改行＝LF。
4. アクセラレータ（§3）＝付ける。Edit 系（Ctrl+Z/Y/X/C/V/A）に `setAccelerator` を設定（二重発火しないと実測済み・
   メニュー表示と本文外発火のため）。File 系（Ctrl+N/O/S・Ctrl+Shift+S）も設定。
5. ファイル I/O 所在＝アプリ内で `std.Io.Dir` を直接使う（`app_filer` 踏襲）。framework ヘルパは置かない。
6. 未保存プロンプト（§6）＝`Dialog.Result` 拡張値へ写像（Save=ok / Cancel=cancel / Discard=拡張値）。
7. コンテキストメニュー（貼り付け等）＝v1 スコープ外。v2 で framework #8（コンテキストメニュー汎用化）の
   2 件目の実需として扱う。
8. Action は例アプリ内ヘルパー（§3）として実装。framework に Action widget は新設しない
   （ツールバー / ステータスバーと同じ YAGNI 判断。昇格は再利用が見えてから）。
