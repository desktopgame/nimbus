---
unsafe: true
---

# popup_window
枠なしのトップレベルポップアップウィンドウを扱う内部基盤プリミティブ。
これは利用者向けウィジェットではなく、`ComboBox` のドロップダウンや `Menu` のメニュー本体を実体のある子ウィンドウとして出すための土台である。
通常は `Application.popupWindow` / `popupWindowWithOptions` 経由で `ComboBox` / `Menu` が使い、利用者が直接生成することはほぼない。

## 型定義
```zig
pub const LocalRect = struct {
    x:      f32,
    y:      f32,
    width:  f32,
    height: f32,
};

pub const Options = struct {
    no_activate: bool = false,   // 表示時にフォーカスを奪わない (メニュー向け)
};

pub const PopupWindow = struct {
    window:        Window,       // ポップアップ本体のスワップチェイン付き Window
    app:           *Application,
    owner:         *Window,      // 位置決めの基準になる親 Window (所有はしない)
    shown:         bool,
    allocator:     std.mem.Allocator,
    dismiss_ctx:   ?*anyopaque,  // onDismiss で登録するコールバックの引数
    dismiss_cb:    ?*const fn (*anyopaque) void,
    focus_on_show: bool,         // 表示時にフォーカスを取るか (no_activate の裏返し)
};
```

`window` は枠なし・フローティング・タスクバー非表示のトップレベルウィンドウとして作られる。`no_activate` のときはフォーカスを奪わない。
`owner` は位置決めの基準に使うだけで、寿命は所有しない (親を借用する)。

## 関数定義

### 生成
```zig
pub fn init(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !PopupWindow;

pub fn initWithOptions(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
    options: Options,
) !PopupWindow;
```

枠なし Window を作り、非表示の状態の `PopupWindow` を値で返す。`init` は既定 `Options` で `initWithOptions` を呼ぶ。
通常はこれらを直接呼ばず、`Application.popupWindow(owner, title, w, h)` / `popupWindowWithOptions(...)` を使う。
ファクトリは `PopupWindow` をヒープに確保して `*PopupWindow` を返し、`device` / `context` を `Application` のものから埋める。

### 破棄
```zig
pub fn deinit(self: *PopupWindow) void;
pub fn destroy(self: *PopupWindow) void;
```

`deinit` は表示中なら先に `dismiss` してから内部 Window を解放する (値で持っている場合向け)。
`destroy` は `deinit` に加えて `self` 自身を `allocator` で free する (ファクトリが返したヒープインスタンス向け)。

### 表示
```zig
pub fn showAtLocal(self: *PopupWindow, anchor: LocalRect, popup_size: awt.Window.Size) !void;
pub fn showAtScreen(self: *PopupWindow, rect: awt.Window.Rect, popup_size_logical: awt.Window.Size) !void;
```

`showAtLocal` は `owner` のローカル座標で与えた `anchor` (アンカー矩形) を基準に `popup_size` のポップアップを出す。
アンカーの下、収まらなければ上へ、それも無理なら作業領域内へ配置する。
`showAtScreen` はスクリーン座標の `rect` にそのまま出す (位置は呼び出し側が決める)。
どちらも Escape バインドと focus-lost フックを仕掛け、未所有ウィンドウとして `Application` に登録してから可視にする。すでに表示中なら何もしない。

#### 事前条件
* `showAtLocal` は `owner` に OS ウィンドウがあること。無ければ `error.OwnerHasNoOsWindow` を返す。

### 消去のフックと実行
```zig
pub fn onDismiss(self: *PopupWindow, ctx: *anyopaque, cb: *const fn (*anyopaque) void) void;
pub fn dismiss(self: *PopupWindow) void;
pub fn dismissFromSelection(self: *PopupWindow) void;
pub fn dismissFromFocusLoss(self: *PopupWindow) void;
pub fn dismissFromEscape(self: *PopupWindow) void;
```

`onDismiss` は消去時に呼ぶコールバックを 1 つ登録する。
`dismiss` はポップアップを非表示にし、`Application` の登録を外し、登録済みなら `dismiss_cb` を呼ぶ。表示中でなければ何もしない。
`dismissFromSelection` / `dismissFromFocusLoss` / `dismissFromEscape` は `dismiss` の意味付き別名である。
呼び出し文脈 (選択確定 / フォーカス喪失 / Escape) を読みやすくするためのもので、フォーカス喪失と Escape は内部で自動的に配線される。

### 表示状態の取得
```zig
pub fn isShown(self: PopupWindow) bool;
```

現在ポップアップが表示中かを返す。

### 座標計算ヘルパ
```zig
pub fn decidePopupRect(anchor: awt.Window.Rect, popup_size: awt.Window.Size, work_area: awt.Window.Rect) awt.Window.Rect;
pub fn ownerLocalPopupRect(
    owner_pos: awt.Window.Point,
    local_anchor: LocalRect,
    popup_size: awt.Window.Size,
    scale: f32,
    work_area: awt.Window.Rect,
) awt.Window.Rect;
pub fn ownerLocalRectToScreen(owner_pos: awt.Window.Point, local: LocalRect, scale: f32) awt.Window.Rect;
pub fn scaleSizeToScreen(size: awt.Window.Size, scale: f32) awt.Window.Size;
```

いずれもウィンドウを開かずに位置を計算できる純関数。
`decidePopupRect` は「アンカーの下に収まればその下、収まらなければ上へフリップ、どちらも無理なら作業領域内へクランプ」で最終矩形を返す。
`ownerLocalRectToScreen` は `owner` ローカル矩形を content scale を掛けてスクリーン座標へ、`scaleSizeToScreen` はサイズをスケール変換する。
`ownerLocalPopupRect` はそれらを合成し、`showAtLocal` が内部で使う「ローカルアンカー → スクリーン矩形」の一括計算を行う。

---

## 利用例
`ComboBox` がドロップダウンを出す骨組み (`ensurePopupWindow` 相当)。生成はファクトリ、位置決めは `showAtLocal`。

```zig
const popup = try app.popupWindow(owner, "ComboBox", 1, 1);
errdefer popup.destroy();
popup.onDismiss(@ptrCast(self), onPopupDismiss);
try nimbus.BorderLayout.add(&popup.window.container, .center, &self.popup_root);

// アンカー = コンボボックス本体の矩形 (owner ローカル)。その下 / 上に popup_size で出す。
try popup.showAtLocal(
    .{ .x = origin.x, .y = origin.y, .width = self.component.size.width, .height = self.component.size.height },
    .{ .width = popup_w, .height = popup_h },
);
```

## 機能要望
* `ComboBox` / `Menu` 以外の呼び出し側の整理 (現状の実利用者はこの 2 つ)。
* アニメーション付きの表示 / 消去 (現状は即時に可視 / 非可視を切り替える)。
