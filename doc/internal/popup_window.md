# PopupWindow (OS レベル子ウィンドウ popup) 設計 spec — Phase 1

メニュー / コンボの popup を **装飾なし（borderless）の OS レベル子ウィンドウ**で出せるようにするための設計 spec。
現状の popup は in-window overlay（`OverlayManager` 経由）でウィンドウ内にクランプされ、ウィンドウ端で
はみ出せず正しく表示できない。これを解く第一歩を切る。

**Phase 1 のスコープ（このドキュメントが扱う範囲）:**

- **(1)** 汎用 borderless `PopupWindow` プリミティブの導入（tooltip 等への転用も視野に入れた素のプリミティブ）。
- **(2)** `ComboBox` のドロップダウンをそれに載せ替え（FileChooser 下部コンボのはみ出しを解消）。

**Phase 1 のスコープ外（Phase 2 以降）:** `Menu.show` / `PopupMenu` / サブメニュー / hover-switch /
親フォーカス維持 / tooltip 実装。メニューは今回触らず in-window overlay のまま（§6）。

実装はしない（コードは書かない＝Codex 担当）。`border_model.md` / `cursor_shape.md` / `menu_display.md` の流儀に倣い
**「確定」と「未決」を分ける**。load-bearing な主張には実ファイルの行番号を引用する。`framework/src` は触らない。

関連:
`{REPO_ROOT}/framework/src/Dialog.zig`（2 つ目の OS 窓の雛形・寿命 / 配置 / teardown の作法）、
`{REPO_ROOT}/framework/src/Application.zig`（`windows` リスト・`tickOnce` の全窓描画・`registerDialog` / `unregisterWindow`）、
`{REPO_ROOT}/framework/src/Window.zig`（インスタンス型 Window・`dispatchInput` / `focus_owner` / `overlays`）、
`{REPO_ROOT}/framework/src/ComboBox.zig`（`show` / `hide` / `popup_root` / `popupProcessEvent`）、
`{REPO_ROOT}/framework/src/OverlayManager.zig`（既存の in-window overlay 機構）、
`{REPO_ROOT}/framework/src/FileChooser.zig`（`filter_combo` ＝ はみ出しの実害箇所）、
`{REPO_ROOT}/awt/src/Window.zig`（awt Window ラッパ・`setVisible` / `setFloating` / `monitorWorkarea`）、
`{REPO_ROOT}/awt-c/src/glfw_shim.c`（`nmCreateWindow` の窓生成ヒント・`nm_internal_get_hwnd`）、
`{REPO_ROOT}/awt-c/src/internal.h`（公開 C API 宣言）、
`{REPO_ROOT}/framework/doc/overlay.md` / `dialog.md` / `combobox.md`。

---

## 0. 背景・確定方針（pm が Plan 調査で実コードに当てて確認済み・再調査不要）

以下は実コードで裏取り済み。本 spec はこれに沿って具体化するだけで、選択肢の再検討はしない。

1. **複数 OS 窓は既に動く。** `Application.windows`（`Application.zig:89`）は `WindowEntry` のリストで、
   `tickOnce`（`Application.zig:289`）が全窓を走査し dirty な窓を `redraw` する（`Application.zig:296-300`）。
   `Dialog` が既に 2 つ目の OS 窓として動いており（`Dialog.zig`）、**`PopupWindow` の雛形になる**。
2. **描画は device 共有・swapchain 窓ごとが既存設計。** `nmCreateDevice` は窓を取らない
   （`{REPO_ROOT}/awt-c/src/dx12_device.c:251` `nmDevice* nmCreateDevice(void)`）。`nmCreateSwapchain(device, window)`
   が窓ごとに作られる（`{REPO_ROOT}/awt-c/src/dx12_swapchain.c:105`）。awt 側も `Device`（窓非依存）/
   `Swapchain.init(device, window)`（`{REPO_ROOT}/awt/src/Swapchain.zig:13`）。
   **2 枚目の窓に描くのは swapchain を 1 個増やすだけで、レンダラ改修は不要。**
3. **framework は単一 Window 前提でない。** `Window` はインスタンス型で、各窓が自分の
   `dispatchInput`（`Window.zig:672`）/ `focus_owner`（`Window.zig:94`）/ `overlays`（`Window.zig:54`）/
   redraw（`Window.zig:382`）を持つ。
4. **座標変換 API は既存。** `nmGetWindowPos` / `nmSetWindowPos`（`glfw_shim.c:281,285`）・
   `monitorWorkarea`（`glfw_shim.c:293`）・`contentScale`（awt `Window.contentScale` ＝ `{REPO_ROOT}/awt/src/Window.zig:46`）。
   窓ローカル→スクリーン = `window.pos + local`。HiDPI / マルチモニタの作法は `Dialog.centerOnOwnerMonitor`
   （`Dialog.zig:198`）に倣う。
