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
キャレットを可視に保つためのスクロールは、囲っている `ScrollPane` に `scrollRectToVisible` を依頼する。
依頼経路は `Component.ScrollController` (`scrollpane.md` 参照)。

## 型定義
```zig
pub const TextArea = struct {
    component:      Component,
    app:            *Application,            // タイマー / フォーカス連携
    core:           EditableText,            // テキスト本体・キャレット・選択・undo/redo (共有コア)
    font:           awt.Graphics.TextFont,
    color:          awt.Graphics.Color,      // テキスト色
    background:     awt.Graphics.Color,      // 背景色 (デフォルト白)
    caret_color:    awt.Graphics.Color,
    caret_visible:  bool,                    // タイマーが toggle する
    blink_timer_id: ?Application.TimerId,
    has_focus:      bool,
    dragging:       bool,                    // 内部での左ボタン押下から release までのあいだ true (選択ドラッグの gate)
    line_wrap:      bool,                    // false=折り返しなし / true=折り返しあり
    lines:          std.ArrayList(VisualLine), // 画面行モデル (reflow で再構築)
    scratch:        std.ArrayList(u8),       // 範囲コピー用の再利用バッファ
    ime:            ImeSession,              // IME composition (preedit) セッション。未変換時は空
    change_listeners: ChangeListenerList,    // テキスト / キャレット / 選択の変化で発火
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

テキスト本体・キャレット・選択・アンドゥ/リドゥ は `EditableText` (`editable_text.md` 参照) に委譲する。
`TextArea` は画面行モデル (`lines`)・折り返し・描画・IME・スクロール連携など複数行ウィジェット固有の関心を持つ。
`core.caret` / `core.mark` は UTF-8 バイトオフセットだが内部実装の詳細で、挿入・削除・キャレット移動はすべて書記素クラスタ境界で行う。
境界計算は `EditableText` の `prevBoundary` / `nextBoundary` / `snapToBoundary` に集約され、`awt.grapheme` の UAX #29 ベースの実装に委譲する。

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
内部で blink タイマーを `clearTimer` し、フォーカスを解除し、`core` / `lines` / `scratch` / `ime` / 各リスナーを解放してからウィジェット自身を free する。
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
* `component.size_query` に height-for-width 関数 (`minHeightForWidth`) を入れる。
  親レイアウトがその幅での最小高さを pure query で取得できるようにする (`component.md`「SizeQuery」参照)。

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

## 編集アクション (アンドゥ / リドゥ / クリップボード / 全選択)
```zig
pub fn undo(self: *TextArea) void;
pub fn redo(self: *TextArea) void;
pub fn cut(self: *TextArea) void;
pub fn copy(self: *TextArea) void;
pub fn paste(self: *TextArea) void;
pub fn selectAll(self: *TextArea) void;
```

キーボードショートカット (`Ctrl+Z` / `Ctrl+Y` / `Ctrl+X` / `Ctrl+C` / `Ctrl+V` / `Ctrl+A`) と同じ処理を公開メソッドとしても呼べる。
メニュー項目・ツールバーボタンからエディターの編集操作を駆動するためのもので、内容が変化したときは change リスナーが発火する。
`undo` / `redo` は `EditableText` のアンドゥスタックを 1 手戻す / 進める。戻せる / 進められる手が無ければ何もしない。
`cut` / `copy` / `paste` は親 `Window` のクリップボードを経由する (orphan 状態では no-op)。

## アンドゥ / リドゥ 可否の取得
```zig
pub fn canUndo(self: *const TextArea) bool;
pub fn canRedo(self: *const TextArea) bool;
```

`EditableText` のアンドゥスタックの状態を返す。メニュー項目・ツールバーボタンの enable / disable を切り替えるのに使う。

## 選択の有無の取得
```zig
pub fn hasSelection(self: TextArea) bool;
```

現在選択範囲があるか (`caret != mark`) を返す。

## キャレット行 / 列の取得
```zig
pub fn caretLineColumn(self: *const TextArea) struct { line: usize, col: usize };
```

キャレット位置の論理行・列を 1 始まりで返す。`col` はコードポイント数で数える (書記素クラスタや表示セル幅ではない)。
ステータスバーに「行:列」を表示するなどに使う。

## ChangeListener
```zig
pub fn addChangeListener   (self: *TextArea, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *TextArea, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

テキスト内容・キャレット・選択のいずれかが変化したときに発火する。
`TextField` の `ChangeListener` が内容変化だけで発火するのと異なり、`TextArea` はキャレット移動・選択変更でも発火する。
ステータスの行:列表示や、コマンドの enable 判定を 1 か所で観測するためである。
`event.source` は発火元の `*TextArea`。

## 機能要望
* 単語単位の折り返し (現状は書記素クラスタ境界を尊重する greedy 折り返しで、`awt.textwrap` が break opportunity と禁則を扱う)。
* `↑` / `↓` の sticky column (現状は毎回再計算)。
* インクリメンタルな行モデル再構築 (現状は編集のたびに O(n) 全走査)。
* `setTabSize` / タブ展開 (現状タブはそのまま 1 グリフ)。
* `setColumns` / `setRows` で推奨サイズを桁・行数指定。
* 部分再描画 (キャレット点滅で全体再描画になるのを避ける)。
* color emoji 表示 (`textfield.md`「棚上げ中」と同じ条件)。
* TextFieldと同じようなIME制御があれば切り出し
