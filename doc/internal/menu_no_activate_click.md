# no-activate メニュー popup のクリック非到達 — awt/Win32 層の根治設計 spec

メニュー項目をマウスでクリックすると「メニューは開いたまま見え、項目も押せるのにアクションが発火しない」回帰
（`feat/menu-click-fix` で 3 コミット直したが実機で再発）の**真因が実機計装で確定**した。
これまでの framework 理論（「項目 press 中にオーナー focus-loss が割り込み、press-active フラグで抑止する」）は**誤り**だった。
本 spec はその真因と、awt/Win32 層を含む根治設計を扱う。

実装はしない（コードは書かない＝Codex 担当）。`menu_os_popup.md` / `menu_popup_test_seam.md` の流儀に倣い
**「確定」と「未決」を分ける**。load-bearing な主張には実ファイルの行番号を引用する。
awt-c の行番号は現状の `{REPO_ROOT}/awt-c/src/*`（本ブランチで未改変）基準。framework は主にシンボル名で指す
（同ブランチに未コミットの seam 差分があり行番号がぶれるため）。

関連:
`{REPO_ROOT}/awt-c/src/glfw_shim.c`（`nmCreateWindowEx` の no-activate フラグ処理・入力コールバック・イベントポンプ）、
`{REPO_ROOT}/awt-c/src/win32_ime.c`（既存の wndproc subclass `ime_wndproc` / `nm_ime_attach`）、
`{REPO_ROOT}/awt-c/src/internal.h`（`nmWindowFlagNoActivate`）、
`{REPO_ROOT}/awt/src/Window.zig`（`WindowFlags` ＝ no-activate を C へ渡すのみ）、
`{REPO_ROOT}/framework/src/PopupWindow.zig`（`initWithOptions` / `showAtScreen` の `focus_on_show`）、
`{REPO_ROOT}/framework/src/Menu.zig`（`ensurePopupWindow` ＝ `.{ .no_activate = true }`）、
`{REPO_ROOT}/framework/src/ComboBox.zig`（`ensurePopupWindow` ＝ 既定 `no_activate = false`・比較材料）、
`{REPO_ROOT}/framework/src/Window.zig`（`menuSessionFocusLost` / `onFocus` / `dispatchInput`）、
`{REPO_ROOT}/framework/src/Application.zig`（`run` / `tickOnce` ＝ 全窓ポンプ）、
`{REPO_ROOT}/doc/internal/menu_os_popup.md`（Phase 2 本体）、
`{REPO_ROOT}/doc/internal/menu_popup_test_seam.md`（前段の headless シーム設計・本 spec で方針修正）。

---

## 0. 実機トレース（確定した一次事実）

app_texteditor で File を開き Open をクリック（`[MCDBG]` は本ブランチに staged 済みの一時計装）。
**ユーザー確認 ＝ メニューは開いたまま見え、Open も押せたが動かない**:

```
press stage=menu_bar (owner)            ← File 押下
[swapchain] created (1x1)               ← File メニュー popup 窓生成
release menu_bar / container (owner)    ← File 離し（メニューは開いたまま）
...ユーザーが Open をクリック...
onFocus title=untitled focused=false active_menu_session=true   ← オーナー非アクティブ化
menuSessionFocusLost FL fired (owner)
dismissMenuSession (owner)
onFocus title=Menu focused=false
onFocus title=untitled focused=true active_menu_session=true
finishDismiss detach items=6            ← メニューが閉じる
release stage=container (owner)         ← 離しは空 container へ
```

**決定的事実**:

- トレース中に `dispatchInput title=Menu` が**一度も無い**。`popupProcessEvent` も `MenuItem.release` も**無い**。
  ＝ Open クリックが popup 窓（`title=Menu`）の入力ディスパッチに**到達していない**。
- 代わりに、popup をクリックした瞬間オーナーが focus-loss → `menuSessionFocusLost` → `dismissMenuSession` で
  メニューが閉じ、クリックは item に届かず action 非発火。
- `feat/menu-click-fix` の `menu_session_press_active` が効かない理由も確定 ＝ フラグは `popupProcessEvent` の
  press 内でセットするのに、**その `popupProcessEvent` 自体が走らないから**（press イベントが popup に来ない）。

つまり前段の理論（press は popup に届いていて、その最中の FL を抑止すればよい）は前提から崩れている。
**真の問題は「press イベントが popup 窓に配送されないこと」自体**にある。