5. **窓生成ヒントは現状固定。** `nmCreateWindow`（`glfw_shim.c:154-180`）は
   `GLFW_CLIENT_API` / `GLFW_SCALE_TO_MONITOR` のみセット（`glfw_shim.c:156-160`）。
   `DECORATED=false` / `FOCUS_ON_SHOW` / `FLOATING` を受けられる形に拡張が要る。
   **window-focus コールバック（`glfwSetWindowFocusCallback`）は未配線**（`Window.zig:625-635` の callback 配線群に不在）
   ＝ dismiss 用に新規 1 本要る。

---

## 1. 確定: 縦スライスの全体像

最小縦スライスを **awt-c → awt → framework(PopupWindow) → ComboBox** の順で積む。各層の責務:

- **awt-c**: borderless / no-activate / floating な窓を作る経路と、window-focus コールバック 1 本（dismiss 用）。
  glfw 型を Zig へ漏らさない既存方針を守る。
- **awt**: `awt.Window` に borderless 生成オプションと focus コールバックの passthrough を足す。
- **framework**: 新 `PopupWindow`（`Dialog` を雛形）。装飾なし・スクリーン座標で配置・modal ループなし・
  `Application.windows` 登録で既存 `tickOnce` が自動描画・focus-loss と内部選択で dismiss。
- **ComboBox**: `show()` の利用者 API は温存し、内部 backend を overlay から `PopupWindow` へ差し替え。

§2〜§5 が各層の確定 / 未決、§6 がスコープ外、§7 がテスト規律、§8 が段割り。

---

## 2. 確定: awt-c — borderless 窓と focus コールバック

### 2.1 確定: borderless / no-activate / floating な窓を作る経路

現状 `nmCreateWindow(title, width, height)`（`internal.h:37`・`glfw_shim.c:154`）は装飾付き・通常窓固定。
popup 窓は **装飾なし・タスクバー非表示・フォーカスを奪わない**で生成したい。

**確定: フラグ列挙を取る別経路 `nmCreateWindowEx` を足す**（既存 `nmCreateWindow` は薄いラッパとして残す）。

理由: `nmCreateWindow` のシグネチャ（`internal.h:37`）は既に awt `Window.init`（`{REPO_ROOT}/awt/src/Window.zig:11-14`）と
`Dialog` / `Frame` の全生成経路が依存している。第 4 引数を生やす破壊的変更より、`Ex` を足して
`nmCreateWindow` を `nmCreateWindowEx(title, w, h, 0)` に畳むほうが既存呼び出しを動かさずに済む。

```c
/* Window creation flags. Combine with bitwise OR. 0 == a normal decorated
 * window (what nmCreateWindow makes). */
typedef enum nmWindowFlags {
    nmWindowFlagBorderless = 1 << 0, /* GLFW_DECORATED = false */
    nmWindowFlagNoActivate = 1 << 1, /* GLFW_FOCUS_ON_SHOW = false */
    nmWindowFlagFloating   = 1 << 2, /* GLFW_FLOATING = true (always-on-top) */
    nmWindowFlagNoTaskbar  = 1 << 3, /* exclude from taskbar (Win32 WS_EX_TOOLWINDOW) */
} nmWindowFlags;

nmWindow* nmCreateWindowEx(const char* title, int width, int height, int flags);
```

glfw ヒントへの対応（`glfwCreateWindow` 前に `glfwWindowHint` で積む・`glfw_shim.c:156-160` の隣）:

- `nmWindowFlagBorderless` → `glfwWindowHint(GLFW_DECORATED, GLFW_FALSE)`。
- `nmWindowFlagNoActivate` → `glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE)`。
- `nmWindowFlagFloating` → `glfwWindowHint(GLFW_FLOATING, GLFW_TRUE)`。
  （実行時トグルは既存 `nmSetWindowFloating` ＝ `glfw_shim.c:244` があるので、生成時に積むか
  生成後に呼ぶかは実装裁量。生成時ヒントのほうが初回表示で確実。）
- 既存の `GLFW_CLIENT_API = GLFW_NO_API` / `GLFW_SCALE_TO_MONITOR = GLFW_TRUE`（`glfw_shim.c:156-160`）は
  **flags に関わらず常に積む**（DX12 描画先・HiDPI は popup 窓でも必要）。

### 2.2 確定: Win32 の no-activate / taskbar 除外は `nm_internal_get_hwnd` 経由で ex-style を足す

glfw ヒントだけでは Win32 のタスクバー除外（`WS_EX_TOOLWINDOW`）と「クリックでアクティブ化しない」
（`WS_EX_NOACTIVATE`）を完全に表現できない。**生成直後に HWND を取って ex-style を OR する**。

- HWND 取得は既存の `nm_internal_get_hwnd`（`glfw_shim.c:458` ＝ `glfwGetWin32Window` を返す。
  `dx12_swapchain.c:115` で swapchain も同じ経路で HWND を得ている）を再利用する。
