---
unsafe: true
---

# textarea
TextArea の v1 スコープ・入力ハンドリング・行モデル・折り返し連携・IME・描画。

## v1 スコープ
CLAUDE.md「文字コード」「書記素クラスタ」の方針に従う:

* 複数行。左から右に書く言語のみ (RTL 未対応)。
* 書記素クラスタ単位の挿入・削除・キャレット移動 (境界計算は `EditableText` 経由で `awt.grapheme` に委譲。`TextField` と同一コア)。
* color emoji 表示は対象外 (`textfield.md`「棚上げ中」参照)。
* IME composition の inline 表示は Windows / macOS で動作 (Linux はバックエンド未対応)。
* 折り返しは **書記素クラスタ境界を尊重する greedy 折り返し** (`awt.textwrap` が break opportunity と禁則を扱う)。単語単位の折り返しは将来課題。
* 属性付きテキストは対象外。

## キー入力の状態遷移
`key.action == .press` または `.repeat` のときのみ反応する。

| キー | 動作 |
|---|---|
| `←` / `→` | キャレットを 1 書記素クラスタ 左右へ。`Shift` で選択拡張 |
| `↑` / `↓` | キャレットを 1 画面行 上下へ (水平オフセットを近い位置で維持)。上端/下端では文書先頭/末尾へ。`Shift` で選択拡張 |
| `Home` / `End` | **画面行**の先頭 / 末尾へ。`Shift` で選択拡張 |
| `Backspace` | 選択あり → 削除。なし → キャレット直前 1 書記素クラスタを削除 |
| `Delete` | 選択あり → 削除。なし → キャレット直後 1 書記素クラスタを削除 |
| `Enter` | 選択あれば置換しつつ `\n` を挿入 (改行) |
| `Ctrl+A` | 全選択 |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | クリップボードへコピー / 切り取り / 貼り付け |
| `Ctrl+Z` / `Ctrl+Y` | アンドゥ / リドゥ (`EditableText` のアンドゥスタック) |

`.char` イベントは「選択があれば削除 → キャレット位置にコードポイントを挿入 → キャレットを進める」。
挿入はコードポイント単位で届くが、削除とキャレット移動は書記素クラスタ境界で行う。
これらのキーと同じ処理は公開メソッド (`undo` / `redo` / `cut` / `copy` / `paste` / `selectAll`) からも呼べる (`textarea.md`「編集アクション」参照)。
メニュー項目・ツールバーからエディター操作を駆動するときに使う。

`↑` / `↓` のカーソル列は毎回現在のキャレット位置から再計算する (sticky column は持たない。将来課題)。

TODO: KeyStroke, InputMap, ActionMapなど整備される可能性あり。

## マウス入力
| アクション | 動作 |
|---|---|
| `.press` (left, inside) | キャレットを click 位置に、mark = caret。`requestCapture` + `requestFocus` |
| `.move` (capture 中) | キャレットを更新 → 選択拡張 |
| `.release` | capture 解除 |
| `.scroll` | 何もしない (囲っている `ScrollPane` がホイールを処理する) |

`y` から画面行を、`x` から行内の位置を引き当てる (グリフは半分の幅を境に切り替え、結果を書記素クラスタ境界へスナップする)。

## 行モデル (reflowAt / refreshMinSize)
`lines` は画面行の配列で、編集 / `setText` / `setLineWrap` / 親レイアウトからの `minHeightForWidth(w)` 問い合わせのたびに `reflowAt(inner_w)` が再構築する。
論理行を `\n` で区切り、折り返しありのときは各論理行を `inner_w` 以内に `awt.textwrap.wrapSegment` で分割する。
分割は書記素クラスタ境界を尊重し、break opportunity と禁則を扱う (最低 1 クラスタは載せて進行を保証)。
`reflowAt` は現状テキスト長に対して O(n) で全走査する。インクリメンタルな部分再構築は将来課題。

`reflowAt` は **`lines` の更新と min サイズの計算までを行い、戻り値で `min_w` / `min_h` を返す**。`min_size` の書き換えはしない (pure)。

`min_size` への push は別関数 `refreshMinSize` が担う:
* `setText` / `setLineWrap` / 初期化 / 編集 (`afterReflow`) — つまり利用者操作起源で内容が変わったときに呼ぶ
* 内部で `reflowAt(現在の wrap 幅)` を呼んで結果を `component.setMinSize` する。これで `markLayoutDirty` 経由で親に通知される

サイズ:
* 高さ = 画面行数 × `line_height` + 上下パディング
* 幅 (折り返しなし) = 最長行の自然幅 + 左右パディング
* 幅 (折り返しあり) = 既定列数ぶんの幅 (実幅は親レイアウトが `minHeightForWidth(w)` 経由でビューポート幅を渡すので、 そのときに使われる)

## 折り返しと ScrollPane 連携
`scrollpane.md`「サイズ決定とビューの契約」の height-for-width 機構に乗る。

