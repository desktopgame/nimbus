# メニューの OS 子窓化（hover-switch / クロスウィンドウ入力）設計 spec — Phase 2

Phase 1 で入れた `PopupWindow`（装飾なし OS レベル子窓・`doc/internal/popup_window.md`）の上に、
**メニュー（`Menu` / `PopupMenu` / `MenuBar` / サブメニュー）を載せ替える**ための設計 spec。
目的は、メニュー popup を in-window overlay から OS 子窓へ移すことで、メニューバーの
**hover-switch 不調（#1）と stale `open_menu`（#2）を本解決**することにある。

Phase 1 は `ComboBox` のみ載せ替え済み（`develop` = a82fc9d）。メニューはまだ in-window overlay
（`OverlayManager` 経由）のまま。本 spec はメニューを Phase 1 の `PopupWindow` プリミティブに乗せ替える。

実装はしない（コードは書かない＝Codex 担当）。`popup_window.md` / `cursor_shape.md` / `border_model.md` の流儀に倣い
**「確定」と「未決」を分ける**。load-bearing な主張には実ファイルの行番号を引用する。本 spec では `framework/src` を触らない。

関連:
`{REPO_ROOT}/framework/src/PopupWindow.zig`（Phase 1 のプリミティブ・本 spec の土台）、
`{REPO_ROOT}/framework/src/Menu.zig`（`show` / `hide` / `popupProcessEvent` / `openSubmenu`）、
`{REPO_ROOT}/framework/src/MenuBar.zig`（`open_menu` / hover-switch の `.move` ハンドラ）、
`{REPO_ROOT}/framework/src/PopupMenu.zig`（コンテキストメニュー）、
`{REPO_ROOT}/framework/src/Window.zig`（`dispatchInput` の overlay 段 / key 段・`findAcceleratorTarget` / `mnemonicScan` / `onFocusLost`）、
`{REPO_ROOT}/framework/src/OverlayManager.zig`（既存 in-window overlay・`dismissAll` / `dismissTop`）、
`{REPO_ROOT}/framework/src/ComboBox.zig`（Phase 1 の載せ替え先行例・`show` / `ensurePopupWindow`）、
`{REPO_ROOT}/framework/src/Application.zig`（`popupWindow` ファクトリ・`registerUnownedWindowNoReap`）、
`{REPO_ROOT}/awt/src/Window.zig`（`WindowFlags` / `nmWindowFlagNoActivate` / `setFocusCallback`）、
`{REPO_ROOT}/framework/doc/menu.md` / `menu_bar.md` / `popup_menu.md` / `overlay.md`。

---

## 0. 背景・確定済みの土台

### 0.1 Phase 1 で確定したプリミティブ（実コードで確認済み・再調査不要）

- **`PopupWindow` は装飾なし OS 子窓を出せる。** `PopupWindow.init`（`PopupWindow.zig:31-65`）は
  `Window.initWithFlags` を `{ borderless = true, floating = true, no_taskbar = true }` で呼ぶ
  （`PopupWindow.zig:49-54`）。**`no_activate` は立てていない**＝Phase 1 の ComboBox popup は
  フォーカスを取る前提。
- **配置幾何は純関数として切り出し済み・テスト済み。** `decidePopupRect`（`PopupWindow.zig:186-206`）が
  下に収まれば下・はみ出せば上 flip・両方ダメならクランプを返す。`ownerLocalRectToScreen`
  （`PopupWindow.zig:154-162`）が窓ローカル→スクリーン変換＋scale 補正。すでに 8 本の手組みテストが付く
  （`PopupWindow.zig:219-298`）。**メニューはこの幾何をそのまま再利用できる**（アンカー矩形だけ差し替え）。
- **dismiss は 3 経路ある。** `dismissFromSelection` / `dismissFromFocusLoss` / `dismissFromEscape`
  （`PopupWindow.zig:113-123`）が全て `dismiss`（`PopupWindow.zig:125-132`）に収束し、冪等
  （`if (!self.shown) return` ＝ `:126`）。`onDismiss` で owner へ通知（`:108-111`・`:130`）。
- **window-focus コールバックは配線済み。** `Window.onFocusLost`（`Window.zig:401-404`）が
  `onFocus` ブリッジ（`Window.zig:1322-1332`）に繋がる。**ただし loss エッジのみ届く**
  （`if (focused) return` ＝ `Window.zig:1327`）。**コールバックは 1 窓 1 スロット**
  （`focus_loss_ctx` / `focus_loss_cb` ＝ `Window.zig:122-123`）＝ 複数 consumer は持てない（§5.3 で効く）。
- **登録は unowned-no-reap 経路がある。** `registerUnownedWindowNoReap`（`Application.zig:402-412`）が
  `tickOnce` の全窓描画に乗せつつ close-reaper を外す。`popupWindow` ファクトリ（`Application.zig:660`）が
  PopupWindow を生成する。
