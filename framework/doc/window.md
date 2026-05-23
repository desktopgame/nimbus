# window
ウィンドウについての設計ノート。
Frame / Dialog の共通親となる抽象トップレベル。
Container を embed しており、推移的に Component の派生型でもある。

## 型定義
```zig
pub const Window = struct {
    container:  Container,             // Container embed = Container 派生 = 推移的に Component 派生
    awt_window: awt.Window,
    swapchain:  awt.Swapchain,
    context:    *awt.Graphics.Context, // Application から借用 (programs / rings / atlas を束ねたもの)
    app:        *Application,          // back-pointer。OS callback が Application 側の synced cache を更新するため
    dirty_rect: ?Component.Rect,       // null = clean、それ以外 = 再描画必要領域 (絶対 pt)
    title:      [:0]u8,                // 動的変更可能。allocator.dupeZ で所有 (C ABI 互換)
    background: awt.Graphics.Color,    // ウィンドウのクリア色 (デフォルトはライトグレー)
    fb_w:       i32, fb_h: i32,        // framebuffer pixel (HiDPI 用)
    allocator:  std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paintWindow,   // Container.paint と挙動が違う (後述「paint dispatch」)
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    // ... メソッド
};
```

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

タイトル文字列を dup し直して保持する。
OS への反映は次のイベントループ末尾の `syncOsState` で行う（即時には反映されない）。

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

`dirty_rect` をウィンドウ全体に拡張する。
次回のイベントループで `redraw` が呼ばれる。

## 再描画の領域指定要求
```zig
pub fn repaintRect(self: *Window, r: Component.Rect) void;
```

`dirty_rect` を引数の rect と union する。
v1 では実描画には反映されず（full redraw に倒す）、API として将来の部分再描画のために用意。

## 再描画の実行
```zig
pub fn redraw(self: *Window) void;
```

CommandBuffer を acquire し、ウィンドウ全体を描画して present する。
`dirty_rect` を null に戻す。
通常は Application のイベントループが「`dirty_rect != null` の時だけ」呼ぶ。利用者が直接呼ぶ機会は無い。

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
利用者がコードからウィンドウを閉じたいときに呼ぶ。
実際の解放はやはり Application のループが行う。

---

## 階層と依存関係
nimbus のトップレベル階層:

```
framework.Window (抽象トップレベル、Container 派生)
  ├─ framework.Frame    (独立トップレベル、タイトルバー / 最大化最小化)
  └─ framework.Dialog   (オーナー必須、モーダル / モードレス)   ← v2
```

Swing と同じく Window を抽象基底にし、Frame と Dialog を並列の派生型として持つ。
共通機能（タイトル、close 処理、resize、root container、repaint dispatch）は Window に集約する。

`awt` の `Window` / `Swapchain` / `Graphics.Context` に依存する（描画面と GPU 共有資源）。

## Container 派生として扱う
Window は `Container` を embed する。
Container は `Component` を embed しているので、推移的に「Window は Component」「Window は Container」として扱える（Swing の `Window extends Container extends Component` と同じ階層）。

これにより：
* `window.container.add(child)` で root level に子を足せる（`window.add(child)` のショートカットあり）
* `window.container.component` (= Component) として汎用 walker / paint dispatch に流せる
* LayoutManager も他の Container と同じ機構で挿せる

## awt.Window との関係（名前衝突注意）
**`awt.Window` と `framework.Window` は同名で別物**。役割は完全に違う。

| | `awt.Window` | `framework.Window` |
|---|---|---|
| 役割 | OS native ウィンドウのラッパー、描画面 (swapchain ターゲット) | UI トップレベルの抽象、Container 派生 |
| 内部に持つもの | glfw ウィンドウハンドルのみ | `awt.Window` + `awt.Swapchain` + Container embed + dirty フラグ |
| 寿命 | `framework.Window` が所有 | Application が所有 |

`framework.Window` は内部に `awt.Window` を埋め込み、UI レイヤーとして肉付けする。

## position / size のセマンティクス
**Window では `component.position` / `component.size` は OS 絶対座標で扱う**（Swing の `Window.getBounds` が screen 座標を返すのと同じ特例）。

通常 Component の position は parent-relative だが、Window は parent を持たない root なので「parent-relative」と「OS 絶対」は実用上区別不能。
なら OS 座標として使うのが素直で、ツリー走査で「子の絶対 screen 座標」を計算する時に親方向に積み上げれば自然に screen pt に到達できる。

