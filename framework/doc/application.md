---
unsafe: true
---

# application
Application についての設計ノート。
nimbus アプリのエントリーポイントとなる top-level オブジェクト。
アロケータ、ファクトリ、イベントループ、共有リソース、ウィンドウ追跡を一手に担う。

## 型定義
```zig
pub const Application = struct {
    allocator:    std.mem.Allocator,
    device:       awt.Device,
    context:      awt.Graphics.Context,
    default_font: awt.Font,
    event_queue:  *awt.EventQueue,
    windows:      std.ArrayList(WindowEntry),
    timers:       std.ArrayList(Timer),           // 登録中のタイマー (詳細は「タイマー」)
    next_timer_id: TimerId,                       // タイマー id 採番カウンター
    icon_cache:   [lucide.Icon.count]?awt.Image,  // ビルトインアイコン (詳細は後述)

    // 内部所有: programs / ring バッファ / glyph atlas (Graphics.Context が借用)
    // ... メソッド
};

const WindowEntry = struct {
    window:  *Window,
    outer:   *anyopaque,                                          // Frame / Dialog 等の外側ウィジェット
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,      // outer の解放関数
    dialog:  ?*Dialog = null,                                     // 非 null なら Dialog (close を destroy でなく Dialog.close に振る)
    synced_pos:  awt.Window.Point,                               // OS と最後に同期した位置 (ループ末尾で diff)
    synced_size: awt.Window.Size,                                // OS と最後に同期したサイズ
};
```

## アプリケーションの初期化
```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Application;
```

awt の初期化（GLFW）、Device の生成、Graphics.Context（programs / rings / atlas）の構築、デフォルトフォントの読み込み、EventQueue の生成までを一括で行う。
デフォルトフォントは framework に同梱された Noto Sans JP（`framework/src/noto/`、`nimbus.noto.noto_sans_jp_regular` でも参照可）を `@embedFile` で焼き込んで使う。利用者がフォントバイトを渡す必要は無い。
失敗時は途中まで確保したリソースを全部解放する（強い例外保証）。

## アプリケーションの後片付け
```zig
pub fn deinit(self: *Application) void;
```

残っている Window をすべて破棄したのち、EventQueue → default font → Graphics.Context → awt の順に解放する。
順序を変えると残った Window が context を参照して落ちる。

## イベントループの実行
```zig
pub fn run(self: *Application) !void;
```

全ウィンドウが閉じるまでイベントループを回す。
各反復で次を順に行う。

1. 次のタイマー deadline までイベントを待つ（タイマーが無ければ `awt.waitEvents()`、あれば `awt.waitEventsTimeout(...)`）。アイドル時の CPU は 0
2. due 時刻に達したタイマーを発火する（詳細は「タイマー」参照）
3. `event_queue.drain()` で別スレッドからポストされたタスクを UI スレッドで実行
4. 各 Window の `paint_dirty` または `layout_dirty` が true なら `window.redraw()` を呼ぶ
5. close フラグが立った Window を `windows` リストから外して `destroy`

OS と Window state の同期（位置 / サイズ）はループ末尾で `syncWindowGeometry` が行う。
`WindowEntry.synced_pos` / `synced_size` を model と diff し、差があるところだけ awt に push する（詳細は narrative の「OS との同期」参照）。
タイトルは頻度が低いため `Window.setTitle` 内で直接 push する。

最後のウィンドウが閉じたらループ抜け（「最後のウィンドウを閉じたら exit」セマンティクス）。

## イベントキューの取得
```zig
pub fn getEventQueue(self: *Application) *awt.EventQueue;
```

別スレッドから UI を触りたい場合の窓口。
`queue.invokeLater(...)` / `queue.invokeAndWait(...)` を呼ぶ。
詳細は後述「イベントキュー」を参照。

## フレームの生成
```zig
pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame;
```

`Frame` を allocator で確保 → `Frame.init` → `windows` リストに WindowEntry を append、までを行う。
利用者は戻り値の `*Frame` で setter / add を呼ぶだけ。

## ダイアログの生成
```zig
pub fn dialog(
    self: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
) !*Dialog;
```

`Dialog` を allocator で確保 → `Dialog.init` を呼ぶ。
`owner` は親ウィンドウ (典型的には `frame.window`)。
所有権は呼び出し側で、最後に `dialog.deinit()` + `allocator.destroy(dialog)` する必要がある (複数回の `showModal` 間で使い回せるため Application は管理しない)。
詳細は `dialog.md`。

## ラベルの生成
```zig
pub fn label(self: *Application, text: []const u8) !*Label;
```

`Label.create` をラップして default font と黒色を注入する。

## コンテナーの生成
```zig
pub fn container(self: *Application) !*Container;
```

`Container.create` をラップする。

