---
unsafe: true
---

# window
ウィンドウについての設計ノート。
Frame / Dialog の共通親となる抽象トップレベル。
Container を embed しており、推移的に Component の派生型でもある。

## 型定義
```zig
pub const Window = struct {
    container:    Container,                   // メインのコンポーネントツリー (Container 派生 = 推移的に Component 派生)
    awt_window:   awt.Window,
    swapchain:    awt.Swapchain,
    context:      *awt.Graphics.Context,       // Application から借用 (programs / rings / atlas を束ねたもの)
    device:       *awt.Device,
    app:          *anyopaque,                  // *Application back-pointer
    event_queue:  *awt.EventQueue,             // Application 所有の queue を借用 (post 経由 dispatch)
    menu_bar:     ?*Component,                 // 上部固定のメニューバー (Frame.setMenuBar が設定、Window は所有しない)
    overlays:     OverlayManager,              // フローティング層 (popup / ghost)。`overlay.md`
    title:        [:0]u8,                      // 動的変更可能。allocator.dupeZ で所有 (C ABI 互換)
    background:   awt.Graphics.Color,          // ウィンドウのクリア色 (デフォルトはライトグレー)
    fb_w:         i32, fb_h: i32,              // framebuffer pixel (HiDPI 用)
    cursor_x:     f32, cursor_y: f32,
    paint_dirty:  bool,
    layout_dirty: bool,
    mouse_capture: ?*Component,                // ドラッグ中の capture 先 (詳細は「マウスキャプチャ」参照)
    focus_owner:   ?*Component,                // キーボードフォーカスの現オーナー (詳細は「フォーカス」参照)
    allocator:    std.mem.Allocator,
    dirty_notify: Component.DirtyNotify,
    focus_controller: Component.FocusController,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paintWindow,           // Container.paint と挙動が違う (後述「paint dispatch」)
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    // ... メソッド
};
```

オーバーレイ管理 (`OverlayEntry` 型、登録 / 解除 / dismiss / 描画) は `OverlayManager` モジュールへ切り出した。`Window` はそれを `overlays` フィールドとして持ち、`install` で `overlays.wire(...)` し、描画 / イベント dispatch から `window.overlays` を参照するだけ。API と詳細は `overlay.md`。

## 子の追加
```zig
pub fn add(self: *Window, child: *Component) !void;
```

内部の `Container.add` への委譲。
詳細は `container.md` を参照。

## 子の追加（hint 付き）
```zig
pub fn addWithHint(
    self: *Window,
    child: *Component,
    hint: *anyopaque,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void;
```

内部の `Container.addWithHint` への委譲。

## タイトルの設定
```zig
pub fn setTitle(self: *Window, title: []const u8) !void;
```

タイトル文字列を dup し直して保持し、即座に OS のタイトルバー / タスクバーへ反映する。
位置・サイズと違って頻繁に呼ばれない想定なので、Application のイベントループ末尾 sync 経由ではなく直接 push する。

## タイトルの取得
```zig
pub fn getTitle(self: Window) []const u8;
```

## 背景色の取得
```zig
pub fn getBackground(self: Window) awt.Graphics.Color;
```

## 背景色の設定
```zig
pub fn setBackground(self: *Window, color: awt.Graphics.Color) void;
```

ウィンドウのクリア色（毎フレームの最初に塗る色）を設定する。
デフォルトはライトグレー `(0.94, 0.94, 0.94)`。
hello のような awt 直叩きでクリア色を自分で管理するアプリでは使用されない。
framework 経由の Frame / Window はこの値で `cb.clearColor` を実行する。

## 再描画の要求
```zig
pub fn repaint(self: *Window) void;
```

`paint_dirty` を true にして `awt.postEmptyEvent()` でイベントループを叩き起こす。
次回のイベントループで `redraw` が呼ばれる。

## 再描画の領域指定要求
```zig
pub fn repaintRect(self: *Window, r: Component.Rect) void;
```

v1 では `repaint` と同じく `paint_dirty` を立てるだけ (`r` は無視)。
API として将来の部分再描画 (rect 単位の dirty 蓄積) のために用意。

## 再描画の実行
```zig
pub fn redraw(self: *Window) void;
```

CommandBuffer を acquire し、ウィンドウ全体を 3 層（container → menu_bar → overlays）の順で描画して present する（詳細は「3 つの描画 / イベント層」参照）。
`paint_dirty` を false に戻す。
通常は Application のイベントループが「`paint_dirty == true` の時だけ」呼ぶ。利用者が直接呼ぶ機会は無い。

## クローズリクエストの確認
```zig
pub fn shouldClose(self: Window) bool;
```

OS から close リクエスト（X ボタン押下など）を受け取っているかを返す。
true でも Window 自身は何もしない。後片付けは Application のループが回収する。

## クローズ予約
```zig
pub fn dispose(self: *Window) void;
```

