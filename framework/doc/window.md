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
    overlays:     std.ArrayList(OverlayEntry), // ポップアップ等のフローティング層 (top = 最新)
    title:        [:0]u8,                      // 動的変更可能。allocator.dupeZ で所有 (C ABI 互換)
    background:   awt.Graphics.Color,          // ウィンドウのクリア色 (デフォルトはライトグレー)
    fb_w:         i32, fb_h: i32,              // framebuffer pixel (HiDPI 用)
    cursor_x:     f32, cursor_y: f32,
    paint_dirty:  bool,
    layout_dirty: bool,
    mouse_capture: ?*Component,                // ドラッグ中の capture 先 (詳細は「マウスキャプチャ」参照)
    allocator:    std.mem.Allocator,
    dirty_notify: Component.DirtyNotify,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paintWindow,           // Container.paint と挙動が違う (後述「paint dispatch」)
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    pub const OverlayEntry = struct {
        component:  *Component,                // overlay の root (position は window-local)
        owner:      *anyopaque,                // owner (Menu / PopupMenu)
        on_dismiss: *const fn (*anyopaque) void,
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
利用者がコードからウィンドウを閉じたいときに呼ぶ。
実際の解放はやはり Application のループが行う。

## メニューバーの設定
```zig
pub fn setMenuBar(self: *Window, bar: ?*Component) void;
```

ウィンドウ上部に固定する Component（典型的には `&menu_bar.component`）を登録する。
`null` を渡すと外す。
Window は **所有しない**（Frame が所有を管理する。`frame.md` 参照）。

セットすると `layout_dirty` / `paint_dirty` が立ち、次回 redraw でコンテナーが下にずれて再配置される。
bar の `parent` は内部で `null` にセットされ、Window の dirty 伝搬経路に組み込まれる。

通常は利用者が直接呼ばず `Frame.setMenuBar` 経由で呼ばれる。

## オーバーレイの登録
```zig
pub fn addOverlay(
    self: *Window,
    component: *Component,
    owner: *anyopaque,
    on_dismiss: *const fn (*anyopaque) void,
) !void;
```

popup / tooltip 等の浮動 UI を Window に登録する。
`component.parent` は内部で `null` にセットされ、dirty 伝搬は Window に接続される。
`component.position` は登録時点で**ウィンドウローカル座標**にセットしておくこと（overlay は parent を持たないので絶対座標になる）。

`owner` と `on_dismiss` は dismiss 時のコールバック用。Window が外クリック / ESC で全 overlay を dismiss する際、各 entry の `on_dismiss(owner)` が呼ばれて owner が `open=false` 等の状態を更新できる。

通常は Menu / PopupMenu の `show` メソッドから呼ばれる（`menu.md` / `popup_menu.md` 参照）。

## オーバーレイの解除
```zig
pub fn removeOverlay(self: *Window, owner: *anyopaque) void;
```

指定 `owner` の overlay を登録解除する。
`on_dismiss` は**呼ばれない**（呼び出し元が owner 自身で、自分で状態管理する前提）。
該当が無ければ no-op。

`Menu.hide()` / `PopupMenu.hide()` 内で使われる。

## 全オーバーレイの dismiss
```zig
pub fn dismissAllOverlays(self: *Window) void;
```

登録されている overlay をすべて top から解除し、各 `on_dismiss(owner)` を呼ぶ。
外クリック / ESC キー押下のときに Window 内部で呼ばれる。
利用者が直接呼ぶ機会は通常ない。

cascade した menu popup（File → Find → submenu）が一発で全部閉じる。

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

デフォルト LayoutManager は `BorderLayout`。
ツールバー / ステータスバー / サイドバー / center の典型シェルが追加設定なしで組める。
別の layout を使いたければ `window.container.setLayout(...)` で差し替える。

## 3 つの描画 / イベント層
Window は通常コンポーネントツリーの他に、特殊扱いされる 2 つのレイヤを持つ。
合わせて以下の 3 層が縦に重なる：

```
+------------------+
| menu_bar         | ← 上部固定、container の外
+------------------+
| container        | ← メインのコンポーネントツリー (BorderLayout 等で構成)
| (children...)    |
+------------------+
                    overlays (popup / tooltip) ← container と menu_bar の上に重なる
```

### menu_bar 層
Frame の `setMenuBar(MenuBar)` で取り付ける、ウィンドウ最上部の固定領域。
通常コンポーネントツリーの**外側**にあり、`Container.add` 経由ではなく Window が直接保持する。

レイアウト：
* `menu_bar.size.height` は `menu_bar.min_size.height` に固定（高さ = メニューバーの自然高）
* `menu_bar.size.width` はウィンドウ幅いっぱい
* `container` の bounds は `(0, bar_h, win_w, win_h - bar_h)` に詰められる（メニューバー分下にずれる）

描画：
* container を先に描き、menu_bar を後に重ね描き。これにより menu_bar が常に最前面（その下にある container 上端は menu_bar に隠れる）

イベント：
* `.move` は常に menu_bar に dispatch（カーソルがバー外に出たとき rollover をクリアするため）
* `.press` / `.release` は menu_bar 内側のときだけ dispatch
* menu_bar が consume すれば container へは流れない

詳細な API は `menu_bar.md` / `frame.md` 参照。

### オーバーレイ層
ポップアップメニュー / ツールチップ等の浮動 UI。
`Window.addOverlay(component, owner, on_dismiss)` で登録、`removeOverlay(owner)` で外す。
複数の overlay を同時に登録でき、登録順に下から積み上がる（top = 最新 = サブメニュー）。

特徴：
* overlay の root component の `parent` は `null`（root として扱われる）
* `position` は**ウィンドウローカル座標**（登録時に owner が指定）
* `Component.absoluteOriginInWindow` は root の position も足すので、overlay 内の子の hit-test が正しく動く（`component.md` 参照）
* 描画は container / menu_bar の**後**で、登録順（古→新）で重ねる
* イベントは登録順の**逆**（新→古）で hit-test、最初に bounds 内に当たった overlay へ dispatch

dismiss 規則：
* overlay の bounds 外で `.press` → `dismissAllOverlays` 発火（cascade した全 popup が閉じる）
* `.move` / scroll が overlay 外でも menu_bar の上ならそちらへ dispatch（ホバー切替を可能にする）
* ESC キー → 全 overlay dismiss
* overlay 内の MenuItem が action を発火 → owner（Menu / PopupMenu）の listener が `dismissAllOverlays` を呼ぶ

詳細は `menu.md` / `popup_menu.md` 参照。

### 3 層の dispatch 順（`dispatchInput`）

```
mouse_capture (drag continuation, 最優先)
  ↓ なし
overlays (top → bottom で hit-test)
  ↓ 当たらなかったら
menu_bar (内側のみ; .move は常に届く)
  ↓ consume されなかったら
container
```

overlay が open 中は menu_bar と container への .move ルートも制限される（外クリックは dismiss、ホバーは menu_bar 切替のみ）。
詳細実装は `Window.dispatchInput` 参照。

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
描画の主たる経路は `Window.redraw`。
Application のループが「`paint_dirty == true` の Window」に対して `redraw` を呼び、内部で root 用の `Graphics` を作って 3 層を順に描く（container → menu_bar → overlays。「3 つの描画 / イベント層」参照）。

Window の `vtable.paint`（`paintWindow`）は **fallback** として残してある：
* Window を通常の `Component` として扱った場合（例: 別の Container に embed したい等の例外用途）に呼ばれる
* `container.children` を再帰描画するだけ。menu_bar / overlays は描かない
* Window struct の `position` は OS 絶対座標なので、`paintAt` の `g.clip(self.getBounds())` には**通常用途では合わない**。`paintWindow` 経由のレンダリングは subwindow 的な実験用途と割り切る

通常用途では `paintAt` 経由は使わず、`redraw` を直接呼ぶ。

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

## イベント post と dispatch
Window の OS 入力コールバック（mouse button / cursor pos / scroll / key）は widget へ直接配送せず、**Application が持つ `EventQueue` に post する**。
実 dispatch はイベントループの次サイクルで `EventQueue.drain` が呼び出された時に走る。

具体的には：

1. GLFW callback → Window の `onMouseButton` 等が起動
2. `awt.Event` を組み立て、`event_queue.postEvent(ev, self, dispatchInputThunk)` で queue に積む
3. callback はそこで return
4. Application のループが `awt.waitEvents` から戻り、`event_queue.drain()` を呼ぶ
5. drain が queue 内のアイテムを順に処理し、入力アイテムなら `dispatchInputThunk(target, &ev)` → `Window.dispatchInput(&ev)` を呼ぶ
6. `dispatchInput` がマウスキャプチャ状態を加味して `container.processEvent` または capture 先の `processEvent` に流す

この設計の理由：

* `invokeLater` で投入されるタスクと入力イベントが同じ queue に並ぶので、post 順がそのまま処理順になる（順序保証）
* 外部から `event_queue.postEvent` 経由で合成入力イベントを差し込める（テスト / マクロ / IME 等）
* GLFW callback はキューに積むだけなのですぐ return する → コールバック中の重い処理で GLFW のイベント処理が滞らない

トレードオフ：OS callback から widget まで 1 ループサイクル分の latency が乗る。
60fps なら 16ms 未満で体感はほぼ無い。

詳細は `awt/doc/event_queue.md`「入力イベントの post」も参照。

## マウスキャプチャ
ドラッグ操作中にカーソルが widget の bounds から外れても、`.move` / `.release` を当該 widget に届け続けるための機構。
Window が `mouse_capture: ?*Component` を保持する。
判定は post 時ではなく **dispatch 時 (`dispatchInput` 内)** で行う。

シーケンス：

1. `.press` event が `dispatchInput` に届く → `container.processEvent` 経由で hit-test dispatch
2. dispatch 先の widget（例: Slider, Button）の `processEvent` が `ev.requestCapture(@ptrCast(self))` を呼ぶ
3. `dispatchInput` 内の press 処理終了後、`ev.capture_target` を読み取り、non-null なら `mouse_capture` に格納する
4. 以降の `.move` event は `mouse_capture` が non-null なら hit-test を経由せず capture 先の `processEvent` を直接呼ぶ
5. `.release` event も `mouse_capture` non-null なら capture 先へ直接配送、その後 `mouse_capture = null` でクリア

この仕組みにより：

* Slider のつまみをドラッグして widget 外に出ても値が追従する
* Button を押下後にドラッグで外に出て戻す挙動（Swing と同じ「ドラッグで取り消し」）が成立する
* 解放イベントが必ず press と同じ widget に届く（pressed 状態がクリーンアップされる）

awt 層は capture state を持たず、Event 型に「capture を要求するためのフィールドとメソッド」を提供するだけ（`awt/doc/event.md` 「マウスキャプチャ」参照）。
routing 自体は Window の責務。

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