- **awt 側に no-activate フラグの口がある。** `awt.Window.WindowFlags` に `no_activate` があり
  `nmWindowFlagNoActivate` に対応（`{REPO_ROOT}/awt/src/Window.zig:24-27`）。`setFocusCallback`
  （`{REPO_ROOT}/awt/src/Window.zig:201,224`）も配線済み。**メニュー向けに「フラグを立て、`focus()` を呼ばない」
  経路を PopupWindow に足すだけで no-activate メニューが成立する**（§5.1）。

### 0.2 ComboBox（Phase 1）の入力モデル ＝ メニューが踏襲しない先行例

ComboBox の popup は **フォーカスを取る OS 窓**で、キーは popup 窓自身に来る:

- `show`（`ComboBox.zig:235-255`）が `PopupWindow.showAtLocal` を呼び、`showAtScreen` が
  `self.window.awt_window.?.focus()` する（`PopupWindow.zig:104`）。
- `popup_root` を popup 窓の container へ `BorderLayout.add`（`ComboBox.zig:283`）＝ popup 窓の
  `dispatchInput` が矢印 / Enter を `popupProcessEvent` へ配る。Escape は popup 窓の container に
  bind（`PopupWindow.zig:138-143`）。dismiss は **popup 窓自身の** focus-loss（`PopupWindow.zig:93`）。

このモデルが ComboBox で成立するのは、ComboBox に **hover-switch もサブメニューもアクセラレータも
ニーモニックも無い**から。メニューはこれらを全部持つので、後述の通り **逆の方針（親フォーカス維持）を採る**（§5）。

### 0.3 解決すべき既知バグ（実コードに当てて確認済み）

- **#1 hover-switch がデッドコード。** 「開いている間に別トップ項目へホバーで自動切替」は
  `MenuBar.processEvent` の `.move` 内（`MenuBar.zig:160-185`、切替の核は `:169-184`）にあるが**発火しない**。
  原因＝メニュー popup が in-window modal overlay なので、`Window.dispatchInput` の overlay 段
  （`Window.zig:752-786`）が popup 外への `.move` を握り潰して `return` する（`:771-785`）＝
  menu_bar 段（`Window.zig:788-804`）に到達しない。`MenuBar` の `.move` ハンドラにイベントが届かない。
- **#2 stale `open_menu`。** `MenuBar.open_menu`（`MenuBar.zig:17`）は press 時に立つ（`MenuBar.zig:155`）が、
  dismiss（`Menu.hide` ＝ `Menu.zig:284`、`onOverlayDismiss` ＝ `:296`、`OverlayManager.dismissAll` ＝
  `:127`、ESC の `dismissTop` ＝ `:142`、外クリック ＝ `Window.zig:771-776`）のいずれでも**クリアされない**。
  閉じた後に stale なポインタが残り、overlay 無し状態で別トップ項目ホバー時の誤発火を誘発しうる。
- **標準挙動（あるべき姿・作者確認済み）**: 初回はクリックで開く／開いている間は他トップ項目へホバーで
  自動切替／閉じたらホバーでは開かない（VSCode / Fork も同じ）。

---

## 1. 結論サマリ（先に決める）

本 spec で確定する設計判断を冒頭に置く。根拠は §2〜§8。

1. **メニューは「常に OS 窓」にする（ハイブリッドにしない）。** 収まる場合に in-window overlay を残すと
   #1 の握り潰し（`Window.zig:771-785`）と hover-switch / キールーティングを 2 経路で抱える。
   経路 1 本に倒すのが Phase 2 の本旨（§8）。
2. **メニュー popup は no-activate（親フォーカスを奪わない）。** ComboBox（§0.2）と逆。理由は
   キーボード基盤（アクセラレータ / ニーモニック走査）が **親窓の `menu_bar` 前提**で組まれているから（§5・§6）。
3. **マウスは各 popup 窓の `dispatchInput` が処理／キーは親窓が「アクティブメニューチェーン」へルートする。**
   OS はカーソル下の窓へマウスを送る（popup 上の move/click は popup 窓へ・メニューバー上の move は親窓へ）。
   no-activate でキーは親窓に来るので、親窓に**メニューセッション key 段**を新設する（§6）。
4. **hover-switch は親窓の `MenuBar.move` ハンドラがそのまま駆動する。** OS 窓化で overlay 握り潰しが
   消え、`MenuBar.zig:169-184` が live になる（§2）。`open_menu` のライフサイクルを dismiss と同期し #2 も同時に解消（§3）。
5. **メニューセッション ＝ メニューバー＋開いている popup 窓群を 1 単位**として扱い、チェーン全体で
   dismiss する（§7）。

---

## 2. 確定: hover-switch 復活の経路（#1 の裏取り）

**#1 は OS 窓化で素直に解ける。** 実コードで経路を追うと:

現状（in-window overlay）:

1. メニューを開くと `Menu.show` が `w.overlays.add(&self.popup_root, ...)`（`Menu.zig:280`）で modal overlay を積む。
2. 以後 `Window.dispatchInput` は overlay 段（`Window.zig:752`）で `topModalIndex() != null` を見て、
   popup 外の `.move` を握り潰す（`Window.zig:771-785` で `return`）。
3. ゆえに menu_bar 段（`Window.zig:788-804`）に `.move` が届かず、`MenuBar.processEvent` の hover-switch
   （`MenuBar.zig:169-184`）が発火しない。**これが #1 のデッドコードの正体**。

OS 窓化後:

1. メニューを開くと `Menu.show` は overlay を積まず、別 OS 窓（`PopupWindow`）を出す（§4）。
2. その窓は `Application.windows` に居るだけで、**親窓の `overlays` は空**＝
   `topModalIndex()` は null（`OverlayManager.zig:151`）。
3. 親窓の `dispatchInput` は overlay 段を素通りし、メニューバー上の `.move` が menu_bar 段
   （`Window.zig:788-804`）に到達する。`.move` は領域外でも常にバーへ配られる設計（`Window.zig:791-794`）なので、
   `MenuBar.processEvent` の hover-switch ブロック（`MenuBar.zig:169-184`）が**そのまま生きる**。
4. OS はカーソル下の窓へマウスを送るので、メニューバー（親窓）上の move は親窓に・項目（popup 窓）上の
   move は popup 窓に、それぞれ自然に分岐する。hover-switch の駆動源（メニューバー上の move）は確実に親窓に来る。

**結論: #1 は「overlay 段の握り潰しを経由しなくなる」ことで自然に解ける。** ただし `MenuBar.zig:173-181` の
`cur.hide()` → `new.show(...)` は現状 in-window overlay 前提の座標・呼び出しなので、§4 の OS 窓 `show` へ
差し替える必要がある（ロジックの骨格は不変・呼ぶ先が変わるだけ）。

---

## 3. 確定: `open_menu` のライフサイクル（#2 の修正）

`MenuBar.open_menu` は「いまアクティブなトップメニュー」を指す唯一の真実にする。立てる／クリアするタイミングを
**popup 窓の show / dismiss に一対一で同期**させる:

- **立てる**: トップ項目クリックで開いたとき（`MenuBar.zig:155`）／ニーモニックで開いたとき
  （`Window.mnemonicScan` が `bar.open_menu = ...` を既に書いている ＝ `Window.zig:1081`）／hover-switch で
  別項目へ切り替えたとき（`MenuBar.zig:180`）。ここは現状コードのまま。
- **クリア**: **dismiss のすべての経路でクリアする**（現状欠けている #2 の本体）。
  - 内部選択（項目クリック / Enter）→ チェーン dismiss。
  - 外クリック（親窓の content 上の press・他 popup 窓外）。
  - 親窓フォーカス喪失（他アプリへ移動）。
  - ESC でトップまで閉じたとき。

確定する仕掛け: **トップメニューの popup 窓 `onDismiss`（`PopupWindow.zig:108`）コールバックが
`MenuBar.open_menu = null` を書く**。ComboBox が `onPopupDismiss`（`ComboBox.zig:266-269`）で自分の
`open` を畳んでいるのと同型。これにより、どの経路で閉じても（focus-loss / 外クリック / ESC / 選択）
popup 窓の `dismiss` が必ず通り、その `onDismiss` が `open_menu` をクリアする＝ stale が生じない。

`Menu.open` フラグ（`Menu.zig:40`）も同様に popup 窓の show / dismiss と同期させる。現状 `Menu.hide`
（`Menu.zig:284-294`）が `overlays.remove` を呼ぶ箇所が、popup 窓の `dismiss` 呼び出しに置き換わる（§4.3）。

**未決（§11）**: `open_menu` を `MenuBar` に置くか、親窓側の「メニューセッション」状態（§6）に一本化するか。
キールーティングの段（§6）でも「アクティブなチェーンの根」が要るので、両者を同じ 1 つの真実に寄せたい。

---

## 4. 確定: PopupWindow への載せ替え方針

### 4.1 確定: 利用者 API は温存・内部 backend だけ差し替え

`Menu` / `PopupMenu` / `MenuBar` の公開 API（`add` / `addSeparator` / `setMnemonic` / `doClick` …）は
**一切変えない**。`examples` も無改修。差し替えるのは内部の popup backend のみ:

- **現状**: `Menu.show`（`Menu.zig:241-282`）は popup サイズ／窓内クランプ（`Menu.zig:256-262`）を計算し
  `popup_root` を窓ローカルに置き、`w.overlays.add`（`Menu.zig:280`）で in-window overlay 登録。