- `nmRequestWindowAttention`（`glfw_shim.c:220-242`）が既に `#ifdef _WIN32` で `nm_internal_get_hwnd(self)` を
  使い Win32 専用処理（`FlashWindowEx`）を足している前例があるので、**同じ `#ifdef _WIN32` ブロックで
  `GetWindowLongPtr(hwnd, GWL_EXSTYLE)` → `| WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` → `SetWindowLongPtr`** を行う。
- 置き場所は `nmCreateWindowEx` 内（flags に該当ビットが立っているときだけ）。macOS / Linux はこの ex-style 適用を
  no-op にし、glfw ヒント側（borderless / floating）で表現する（§2.5 未決）。

**却下案: glfw ヒントだけで済ませる。** GLFW には `GLFW_FOCUS_ON_SHOW` はあるが、Win32 の
`WS_EX_NOACTIVATE`（フォーカスを物理的に奪わない）に正確対応するヒントは無い。popup は「親のフォーカスを
保ったまま開く」のが本質（特に Phase 2 のメニュー / tooltip）なので、ex-style 適用は load-bearing。
**ただし Phase 1 の ComboBox は focus を取ってよい**（§5.3）ので、`WS_EX_NOACTIVATE` は
Phase 1 では必須ではなく、プリミティブとして正しく持たせるための先行整備。

### 2.3 確定: window-focus コールバック 1 本（dismiss 用）

`glfwSetWindowFocusCallback`（`{REPO_ROOT}/vendor/glfw-3.4/include/GLFW/glfw3.h:4375`）は GLFW にあるが、
nimbus は未配線（`Window.zig:625-635` の callback 配線群に focus 系が無い）。popup の **外側クリック /
フォーカス喪失で dismiss** するために、フォーカス喪失を framework へ届ける 1 本を足す。

```c
/* Window gained / lost OS input focus. `focused` is true on gain, false on
 * loss. A borderless popup uses the loss edge to dismiss itself. */
typedef void (*nmWindowFocusCallback)(nmWindow* window, bool focused, void* user_data);

void nmSetWindowFocusCallback(nmWindow* self, nmWindowFocusCallback cb, void* user_data);
```

- 実装は `nmWindowCallbacks`（`glfw_shim.c:164` で `calloc` される per-window コールバック構造体）に
  focus コールバックのスロットを 1 つ足し、`nmCreateWindow` / `nmCreateWindowEx` の callback 配線
  （`glfw_shim.c:170-177`）に `glfwSetWindowFocusCallback(w, on_window_focus, ...)` を 1 行加える。
  `on_window_focus` は他の `on_*` ブリッジ（例 `on_window_pos`）と同型で、user pointer から
  `nmWindowCallbacks` を引いて framework のコールバックへ転送する。
- このコールバックは **全窓に配線してよい**（Frame / Dialog は focus loss を無視するだけ）。popup 専用に
  分岐する必要はない。

---

## 3. 確定: awt — borderless オプションと focus passthrough

`awt.Window`（`{REPO_ROOT}/awt/src/Window.zig`）は awt-c の薄いラッパ。Phase 1 で足すもの:

### 3.1 確定: borderless 生成

現状 `awt.Window.init(title, width, height)`（`awt/src/Window.zig:11-14`）が `nmCreateWindow` を呼ぶ。
**`initBorderless`（または flags を取る `initEx`）を足し、`nmCreateWindowEx` を呼ぶ。**

- シグネチャの形は実装裁量だが、`Dialog` の雛形に倣うなら framework 側が「popup 用」と明示できる
  名前付き経路（`initBorderless`）が読みやすい。flags をそのまま透過する `initEx(title, w, h, flags)` でも可。
- **確定: awt は flags 値を framework へ意味のある形（enum / packed struct）で渡し、`c.nmWindowFlag*` を
  Zig 側 import からは露出させない**（glfw 型非露出方針の延長 ＝ awt-c の C enum を awt の Zig enum に
  写し替える。`CursorShape`（`awt/src/Window.zig:128-138`）が `nmCursorShape` を Zig enum で包んでいるのと同型）。

### 3.2 確定: focus コールバック passthrough

`setResizeCallback` 等（`awt/src/Window.zig:179-219`）と同型で `setFocusCallback` を足し、
`nmSetWindowFocusCallback` を呼ぶ。型エイリアス `pub const FocusCallback = c.nmWindowFocusCallback;`
（`awt/src/Window.zig:169-177` の callback 型エイリアス群に並べる）。

