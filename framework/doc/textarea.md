---
unsafe: true
---

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
`setLineWrap(true)` のとき:
* `component.scrollable = .{ .tracks_viewport_width = true }` を立て、`ScrollPane` がビュー幅をビューポート幅に固定するようにする
* `component.size_query` に height-for-width 関数 (`minHeightForWidth`) を入れ、 親レイアウトがその幅での最小高さを pure query で取得できるようにする (`component.md`「SizeQuery」参照)

`false` のときはどちらも `null` に戻し、最長行の自然幅を報告して水平スクロールに任せる。
詳細は後述「折り返しと ScrollPane 連携」。

## キャレット色 / 背景色の取得・設定
```zig
pub fn getCaretColor(self: TextArea) awt.Graphics.Color;
pub fn setCaretColor(self: *TextArea, c: awt.Graphics.Color) void;
pub fn getBackground(self: TextArea) awt.Graphics.Color;
pub fn setBackground(self: *TextArea, c: awt.Graphics.Color) void;
```

`TextField` と同じ意味。`caret_color` のデフォルトはテキスト色、`background` のデフォルトは白。

## 機能要望
* `ChangeListener` (内容変更通知)。現状は呼び出し側が polling。
* 単語単位の折り返し (現状は文字単位)。
* `↑` / `↓` の sticky column (現状は毎回再計算)。
* インクリメンタルな行モデル再構築 (現状は編集のたびに O(n) 全走査)。
* `setTabSize` / タブ展開 (現状タブはそのまま 1 グリフ)。
* `setColumns` / `setRows` で推奨サイズを桁・行数指定。
* 部分再描画 (キャレット点滅で全体再描画になるのを避ける)。
* 書記素クラスタ単位の編集 / color emoji (`textfield.md`「棚上げ中」と同じ条件)。