- **変更後**: `Menu.show` は `PopupWindow` をスクリーン座標で出す。ComboBox の `ensurePopupWindow`
  （`ComboBox.zig:277-286`）と同型に、Menu が `PopupWindow` を 1 つ持ち、`popup_root` をその窓の container へ
  `BorderLayout.add`（`ComboBox.zig:283` と同手）で載せる。窓内クランプ（`Menu.zig:256-262`）は捨て、
  `decidePopupRect`（`PopupWindow.zig:186-206`）の上 flip／クランプに置き換える。

### 4.2 確定: 描画コンテンツとヒットテストはそのまま流用

- 項目描画 `popupLookPaint`（`Menu.zig:571-583`）／枠描画 `popupLookPaintOver`（`:585-596`）／
  ヒットテストと move/press 配送の `popupProcessEvent`（`Menu.zig:602-707`）は**座標系が変わるだけで
  ロジックは不変**。現状「親窓ローカル（overlay）」だった `popup_root` の座標が「popup 窓ローカル
  （中身が窓いっぱい）」になる。ComboBox 載せ替えで同じ流用が成立済み（§0.2）。
- `detached_look_roots`（`Menu.zig:110,557-565`）は overlay 描画のために `popup_root` を別ルートとして
  見せる機構。popup 窓 container に載せると通常の component ツリー描画に乗るので、**Menu からも外せる可能性が高い**
  （ComboBox 載せ替えと同じ論点・**未決 §11**: laf のプレビュー描画が依存しないか実装段で確認）。

### 4.3 確定: サブメニューは子 popup 窓を連鎖させる

現状 `openSubmenu`（`Menu.zig:393-401`）は親 popup の右隣に in-window overlay で子を出す
（`ox = popup_root.position.x + width` ＝ `:396`）。OS 窓化後:

- 子メニューの `PopupWindow` を**親 popup 窓を owner として**スクリーン座標で出す。アンカー矩形は
  「親 popup 窓ローカルでの、親項目の右辺・上辺」＝ `{ x = parent_popup_w, y = item.position.y, ... }`。
  `decidePopupRect` が右にはみ出せば左 flip する余地は **未決（§11）**（現状 `decidePopupRect` は y 方向の
  flip のみ。横方向 flip が要るなら拡張）。
- チェーン管理は現状の `open_child`（`Menu.zig:41`）をそのまま使う。親 popup の `popupProcessEvent` の
  move が、別項目へ移ったとき子を閉じる（`Menu.zig:616-621`）／新項目で開く（`:628`）ロジックは不変。
  ただし子は別 OS 窓なので、`hide` が overlay remove でなく子 popup 窓 dismiss になる。
- **メニューセッション ＝ メニューバー ＋ そこからぶら下がる全 popup 窓**。チェーンを 1 単位として
  dismiss / キールーティングする（§6・§7）。

### 4.4 確定: `PopupMenu`（コンテキストメニュー）も同経路

`PopupMenu`（`PopupMenu.zig`）は親が無い独立のコンテキストメニューだが、popup の中身は `Menu` と同じ
`popup_root` 系。**owner 窓を「右クリックが起きた窓」として同じ OS 子窓経路に載せる**。メニューバー由来の
hover-switch（§2）は無関係だが、サブメニュー連鎖（§4.3）・キールーティング（§6）・dismiss（§7）は共通。

---

## 5. 確定: 親フォーカス維持（no-activate）と副作用

### 5.1 確定: メニュー popup は no-activate ＝ `focus()` を呼ばない

ComboBox（§0.2）はフォーカスを取るが、**メニューは取らない**。理由は §6 のキールーティングと表裏一体:
アクセラレータ走査 `findAcceleratorTarget`（`Window.zig:1045-1052`）とニーモニック走査 `mnemonicScan`
（`Window.zig:1073-1091`）は **`self.menu_bar` を起点に走る**。`menu_bar` は親窓にしか無い
（`Window.zig:52`）。popup 窓に focus を移すとキーが popup 窓へ行き、そこには `menu_bar` が無いので
アクセラレータ / ニーモニックが死ぬ。**親フォーカスを保てば、これらは無改修で生き続ける**。

実装の口は揃っている（§0.1）: `PopupWindow` に no-activate 経路を足す（`WindowFlags.no_activate` を立て、
`showAtScreen` の `focus()`（`PopupWindow.zig:104`）を**呼ばない**バリアントにする）。具体的な API 形
（`init` 引数で分けるか `showAtScreenNoActivate` を足すか）は実装裁量（**未決 §11**）。

### 5.2 確定: 副作用 — 親のキャレット / IME は親に残る

no-activate なので、メニューを開いても親窓の `focus_owner`（例: テキストフィールド）は**変わらない**
（`Window.zig:94`）。これは Swing の挙動（メニューを開いてもキャレット位置は保たれる）と一致し望ましい。

ただし副作用として:

- **親のキャレットがメニュー表示中も点滅し続けうる**（`focus_owner` のままなので）。Swing はメニュー中
  キャレットを保持する。許容するが、**実機目視項目**（§9.3）に挙げる。
