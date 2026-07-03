---
unsafe: true
---

#  textfield
単一行のテキスト入力ウィジェット。
キャレットの点滅、選択範囲のハイライト、クリップボード連携、IME composition (preedit) 表示を内包する。

## 型定義
```zig
pub const TextField = struct {
    component:      Component,
    app:            *Application,            // タイマー / フォーカス連携で使う
    core:           EditableText,            // テキスト本体・キャレット・選択・undo/redo (共有コア)
    font:           awt.Graphics.TextFont,
    color:          awt.Graphics.Color,      // テキスト色
    background:     awt.Graphics.Color,      // 入力欄の背景色 (デフォルト白)
    caret_color:    awt.Graphics.Color,      // キャレットの色 (デフォルト color と同じ)
    caret_visible:  bool,                    // タイマーが toggle する
    blink_timer_id: ?Application.TimerId,    // install で setInterval、uninstall で clearTimer
    has_focus:      bool,                    // focus_owner が自分なら true
    dragging:       bool,                    // フィールド内での左ボタン押下から release までのあいだ true (選択ドラッグの gate)
    scroll_x:       f32,                     // 水平スクロール量 (px、テキスト先頭起点、>= 0)
    ime:            ImeSession,              // IME composition (preedit) セッション。未変換時は空
    submit_listeners: ActionListenerList,    // Enter で発火
    cancel_listeners: ActionListenerList,    // Escape で発火
    change_listeners: ChangeListenerList,    // 内容変化で発火
    allocator:      std.mem.Allocator,
};
```

テキスト本体・キャレット・選択・アンドゥ/リドゥ は `EditableText` (`editable_text.md` 参照) に委譲する。
`TextField` は描画・クリップボード・IME・横スクロールなど単一行ウィジェット固有の関心だけを持つ。
`core.caret` / `core.mark` は UTF-8 バイトオフセットだが内部実装の詳細である。
挿入・削除・キャレット移動はすべて書記素クラスタ境界で行う (`EditableText` が `awt.grapheme` の境界計算に委譲する)。

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
内部で `vtable.uninstall` を呼んで blink タイマーを `clearTimer` し、フォーカスを解除し、`core`・IME・各リスナーを解放してからウィジェット自身を free する。

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
pub fn getText(self: *TextField) []const u8;
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

## submit / cancel リスナー
```zig
pub fn addSubmitListener   (self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeSubmitListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
pub fn addCancelListener   (self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeCancelListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
```

`Enter` 押下で submit リスナーが、`Escape` 押下で cancel リスナーが発火し、 そのキーは **consume される** (バブルしない)。
単一行フィールドの「確定 / 取り消し」シグナルで、 たとえば `List` のセルエディタが commit / cancel を繋ぐのに使う (`list.md`「編集 (CellEditor)」)。
リスナー登録が無くても発火呼び出し自体は走る (consume だけされる)。

## ChangeListener
```zig
pub fn addChangeListener   (self: *TextField, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
```

テキスト内容が変化したとき (`setText`・文字入力・Backspace 等の編集) に発火する。
キャレット移動・選択範囲の変更・フォーカスの出入り・IME preedit の変化では発火しない (内容そのものが変わったときだけ)。
内容をミラー / バリデーションしたい呼び出し側が、 polling せずに変更を受け取るために使う。

## 機能要望
* `setColumns(n: u32)` — `'M'` ベースの幅算出を桁数で外から指定
* `setPlaceholder(text)` — 空のときに薄く表示するヒント
* Linux 用 IME バックエンドの実装 (現状は Windows + macOS のみ。Linux は `awt-c/src/ime_stub.c` で no-op)
* IME composition attribute の多段化 (現状は target 1 区間のみ)。
  Windows IMM の CompAttr の TARGET_NOTCONVERTED / CONVERTED / INPUT 等を色分けして見せたい場合に必要。
* `Tab` / `Shift+Tab` traversal の標準対応
* 部分再描画 (キャレット点滅で全画面再描画になるのを避ける)
* パスワード入力モード (グリフを `•` で置換)

### 棚上げ中 (color emoji)
書記素クラスタ単位の挿入・削除・キャレット移動は実装済みで、`EditableText` が `awt.grapheme` の UAX #29 ベースの境界計算に委譲する。
ZWJ シーケンス / 結合文字 / 肌色 modifier 等を 1 表示単位として扱う。
残る棚上げは color emoji の表示のみ。 背景と再開条件のメモ:

* **絵文字 (color emoji)** — 編集単位としては書記素クラスタで扱えるが、 表示はまだ出ない。 表示に必要な作業が 2 軸あり、 どちらか欠けても完成しない:
  1. emoji フォントの追加 (例: Noto Color Emoji。 ただしフォントサイズが数 MB〜数十 MB 規模)
  2. カラー描画パス — 現状の `GlyphAtlas` は R8 (alpha mask only)、 `text_program` も grayscale 前提。
     COLR/CPAL (v0/v1) / sbix / CBDT/CBLC のいずれかをサポートし、 RGBA8 atlas + RGBA tinted text program に拡張する必要がある。

ユーザー視点では 「絵文字を入れると `□` が出る」 だが、 これは NotoSansJP に glyph が無いだけではない。
描画パスとフォントの 2 重制約がかかっている (どちらか片方を直しても出ない)。
color emoji 表示に今すぐ取り組まない判断は **2026-05-23**。