---

## 1. 結論サマリ（先に決める）

1. **真因は no-activate 窓に `WM_MOUSEACTIVATE` ハンドラが無いこと**（§2）。`WS_EX_NOACTIVATE` を立てる
   （`glfw_shim.c:186-187`）が、`WM_MOUSEACTIVATE` を捌く wndproc が無いため、popup へのクリックが
   Win32 既定処理で (a) オーナーの非アクティブ化を誘発し (b) クリック自体が item に届かない。
2. **比較材料 ComboBox は no-activate でない**（§3）。`ComboBox.ensurePopupWindow` は既定（`no_activate = false`）の
   `popupWindow` を使い `focus()` でアクティブ化する。ゆえに同じ `PopupWindow` 経路でも**ドロップダウン項目クリックは
   届く想定**（実機確認要）。差は「no-activate か否か」一点 ＝ **一般 popup バグではなく no-activate 固有**。
3. **根治は awt-c の `WM_MOUSEACTIVATE` ハンドラ（案 A）＋ framework の良性 focus-blip ガード（案 B）の併用**（§4）。
   A で「クリックを activate 無しで item へ配送」する根治、B で「一過性 focus blip で閉じない」頑健化。
4. **検証は OS ルーティングが絡むため実機必須**（§5）。前段の headless seam（Robot が OS 配送を飛ばして
   `popup.dispatchInput` を直接叩く）は **A の OS 配送部を再現できない＝この層は headless で緑にできない**（偽の緑を避ける）。
   B の framework ガードは seam で検証可能。
5. **前段 seam の Case A/C は否定された筋なので作り替える**（§6）。seam 自体は framework メニューロジック用インフラとして残す。
6. **規模は小**（§7）。awt-c の wndproc subclass は IME 用に**既に存在**（`win32_ime.c:289-362`）＝
   `WM_MOUSEACTIVATE` の 1 ケース追加と no-activate 判定の受け渡しで収まる。

---

## 2. 確定: なぜ Open クリックが popup 窓に届かないのか

### 2.1 実コードで特定した経路

no-activate 窓の生成（`glfw_shim.c:165-200`）:

- `GLFW_FOCUS_ON_SHOW` を false に（`glfw_shim.c:173`）＝表示時に自動フォーカスしない。
- `WS_EX_NOACTIVATE` を ex-style に立てる（`glfw_shim.c:186-187`）＝クリックされても**前面/アクティブ窓にならない**。
- 入力コールバックは GLFW 標準の配線のみ（`on_mouse_button` ＝ `glfw_shim.c:89-101`、`glfwSetMouseButtonCallback` ＝ `:212`）。
- **`WM_MOUSEACTIVATE` を捌く処理はどこにも無い**（awt-c 全体を grep して該当なし）。

`WM_MOUSEACTIVATE` は「非アクティブ窓がマウスで押された」ときカーソル下の窓へ送られ、戻り値で
「アクティブ化するか」「そのクリックを食う（後続の `WM_LBUTTONDOWN` を出さない）か」が決まる
（`MA_ACTIVATE` / `MA_NOACTIVATE` / `MA_ACTIVATEANDEAT` / `MA_NOACTIVATEANDEAT`）。ハンドラが無いと
`DefWindowProc`（IME subclass 経由でも最終的に `CallWindowProcW(prev, ...)` ＝ `win32_ime.c:338-339`）の既定値になる。

トレースの症状（オーナー focus-loss が起き、かつ popup に press が届かない）は、この既定処理が
**(a) アクティブ化を試みてオーナーを非アクティブ化し（focus blip）、(b) クリックを item へ通さない**ことに整合する。

### 2.2 確定と未決の切り分け

**確定（コードから）**: no-activate 窓に `WM_MOUSEACTIVATE` ハンドラが無く、popup へのクリックが既定処理に委ねられている。
トレースが示す「popup に press 不達 ＋ オーナー focus blip」はこの欠落の帰結。

**未決（実機での裏取りが要る §5）**: 既定が具体的にどの戻り値相当で振る舞っているか
（クリックを食う `*ANDEAT` 系か、アクティブ化のみでイベント自体は別要因で popup に来ないのか）。
`WS_EX_NOACTIVATE` 窓でも press が来ない理由が「食われる」のか「フォーカス遷移でイベントの宛先窓が入れ替わる」のかは、
案 A の subclass を入れて `WM_MOUSEACTIVATE` / `WM_LBUTTONDOWN` を実機ログして確定する。
**どちらでも案 A（明示的に `MA_NOACTIVATE` を返す）が正しい修正方向**である点は変わらない（§4.1）。