- **メニュー表示中の矢印 / Enter / 文字キーが、親の `focus_owner`（テキストフィールド）に漏れてはいけない。**
  ＝ §6 のメニューセッション key 段を `focus_owner` 段（`Window.zig:879-882`）**より前**に置き、
  メニューがアクティブな間はキーを横取りする。`char` も同様に横取り／握り潰す（現状 `char` は overlay 優先
  ＝ `Window.zig:926-937`、これをセッション優先に置換）。
- IME composition も同様にメニュー中は親フィールドへ流さない（`composition` 段 ＝ `Window.zig:943-948`）。
  ただし「メニュー中に IME を完全停止すべきか」は v1 では踏み込まず、**未決 §11**。

### 5.3 確定: 親窓フォーカス喪失を dismiss に使う（1 スロット制約に注意）

no-activate メニューでは popup 窓は focus を持たないので、**popup 窓自身の focus-loss は起きない**。
代わりに **親窓の focus-loss**（他アプリへ移動）を session dismiss に使う（`Window.onFocusLost` ＝
`Window.zig:401-404`・loss エッジのみ ＝ `:1327`）。

注意点:

- `onFocusLost` は **1 窓 1 スロット**（`focus_loss_ctx` / `focus_loss_cb` ＝ `Window.zig:122-123`）。
  親窓のこのスロットをメニューセッションが使うので、**同じ親窓で別用途（将来）と競合しないか**を
  実装段で確認（**未決 §11**）。必要なら multi-listener 化。
- no-activate により「メニューを開いても親はフォーカスを失わない」ので、**show 直後に誤って自分を
  dismiss しない**。これは ComboBox のフォーカス取得モデルでは成立しない安全性で、no-activate を採る
  もう一つの実利（§8 で再掲）。

---

## 6. 確定: クロスウィンドウ キールーティング（親窓 → アクティブメニューチェーン）

Phase 2 最大の難所。no-activate ゆえ**キーは親窓に来る**。親窓がそれを「いま開いているメニューチェーンの
最深 popup」へ配る機構を新設する。

### 6.1 現状: キーは modal overlay 段が握っている

現状 `Window.dispatchInput` の `.key` 段（`Window.zig:838-925`）は、in-window modal overlay があると
最初に overlay 段（`Window.zig:850-875`）で `top.component.processEvent`（＝ `popupProcessEvent` の key 分岐
`Menu.zig:642-704`）へキーを渡す。矢印 / Enter / メニューローカルニーモニックはここで処理され、ESC は
`dismissTop`（`Window.zig:856`）、アクセラレータは `dismissAll` + `doClick`（`:864-871`）。

OS 窓化すると `topModalIndex()` は null（§2）になるので、**この overlay key 段が丸ごと死ぬ**。ここを
**メニューセッション key 段**で置き換える。

### 6.2 確定: メニューセッション key 段（overlay key 段の置換）

`Window.dispatchInput` の `.key` 段に、`focus_owner` 段（`Window.zig:879`）**より前**で次を行う段を新設する。
ゲートは「いまメニューセッションがアクティブか」（＝ `MenuBar.open_menu != null`、または §3 で一本化する
セッション状態）:

1. **アクティブチェーンの最深 popup を求める**: セッションの根（トップメニュー）から `open_child`
   （`Menu.zig:41`）を辿った末端の `Menu`。その `popup_root` が現在のキー宛先。
2. **矢印 / Enter / メニューローカル文字キーを、その `popupProcessEvent`（`Menu.zig:642-704`）へ転送**する。
   ロジックは現状のまま（`moveHighlight` / `activateHighlighted` / メニューローカルニーモニック ＝
   `Menu.zig:648-703`）。`arrow_right` でサブメニューを開く（`Menu.zig:658-671`）／`arrow_left` で一段戻る
   （`:672-679`）も、open_child 連鎖を辿る今の実装がそのまま効く。
3. **ESC は一段だけ閉じる**。最深サブメニューがあればそれを閉じ、無ければトップを閉じてセッション終了。
   現状の `dismissTop`（`OverlayManager.zig:142`）に対応する「チェーン末端だけ閉じる」を、popup 窓の
   dismiss で表現する（§7）。
4. **アクセラレータ（Ctrl / Meta 修飾）は既存 Stage 4 をそのまま使う**。`findAcceleratorTarget`
   （`Window.zig:1045`）は親窓の `menu_bar` を走るので、no-activate でキーが親窓に来ている限り**無改修で動く**。
   メニューを閉じてから `doClick` する作法（現状 `Window.zig:864-871`）も踏襲。
5. **Alt+letter ニーモニック（Stage 5・`Window.zig:918-924` / `mnemonicScan` ＝ `:1073`）も無改修**。
   親窓の `menu_bar` 起点で走るため。

