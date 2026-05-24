# textarea
複数行のテキスト入力ウィジェット。
キャレットの点滅、複数行にまたがる選択範囲、クリップボード連携、IME composition (preedit) の inline 表示を内包する。
内部のテキストは `GapBuffer` で保持し、`TextField` より長い文字列の編集を最初から想定する。
属性付きテキスト (色 / フォント混在) は対象外。

折り返しの 2 モード (`line_wrap`) を持ち、いずれも `ScrollPane` に入れて使うのが基本。
`TextArea` 自身はスクロールせず、内容サイズに合わせて自分のサイズを報告し、クリップとオフセットは `ScrollPane` に任せる。
キャレットを可視に保つためのスクロールは、囲っている `ScrollPane` に `scrollRectToVisible` を依頼する (`Component.ScrollController` 経由。`scrollpane.md` 参照)。

## 型定義
```zig
pub const TextArea = struct {
    component:      Component,
    app:            *Application,            // タイマー / フォーカス連携
    text:           GapBuffer,               // UTF-8 内部表現
    caret:          usize,                   // キャレットの論理バイト位置 (内部)
    mark:           usize,                   // 選択範囲の他端 (caret == mark なら選択なし)
    font:           awt.Graphics.TextFont,
    color:          awt.Graphics.Color,      // テキスト色
    background:     awt.Graphics.Color,      // 背景色 (デフォルト白)
    caret_color:    awt.Graphics.Color,
    caret_visible:  bool,                    // タイマーが toggle する
    blink_timer_id: ?Application.TimerId,
    has_focus:      bool,
    line_wrap:      bool,                    // false=折り返しなし / true=折り返しあり
    lines:          std.ArrayList(VisualLine), // 画面行モデル (reflow で再構築)
    scratch:        std.ArrayList(u8),       // 範囲コピー用の再利用バッファ
    preedit_text:         std.ArrayList(u8), // IME 変換中文字列 (UTF-8 コピー)
    preedit_target_start: usize,
    preedit_target_end:   usize,
    allocator:      std.mem.Allocator,
};

/// 画面上の 1 行。start/end は論理バイトオフセットで、end は末尾の '\n' を含まない。
/// 折り返しで分割された行では end はソフト改行位置で、次の行の start と一致する。
const VisualLine = struct {
    start:       usize,
    end:         usize,
    has_newline: bool, // end の位置にハード改行 '\n' が続くか
};
```

`caret` / `mark` は UTF-8 バイトオフセットだが内部実装の詳細。
コードポイント境界の移動は `prevBoundary` / `nextBoundary` に集約してあり、将来書記素クラスタ単位へ移行する際はこの 2 関数 (と `decodeAt` の呼び出し) を UAX #29 ベースに差し替えるだけで済む設計。