### 2.3 前段理論が誤りだった理由

`menu_session_press_active`（`feat/menu-click-fix`）は「popup の `popupProcessEvent` press が走り、その内側でフラグを立て、
最中の FL を抑止する」前提だった。だが §0 の通り **press が popup に来ない＝`popupProcessEvent` が走らない**ので、
フラグは永遠に立たず抑止は空振りする。framework だけを見ていては届かない層（Win32 のクリック配送）に真因があった。

---

## 3. 確定: ComboBox との比較（no-activate 固有かの裏取り）

同じ `PopupWindow` プリミティブを使う ComboBox ドロップダウンと比較する。

- **Menu**: `Menu.ensurePopupWindow` は `app.popupWindowWithOptions(owner, "Menu", 1, 1, .{ .no_activate = true })`。
  `PopupWindow.showAtScreen` は `focus_on_show = !no_activate` ＝ **false** なので `focus()` を呼ばない。
- **ComboBox**: `ComboBox.ensurePopupWindow` は `app.popupWindow(owner, "ComboBox", 1, 1)`（`ComboBox.zig:280`）
  ＝ 既定オプション ＝ **`no_activate = false`**。`focus_on_show = true` ＝ `showAtScreen` が `focus()` を呼び、
  ドロップダウンが**アクティブ窓になる**。

アクティブ窓へのクリックは `WM_MOUSEACTIVATE` の論点を踏まない（既にアクティブ／通常のアクティブ化）。
ゆえに **ComboBox のドロップダウン項目クリックは実機で効いている想定**（コード上の差は no-activate フラグ一点）。

- もし実機で**ComboBox は効いていれば**: 本件は **no-activate 固有**で確定 ＝ §4 の方向で正しい。
- もし実機で**ComboBox も効いていなければ**: より一般的な popup 入力配送バグ（ポンプ／登録経路）を疑う必要があるが、
  §1 の run ループ調査（`glfwWaitEvents` がプロセス全窓をポンプ・per-window ポンプではない ＝ `Application.zig:271-283`）
  からはポンプ漏れ説は薄い。**この分岐は実機で ComboBox を 1 回触れば即決する**ので §5 の必須項目にする。

---

## 4. 確定: 修正方針の設計

### 4.1 案 A（根治・awt-c）: `WM_MOUSEACTIVATE` ハンドラで `MA_NOACTIVATE` を返す

no-activate 窓に対し `WM_MOUSEACTIVATE` で **`MA_NOACTIVATE`** を返す。意味は「この窓をアクティブ化せず、
**かつクリックは食わずに**通常どおり `WM_LBUTTONDOWN` を配送する」。これにより:

- popup はアクティブ化されない ＝ オーナーは非アクティブ化されない（focus blip が消える）。
- クリックが `WM_LBUTTONDOWN` として popup に届く ＝ GLFW の `on_mouse_button`（`glfw_shim.c:89`）→
  popup 窓の `dispatchInput` → `popupProcessEvent` → `MenuItem` press/release ＝ **action が発火する**。

**実装の置き場所は既存 subclass を流用**: IME 用の `ime_wndproc`（`win32_ime.c:289-340`）が既に
`SetWindowLongPtrW(... GWLP_WNDPROC ...)`（`win32_ime.c:360`）で全窓に入っており、`prev_wndproc` へ chain している。
ここに `case WM_MOUSEACTIVATE:` を 1 つ足し、その窓が no-activate なら `return MA_NOACTIVATE;` する。

`ime_wndproc` から「この窓は no-activate か」を知る必要がある（**未決 §8**: 判定の渡し方）。候補:

- `nmCreateWindowEx` で立てた no-activate を `nmWindowCallbacks`（`GWLP_USERDATA` に格納・`win32_ime.c:357`）へ
  bool として保存し、`ime_wndproc` が読む。最小。
- もしくは `WM_MOUSEACTIVATE` 時に `GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_NOACTIVATE` を見る（フラグ保存不要）。
  ex-style は生成時に立てている（`glfw_shim.c:187`）ので自己完結する。**こちらがより堅い**（状態を二重化しない）。