ここが「**no-activate を選ぶと、アクセラレータ / ニーモニックは触らずに済み、新規に書くのは
矢印 / Enter / ESC のチェーン転送だけ**」という設計上の旨味（§8）。

### 6.3 確定: マウスはルーティング不要（各 popup 窓が自前で処理）

キーと違い、マウスは OS がカーソル下の窓へ配るので**ルーティング不要**。popup 窓の中身（`popup_root`）が
その窓の `dispatchInput` で `popupProcessEvent`（`Menu.zig:602-641` の mouse 分岐）を回す。サブメニューの
hover open / close（`Menu.zig:607-628`）もその窓内 move で完結する。**親窓に来るマウスはメニューバー上の
move（hover-switch ＝ §2）だけ**が意味を持つ。

### 6.4 「セッションの根」をどこが持つか

key 段（親窓）はセッションの根（トップメニュー）への参照が要る。候補:

- `MenuBar.open_menu`（`MenuBar.zig:17`）をそのまま根とし、`Window` から `menu_bar` 経由で辿る
  （`Window.zig:52` の `menu_bar: ?*Component` → `MenuBar`）。`PopupMenu`（メニューバー無し）は別途
  セッション根を親窓に持たせる必要がある。
- もしくは **親窓に `active_menu_session: ?*Menu`（または専用 struct）を 1 本持たせ**、`MenuBar` /
  `PopupMenu` 双方が同じ口に登録する。`open_menu` はその射影にする。

**§3 と合わせて「セッションの根は 1 つの真実」に寄せるのを推奨**（#2 のクリア漏れも、根が 1 箇所なら
dismiss 同期が単純化する）。最終的な置き場所は実装段で決める（**未決 §11**）。

---

## 7. 確定: dismiss の経路（チェーン全体 vs 一段）

メニューセッションは「メニューバー＋開いている popup 窓群」を 1 単位として畳む。経路:

- **内部選択（項目クリック / Enter）**: 末端で `activateItem`（`Menu.zig:712-729`）→ leaf なら `doClick`
  → `onItemAction`（`Menu.zig:307-309`）相当で**チェーン全体を dismiss**。現状 `overlays.dismissAll`
  （`Menu.zig:308`）が、トップ popup 窓 dismiss → 連鎖（子 → 親）に置き換わる。
- **外クリック**:
  - **親窓 content 上の press**（メニューバー外）→ 親窓 dispatch で「セッション中なら全 dismiss」。
    現状の overlay 外クリック dismiss（`Window.zig:771-776`）に対応する処理を、セッション中の親窓に持たせる。
  - **メニュー popup 窓の外だが別 popup 窓でもない領域** → 各 popup 窓の dispatch では拾えないので、
    親窓フォーカス喪失（下）か親窓 press で拾う。
- **親窓フォーカス喪失（他アプリ / 他ウィンドウへ移動）**: §5.3 の `onFocusLost` →**チェーン全体 dismiss**。
- **ESC**: §6.2-3 ＝ **最深サブメニューだけ閉じる**（一段）。トップで ESC ならセッション終了。

確定する不変条件:

- **dismiss は子 → 親の順で連鎖**し、各 popup 窓 `dismiss`（`PopupWindow.zig:125-132`）は冪等
  （`:126`）。focus-loss と内部選択がほぼ同時でも二重 unregister しない。
- **トップ popup 窓 `onDismiss` が `MenuBar.open_menu`（およびセッション根）をクリア**（§3）＝ #2 解消。
- **popup 窓は隠して再利用**（`setVisible(false)` ＝ `PopupWindow.zig:128`）。開閉が頻繁なメニューで
  毎回 OS 窓を生成しない（Dialog / ComboBox と同方針）。所有は Menu（ComboBox の `ensurePopupWindow` 同型）。

---

## 8. 確定: 「常に OS 窓」 vs 「ハイブリッド」 — 結論と理由

**結論: メニューは常に OS 窓。Swing PopupFactory 流のハイブリッド（収まれば in-window）は採らない。**

判断軸を実コードに当てて比較する:

| 観点 | 常に OS 窓 | ハイブリッド（収まれば in-window overlay） |
|---|---|---|
| #1 hover-switch | overlay 握り潰し（`Window.zig:771-785`）を経由せず素直に解ける（§2） | 収まる場合は overlay 経路 ＝ #1 が残る。収まる時用の hover-switch 駆動を別途要する |
| キールーティング | 親窓のセッション key 段 1 本 + 既存アクセラレータ / ニーモニック流用（§6） | 収まる時は overlay key 段、はみ出す時はセッション key 段 ＝ 2 経路維持 |
| 入力モード | クロスウィンドウ 1 モード | クロスウィンドウ＋ローカル overlay の 2 モード |
| 軽さ | 収まるメニューでも OS 窓生成（隠して再利用で緩和 §7） | 収まる時は軽い |
| 癖 | OS 窓のフォーカス / ちらつき / マルチモニタ癖を全メニューで払う | 収まる時はその癖を回避 |