- **borderless / floating / no-activate を既存の実行時トグル（`setFloating` ＝ `awt/src/Window.zig:124）と
  どう住み分けるか**: 生成時フラグ（`initBorderless`）は装飾の有無のように後から変えられない属性、
  `setFloating` は実行時に切り替える属性。popup は生成時に borderless 固定、floating は生成時ヒントで積む。

---

## 4. 確定: framework — `PopupWindow` プリミティブ

`Dialog`（`Dialog.zig`）を雛形に、装飾なし・modal ループ無し・フォーカスを奪わない top-level として設計する。

### 4.1 確定: 構造（Dialog との対比）

`PopupWindow` は `Dialog` と同じく **`window: Window` を内包し `app` / `owner` を持つ caller-owned 型**だが、
modal 関連（`modal` / `result` / `modal_done` ＝ `Dialog.zig:33-40`）を持たない。

| 項目 | Dialog | PopupWindow |
|---|---|---|
| OS 窓 | 装飾付き（`nmCreateWindow`） | 装飾なし（`nmCreateWindowEx` + borderless/floating） |
| 配置 | owner モニタ中央（`centerOnOwnerMonitor` ＝ `Dialog.zig:198`） | 呼び出し側がスクリーン座標で指定（§4.3） |
| modal ループ | `showModal` がネストループ（`Dialog.zig:121-128`） | 無し（`tickOnce` が描画・呼び出し側はブロックしない） |
| dismiss | OK/Cancel ボタン / X / Esc（`Dialog.zig:152-179`） | focus-loss / 内部選択 / 外クリック（§4.4） |
| 登録 | `registerDialog`（`Application.zig:386`） | 同じ経路を再利用（§4.2） |
| 寿命 | caller-owned・`destroy`（`Dialog.zig:83`） | caller-owned（ComboBox が所有 ＝ §5.4） |

- **確定: 内容（中身のコンポーネント）は `PopupWindow` の `window.container` に add する**
   （`Window.add` ＝ `Window.zig:294`）。これにより popup 窓の中身は通常の component ツリーとして
   レイアウト / 描画 / 入力配送される（その窓自身の `dispatchInput` ＝ `Window.zig:672` が処理する）。
   ComboBox の `popup_root`（現状の overlay 用 standalone component ＝ `ComboBox.zig:40`）を、この窓の
   container に載せる中身として作り直す（§5）。

### 4.2 確定: Application への登録は既存経路を再利用

`PopupWindow` も `Application.windows` に登録されれば `tickOnce`（`Application.zig:289-303`）が
自動で描画する（前提 §0-1）。

- **確定: `registerDialog` 相当の登録経路を使う**（`Application.zig:386-398`）。`registerDialog` は
  `destroy` を no-op にし `dialog` フィールドで close-reaper をルートする（`Application.zig:368-372`）。
  PopupWindow も caller-owned ＝ destroy は no-op が正しい。`dialog` フィールドのような型タグが要るかは
  実装裁量（**確定: PopupWindow は OS の X ボタンを持たない borderless 窓なので `shouldClose` 由来の
  close-reaper を踏まない** ＝ `collectClosedWindows` ＝ `Application.zig:349` のルートに乗らず、
  dismiss は自前で `unregisterWindow`（`Application.zig:402`）を呼ぶ）。
- **確定: modal stack（`Application.zig:93` `modal_stack` / `pushModal` ＝ `:421`）には積まない。**
  popup は親をブロックしない。`input_blocked`（`Window.zig:102`）の対象外。
- 命名は `registerDialog` が Dialog 専用名なので、**汎用化して `registerWindow(window, dialog_or_null)` に
  リネームするか、PopupWindow 用の薄い登録関数を足すかは実装裁量**（未決 §9）。`framework/src` は
  この spec では触らないので、Codex が実装段で決める。

### 4.3 確定: スクリーン座標で配置（窓ローカル→スクリーン変換 ＋ 上方向 flip）

popup は **スクリーン絶対座標**で出す（in-window overlay の窓ローカル座標とは別系）。変換は前提 §0-4 の通り
`screen = owner_window.pos + local`。

確定する純ロジック（GPU 非依存・§7.1 でテスト）:

- **アンカー**: ComboBox のフィールド左下隅を、owner 窓ローカル座標で取る
  （`absoluteOriginInWindow`（`ComboBox.zig:230` で既に使用）＋ `size.height`）。
- **スクリーン変換**: `screen_x = owner.pos.x + local_x * scale_correction`、同様に y。
  HiDPI は `Dialog` の作法（`monitorWorkarea` ＝ `Dialog.zig:200` / `screenSize` ＝ `Dialog.zig:201`）に倣う。
  座標単位の整合（logical point vs physical pixel）は `awt/src/Window.zig:46,145,158` の注記
  （`pos`/`size` は logical、`framebufferSize` は physical、`setSize` が scale 補正 ＝ `awt/src/Window.zig:95-103`）に
  従う。**確定: popup の配置計算は logical point で行い、awt 境界で scale 補正する**（既存方針の踏襲）。
- **上方向 flip（はみ出し解消の核）**: popup の希望矩形
  `{ x, y = anchor_bottom, w, h = item_h * item_count }` が owner モニタの work area 下端
  （`monitorWorkarea` ＝ `glfw_shim.c:293` の y+height）を超える場合、**アンカーをフィールド上辺へ移し
  上方向に展開する**（`y = anchor_top - h`）。上方向も入らない場合は、入る方向のうち広いほうに出して
  高さをクランプする（実装裁量・未決 §9 で詳細）。

  この flip 判定を **owner 窓に依存しない純関数**に切り出す:

  ```
  decidePopupRect(anchor_top, anchor_bottom, popup_h, popup_w, work_area) -> ScreenRect
  ```

  入力は全て数値（アンカーの上下 y・popup の希望サイズ・モニタ work area の矩形）、出力は配置矩形。
  これが §7.1 の手組みテスト対象。

### 4.4 確定: dismiss の経路

3 経路で dismiss する。いずれも「popup 窓を unregister + hide + owner へ通知」に収束させる。

1. **内部選択**: ドロップダウン内の項目クリック / Enter（§5.3）。選択を owner ComboBox に反映してから dismiss。
2. **フォーカス喪失**: §2.3 の focus コールバックが `focused == false` を届けたら dismiss。
   popup 窓自身がフォーカスを得ている前提（§5.3 ＝ ComboBox は focus を取ってよい）で、ユーザーが
   親窓や他アプリをクリックすると focus loss が飛ぶ。
3. **Escape**: popup 窓の `dispatchInput`（`Window.zig:672`）に届く key を ComboBox 側で処理し dismiss（§5.3）。

- **確定: dismiss は冪等**（`Dialog.close` ＝ `Dialog.zig:152` の `if (!self.shown) return` と同型のガードを持つ）。
  focus loss と内部選択がほぼ同時に来ても二重 unregister しない。
- **確定: dismiss 時、popup 窓は `setVisible(false)`（`awt/src/Window.zig:107`）で隠して再利用するか、毎回
  destroy するかは寿命方針（§5.4）に従う**。Dialog は隠して再利用する（`Dialog.zig:57,110,146`）。
  ComboBox の popup も開閉が頻繁なので **隠して再利用を推奨**（窓生成コストを開閉ごとに払わない）。

### 4.5 確定: teardown は Dialog の作法に合わせる

- `PopupWindow.deinit`: まだ登録中なら `unregisterWindow`（`Application.zig:402`）してから `window.deinit`
  （`Dialog.deinit` ＝ `Dialog.zig:70-75` と同型）。
- owner（ComboBox）の `destroy`（`ComboBox.zig:419`）で popup 窓も確実に解放する（§5.4）。
- `Window.deinit`（`Window.zig:276-292`）は overlay を dismiss し container を deinit し swapchain / awt_window を
  解放する。popup 窓も同じ経路を通る（borderless でも Window としては同型）。

---

## 5. 確定: ComboBox 載せ替え

### 5.1 確定: 利用者 API は温存・内部 backend だけ差し替え

`ComboBox` の公開 API（`getSelectedIndex` / `setSelectedIndex` / `setItems` / `addChangeListener` …
`ComboBox.zig:125-198`）は **一切変えない**。FileChooser（`filter_combo` ＝ `FileChooser.zig:735`・
south 領域 ＝ `FileChooser.zig:748,752-754`）も `examples` も無改修で恩恵を受ける。

差し替えるのは内部の `show`（`ComboBox.zig:229-244`）/ `hide`（`ComboBox.zig:246-252`）の backend のみ:

- **現状**: `show` は `popup_root.position` を窓ローカルで置き（`ComboBox.zig:234-237`）、
  `w.overlays.add(&self.popup_root, ...)`（`ComboBox.zig:242`）で in-window overlay 登録 ＝ 窓内クランプ。
- **変更後**: `show` は `PopupWindow` をスクリーン座標で出す。`popup_root` の中身（項目描画 ＝
  `popupLookPaint` ＝ `ComboBox.zig:440-469`）は popup 窓の container に載せる component として作り直す。

### 5.2 確定: 描画コンテンツの移設

現状 `popup_root` は ComboBox に埋め込まれた standalone component（`ComboBox.zig:40,101`）で、
overlay 専用の vtable / look_vtable（`ComboBox.zig:66-77`）を持つ。これを popup 窓の container 子として
載せ替える。

- **確定: 項目リストの見た目（`popupLookPaint` ＝ `ComboBox.zig:440-469`）と当たり判定の式
  （`popupProcessEvent` の `idx` 算出 ＝ `ComboBox.zig:483-492`）はそのまま流用できる**。座標系が
  「窓ローカル（overlay）」から「popup 窓ローカル（中身が窓いっぱい）」に変わるだけで、相対座標の
  ロジックは不変。
- popup 窓のサイズ ＝ 中身のサイズ（`popup_w = field width`・`popup_h = item_h * count` ＝
  現状 `ComboBox.zig:232-233` の計算をそのまま使う）。窓を中身ぴったりに作る。
- `detached_look_roots`（`ComboBox.zig:115,562-570`）は overlay 描画のために `popup_root` を別ルートとして
  見せる仕組み。popup 窓の container に載せると **通常の component ツリー描画に乗る**ので、この detached 機構は
  ComboBox からは外せる可能性が高い（**未決 §9**: laf の detached プレビュー描画が依存していないか実装段で確認）。

### 5.3 確定: クロスウィンドウ入力 ＝ popup 窓自身の dispatchInput で処理

ComboBox は **クロスウィンドウ入力の最小複雑度**（focus を取ってよい・hover-switch もサブメニューも無い）。
ゆえに **ドロップダウン窓自身の `dispatchInput`（`Window.zig:672`）で矢印 / Enter / Escape を処理**する。

- popup 窓は `nmWindowFlagNoActivate` を**使わない**（または focus を明示取得する ＝ `awt` `focus` ＝
  `awt/src/Window.zig:112`）。これにより矢印 / Enter キーが popup 窓に届く。
- popup 窓内の component（移設した項目リスト）の `processEvent` が、現状 `popupProcessEvent`
  （`ComboBox.zig:477-546`）と同じロジック（move で hover 更新・press / Enter で `setSelectedIndex` + dismiss・
  Escape で dismiss・矢印で hover 移動 ＝ `ComboBox.zig:494-543`）を行う。
- **選択の反映**: popup 窓内で確定した index を **親 ComboBox の `setSelectedIndex`（`ComboBox.zig:129`）へ
  反映**する。ComboBox 本体（別窓）と popup 窓は同じ `*ComboBox` を共有する（popup の component は
  `@fieldParentPtr` で ComboBox に戻れる ＝ 現状 `ComboBox.zig:441,478` と同手）。`setSelectedIndex` は
  `change_listeners.fire`（`ComboBox.zig:133`）するので、**FileChooser の `onFilterChanged`
  （`FileChooser.zig:742`）は無改修で発火する**。
- **外クリック / フォーカス喪失で dismiss**: §4.4-2 の focus コールバック。

### 5.4 確定: popup 窓の所有は ComboBox

- **確定: `PopupWindow` は ComboBox が所有する**（`popup_root` が現状 ComboBox 埋め込みなのと同じ所有関係）。
  `ComboBox.create`（`ComboBox.zig:79`）で生成するか、初回 `show` で遅延生成するかは実装裁量
  （**遅延生成を推奨** ＝ 開かれない ComboBox が OS 窓を抱えないため・現状 overlay の property map が
  遅延確保なのと同流儀 ＝ `ComboBox.zig:425-427`）。
- `ComboBox.destroy`（`ComboBox.zig:419-432`）で popup 窓も deinit + destroy する。現状 `popup_root.deinit()`
  （`ComboBox.zig:427`）を呼んでいる箇所が、PopupWindow の teardown に置き換わる。
- ComboBox が属する owner 窓が先に閉じる場合の順序: 現状 `Window.deinit` が overlay を dismiss する
  （`Window.zig:283`）のと同様、**owner 窓 teardown 時に開いている popup 窓を dismiss する経路**が要る
  （未決 §9: ComboBox の `uninstall` ＝ `ComboBox.zig:279-284` で `hide` 済みなので、`hide` が popup 窓を
  unregister すれば足りるか確認）。

### 5.5 確定: OverlayManager との住み分け

- **確定: ComboBox は `overlays.add`（`ComboBox.zig:242`）をやめ、`PopupWindow` を使う。**
- **`OverlayManager`（`OverlayManager.zig`）自体は残す**。Phase 2 までメニュー（`Menu.show` / `PopupMenu` ＝
  in-window overlay）/ ドラッグゴースト（`addPassthrough` ＝ `OverlayManager.zig:99`）が使い続ける。
- 住み分けの明文化（doc に残す load-bearing な線引き）:
  - **in-window overlay（`OverlayManager`）**: 窓内に収まる前提の軽量な浮遊レイヤ。窓クランプを許容できる
    もの（ドラッグゴースト）、または Phase 2 までの暫定（メニュー）。同一窓の `dispatchInput` で配送
    （`Window.zig:726-760`）。
  - **OS 子窓（`PopupWindow`）**: 窓端を越えてはみ出せる必要があるもの（ComboBox ドロップダウン・
    将来のメニュー / tooltip）。別窓の `dispatchInput` で配送・focus loss で dismiss。
  - **選択基準**: 「窓端ではみ出すと壊れるか」。ComboBox は south 領域（`FileChooser.zig:748`）で下方向に
    はみ出すので OS 子窓が必須。ドラッグゴーストは窓内なので overlay で足りる。

---

## 6. スコープ外（Phase 2 以降）

以下は **このタスクでは設計しない**（PopupWindow プリミティブと ComboBox のみが Phase 1）:

- **`Menu.show` / `PopupMenu` / `MenuBar` の OS 子窓化**。メニューは今回触らず in-window overlay のまま
  （`Window.dispatchInput` の overlay 段 ＝ `Window.zig:726-760`・`OverlayManager` 経由）。
- **hover-switch / サブメニュー**（メニュー間をホバーで切り替え・多段ポップアップ）。クロスウィンドウ入力の
  複雑度が高い（複数 popup 窓間のホバー連携・親窓のホバー追従）。Phase 2 で本設計する。
- **親フォーカス維持**（popup を出しても親窓のフォーカス / キャレットを保つ ＝ メニュー / tooltip の本質）。
  §2.2 の `WS_EX_NOACTIVATE` は先行整備するが、それを使う側（メニュー）は Phase 2。
- **tooltip 実装**。`PopupWindow` は tooltip 転用も視野に入れた素のプリミティブとして設計する（§4）が、
  tooltip 自体（ホバー検出・遅延表示・passthrough 配置）は Phase 2 以降。
- **OS ドロップ / ghost の OS 窓化**（DnD の `addPassthrough` ＝ `OverlayManager.zig:99`）。対象外。

これらを Phase 2 でまとめてバックログ化するかは作者判断（提案: `dogfooding_backlog.md` か
`framework_backlog.md` に「メニューの OS 子窓化（hover-switch / サブメニュー / 親フォーカス維持）」1 件）。

---

## 7. テスト計画（テスト規律）

`menu_display.md §5` / `cursor_shape.md §4.3` の教訓を踏襲する。
**純ロジックを `initHeadless` で実 DX12 を引く形にしない**（`focus_disabled` / `fc-swing` の轍 ＝
build 緑でも `--listen` 下で test.exe 非ゼロ終了を踏む）。手組みで完結させる。
別 OS 窓の生成 / クロスウィンドウ入力 / dismiss は headless で完全検証できない部分があるので、
**自動テスト可能なものと実機目視必須なものを正直に切り分ける**。

### 7.1 純ロジック（GPU 非依存・手組み）— 自動テスト可能

- **配置幾何 `decidePopupRect`（§4.3）**: owner 窓にも Application にも依存しない純関数として切り出し、
  手組みで検証（`Dialog.centeredTopLeft` ＝ `Dialog.zig:213-248` が既に同じ作法 ＝ 純関数 + `test` ブロックで
  座標を assert している。それに倣う）。ケース:
  - 下方向に収まる: アンカー下にそのまま展開（`y == anchor_bottom`）。
  - 下方向にはみ出す: 上方向 flip（`y == anchor_top - popup_h`）。
  - 上下どちらも入りきらない: 入る方向にクランプ（高さ縮約・方向は未決 §9）。
  - work area オフセット（マルチモニタ ＝ 負の原点）でも相対位置が保たれる（`centeredTopLeft` の
    `Dialog.zig:243-248` テストと同じ観点）。
- **窓ローカル→スクリーン変換（§4.3）**: `screen = owner.pos + local`（scale 補正込み）の純計算を
  手組みで検証。owner pos / scale / local を数値で与え、期待スクリーン座標を assert。
- **ComboBox の選択反映ロジック（§5.3）**: 「確定 index → `setSelectedIndex` → `change_listeners` 発火」を
  window backend 非依存に寄せ、`ComboBox.create` を直接叩いて（最小の手組みフォント・Application 非依存で
  作れる範囲で）`setSelectedIndex` が listener を呼ぶことを assert。`hovered_index` の矢印移動
  （`ComboBox.zig:518-533`）も純ロジックとして検証可能。

### 7.2 headless で部分的に検証可能

- **dismiss の冪等性（§4.4）**: 二重 dismiss / 選択 + focus-loss 競合で二重 unregister しないことを、
  状態フラグ（`shown` 相当）レベルで手組み検証。OS 窓を実際に開かずフラグ遷移だけ見る。
- **登録 / 解除の Application 状態（§4.2）**: `registerWindow` 相当で `Application.windows` に 1 件増え、
  dismiss で減ることを headless（`frameHeadless` ＝ `Application.zig:599`）で確認できる可能性がある。
  ただし popup 窓自体は OS 窓（borderless でも awt_window 非 null）なので、**headless で popup 窓を
  作れるか（borderless headless 経路を用意するか）は実装段で判断**（未決 §9）。無理なら §7.3 へ送る。

### 7.3 実機目視必須（CI GPU ゲート外・正直に明記）

以下は headless で検証できない。**自動テストに載せず、実機での目視確認項目として doc に列挙する**:

- borderless 窓が実際に装飾なしで出るか・タスクバーに出ないか（`WS_EX_TOOLWINDOW`）。
- popup が **owner 窓の端を越えてはみ出して表示できる**こと（＝ 本タスクの目的そのもの。
  FileChooser を画面下端付近に置き、`filter_combo` を開いて下方向 flip で全項目が見えること）。
- focus loss（親窓 / 他アプリクリック）で dismiss されること。
- マルチモニタ境界・HiDPI（150% / 200%）での配置ずれが無いこと。
- floating（always-on-top）で親より前に出ること。

CI 注意: GPU を引くテスト（snapshot 含む）は GPU ゲート下でのみ走る。Phase 1 は **純ロジック（§7.1）を
GPU ゲートから独立させる**のが最優先（`menu_display.md §5` 冒頭・`cursor_shape.md §4.3` と同方針）。
snapshot を 1 枚足すなら ComboBox を開いた状態だが、**別窓 popup は snapshot 機構
（`snapshotPng` ＝ 単一窓の RT 読み戻し前提）に乗らない可能性が高い** ＝ §7.3 の目視に倒す（実装段で確認・未決 §9）。

---

## 8. 実装の段割り提案（最小縦スライス）

awt-c → awt → PopupWindow → ComboBox の順で、各段を緑に保ちながら積む。

**スライス 0（awt-c）**:

1. `nmCreateWindowEx(title, w, h, flags)` ＋ `nmWindowFlags`（§2.1）。`nmCreateWindow` を `Ex(…, 0)` に畳む。
2. Win32 ex-style 適用（`WS_EX_TOOLWINDOW` / `WS_EX_NOACTIVATE`）を `nm_internal_get_hwnd` 経由で（§2.2）。
3. `nmSetWindowFocusCallback` ＋ `nmWindowFocusCallback`・`on_window_focus` ブリッジ（§2.3）。

**スライス 1（awt）**:

4. `awt.Window.initBorderless`（or `initEx`）＝ `nmCreateWindowEx` を呼ぶ（§3.1）。flags を Zig enum で包む。
5. `awt.Window.setFocusCallback` ＋ 型エイリアス（§3.2）。

**スライス 2（framework: PopupWindow）**:

6. `PopupWindow` 型（`Dialog` を雛形・modal 除去 ＝ §4.1）。登録経路（§4.2）・focus コールバック配線。
7. `decidePopupRect`（§4.3）を純関数で。`dispatchInput` は既存の Window 経路を再利用（borderless でも同型）。
8. dismiss 3 経路（§4.4）・teardown（§4.5）。
9. テスト: §7.1 の `decidePopupRect` / 座標変換（純ロジック・手組み）。

**スライス 3（ComboBox 載せ替え）**:

10. `show` / `hide`（`ComboBox.zig:229-252`）の backend を overlay → PopupWindow へ（§5.1-5.2）。
    `popup_root` の中身を popup 窓 container へ移設。detached_look_roots の要否確認（§5.2 未決）。
11. クロスウィンドウ入力（§5.3）・選択反映（`change_listeners` 発火経路の維持）。
12. 所有 / teardown（§5.4）・`OverlayManager` 住み分けの doc 明記（§5.5）。
13. テスト: §7.1 の選択反映 / 冪等 dismiss。§7.3 の実機目視（FileChooser はみ出し解消）。

各スライスとも `zig build test` を緑のまま進める。FileChooser / examples は ComboBox の公開 API 温存
（§5.1）ゆえ無改修で追従する。

---

## 9. 未決事項

- **上下どちらも入りきらないときの flip 方向 / 高さクランプ**（§4.3）。入る方向のうち広いほうへ出して
  クランプ ＋ スクロールにするか、単純に下固定でクランプするか。実機でモニタ下端ギリギリの ComboBox を
  見て決める（snapshot では測れない ＝ §7.3）。
- **`registerDialog` の汎用化 / リネーム**（§4.2）。`registerWindow(window, dialog_or_null)` に一般化するか
  PopupWindow 用の薄い登録関数を足すか。`framework/src` を触る実装段で Codex が決める。
- **`detached_look_roots` の除去可否**（§5.2）。popup 窓 container に中身を載せると通常描画に乗るので
  ComboBox から外せそうだが、laf のプレビュー描画（`detachedLookRootAt` ＝ `ComboBox.zig:566`）依存が
  無いか実装段で確認。
- **owner 窓 teardown 時の popup dismiss 順序**（§5.4）。ComboBox の `uninstall`（`ComboBox.zig:279-284`）の
  `hide` が popup 窓 unregister まで確実に行うか確認。
- **`WS_EX_NOACTIVATE` の Phase 1 採用範囲**（§2.2 / §5.3）。ComboBox は focus を取ってよい
  （no-activate を使わない）ので、no-activate は Phase 2 メニュー向けの先行整備に留めるか、プリミティブとして
  常時有効にするか。
- **borderless headless 経路の有無**（§7.2）。headless で popup 窓を作れるようにして登録 / 解除を
  自動テストするか、§7.3 の目視に倒すか。
- **snapshot 機構が別窓に乗るか**（§7.3）。`snapshotPng` の単一窓 RT 前提を別窓へ拡張するコストが
  見合うか。Phase 1 では目視に倒す前提。
- **macOS / Linux の borderless / no-taskbar 表現**（§2.2）。Win32 ex-style に対応する Cocoa（`NSWindow`
  styleMask / level）の整備は実機がある段で。Phase 1 の主ターゲットは Windows。