## OS との同期（Application が責務を負う）
Window 自身は「OS と同期済みの値」を覚えない。
Application が `WindowEntry` で per-window に保持し、毎イベントループ末尾で diff → 差分があれば OS に push する。
詳細は `application.md` 参照。

ポイント：OS callback は `component.position/size` と Application 側の `synced_xxx` を**両方**更新する。
これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになる。

これにより：
* `Component.setBounds` の override 不要（通常規約のまま）
* 同一フレーム内で setBounds を複数回呼んでも自動 coalesce（最後の値だけ push）
* Window struct は sync 用フィールドで汚れない

## paint dispatch
Window の paint は他の Container と挙動が違うため、**専用 `vtable.paint`（`paintWindow`）** を持つ。

通常 `Component.paintAt` は親から渡された `g` に対して `g.translate(position)` してから `vtable.paint(self, g)` を呼ぶ。
Window では `position` が OS 絶対座標なので、これをそのまま translate に使うと描画が壊れる。

対処：Window は `paintAt` 経由で描画しない。
Application のループが `window.redraw()` を直接呼び、そこで root 用の `Graphics` を作って Container の `paint` に流す。
`position` の translate はスキップする。

`paintWindow` vtable の中身は「children を再帰描画」だけ（実質 `Container.paint` と同じ）。
`paint` を別名にしておくのは「Window は paintAt 経由で呼ばれない」という意図表明と、将来 Window 固有の描画（背景色 / 装飾）を入れる時の hook を残しておくため。

## repaint と dirty 駆動
`Component.repaint()` / `repaintRect(r)` が呼ばれると、parent を遡って Window まで上がり、`window.dirty_rect` に union で蓄積される。
これは `framework.Component` で実装する責務。

`dirty_rect` の扱いは graphics 層に伝えるシザーのヒントとして使う。
v1 では full redraw に倒すが、API としては rect 単位で受けられるようにしておく（`component.md`「repaint」参照）。

## close 処理
GLFW が close リクエストを受け取ると `awt_window.shouldClose()` が `true` になる。
Window 自体は何もしない（close ボタンを押した瞬間に dispose しない）。
Application のループが：

1. `shouldClose()` をチェック
2. true ならウィンドウを `windows` リストから外して `dispose` → `destroy`

これにより Window 側で「閉じる前に保存しますか?」のような確認ダイアログを差し挟む余地が生まれる。
WindowListener 相当（機能要望）が入った時に活きる。

## イベントループとの関係

### グローバル singleton は不要
GLFW のイベントキューはプロセス単位なので「全ウィンドウのループ」は 1 本でよく、そのループを **Application が単一管理する**。
Application がウィンドウを tracking している限り、Window 側はグローバル状態を持たない（Singleton レジストリや `var all_windows = ...` は使わない）。

### awt 側 callback とウィンドウの紐付け
GLFW callback は `glfwGetWindowUserPointer` で任意のポインタを受け取れる。
Window の init で `awt.Window.setResizeCallback` / `setRefreshCallback` に自身のポインタを user_data として登録する。
callback の中では `*Window` を取り出して、`component.position/size` と Application 側の `WindowEntry.synced_xxx` を**両方**更新する。

これで「グローバルレジストリなし」でウィンドウ個別のイベントをハンドリングできる。
Application はループの主体（waitEvents + 全ウィンドウの dirty 走査 + OS sync + close 回収）だけを担当し、イベントの dispatch 自体は GLFW + user_data 経由。

## ライフサイクル
Window は Application のファクトリ（`app.frame(...)` 等）が `Frame.init` 内で生成する。
利用者が直接 `Window.init` を呼ぶことは無い。

destroy は子（children）→ swapchain → awt_window → title バッファ の順。
swapchain が awt_window より先に破棄されないと、swapchain が破棄済みウィンドウを参照して落ちる。

---

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
* Dialog（オーナー必須、モーダル / モードレス）
* WindowListener 相当（close 確認、minimize 通知等）
* 複数モニタ対応（モニタ選択、移動時の DPI 変化対応）
* アニメーション駆動（`requestAnimationFrame` 相当の連続再描画）
* `dirty_rect` を実描画に反映する部分再描画（現状は API のみ rect 単位で受け、実装は full redraw に倒す）