## TextArea の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    app: *Application,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
    initial_text: []const u8,
) !*TextArea;
```

`TextArea` をヒープに確保し、`initial_text` を `GapBuffer` にコピーしてから行モデルを構築し、vtable.install を呼ぶ。
失敗時は途中で確保したリソースをすべて解放する。
通常は `Application.textArea(initial_text)` ファクトリ経由で生成する。

### 事前条件
* `initial_text` が有効な UTF-8 であること。違反した場合の動作は UB。

## TextArea の破棄
`vtable.destroy(&ta.component, allocator)` で破棄する。
内部で blink タイマーを `clearTimer` し、フォーカスを解除し、`text` / `lines` / `scratch` / `preedit_text` を解放してから widget 自身を free する。
通常は `ScrollPane` / `Container` の `deinit` 経由で間接的に呼ばれる (所有者がビューの destroy を担う)。

## テキストの設定
```zig
pub fn setText(self: *TextArea, new_text: []const u8) !void;
```

内部バッファを `new_text` で置き換える。キャレットと mark は末尾へ移動し、行モデルを再構築する。

## テキストの取得
```zig
pub fn getText(self: *TextArea) []const u8;
```

内部 UTF-8 バッファの連続スライスを返す (ギャップを末尾へ寄せてから返す)。
内容は次の編集操作まで有効。コピーを保持したいなら呼び出し直後に `allocator.dupe` する。
レシーバが `*TextArea` なのは、内部でギャップを移動する (状態を変える) ため。

## 折り返しモードの取得 / 設定
```zig
pub fn getLineWrap(self: TextArea) bool;
pub fn setLineWrap(self: *TextArea, wrap: bool) void;
```

`true` で折り返しあり、`false` で折り返しなし (デフォルト)。
`setLineWrap(true)` のとき `component.scrollable = .{ .tracks_viewport_width = true }` を立て、`ScrollPane` がビュー幅をビューポート幅に固定するようにする。
`false` のときは `scrollable = null` に戻し、最長行の自然幅を報告して水平スクロールに任せる。
詳細は後述「折り返しと ScrollPane 連携」。

## キャレット色 / 背景色の取得・設定
```zig
pub fn getCaretColor(self: TextArea) awt.Graphics.Color;
pub fn setCaretColor(self: *TextArea, c: awt.Graphics.Color) void;
pub fn getBackground(self: TextArea) awt.Graphics.Color;
pub fn setBackground(self: *TextArea, c: awt.Graphics.Color) void;
```

`TextField` と同じ意味。`caret_color` のデフォルトはテキスト色、`background` のデフォルトは白。

---

## v1 スコープ
CLAUDE.md「文字コード」「書記素クラスタ」の方針に従う:

* 複数行。左から右に書く言語のみ (RTL 未対応)。
* codepoint 単位の挿入・削除・キャレット移動 (書記素クラスタ単位は将来課題。`textfield.md`「棚上げ中」と同じ理由)。
* color emoji 表示は対象外 (`textfield.md` 参照)。
* IME composition の inline 表示は Windows / macOS で動作 (Linux はバックエンド未対応)。
* 折り返しは **文字単位の greedy 折り返し** (単語境界では折らない)。単語折り返しは将来課題。
* 属性付きテキストは対象外。

## キー入力の状態遷移
`key.action == .press` または `.repeat` のときのみ反応する。

| キー | 動作 |
|---|---|
| `←` / `→` | キャレットを 1 codepoint 左右へ。`Shift` で選択拡張 |
| `↑` / `↓` | キャレットを 1 画面行 上下へ (水平オフセットを近い位置で維持)。上端/下端では文書先頭/末尾へ。`Shift` で選択拡張 |
| `Home` / `End` | **画面行**の先頭 / 末尾へ。`Shift` で選択拡張 |
| `Backspace` | 選択あり → 削除。なし → キャレット直前 1 codepoint を削除 |
| `Delete` | 選択あり → 削除。なし → キャレット直後 1 codepoint を削除 |
| `Enter` | 選択あれば置換しつつ `\n` を挿入 (改行) |
| `Ctrl+A` | 全選択 |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | クリップボードへコピー / 切り取り / 貼り付け |

`.char` イベントは「選択があれば削除 → キャレット位置に codepoint を挿入 → キャレットを進める」。

`↑` / `↓` のカーソル列は毎回現在のキャレット位置から再計算する (sticky column は持たない。将来課題)。

## マウス入力
| アクション | 動作 |
|---|---|
| `.press` (left, inside) | キャレットを click 位置に、mark = caret。`requestCapture` + `requestFocus` |
| `.move` (capture 中) | キャレットを更新 → 選択拡張 |
| `.release` | capture 解除 |
| `.scroll` | 何もしない (囲っている `ScrollPane` がホイールを処理する) |

`y` から画面行を、`x` から行内のコードポイント位置を引き当てる (グリフは半分の幅を境に切り替え)。

## 行モデル (reflow)
`lines` は画面行の配列で、編集・`setText`・`setLineWrap`・幅変更 (`reshape`) のたびに `reflow` が再構築する。
論理行を `\n` で区切り、折り返しありのときは各論理行を `wrapWidth` 以内に greedy で分割する (最低 1 codepoint は載せて進行を保証)。
`reflow` は現状テキスト長に対して O(n) で全走査する。インクリメンタルな部分再構築は将来課題。

`reflow` は内容サイズを `min_size` に反映する:
* 高さ = 画面行数 × `line_height` + 上下パディング
* 幅 (折り返しなし) = 最長行の自然幅 + 左右パディング
* 幅 (折り返しあり) = 既定列数ぶんの幅 (実幅は `ScrollPane` が `tracks_viewport_width` で上書きする)

## 折り返しと ScrollPane 連携
`scrollpane.md`「サイズ決定とビューの契約」の height-for-width 機構に乗る。

| モード | 宣言 | 挙動 |
|---|---|---|
| 折り返しなし | `scrollable = null` | 最長行の自然幅 → 水平 + 垂直スクロール |
| 折り返しあり | `scrollable.tracks_viewport_width = true` | 幅をビューポートに固定 → 折り返して高さが伸びる → 垂直のみスクロール |

折り返しありのとき「幅を受け取ったら測り直して `min_size.height` を更新する」契約は、`Component.VTable.reshape` フック (`component.md` 参照) で実現する。
`ScrollPane` がビューに `setBounds` で幅を与えると `reshape` が呼ばれ、`TextArea` がその幅で `reflow` して高さを更新する。
`ScrollPane` は直後に `effectiveMinSize` を読み、折り返し後の高さで垂直スクロール範囲を決める。

## キャレット追従
編集 / クリック / フォーカス獲得のたびに `ensureCaretVisible` が、囲っている `ScrollPane` に「キャレット矩形 (ビューローカル座標) を可視域に入れる」よう依頼する。
`ScrollPane` を `Component.enclosingScrollController` で親方向にたどって見つける。見つからなければ (単体使用) no-op。

## キャレット点滅 / フォーカス / クリップボード
いずれも `TextField` と同じ仕組み。
`install` で `setInterval(500ms)` を仕込み `blinkTick` が toggle、`uninstall` で `clearTimer`。
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

## 機能要望
* `ChangeListener` (内容変更通知)。現状は呼び出し側が polling。
* 単語単位の折り返し (現状は文字単位)。
* `↑` / `↓` の sticky column (現状は毎回再計算)。
* インクリメンタルな行モデル再構築 (現状は編集のたびに O(n) 全走査)。
* `setTabSize` / タブ展開 (現状タブはそのまま 1 グリフ)。
* `setColumns` / `setRows` で推奨サイズを桁・行数指定。
* 部分再描画 (キャレット点滅で全体再描画になるのを避ける)。
* 書記素クラスタ単位の編集 / color emoji (`textfield.md`「棚上げ中」と同じ条件)。