**常に OS 窓を採る理由:**

- Phase 2 の本旨は **#1 を生む overlay 握り潰しを排除すること**。収まる場合に in-window overlay を残すと、
  まさに直したいバグ（#1）と stale（#2）を「収まるメニュー」で再導入し、hover-switch とキールーティングを
  2 系統で保守することになる。経路 1 本のほうが正味のコードと不具合面が小さい。
- no-activate ＋ 親フォーカス維持の設計（§5・§6）は **OS 窓前提**。ハイブリッドだと収まる時は
  in-window overlay（親フォーカスのまま・既存 overlay 段）／はみ出す時は OS 窓（no-activate）と、
  フォーカスモデルが 2 種混在し、dismiss / キー横取りの分岐が増える。
- 「軽さ」の差は **隠して再利用**（§7）でほぼ消える（窓は開閉ごとに作らない）。

**tooltip（将来）への波及 — メニューと別判断にする:**

- tooltip は **passthrough / no-focus / 入力を取らない**（`OverlayManager.OverlayPolicy.passthrough` ＝
  `OverlayManager.zig:14-20`）。メニューのような hover-switch / キーチェーンが無い。
- ゆえに **tooltip は収まれば in-window passthrough overlay のままでよく、はみ出す時だけ OS 窓**という
  ハイブリッドが妥当になりうる。**メニューの「常に OS 窓」結論を tooltip に機械的に波及させない**
  （tooltip は Phase 2 スコープ外・別途設計）。

**未決はこの章には無い**（結論を出す章）。残る論点は §11 へ。

---

## 9. テスト計画

`popup_window.md §7` / `menu_display.md` / `cursor_shape.md §4.3` の教訓を踏襲する。
**純ロジックを `initHeadless` で実 DX12 を引く形にしない**（`focus_disabled` / `fc-swing` の轍 ＝
build 緑でも `--listen` 下で test.exe 非ゼロ終了を踏む ＝ `[[zig-test-exit0-failed-command]]`）。
別 OS 窓のクロスウィンドウ挙動は headless で完全検証できないので、**自動可能なものと実機目視必須なものを
正直に切り分ける**。

### 9.1 純ロジック（GPU 非依存・手組み）— 自動テスト可能

- **メニューセッションの状態遷移**: 「open（press / ニーモニック）→ hover-switch → サブ open → ESC 一段 →
  dismiss」を、OS 窓を開かずに **セッション struct のフラグ遷移**として検証する。`open_menu` /
  `open_child` / セッション根が、各遷移後に期待値であることを assert（特に**全 dismiss 経路後に
  `open_menu == null`** ＝ #2 の回帰防止）。
- **hover-switch 判定の純化**: 「セッションがアクティブ、かつ hovered が現 top と異なる」→ 切替、を
  `MenuBar` のヒットテスト（`MenuBar.zig:142-147`）と分けて純関数に切り出し、座標→切替要否を手組みで assert。
  「閉じている間は hover で開かない」（標準挙動 §0.3）も同じ関数で false を返すことを確認。
- **キールーティングの宛先選択**: 「セッション根から `open_child` を辿った最深 popup」を返す純関数（§6.2-1）を
  切り出し、チェーン深さ別に正しい末端を返すことを assert。矢印 highlight 移動（`moveHighlight` ＝
  `Menu.zig:376-389`）は既にチェーンと独立した純ロジックなので、`create` を直接叩いて検証可能。
- **配置幾何**: `decidePopupRect` / `ownerLocalPopupRect`（`PopupWindow.zig:186-298`）は Phase 1 で
  テスト済み。サブメニュー横 flip を足すなら（§4.3）その分岐に手組みケースを追加。

### 9.2 headless で部分的に検証可能

- **dismiss の冪等性と連鎖順**: 子 → 親の dismiss 連鎖、二重 dismiss 無害（`PopupWindow.zig:126`）を、
  OS 窓を実際に出さずフラグ遷移で検証。
- **登録 / 解除**: `registerUnownedWindowNoReap`（`Application.zig:402`）/ `unregisterWindow`（`:416`）で
  `Application.windows` が増減することを headless で確認できる可能性。ただし popup 窓は OS 窓
  （`awt_window` 非 null）なので、borderless headless 経路があるかは実装段判断（Phase 1 と同じ**未決 §11**）。

### 9.3 実機目視必須（CI GPU ゲート外・正直に明記）

別 OS 窓は `snapshotPng`（単一窓 RT 読み戻し前提）に乗らない可能性が高い。以下は目視で:

- **hover-switch**: メニューを開いたまま別トップ項目へホバーして自動切替（VSCode / Fork 相当）。
  **閉じてからホバーで開かない**ことも。
