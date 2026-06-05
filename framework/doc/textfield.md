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
    scroll_x:       f32,                     // 水平スクロール量 (px、テキスト先頭起点、>= 0)
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

## submit / cancel リスナー
```zig
pub fn addSubmitListener   (self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeSubmitListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
pub fn addCancelListener   (self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
pub fn removeCancelListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
```

`Enter` 押下で submit リスナーが、`Escape` 押下で cancel リスナーが発火し、 そのキーは **consume される** (バブルしない)。
単一行フィールドの「確定 / 取り消し」シグナルで、 たとえば `List` のセルエディタが commit / cancel を繋ぐのに使う (`list.md`「編集 (CellEditor)」)。
リスナー登録が無くても発火呼び出し自体は走る (consume だけされる)。

## 機能要望
* `ChangeListener` (`addChangeListener` / `removeChangeListener`) — 内容変更時の通知。現状は呼び出し側が tick タイマー等で polling
* `setColumns(n: u32)` — `'M'` ベースの幅算出を桁数で外から指定
* `setPlaceholder(text)` — 空のときに薄く表示するヒント
* Linux 用 IME バックエンドの実装 (現状は Windows + macOS のみ。Linux は `awt-c/src/ime_stub.c` で no-op)
* IME composition attribute の多段化 (現状は target 1 区間のみ。Windows IMM の CompAttr の TARGET_NOTCONVERTED / CONVERTED / INPUT 等を色分けして見せたい場合に必要)
* `Tab` / `Shift+Tab` traversal の標準対応
* 部分再描画 (キャレット点滅で全画面再描画になるのを避ける)
* パスワード入力モード (グリフを `•` で置換)

### 棚上げ中 (書記素クラスタ + 絵文字)
書記素クラスタ単位の編集と color emoji 対応は、 v1 スコープから外して将来課題に。
背景と再開条件のメモ:

* **書記素クラスタ単位の編集** — ZWJ シーケンス / 結合文字 / 肌色 modifier 等で「複数 codepoint = 1 表示単位」になるものを正しく扱いたい。Zig 標準には UAX #29 実装が無く、 既存ライブラリ [ziglyph](https://github.com/jecolon/ziglyph) も 1〜2 年メンテが止まっている。 再開条件:
  - 活発な代替 Unicode ライブラリが出る
  - もしくは UAX #29 を自前実装する判断をする (それなりに大きい)
* **絵文字 (color emoji)** — 単体では出ない。 必要な作業が 3 軸あり、 どれか欠けても完成しない:
  1. 書記素クラスタ単位の編集 (上記)
  2. emoji フォントの追加 (例: Noto Color Emoji。 ただしフォントサイズが数 MB〜数十 MB 規模)
  3. カラー描画パス — 現状の `GlyphAtlas` は R8 (alpha mask only)、 `text_program` も grayscale 前提。 COLR/CPAL (v0/v1) / sbix / CBDT/CBLC のいずれかをサポートし、 RGBA8 atlas + RGBA tinted text program に拡張する必要がある

ユーザー視点では 「絵文字を入れると `□` が出る」 だが、 これは NotoSansJP に glyph が無いだけではなく、 描画パスとフォントの 2 重制約がかかっている (どちらか片方を直しても出ない)。
今すぐ取り組まない判断は **2026-05-23**。