awt 層（`awt/src/Window.zig`）は no-activate を C へ渡すだけなので**改修不要**。framework も案 A 単独なら不要。

### 4.2 案 B（頑健化・framework）: 良性 focus-blip では dismiss しない

案 A で focus blip 自体が消える見込みだが、**OS / ドライバ差で一過性の focus blip が残る可能性**に対する保険として、
`menuSessionFocusLost`（`Window.zig`）に「セッション自身の popup 窓グループ内へ focus が移った、
または直後にオーナーへ戻る良性遷移なら dismiss しない」ガードを足す。

- 真に外部（他アプリ）へ移ったときだけ dismiss する。判定材料は「新たに focus を得た窓がこのセッションの
  popup 窓群のいずれか／オーナー自身か」。`onFocus`（`Window.zig:onFocus`）が得る focused フラグだけでは
  「どこへ移ったか」が分からないので、**focus-gained 側の窓 identity**（awt から得るフォアグラウンド窓、
  またはセッションが保持する popup 窓集合との照合）が要る（**未決 §8**）。
- 前段 `menu_session_press_active` は §2.3 で否定されたので、B はそれの置換ではなく**別軸のガード**
  （press タイミングでなく focus の移り先で判定する）。

### 4.3 確定: 推奨は A＋B

- **A は根治**（クリックが item に届き発火する・focus blip の発生源を断つ）。これ単体で §0 の症状は解消する見込み。
- **B は頑健化**（A 後も残りうる一過性 blip や、将来別経路の blip でメニューが誤って閉じない保険）。
- **案 C（メニューで no-activate を使う是非の再検討）は不採用方向**。no-activate は Phase 2 の中核要件
  （親フォーカス維持＝アクセラレータ／ニーモニックが親窓 `menu_bar` 起点で動く・キャレット保持 ＝
  `menu_os_popup.md §5-6`）を満たすための選択で、外すと Phase 2 のキー基盤を作り直すことになる。
  `WM_MOUSEACTIVATE` ハンドラ（A）は no-activate を**保ったまま**クリック配送だけ直せるので、C の代償を払う理由が無い。
  C は「A で解決しない実機問題が出た場合」の最終手段として未決に残す（§8）。

---

## 5. 確定: 検証戦略（各層が何をカバーするか）

OS のクリック配送が絡むので**実機検証が必須**。headless で緑にできる範囲を正直に切る（偽の緑を避ける）。

| 検証層 | 何をカバーするか | カバーしないこと |
|---|---|---|
| **実機目視（必須）** | 案 A の本体: no-activate popup の項目クリックで `WM_MOUSEACTIVATE` → `MA_NOACTIVATE` → `WM_LBUTTONDOWN` が popup に届き action 発火。focus blip が消えること。ComboBox ドロップダウンの項目クリックが効くこと（§3 の分岐確定）。 | 自動化不可。CI の GPU/OS ゲート外。 |
| **awt-c 単体（任意・限定的）** | `WM_MOUSEACTIVATE` ハンドラが no-activate 窓で `MA_NOACTIVATE` を返す純判定（ex-style 読み出しの分岐）。 | クリックが実際に item まで配送されることは OS 依存で再現不可。 |
| **framework seam（headless）** | 案 B の framework ガード: セッション中かつ popup 表示中に focus-loss を**注入**したとき、移り先がセッション内/オーナーなら dismiss しない・外部なら dismiss する、を assert。 | **案 A の OS 配送部は再現不可**。Robot は OS 配送を飛ばして `popup.dispatchInput` を直接叩くため、`WM_MOUSEACTIVATE` の食い／focus blip を再現しない。**この層を緑にしても A の回帰は捕まらない**。 |

**明記する偽の緑の罠**: 前段 seam で「二窓を本物配線で建て、項目を press→release」しても、Robot は
`popup.dispatchInput` を直接叩くので **OS が press を食う／focus blip を出す挙動を再現しない**。
ゆえに seam テストが緑でも実機の本バグ（案 A 対象）は無傷で残りうる。**案 A の回帰ガードは実機目視のみ**と doc に固定する。

---

## 6. 確定: 前段 seam 作業との整合

前段 `menu_popup_test_seam.md` の Case A/C は「項目 press **中**にオーナー FL が割り込む」筋で設計したが、
§2.3 でこの筋は否定された（press が popup に来ないので「press 中の FL」という状態が成立しない）。整合方針:

