# overlay
ウィンドウ内で、通常のレイアウト階層の**上**に浮かべる UI 層。ポップアップメニュー、コンボボックスのドロップダウン、（将来の）ツールチップやドラッグ中のゴーストなどに使う。

オーバーレイは `Window` が所有リストとして保持し、container / menu_bar の上に重ねて描画する。レイアウトの外（`parent = null`、ウィンドウローカル座標）に置かれるので、親のクリップや境界に縛られず画面の任意位置に出せる。

オーバーレイには**入力モデルが 2 種類**あり、`OverlayEntry.policy` で区別する。

* `modal_popup` — ヒットテストの対象。外側クリック / ESC で dismiss される。メニュー・コンボボックスのような「開いている間は他をブロックする」ポップアップ。
* `passthrough` — 非インタラクティブ。ヒットテストも dismiss もされず、描画だけ。ドラッグ中のゴーストやツールチップのような「上に浮かぶが操作対象でない」もの。

これらの API は `Window` のメソッドとして提供される（`window.md` も参照）。

## 型定義
1 つの浮動 UI を表すエントリ。`Window` が登録順のリストで保持する（top = 最新）。

```zig
pub const OverlayEntry = struct {
    component:  *Component,                 // overlay の root (position は window-local)
    owner:      *anyopaque,                 // dismiss コールバックの owner (Menu / PopupMenu 等)
    on_dismiss: *const fn (*anyopaque) void,// dismiss 時に owner の状態を更新するため
    policy:     Policy = .modal_popup,      // 入力モデル。既定はモーダル
};

pub const Policy = enum {
    modal_popup, // ヒットテストし、外クリック / ESC で dismiss (menu / combobox)
    passthrough, // 非インタラクティブ。 ヒットテスト / dismiss の対象外 (ghost / tooltip)
};
```

`root` の `position` はウィンドウローカルの絶対座標で、`parent` は `null`。`Component.absoluteOriginInWindow` が root の `position` を含めて足すので、オーバーレイ内の子も正しくヒットテストできる（`component.md`）。

## オーバーレイの登録
```zig
pub fn addOverlay(
    self: *Window,
    component: *Component,
    owner: *anyopaque,
    on_dismiss: *const fn (*anyopaque) void,
) !void;
```

`modal_popup` ポリシーのオーバーレイを登録する。`component.parent` は内部で `null` にされ、dirty 伝搬が Window に接続される。`component.position` は登録前にウィンドウローカル座標へセットしておくこと。

`owner` / `on_dismiss` は dismiss 時のコールバック用。外クリック / ESC で Window が全 overlay を dismiss する際、各 entry の `on_dismiss(owner)` が呼ばれ、owner が `open = false` 等の状態を更新できる。

通常は Menu / PopupMenu の `show` から呼ばれる（`menu.md` / `popup_menu.md`）。

## オーバーレイの解除
```zig
pub fn removeOverlay(self: *Window, owner: *anyopaque) void;
```

指定 `owner` のオーバーレイを登録解除する。`on_dismiss` は**呼ばれない**（呼び出し元が owner 自身で、自分で状態管理する前提）。該当が無ければ no-op。

## 全オーバーレイの dismiss
```zig
pub fn dismissAllOverlays(self: *Window) void;
```

登録されている `modal_popup` をすべて top から解除し、各 `on_dismiss(owner)` を呼ぶ。外クリック / ESC のとき Window 内部で呼ばれる。cascade したメニュー（File → Find → submenu）が一発で全部閉じる。`passthrough` エントリ（ドラッグゴースト）は残す。

## passthrough オーバーレイの登録
```zig
pub fn addPassthroughOverlay(self: *Window, component: *Component) !void;
```

`passthrough` ポリシーのオーバーレイ（ドラッグゴースト・ツールチップ等の非インタラクティブ浮遊物）を登録する。`component.parent` は内部で `null` にされる。`owner` / `on_dismiss` は不要（dismiss されない）。`component.position` を更新して `Window.repaint` を呼べばカーソル追従などに使える。解除は `removeOverlay(@ptrCast(component))`（owner はコンポーネントのポインタ自身）。

ヒットテストにも dismiss にもかからないので、下の `modal_popup` / container の操作を妨げない。

---

## 描画
描画順は container → menu_bar → overlays。オーバーレイは**登録順（古 → 新）**に重ねるので、後から開いたサブメニューが手前に来る。描画は**ポリシーに関係なく全エントリ**が対象。

## イベントと dismiss
`modal_popup` のオーバーレイが 1 つでも開いている間、入力は次のように扱われる。

* **ヒットテストは登録の逆順（新 → 古）**。最初に bounds 内へ当たったオーバーレイへ dispatch する。
* bounds の**外**で press → `dismissAllOverlays`（cascade した全 popup が閉じる）。外側の hover / scroll も飲み込む（モーダルな手触り）。
* ESC → 全 dismiss。
* オーバーレイ内の MenuItem が action を発火 → owner の listener が `dismissAllOverlays` を呼ぶ。

`passthrough` のエントリは**この一連の対象外**である。ヒットテストでスキップされ（決して consume しない）、外クリックでの dismiss も引き起こさない。座標が重なっていても、イベントはその下の `modal_popup` / container が受ける。だからカーソル追従のゴーストやツールチップを、下の操作を妨げずに重ねられる。

詳細な dispatch 順は `window.md`「3 つの描画 / イベント層」を参照。

## 座標と所有権
* `root.position` はウィンドウローカルの絶対座標。`parent = null`。
* オーバーレイの root component は **Window に所有されない**。owner（Menu / PopupMenu 等）が寿命を持ち、Window はリストを保持するだけで `deinit` でも component を破棄しない。`removeOverlay` でリストから外すのは owner の責任。

## 用途
| 用途 | ポリシー | dismiss |
|---|---|---|
| ポップアップメニュー / サブメニュー | `modal_popup` | 外クリック / ESC / 項目選択 |
| コンボボックスのドロップダウン | `modal_popup` | 外クリック / ESC / 項目選択 |
| ドラッグ中のゴースト | `passthrough` | ドラッグ終了時に登録解除（dismiss 経由ではない） |
| ツールチップ（将来） | `passthrough` | 表示元が hide |

## 実装状況
* `modal_popup`: 実装済み（menu / combobox / popup menu）。
* `passthrough`: 実装済み。`OverlayEntry.policy` と `addPassthroughOverlay`、ヒットテスト / dismiss で `passthrough` をスキップする分岐を入れた。**nimbus は既定ゴーストを描かない** — 利用者がゴーストを出したいとき、`DragSource.onDragStart` で `addPassthroughOverlay`、`onDrag`（ウィンドウ座標）で位置更新、`onDragDone` で `removeOverlay` する。実例は `examples/widget_listdnd`（ラベルをゴーストにする）。`dnd.md`「描画 (ゴースト / 挿入先)」を参照。

## 機能要望
* z 順の明示制御 / 常時最前面の指定
* ゴーストのカスタム描画（現状は既定の汎用矩形。 ドラッグ元の見た目を反映する等は `dnd.md` 機能要望）
* ツールチップの仕組み（`passthrough` を使う将来の利用者）
* 表示 / 非表示のアニメーション（フェードなど）