OS の close フラグを立てる。
直後の Application のループ末尾で `shouldClose()` が観測され、通常の close 回収パス (windows リストから外す → `destroy`) が走る。
利用者から「プログラムからウィンドウを閉じる」操作の入口。

## メニューバーの設定
```zig
pub fn setMenuBar(self: *Window, bar: ?*Component) !void;
```

ウィンドウ上部に固定する Component（典型的には `&menu_bar.component`）を登録する。
`null` を渡すと外す。
Window は **所有しない**（Frame が所有を管理する。`frame.md` 参照）。

セットすると `layout_dirty` / `paint_dirty` が立ち、次回 redraw でコンテナーが下にずれて再配置される。
bar の `parent` は内部で `null` にセットされ、Window の dirty 伝搬経路 (`putProperty` で DirtyNotify を埋め込む) に組み込まれる。
この `putProperty` が OOM で失敗すると error を返す (bar はセットされない)。

通常は利用者が直接呼ばず `Frame.setMenuBar` 経由で呼ばれる。

## オーバーレイ
オーバーレイの登録 / 解除 / dismiss は `OverlayManager` のメソッドで、`window.overlays.add(component, owner, on_dismiss)` / `.addPassthrough(component)` / `.remove(owner)` / `.dismissAll()` / `.dismissTop()` と呼ぶ。型・契約・入力ポリシーは `overlay.md`。`Window` 側はこれらを直接持たず、描画（`overlays.paintAll`）とイベント dispatch から参照する — 外クリック / Tab / アクセラレータ和音は `.dismissAll`、ESC は `.dismissTop`（段階クローズ）。

## フォーカスオーナーの設定
```zig
pub fn requestFocusFor(self: *Window, c: ?*Component) void;
```

`focus_owner` を `c` に切り替える。
旧オーナーには `FocusEvent{ .gained = false }`、新オーナーには `FocusEvent{ .gained = true }` を**同期的に** dispatch する（イベントキューを経由しない）。
両者は `repaint` でマークされ、フォーカスリング / キャレットの表示状態が次回描画に反映される。

`c` を `null` にするとフォーカスを解除する（テキスト入力先がない状態）。
現オーナーと等しい `c` を渡したときは no-op。

通常は利用者が直接呼ばず、widget が `Component.requestFocus()` を呼ぶことで間接的に呼ばれる。

## フォーカストラバーサル
```zig
pub fn focusNext(self: *Window) void;   // Tab
pub fn focusPrev(self: *Window) void;   // Shift+Tab
```

フォーカスを次 / 前の focusable へ移す。順序はコンテナ子の追加順の preorder DFS
(`Component.isFocusEligible` でフィルタ)、端で wrap する。移動先が ScrollPane の
視界外にあれば `scrollIntoView` で視界内へスクロールさせる。
通常は利用者が直接呼ばず、Tab / Shift+Tab の配送から呼ばれる。

BoxLayout は追加順＝視覚順なので Tab 順は常に見た目と一致する。BorderLayout は
配置が region ヒントで決まり追加順が配置に影響しないため、Tab 順を読み順にしたい
場合は add を読み順に呼ぶ (規約)。

初期フォーカス: 最初のフレーム描画時、フォーカスが無ければ先頭の focusable に
フォーカスが移る (one-shot。利用者が空クリックで解除した後に再主張はしない)。

## 既定ボタンの設定
```zig
pub fn setDefaultButton(self: *Window, btn: ?*Button) !void;
```

ウィンドウ全体の Enter を `btn.doClick()` に束縛する (root の `key_bindings` へ登録)。
フォーカス中のウィジェットが Enter を自分で消費する場合 (フォーカスされた Button 等)
はそちらが勝つ。`null` で解除。

### 事前条件
* root 登録束縛は `btn` を参照するが所有しない。ウィンドウ破棄より前に `btn` だけを
  ツリーから外す場合は、先に `setDefaultButton(null)` を呼ぶこと (怠ると dangling)。

## 利用例
利用者は通常 `Frame` 経由で Window を間接利用する（`frame.md` 参照）。
Window の API を直接叩く典型ケースは以下。

```zig
const frame = try app.frame("hello", 800, 600);
const window = &frame.window;

// 子を追加
try window.add(&label.component);

// タイトル変更
try window.setTitle("new title");

// 再描画要求（setter を経由しない直接変更後など）
window.repaint();

// プログラム的に閉じる
window.dispose();
```

## 機能要望
* 明示タブオーダー (Order 値)。実需待ち — 後付けの形は `narrative/keybinding.md`「後付け余地」
* WindowListener 相当（close 確認、minimize 通知等）
* 複数モニタ対応（モニタ選択、移動時の DPI 変化対応）
* アニメーション駆動（`requestAnimationFrame` 相当の連続再描画）
* `dirty_rect` を実描画に反映する部分再描画（現状は API のみ rect 単位で受け、実装は full redraw に倒す）
* ウィンドウが閉じられていることをイベントリスナーで検知、確認ダイアログを出したりキャンセルしたりできるように