## パネルの生成
```zig
pub fn panel(self: *Application) !*Panel;
```

`Panel.create` をラップする。
背景色と境界線はデフォルトで null（透明 / 線なし）。
利用者が `panel.setBackground(...)` / `panel.setBorder(...)` で設定する。

## フィラーの生成
```zig
pub fn filler(self: *Application) !*Panel;
```

`panel()` をラップし、`growX = 1` / `growY = 1` をあらかじめ設定した「余白を埋める空 Panel」を返す。
BoxLayout の主軸方向に余白を伸縮させたいときの定型ショートカット。詳細は `filler.md`。

## ボタンの生成
```zig
pub fn button(self: *Application, text: []const u8) !*Button;
```

`Button.create` をラップして default font と黒色を注入する。
ButtonModel は内部生成される（`owns_model = true`）。
利用者が共有 Model を使いたい場合は `Button.createWithModel` を直接呼ぶ。

## 選択系ウィジェットの生成
```zig
pub fn checkBox    (self: *Application, text: []const u8) !*CheckBox;
pub fn radioButton (self: *Application, text: []const u8) !*RadioButton;
pub fn comboBox    (self: *Application, items: []const []const u8) !*ComboBox;
pub fn buttonGroup (self: *Application) !*ButtonGroup;
```

それぞれ対応する widget の `create` をラップする。
`checkBox` / `radioButton` / `comboBox` には default font (`pixel_size = 14`) と黒色を注入する。
`buttonGroup` はラジオボタンの相互排他選択を束ねるためのコンテナで、利用者所有。

`comboBox` の `items` は呼び出し中だけ借用され、内部で copy される。
共有モデルを使いたい場合は各 widget の `createWithModel` を直接呼ぶ。

## スライダーの生成
```zig
pub fn slider(
    self: *Application,
    orientation: Slider.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider;
```

`Slider.create` をラップする。
BoundedRangeModel は内部生成される（`owns_model = true`）。
共有 Model 版は `Slider.createWithModel` を直接呼ぶ。

## スクロールバーの生成
```zig
pub fn scrollBar(
    self: *Application,
    orientation: ScrollBar.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*ScrollBar;
```

`ScrollBar.create` をラップする。
通常は `scrollPane()` 経由で間接的に使うが、独立した範囲入力 UI として直接使うこともできる。
共有 Model 版は `ScrollBar.createWithModel` を直接呼ぶ。

## スクロールペインの生成
```zig
pub fn scrollPane(self: *Application, view: *Component) !*ScrollPane;
```

`view` をスクロール可能な領域でラップした `ScrollPane` を返す。
`view` の所有権はペインへ移譲される (利用者は ScrollPane の deinit に任せる)。
詳細は `scrollpane.md`。

## リストの生成
```zig
pub fn list           (self: *Application, factory: List.CellFactory) !*List;
pub fn listWithModel  (self: *Application, model: *List.ListModel, factory: List.CellFactory) !*List;
```

縦方向 single-selection の `List` を返す。
`factory` は可視範囲のセル実体を生成 / 再利用するためのコールバック (List 生存期間中は呼び出し側で生かしておく)。
`list` は空の `ListModel` を List 自身が所有して生成、`listWithModel` は呼び出し側が用意したモデル (典型的には共有モデル) を借用する。
詳細は `list.md`。

## ビルトインアイコンの取得
```zig
pub fn icon(self: *Application, id: lucide.Icon) !awt.Image;
```

`nimbus.lucide.Icon` で定義されたビルトインアイコン（PNG 化済み、64×64）を、デコード済みの GPU `awt.Image` として返す。
初回呼び出し時に PNG をデコードして GPU テクスチャにアップロードし、内部キャッシュに格納する。
2 回目以降の同じ `id` に対する呼び出しは、キャッシュ済みの `awt.Image` をそのまま返す。

返り値は `Application` が所有する。利用者は `deinit` を呼んではならない。
寿命は `Application` と同じで、`app.deinit()` 時にキャッシュごとまとめて解放される。

利用者独自の PNG / JPEG を使いたい場合は `app.icon` ではなく `awt.Image.fromMemory` を直接呼ぶ。
こちらは利用者が `deinit` を呼んで寿命を管理する。

## ツールバーの生成
```zig
pub fn toolBar(self: *Application) !*Panel;
```

`Panel` を内部で生成し、ツールバー向けにプリセットを適用して返す：

* 背景色: 薄グレー（メニューバーと揃える）
* レイアウト: `BoxLayout.horizontal()`
* 高さ: 32px 固定（`min_size.height` / `max_size.height` 共に 32）

返り値は普通の `*Panel` なので、`tb.container.add(&btn.component)` で子ボタンを追加して、`BorderLayout.add(window.container, .north, &tb.container.component)` で Frame 上部（メニューバーがあればその下）に取り付ける。
専用型 `ToolBar` は作らない（Panel + BoxLayout のレシピに名前を付けただけ）。