- **クロスウィンドウキー**: 親フィールドにフォーカスがある状態でメニューを開き、矢印 / Enter / ESC /
  メニューローカル文字 / Alt+letter / Ctrl アクセラレータが正しくメニューへ行き、**親フィールドに漏れない**こと。
- **親フォーカス維持**: メニュー表示中も親のキャレット位置が保たれ、閉じた後そのまま入力継続できること
  （キャレット点滅の挙動 §5.2 も確認）。
- **サブメニュー多段**: hover で子が開き、別項目へ移ると閉じる。画面端で flip すること。
- **dismiss**: 親 content 外クリック / 他アプリへの切替で全チェームが閉じること。no-activate で
  **メニューを開いた瞬間に自滅 dismiss しない**こと（§5.3）。
- borderless / no-taskbar / floating が効くこと（Phase 1 の `popup_window.md §7.3` と同項目）。

---

## 10. 実装の段割り提案

各段で `zig build test` を緑に保つ。**hover-switch / #2 を先に最小で解き、サブメニューを後段にする**。

**スライス A（PopupWindow の no-activate 拡張）**:

1. `PopupWindow` に no-activate 経路（`WindowFlags.no_activate` を立て `focus()` を呼ばないバリアント・§5.1）。
2. 親窓 focus-loss を session dismiss に繋ぐ口（`onFocusLost` の利用・§5.3）。

**スライス B（トップメニュー 1 段だけ OS 窓化 ＝ #1 / #2 解消）**:

3. `Menu.show` / `hide`（`Menu.zig:241-294`）の backend を overlay → PopupWindow へ（§4.1-4.2）。
   `popup_root` を popup 窓 container へ。窓内クランプを `decidePopupRect` へ。
4. `MenuBar.open_menu` のライフサイクル同期（§3）＝ トップ popup 窓 `onDismiss` でクリア。
5. メニューセッション key 段（§6.2）を overlay key 段の置換として新設。アクセラレータ / ニーモニックは流用。
6. hover-switch（`MenuBar.zig:169-184`）を OS 窓 `show` 呼び出しへ差し替え（§2 末尾）。
7. テスト: §9.1 の状態遷移 / hover-switch 判定 / `open_menu` クリア / キー宛先選択（純ロジック）。

**スライス C（サブメニュー多段）**:

8. `openSubmenu`（`Menu.zig:393-401`）を子 popup 窓連鎖へ（§4.3）。横 flip の要否判断。
9. ESC 一段／`arrow_left` 一段戻り（`Menu.zig:672-679`）をチェーン dismiss に整合。
10. テスト: §9.1 のチェーン宛先 / 連鎖 dismiss 順。§9.3 の実機目視。

**スライス D（PopupMenu）**:

11. `PopupMenu`（コンテキストメニュー）を同経路に載せる（§4.4）。セッション根を親窓に持たせる。

---

## 11. 未決事項

- **セッション根の置き場所**（§3 / §6.4）。`MenuBar.open_menu` を根にするか、親窓に
  `active_menu_session` を 1 本持たせて `MenuBar` / `PopupMenu` 双方を載せるか。#2 のクリア漏れ防止と
  キールーティングの両方が「1 つの真実」を欲しがる。
- **no-activate の API 形**（§5.1）。`PopupWindow.init` 引数で分けるか `showAtScreenNoActivate` を足すか。
  ComboBox（focus 取得）と Menu（no-activate）が同じ `PopupWindow` 型をどう共有するか。
- **親窓 `onFocusLost` の 1 スロット競合**（§5.3）。同じ親窓でメニュー以外が focus-loss を使うと衝突。
  必要なら multi-listener 化。
- **サブメニュー横 flip**（§4.3）。`decidePopupRect`（`PopupWindow.zig:186-206`）は現状 y 方向の flip のみ。
  右端ではみ出す子メニューを左へ flip する拡張が要るか、実機で確認。
- **メニュー中の IME / composition の扱い**（§5.2）。親フィールドへ流さないのは確定だが、IME を完全停止
  すべきか v1 では踏み込まない。
- **`detached_look_roots` の除去可否**（§4.2）。popup 窓 container に載せると通常描画に乗るので Menu から
  外せそうだが、laf のプレビュー描画依存が無いか実装段で確認（ComboBox 載せ替えと同じ論点）。
- **borderless headless 経路の有無**（§9.2）。headless で popup 窓を作って登録 / 解除を自動テストするか、
  §9.3 の目視に倒すか（Phase 1 と同じ未決）。
- **`snapshotPng` が別窓に乗るか**（§9.3）。単一窓 RT 前提を別窓へ拡張するコストが見合うか。
  Phase 2 では目視に倒す前提。
- **tooltip のハイブリッド適用**（§8）。tooltip は passthrough / no-focus ゆえ「収まれば in-window・
  はみ出す時 OS 窓」が妥当になりうるが、Phase 2 スコープ外。別途設計。
