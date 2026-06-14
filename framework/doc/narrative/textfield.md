---
unsafe: true
---

# textfield
TextField の v1 スコープ・キー/マウス入力・キャレット点滅・クリップボード・フォーカス・レイアウト・IME・横スクロール・描画。

## v1 スコープ
CLAUDE.md「文字コード」「書記素クラスタ」の方針に従って、v1 では以下に絞る：

* 単一行のみ (`TextArea` は別ウィジェット)
* 左から右に書く言語のみ (RTL は未対応)
* コードポイント単位での挿入・削除・キャレット移動 (書記素クラスタ単位は将来課題。詳細は「機能要望」)
* color emoji の表示は v1 では対象外 (フォントと描画パスの両方が要拡張、 詳細は「機能要望」)
* IME composition の inline 表示は **Windows / macOS で実装済み**。Linux はバックエンド未対応 (詳細は「IME 連携」)
* 標準編集ショートカット: `Backspace` / `Delete` / `Home` / `End` / 矢印 / `Shift+矢印` / `Ctrl+A,C,X,V`

単一行なので改行は挿入せず、 `Enter` は submit、 `Escape` は cancel のシグナルとして使う (「submit / cancel リスナー」参照)。
`Tab` / `Shift+Tab` によるフォーカス遷移は Window のトラバーサルが処理する
(TextField は Tab を消費しないので素通しする。`window.md`「フォーカストラバーサル」参照)。

## キー入力の状態遷移
`key.action == .press` または `.repeat` のときのみ反応する。

| キー | 動作 |
|---|---|
| `←` / `→` | キャレットを 1 コードポイント左右へ。`Shift` 押下なら mark を維持して選択拡張、未押下なら mark = caret |
| `Home` / `End` | キャレットを先頭 / 末尾へ。Shift 同上 |
| `Backspace` | 選択あり → 削除。なし → キャレット直前 1 コードポイントを削除 |
| `Delete` | 選択あり → 削除。なし → キャレット直後 1 コードポイントを削除 |
| `Ctrl+A` | 全選択 (`mark = 0`、`caret = text.len`) |
| `Ctrl+C` | 選択範囲をクリップボードへコピー |
| `Ctrl+X` | コピーしてから削除 |
| `Ctrl+V` | クリップボードの内容をキャレット位置に挿入 (選択ありなら置換) |
| `Enter` | submit リスナー発火 + consume (「submit / cancel リスナー」) |
| `Escape` | cancel リスナー発火 + consume |

`.char` イベント (`CharEvent`) は「選択があれば削除 → キャレット位置にコードポイントを UTF-8 で insert → キャレットを進める」。

TODO: KeyStroke, InputMap, ActionMapなど整備される可能性あり。

## マウス入力
| アクション | 動作 |
|---|---|
| `.press` (left, inside) | キャレットを click 位置に、mark = caret。`requestCapture` でドラッグを掴む。`requestFocus` でフォーカス取得 |
| `.move` (capture 中) | キャレットを更新 (mark は維持) → 選択拡張 |
| `.release` | capture 解除 (Window が自動でクリア) |

ヒットテストはコードポイント単位で半分の幅を境に切り替える (グリフの左半分なら前、右半分なら次に置く)。

## キャレット点滅
`install` で `Application.setInterval(500ms)` を仕込み、`blinkTick` が `caret_visible` をトグルして `component.repaint()` する。
フォーカス未獲得時はキャレットを描画しないので、タイマーは走り続けても見た目には影響しない (描画コストはあるが v1 で許容)。
`uninstall` で `clearTimer` する。

部分再描画は v1 で未対応のため、キャレット点滅のたびにウィジェット全体が再描画される (`window.md`「機能要望」参照)。

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

`grow_x` は init 時の既定 (0)。`setText` 等の metrics 再計算では再適用しないため、caller の `setGrowX(1)` は保持される。

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
* `framework.Window.onComposition` が `focus_owner` に同期 dispatch
  (preedit の文字列は OS が所有しコールバック寿命のみ valid のため、queue 経由せずその場で配送)
* TextField が `processEvent .composition` を受けたら、`preedit_text` に UTF-8 でコピー + `target_start` / `target_end` を保持
* `paint` 時にキャレット位置に preedit を inline 描画 + 全体に細い下線 + target 区間に太い下線
* preedit 中はキャレット (`|`) を描画しない (IME 側がキャレット表示を担う)
* caret が動くたび (キー編集 / クリック / フォーカス獲得時) に `Window.setCompositionCursorPos` で OS に位置を push → 候補ウィンドウがキャレット直下に出る

実装状況:
| OS | 状態 |
|---|---|
| Windows | IMM32 (`WM_IME_COMPOSITION` + `ImmGetCompositionStringW`) で動作 |
| macOS | `NSTextInputClient` (`setMarkedText:` / `firstRectForCharacterRange:`) を runtime subclass で intercept (`awt-c/src/cocoa_ime.m`) |
| Linux | バックエンド未実装 (no-op stub)。Wayland text-input v3 ベースの実装は将来 |

## クリッピングと横スクロール
入力がフィールド幅を超えると、キャレットが常に見えるよう内容を水平スクロールする。

`scroll_x` (テキスト先頭からのスクロール量、px、`>= 0`) を状態に持ち、画面上の glyph x を `PADDING_X + glyphXAtByte(b) - scroll_x` で表す。
`glyphXAtByte` はテキスト先頭起点 (0 ベース、`PADDING_X` も `scroll_x` も含まない) の x オフセットを返す。
描画側では `PADDING_X` の加算 (内側クリップ用子 `Graphics` の原点平行移動で吸収) と `scroll_x` の減算をする。

キャレット追従は `ensureCaretVisible` が担う:
* キャレットが可視域を右に超えたら右へ、左に出たら左へ `scroll_x` を寄せる (末尾キャレットが右端で切れないよう `CARET_WIDTH` ぶん余裕を確保)。
* 先頭より手前へはスクロールせず、末尾が戻せるのに無駄に右へ寄らないようクランプする。
* caret が動くたび (`afterEdit` / クリック / ドラッグ / フォーカス獲得) に呼ぶ。加えて **`paint` 冒頭でも呼ぶ**
  — 幅はレイアウト後にしか確定しないため、ここが権威ある再計算になる
  (`setText` / リサイズ / 長い初期テキストもこれで自動補正される)。

ヒットテスト (`hitTestByteAt`) はクリック位置を `x_local - PADDING_X + scroll_x` に変換してから glyph を引き当てる。
`pushCaretToIme` (IME 候補ウィンドウの位置) も `scroll_x` を反映する。

クリッピングはコンポーネント単位で行われる。
`Component.paintAt` が各コンポーネントの `getBounds` でクリップした子 `Graphics` を作って `paint` に渡す
(`graphics.md` のシザー参照)。
これに加え、TextField はテキスト / 選択 / preedit / キャレットを内側コンテンツ矩形
`[PADDING_X, width - PADDING_X]` にクリップした子 `Graphics` 経由で描く。
これによりスクロール時に左の文字がパディングや枠線の上へはみ出さない (背景と枠線は全体の `Graphics` に描画)。

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
