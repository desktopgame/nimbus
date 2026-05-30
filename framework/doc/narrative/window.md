---
unsafe: true
---

# window
Window の階層・3 層構造・dispatch・フォーカス・awt.Window との関係・座標系・OS 同期・paint/repaint・close/event post・マウスキャプチャ・イベントループ。

## 階層と依存関係
nimbus のトップレベル階層:

```
framework.Window (抽象トップレベル、Container 派生)
  ├─ framework.Frame    (独立トップレベル、タイトルバー / 最大化最小化)
  └─ framework.Dialog   (オーナー必須、モーダル / モードレス。`dialog.md`)
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
`window.overlays.add(component, owner, on_dismiss)` で登録、`window.overlays.remove(owner)` で外す（`overlay.md`）。
複数の overlay を同時に登録でき、登録順に下から積み上がる（top = 最新 = サブメニュー）。

特徴：
* overlay の root component の `parent` は `null`（root として扱われる）
* `position` は**ウィンドウローカル座標**（登録時に owner が指定）
* `Component.absoluteOriginInWindow` は root の position も足すので、overlay 内の子の hit-test が正しく動く（`component.md` 参照）
* 描画は container / menu_bar の**後**で、登録順（古→新）で重ねる
* イベントは登録順の**逆**（新→古）で hit-test、最初に bounds 内に当たった overlay へ dispatch

dismiss 規則：
* overlay の bounds 外で `.press` → `overlays.dismissAll` 発火（cascade した全 popup が閉じる）
* `.move` / scroll が overlay 外でも menu_bar の上ならそちらへ dispatch（ホバー切替を可能にする）
* ESC キー → 全 overlay dismiss
* overlay 内の MenuItem が action を発火 → owner（Menu / PopupMenu）の listener が `overlays.dismissAll` を呼ぶ

詳細は `menu.md` / `popup_menu.md` 参照。

オーバーレイ機構の全体（型・API・入力ポリシー modal_popup / passthrough・所有権）は `overlay.md` にまとめてある。 上記はそのうち Window の dispatch に関わる部分。 ドラッグゴーストやツールチップのような非インタラクティブ浮遊物を同じスタックに乗せる `passthrough` ポリシーは拡張予定（`overlay.md`「実装状況」）。

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

## フォーカス
キーボードフォーカスは Window が `focus_owner: ?*Component` で 1 個保持する。
non-null のときキー入力 (`.key` / `.char`) はこのコンポーネントに**直接** dispatch され、container や menu_bar の fan-out は経由しない。
null のとき `.key` は menu_bar → container の従来経路、`.char` は drop（テキスト入力先がないため）。

### フォーカスの取得
* マウス左クリック時、container 配下に `focusable == true` の widget が当たれば自動で `requestFocusFor(widget)` が呼ばれる
* widget が能動的に `Component.requestFocus()` を呼ぶ (例: モーダル表示後の初期フォーカス指定)
* どちらの経路でも `requestFocusFor` を経由するので FocusEvent と repaint は等しく発火する

### フォーカスの喪失
* 別の widget をクリックすると自動で focus が移る (前述)
* container の何もない領域 / Window 外をクリックすると `requestFocusFor(null)` で解除される
* widget 側で能動的に `c.requestFocus()` (= 別 widget の取得) を呼ぶケースもある

menu_bar / overlay 上の左クリックではフォーカスは奪われない（メニュー操作はテキスト入力を中断しない）。

### FocusController プロパティ
Component から Window への直接依存を避けるため、Window は install 時に各ルートコンポーネント (container.component、menu_bar、overlay) に `FocusController` プロパティを put しておく。
`Component.requestFocus` は親チェーンを遡ってルートで `FocusController` を見つけ、コールバック経由で `Window.requestFocusFor` を呼ぶ。
DirtyNotify プロパティと同じ設計パターン。

### v1 の制限
* Tab / Shift+Tab によるフォーカス遷移は未実装 (機能要望)
* フォーカスが付いたウィジェットが destroy される際、Window 側で自動的に `focus_owner = null` にする保護は v1 では持たない。各 widget の `uninstall` で「自分が focus_owner なら解除」を行う規約
* マウスドラッグ中 (mouse_capture が non-null) の focus 遷移は capture を解除しない (drag は drag、focus は focus と独立)

## awt.Window との関係（名前衝突注意）
**`awt.Window` と `framework.Window` は同名で別物**。役割は完全に違う。

| | `awt.Window` | `framework.Window` |
|---|---|---|
| 役割 | OS native ウィンドウのラッパー、描画面 (swapchain ターゲット) | UI トップレベルの抽象、Container 派生 |
| 内部に持つもの | glfw ウィンドウハンドルのみ | `awt.Window` + `awt.Swapchain` + Container embed + dirty フラグ |
| 寿命 | `framework.Window` が所有 | Application が所有 |

`framework.Window` は内部に `awt.Window` を埋め込み、UI レイヤーとして肉付けする。

## position / size のセマンティクス
2 つの座標系を**別インターフェイスに分離**する。混ぜない。

* **コンポーネント座標**（`component.position` / `component.size`、`setBounds` / `getBounds`）: ウィンドウのクライアント矩形を基準とするローカル座標。原点は `(0, 0)`、menu_bar があればその下（コンテンツ用 root の `container.component.position` が `(0, bar_h)`）。これは Window に限らず全コンポーネントで一貫する。
* **ウィンドウの screen ジオメトリ**（`win_pos` / `win_size`、`Window.setPos` / `setSize` / `getPos` / `getSize`）: モニタ内でのウィンドウの位置とサイズ。`framework.Window` 専用フィールドで持つ。

Swing は `Window.getX/getY` が screen 座標を返す（component 座標に screen 座標を相乗りさせる）特例を持つが、nimbus はそれを採らない。
理由: コンテンツ用 root の `container.component.position` は menu_bar 分のローカルオフセット（`redraw` で `{ .x = 0, .y = bar_h }`）として使われ、`paintAt` の clip 平行移動 (`Window.redraw`) と `absoluteOriginInWindow` のヒットテスト (`Component`) が「root の position はローカル」前提で読む。screen 座標を相乗りさせると両方壊れる。
そこで screen ジオメトリは独立フィールドに分離し、コンポーネント座標は常にクライアントローカルに保つ。

## OS との同期（Application が責務を負う）
`framework.Window` が希望値 (`win_pos` / `win_size`) を持ち、Application が `WindowEntry` で「OS と同期済みの値」(`synced_pos` / `synced_size`) を per-window に保持する。
毎イベントループ末尾 (`syncWindowGeometry`) で希望値と synced を diff → 差分があれば OS に push する。
同期は**双方向**。詳細は `application.md`「OS との同期」参照。

ポイント：OS のコールバックは `win_*` と Application 側の `synced_*` を**両方**更新する（`noteOsGeometry` 経由）。

* 移動: `onWindowPos` が `win_pos` を更新
* リサイズ: `onResize` が `win_size` を更新

これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになり、ライブな移動 / リサイズと喧嘩する。

これにより：
* `Component.setBounds` の override 不要（通常規約のまま）
* 同一ループ内で `setPos` / `setSize` を複数回呼んでも自動 coalesce（最後の値だけ push）
* OS ジオメトリの sync 用フィールドは `win_*` / `synced_*` に局所化される

## paint dispatch
描画の主たる経路は `Window.redraw`。
Application のループが「`paint_dirty == true` の Window」に対して `redraw` を呼び、内部で root 用の `Graphics` を作って 3 層を順に描く（container → menu_bar → overlays。「3 つの描画 / イベント層」参照）。

Window の `vtable.paint`（`paintWindow`）は **fallback** として残してある：
* Window を通常の `Component` として扱った場合（例: 別の Container に embed したい等の例外用途）に呼ばれる
* `container.children` を再帰描画するだけ。menu_bar / overlays は描かない
* Window struct の `position` は OS 絶対座標なので、`paintAt` の `g.clip(self.getBounds())` には**通常用途では合わない**。`paintWindow` 経由のレンダリングは subwindow 的な実験用途と割り切る

通常用途では `paintAt` 経由は使わず、`redraw` を直接呼ぶ。

## repaint と dirty 駆動
`Component.repaint()` / `repaintRect(r)` が呼ばれると、parent を遡って Window まで上がり、`window.paint_dirty = true` がセットされる。
これは `Component.markDirty` → `DirtyNotify.paint` 経由で `Window.notifyPaint` を叩く配線で実装している (`framework/src/Window.zig:314-318`)。

v1 では「rect 単位の dirty 蓄積」は行わず、`paint_dirty` の bool 1 個でフル再描画する。
`Component.repaintRect(r)` は API として用意してあるが、`r` は無視されて `repaint` と等価になる (`framework/src/Component.zig:212-215`、`framework/src/Window.zig:174-177`)。
将来 rect 単位で受けて部分再描画に倒す余地のため、API シグネチャだけ rect 引数を保持してある（機能要望）。

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
