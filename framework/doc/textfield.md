#  textfield
単一行のテキスト入力ウィジェット。
キャレットの点滅、選択範囲のハイライト、クリップボード連携、IME composition (preedit) 表示を内包する。

## 型定義
```zig
pub const TextField = struct {
    component:      Component,
    app:            *Application,            // タイマー / フォーカス連携で使う
    text:           std.ArrayList(u8),       // UTF-8 内部表現
    caret_byte:     usize,                   // キャレットのバイト位置 (内部)
    mark_byte:      usize,                   // 選択範囲の他端 (caret == mark なら選択なし)
    font:           awt.Graphics.TextFont,
    color:          awt.Graphics.Color,      // テキスト色
    background:     awt.Graphics.Color,      // 入力欄の背景色 (デフォルト白)
    caret_color:    awt.Graphics.Color,      // キャレットの色 (デフォルト color と同じ)
    caret_visible:  bool,                    // タイマーが toggle する
    blink_timer_id: ?Application.TimerId,    // install で setInterval、uninstall で clearTimer
    has_focus:      bool,                    // focus_owner が自分なら true
    preedit_text:         std.ArrayList(u8), // IME 変換中文字列 (UTF-8 コピー)
    preedit_target_start: usize,             // preedit_text 内の変換中クローズ開始 byte offset
    preedit_target_end:   usize,             // 同上、終了 byte offset
    allocator:      std.mem.Allocator,
};
```

`caret_byte` / `mark_byte` は UTF-8 バイトオフセットだが、これは内部実装の詳細。
将来書記素クラスタ単位に移行する際にも公開 API が破綻しないよう、外向きの API は codepoint index 単位 (もしくは「先頭」「末尾」「選択全体」のような抽象操作) で表現する方針。