- **seam インフラ自体は残す**: headless で二窓パスを本物配線で駆動できる仕組み（headless PopupWindow ＋
  focus-loss 注入口）は、案 B のガード検証と、今後の framework メニューロジック回帰に有用。
- **Case A/C は案 B のガード検証へ作り替える**:
  - 新 Case B1: セッション中＋popup 表示中に「移り先 = セッション内 popup」な focus-loss を注入 → **dismiss しない**。
  - 新 Case B2: 同条件で「移り先 = 外部（セッション外）」な focus-loss を注入 → **dismiss する**。
  - 旧 Case D（真の外部喪失で dismiss）は B2 に吸収。旧 Case A（press 中 FL で発火）は**削除**
    （案 A 対象＝headless で再現不可・§5 の通り実機目視へ移す）。
- **seam doc に追記すべき注記**: 「Case A/C が突こうとした press-中-FL は実機計装で否定された。
  クリック非到達の真因は Win32 `WM_MOUSEACTIVATE`（本 doc §2）であり、その層は headless 対象外」。
  （seam doc 本体の更新は実装段で seam と一緒に・本 spec では doc 追加のみ。）

---

## 7. 確定: 規模 / 工数の見積り

**小。** 新規の窓 proc 機構は要らない（既存を流用）。

- **案 A（awt-c）**: `ime_wndproc`（`win32_ime.c:289`）に `case WM_MOUSEACTIVATE:` を 1 つ追加し、
  `GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_NOACTIVATE` なら `return MA_NOACTIVATE;`。〜10 行。
  subclass の attach（`nm_ime_attach` ＝ `win32_ime.c:344-362`）も chain（`:338-339`）も既存のまま。
  awt / framework の改修は A 単独では不要（フラグは既に C まで届いている）。
- **案 B（framework）**: `menuSessionFocusLost` に移り先判定ガード。focus-gained 窓 identity を得る口が要るなら
  awt に薄い getter（フォアグラウンド窓問い合わせ）を 1 つ足す程度。〜20〜40 行（identity 取得の設計次第・§8）。
- **seam の作り替え（framework テスト）**: Case A/C → B1/B2 へ。前段 seam が入っていれば差分のみ。〜数十行。

**リスク / 注意**:

- `WM_MOUSEACTIVATE` の既定挙動の正確な姿は実機ログで確定（§2.2）。案 A の方向は不変だが、
  もし `MA_NOACTIVATE` でも press が来ない別要因（GLFW 側の foreground 前提など）が判明したら §8 へ。
- IME subclass は全窓に入る（`nm_ime_attach` は `nmCreateWindowEx` の最後で常に呼ぶ ＝ `glfw_shim.c:217`）ので、
  no-activate 判定を窓ごとに ex-style で見れば通常窓には影響しない（通常窓は `WS_EX_NOACTIVATE` を持たない）。

---

## 8. 未決事項

- **`WM_MOUSEACTIVATE` 既定の正確な戦域**（§2.2）。クリックを食う `*ANDEAT` 系か、フォーカス遷移で宛先が
  入れ替わるのか。案 A の subclass で `WM_MOUSEACTIVATE` / `WM_LBUTTONDOWN` を実機ログして確定。
- **案 A の no-activate 判定の渡し方**（§4.1）。`nmWindowCallbacks` に bool を持たせるか、`WM_MOUSEACTIVATE` 時に
  ex-style を読むか。後者（ex-style 読み）推奨だが実装段で確定。
- **案 B の focus-gained 窓 identity の取得**（§4.2）。`onFocus` の focused フラグだけでは移り先が分からない。
  awt にフォアグラウンド窓 getter を足すか、セッションが保持する popup 窓集合と照合するか。
- **ComboBox 実機挙動の確定**（§3）。効いていれば no-activate 固有で確定・効いていなければポンプ／登録経路へ調査拡大。
- **案 C のトリガ条件**（§4.3）。案 A＋B で実機解決しない場合に限り「メニューの no-activate 廃止」を再検討する。
  その場合 Phase 2 のキー基盤（親窓 `menu_bar` 起点のアクセラレータ／ニーモニック）の作り直しコストを別途見積もる。
- **seam doc 本体の更新**（§6）。Case A/C → B1/B2 の作り替えと press-中-FL 否定の注記は、実装段で seam コードと同時に。