## メニュー系の生成
```zig
pub fn menu             (self: *Application, text: []const u8) !*Menu;
pub fn menuItem         (self: *Application, text: []const u8) !*MenuItem;
pub fn checkBoxMenuItem (self: *Application, text: []const u8) !*CheckBoxMenuItem;
pub fn menuBar          (self: *Application) !*MenuBar;
pub fn popupMenu        (self: *Application) !*PopupMenu;
pub fn menuSeparator    (self: *Application) !*MenuSeparator;
```

各 widget の `create` をラップする。
`menu` / `menuItem` / `checkBoxMenuItem` / `menuBar` は default font (`pixel_size = 14`) と濃いグレー (`rgb(0.1, 0.1, 0.1)`) を注入する。
`popupMenu` / `menuSeparator` は font / color を取らないので素通しのラッパー。

専用フォント・色を使いたい場合は各 widget の `create` / `createWithModel` を直接呼ぶ。

利用例:
```zig
const bar = try app.menuBar();
const file = try app.menu("File");
const open = try app.menuItem("Open");
try open.getModel().addActionListener(Ctx, onOpen, &ctx);
try file.add(&open.component);
try file.addSeparator();
try file.add(&(try app.menuItem("Quit")).component);
try bar.add(file);
try frame.setMenuBar(bar);
```

## テキストフィールドの生成
```zig
pub fn textField(self: *Application, initial_text: []const u8) !*TextField;
```

`TextField.create` をラップして default font (14px) と黒色を注入する。
背景はデフォルトで白。
`initial_text` は内部 UTF-8 バッファにコピーされる (呼び出し後すぐ free しても安全)。

詳細は `textfield.md` を参照。

## テキストエリアの生成
```zig
pub fn textArea(self: *Application, initial_text: []const u8) !*TextArea;
```

`TextArea.create` をラップして default font (14px) と黒色を注入する。
複数行テキスト入力 (折り返し / 改行サポート)。
`initial_text` は内部バッファにコピーされる。
詳細は `textarea.md` を参照。

## ワンショットタイマーの登録
```zig
pub fn setTimeout(self: *Application, ms: u32, cb: TimerCallback, user_data: *anyopaque) !TimerId;
```

`ms` ミリ秒経過後に `cb(user_data)` を **UI スレッドで一度だけ**呼ぶよう登録する。
返り値の `TimerId` は `clearTimer` でキャンセルに使える（発火前に widget が destroy される場合など）。
発火後は内部リストから自動的に外れる。
内部で `awt.postEmptyEvent()` を呼んで run ループを起こすので、別スレッドから安全には呼べない（タイマーは UI スレッドで呼び出す前提）。

## 繰り返しタイマーの登録
```zig
pub fn setInterval(self: *Application, ms: u32, cb: TimerCallback, user_data: *anyopaque) !TimerId;
```

`ms` ミリ秒ごとに `cb(user_data)` を繰り返し UI スレッドで呼ぶよう登録する。
最初の発火は登録から `ms` 経過後。停止は `clearTimer` で行う。
ループが詰まって複数 tick 分遅延した場合、tick を取り戻すような catch-up は行わず**まとめて 1 回**だけ発火する（次回 due は `now + period`）。

## タイマーの解除
```zig
pub fn clearTimer(self: *Application, id: TimerId) void;
```

指定 id のタイマーを内部リストから外す。
既に発火・解除済み、または未知の id は no-op。

## 利用例
基本形。

```zig
var app = try nimbus.Application.init(init.gpa, init.io);
defer app.deinit();

const frame = try app.frame("hello nimbus", 800, 600);
const label = try app.label("こんにちは!");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 40 });
try frame.window.add(&label.component);

try app.run();   // event loop。全ウィンドウ閉じで抜ける
```

別スレッドから UI に値を反映する例。

```zig
// UI スレッド
const queue = app.getEventQueue();

// 別スレッドで時間のかかる処理
const worker_thread = try std.Thread.spawn(.{}, struct {
    fn run(q: *awt.EventQueue, lbl: *Label) !void {
        const result = doExpensiveWork();
        try q.invokeLater(updateLabelTask, .{ .label = lbl, .text = result });
    }
}.run, .{ queue, label });
defer worker_thread.join();

try app.run();
```

## 機能要望
* 「最後のウィンドウを閉じても常駐したい」ケース向けの hook（現状は全ウィンドウ閉でループ終了）
* `requestAnimationFrame` 相当 — vsync 同期での連続再描画 (現状のタイマーは ms オーダーの精度)
* min-heap でタイマーを管理して `earliestDueIn` を O(1) に（現状は O(n)、数十〜数百個までは問題ない）