## TextField の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    app: *Application,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
    initial_text: []const u8,
) !*TextField;
```

`TextField` をヒープに確保し、`initial_text` を内部 UTF-8 バッファにコピーしてから vtable.install を呼ぶ。
失敗時は途中で確保したリソースをすべて解放してから error を返す。

`app` はタイマー (キャレット点滅) と将来のフォーカス連携のために保持する。
通常は `Application.textField(initial_text)` ファクトリ経由で生成するので、利用者がこの関数を直接呼ぶ機会は少ない。

### 事前条件
* `initial_text` が有効な UTF-8 であること。違反した場合の動作は UB。

## TextField の破棄
`vtable.destroy(&tf.component, allocator)` で破棄する。
内部で `vtable.uninstall` を呼んで blink タイマーを `clearTimer` し、フォーカスを解除し、`text` バッファを開放してから widget 自身を free する。

利用者は `Container.deinit` 経由で間接的に呼ぶのが普通 (Container が子の destroy を担う)。

## テキストの設定
```zig
pub fn setText(self: *TextField, new_text: []const u8) !void;
```

内部バッファを `new_text` で置き換える。
キャレットと mark は末尾に移動する。
レイアウト / 描画は再計算される。

## テキストの取得
```zig
pub fn getText(self: TextField) []const u8;
```

内部 UTF-8 バッファの slice を返す。
内容は次の編集操作 (`setText`、char 入力、Backspace 等) まで有効。
利用者がコピーを保持したいなら呼び出し直後に `allocator.dupe` する。

## キャレット色の取得 / 設定
```zig
pub fn getCaretColor(self: TextField) awt.Graphics.Color;
pub fn setCaretColor(self: *TextField, c: awt.Graphics.Color) void;
```

デフォルトは `color` (テキスト色) と同じ。
ハイコントラスト L&F でテキスト色から独立させたい場合に setter を使う。

## 背景色の取得 / 設定
```zig
pub fn getBackground(self: TextField) awt.Graphics.Color;
pub fn setBackground(self: *TextField, c: awt.Graphics.Color) void;
```

デフォルトは白 (`rgb(1, 1, 1)`)。
無効状態の表現や、ダークモード対応で setter を使う。

---

## v1 スコープ
CLAUDE.md「文字コード」「書記素クラスタ」の方針に従って、v1 では以下に絞る：

* 単一行のみ (`TextArea` は別ウィジェット)
* 左から右に書く言語のみ (RTL は未対応)
* codepoint 単位での挿入・削除・キャレット移動 (書記素クラスタは未対応)
* IME composition の inline 表示は **Windows のみ実装済み**。macOS / Linux はバックエンド未対応 (詳細は「IME 連携」)
* 標準編集ショートカット: `Backspace` / `Delete` / `Home` / `End` / 矢印 / `Shift+矢印` / `Ctrl+A,C,X,V`

`Enter` は単一行なので無視する (将来 `submit` イベントを発火する余地は残す)。
`Tab` / `Shift+Tab` によるフォーカス遷移は未実装 (`window.md`「フォーカス」参照)。

## キー入力の状態遷移
`key.action == .press` または `.repeat` のときのみ反応する。

| キー | 動作 |
|---|---|
| `←` / `→` | キャレットを 1 codepoint 左右へ。`Shift` 押下なら mark を維持して選択拡張、未押下なら mark = caret |
| `Home` / `End` | キャレットを先頭 / 末尾へ。Shift 同上 |
| `Backspace` | 選択あり → 削除。なし → キャレット直前 1 codepoint を削除 |
| `Delete` | 選択あり → 削除。なし → キャレット直後 1 codepoint を削除 |
| `Ctrl+A` | 全選択 (`mark = 0`、`caret = text.len`) |
| `Ctrl+C` | 選択範囲をクリップボードへコピー |
| `Ctrl+X` | コピーしてから削除 |
| `Ctrl+V` | クリップボードの内容をキャレット位置に挿入 (選択ありなら置換) |
| `Enter` | v1 では無視 |

`.char` イベント (`CharEvent`) は「選択があれば削除 → キャレット位置に codepoint を UTF-8 で insert → キャレットを進める」。

## マウス入力
| アクション | 動作 |
|---|---|
| `.press` (left, inside) | キャレットを click 位置に、mark = caret。`requestCapture` でドラッグを掴む。`requestFocus` でフォーカス取得 |
| `.move` (capture 中) | キャレットを更新 (mark は維持) → 選択拡張 |
| `.release` | capture 解除 (Window が自動でクリア) |

ヒットテストはコードポイント単位で半分の幅を境に切り替える (グリフの左半分なら前、右半分なら次に置く)。

## キャレット点滅
`install` で `Application.setInterval(500ms)` を仕込み、`blinkTick` が `caret_visible` を toggle して `component.repaint()` する。
フォーカス未獲得時はキャレットを描画しないので、タイマーは走り続けても見た目には影響しない (描画コストはあるが v1 で許容)。
`uninstall` で `clearTimer` する。

部分再描画は v1 で未対応のため、キャレット点滅のたびに widget 全体が再描画される (`window.md`「機能要望」参照)。

## クリップボード連携
`Ctrl+C` / `Ctrl+V` / `Ctrl+X` は `awt.Window.getClipboardString` / `setClipboardString` を経由する。
親 Window は parent chain を辿って取得する。
orphan 状態 (`window` に attach されていない) では no-op。

## フォーカス
`install` 時に `Component.setFocusable(true)` を呼んでフォーカス対象になる。
* `.press` 時に `Component.requestFocus()` を呼んでフォーカスを能動的に取る
* `.focus.gained` 受領で `has_focus = true` + `caret_visible = true` リセット (即座にキャレット表示)
* `.focus.gained = false` 受領で `has_focus = false`、描画でキャレットを描かなくなる
* `uninstall` 時に自分が `focus_owner` なら親 Window の `FocusController` 経由で `requestFocusFor(null)` を呼ぶ

詳細は `window.md`「フォーカス」を参照。

## レイアウト
* `min_size.height = font.metrics().line_height + PADDING_Y * 2`
* `max_size.height = min_size.height` (1 行で固定)
* `min_size.width = font.glyphAdvance('M') * 20 + PADDING_X * 2` (約 20 桁の幅)
* `grow_x = 0` (デフォルトでは伸びない。Swing JTextField と同じ)

`'M'` を基準に幅を決めるのは Western 的な慣習で、CJK では 1 セル ≈ 2 セル幅になる。
あくまで「だいたい 20 列ぶんの推奨幅」のヒントで、外部から `setMinSize` で上書き可能。

フォーム幅に伸ばしたい場合は `field.component.setGrowX(1)` を呼ぶ。
「ウィジェットの自然サイズ」と「レイアウト戦略 (どれを伸ばすか)」を分離する設計で、利用者が用途別にコントロールできる。

## IME 連携
IME による composition (preedit、変換中文字列) を inline で表示する。
全文確定はせず、ユーザーが Enter / Space で確定するまでフィールド本体の `text` バッファには入らない。
確定文字列は通常の `CharEvent` 経路で flow する (重複処理しない)。

仕組み:
* awt-c が `nmCompositionCallback` でフレームワークに preedit を渡す
* `framework.Window.onComposition` が `focus_owner` に同期 dispatch (preedit の文字列は OS が所有しコールバック寿命のみ valid のため、queue 経由せずその場で配送)
* TextField が `processEvent .composition` を受けたら、`preedit_text` に UTF-8 でコピー + `target_start` / `target_end` を保持
* `paint` 時にキャレット位置に preedit を inline 描画 + 全体に細い下線 + target 区間に太い下線
* preedit 中はキャレット (`|`) を描画しない (IME 側がキャレット表示を担う)
* caret が動くたび (キー編集 / クリック / フォーカス獲得時) に `Window.setCompositionCursorPos` で OS に位置を push → 候補ウィンドウがキャレット直下に出る

実装状況:
| OS | 状態 |
|---|---|
| Windows | IMM32 (`WM_IME_COMPOSITION` + `ImmGetCompositionStringW`) で動作 |
| macOS | バックエンド未実装 (no-op stub)。`NSTextInputClient` ベースの実装は将来 |
| Linux | バックエンド未実装 (no-op stub)。Wayland text-input v3 ベースの実装は将来 |

## 描画順序
1. 背景塗り (`background`)
2. 枠線 (`BORDER_COLOR` / `FOCUS_BORDER`、focus 状態で色が変わる)
3. 選択範囲のハイライト (`SELECTION_BG`、半透明青)
4. テキスト (`drawString`)
5. preedit (composition、`has_focus && preedit_text 非空` のとき)
   - 5a. preedit テキストをキャレット位置に inline 描画
   - 5b. 全体に細い下線 (`PREEDIT_UNDERLINE`)
   - 5c. target 区間に太い下線 (`PREEDIT_TARGET`)
6. キャレット (`has_focus && caret_visible && preedit_text 空` のときだけ 1px 縦線)

## 機能要望
* `ChangeListener` (`addChangeListener` / `removeChangeListener`) — 内容変更時の通知。現状は呼び出し側が tick タイマー等で polling
* `setColumns(n: u32)` — `'M'` ベースの幅算出を桁数で外から指定
* `setPlaceholder(text)` — 空のときに薄く表示するヒント
* macOS / Linux 用 IME バックエンドの実装 (現状は Windows のみ。`awt-c/src/ime_stub.c` が no-op)
* IME composition attribute の多段化 (現状は target 1 区間のみ。Windows IMM の CompAttr の TARGET_NOTCONVERTED / CONVERTED / INPUT 等を色分けして見せたい場合に必要)
* `Tab` / `Shift+Tab` traversal の標準対応
* 書記素クラスタ単位での編集 (`grapheme` クレートに相当する Zig 実装が要る)
* 部分再描画 (キャレット点滅で全画面再描画になるのを避ける)
* `submit` イベント (`Enter` 押下時)
* パスワード入力モード (グリフを `•` で置換)
* スクロール / 横方向クリッピング (現状はテキストが widget 幅を超えても切れずに描画される)