| モード | 宣言 | 挙動 |
|---|---|---|
| 折り返しなし | `scrollable = null` | 最長行の自然幅 → 水平 + 垂直スクロール |
| 折り返しあり | `scrollable.tracks_viewport_width = true` | 幅をビューポートに固定 → 折り返して高さが伸びる → 垂直のみスクロール |

折り返しありのとき、`setLineWrap(true)` が `component.size_query` に `SizeQuery{ .minHeightForWidth = ... }` をセットする (`component.md`「SizeQuery」参照)。
`ScrollPane` は **ビューに `setBounds` を与える前に** `size_query.minHeightForWidth(view, w)` を呼んで、その幅での最小高さを取得する。
(将来の vertical BoxLayout 配下の wrap Label なども同じ経路に乗る。)
`TextArea` 側の hook (`sizeQueryMinHeightForWidth`) は `reflowAt(inner_w)` を呼ぶ。
これが `lines` を更新しつつ `min_h` を計算して返す。
ビューの観測可能 state (`min_size` 等) は**変えない** pure query。
このため `ScrollPane` の round-trip (旧 `setBounds → reshape → effectiveMinSize` 読み戻し) は不要になり、 親は 1 度の query で高さを知れる。

## キャレット追従
編集 / クリック / フォーカス獲得のたびに `ensureCaretVisible` が、囲っている `ScrollPane` に依頼する。
依頼内容は「キャレット矩形 (ビューローカル座標) を可視域に入れる」こと。
`ScrollPane` を `Component.enclosingScrollController` で親方向にたどって見つける。見つからなければ (単体使用) no-op。

## 編集コアと変更通知
テキスト本体・キャレット・選択・アンドゥ/リドゥ は `EditableText` (`editable_text.md`) が持ち、`TextArea` は `core` フィールドとして 1 つ内包する。
`TextField` と同一コアなので、書記素クラスタ境界計算・改行正規化 (`\r\n` / `\r` → `\n`)・アンドゥコマンドのコアレッシングは両ウィジェットで揃う。

`change_listeners` はテキスト・キャレット・選択のいずれかが変わったときに発火する (`TextField` の ChangeListener が内容変化のみで発火するのと異なる点)。
編集や貼り付けなど内容が変わる操作は行モデル再構築 (`afterReflow`) を経て発火する。
矢印キーやクリックなどキャレット / 選択だけが変わる操作は `afterEdit` / マウスハンドラーから発火する。
エディターはこの 1 か所を購読すれば、ステータスバーの行:列表示 (`caretLineColumn`) と、
アンドゥ / リドゥ ボタンの enable 判定 (`canUndo` / `canRedo`) をまとめて更新できる。
公開メソッド `undo` / `redo` / `cut` / `copy` / `paste` / `selectAll` はキーボード経路と同じコアを叩くので、両者の結果は一致する。

## キャレット点滅 / フォーカス / クリップボード
いずれも `TextField` と同じ仕組み。
`install` で `setInterval(500ms)` を仕込み `blinkTick` がトグル、`uninstall` で `clearTimer`。
`install` で `setFocusable(true)`、`.press` で `requestFocus`、`.focus` 受領で `has_focus` を更新。
`Ctrl+C/V/X` は親 Window の `getClipboardString` / `setClipboardString` を経由する。

## IME 連携
`TextField` と同じく、変換中文字列 (preedit) をキャレット位置に inline 描画し、全体に細い下線、target 区間に太い下線を引く。
キャレットの画面行 / x 位置に追従するので、複数行のどこで変換しても変換中文字列はキャレット直後に出る。
preedit 中はキャレット (`|`) を描かず、`setCompositionCursorPos` で候補ウィンドウ位置を OS に push する。
確定文字列は通常の `.char` イベント経路で流れる。
実装状況 (Windows / macOS 済み、Linux 未対応) は `textfield.md`「IME 連携」と同じ。

## 描画順序
1. 背景塗り
2. 枠線 (focus 状態で色が変わる)
3. 各画面行について: 選択ハイライト → 行テキスト
4. preedit (composition、`has_focus && preedit 非空`)
5. キャレット (`has_focus && caret_visible && preedit 空`)

複数行にまたがる選択は、各画面行で「その行に含まれる選択範囲」を矩形で塗る。
改行そのもの (行末から次行頭への範囲) は v1 ではハイライトしない。

### 可視行カリング
`TextArea` は内容全体のサイズに合わせて配置され、クリップは `ScrollPane` 任せである。
そのため `paint` で全画面行を描こうとすると、画面外の行のグリフまで毎フレーム描画キュー (フレーム共有の頂点リング) に積んでしまう。
頂点リングは有限で、溢れると **以降の描画 (末尾の行や、後から描かれるスクロールバー) が無言で欠落する**。
これを避けるため、`paint` は `Graphics.clipLocalRect` で可視範囲を求め、それに交差する行だけを描く。
これで描画する行数はビューポートの高さ分 (数十行) に収まり、長大なテキストでも頂点リングを溢れさせない。
