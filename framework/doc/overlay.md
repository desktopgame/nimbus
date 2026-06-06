---
unsafe: true
---

# overlay
ウィンドウ内で、通常のレイアウト階層の**上**に浮かべる UI 層。ポップアップメニュー、コンボボックスのドロップダウン、（将来の）ツールチップやドラッグ中のゴーストなどに使う。

オーバーレイは `OverlayManager`（各 `Window` が `window.overlays` として 1 つ持つ）が登録リストとして保持し、container / menu_bar の上に重ねて描画する。レイアウトの外（`parent = null`、ウィンドウローカル座標）に置かれるので、親のクリップや境界に縛られず画面の任意位置に出せる。

オーバーレイには**入力モデルが 2 種類**あり、`OverlayEntry.policy` で区別する。

* `modal_popup` — ヒットテストの対象。外側クリック / ESC で dismiss される。メニュー・コンボボックスのような「開いている間は他をブロックする」ポップアップ。
* `passthrough` — 非インタラクティブ。ヒットテストも dismiss もされず、描画だけ。ドラッグ中のゴーストやツールチップのような「上に浮かぶが操作対象でない」もの。

API は `OverlayManager` のメソッドで、`window.overlays.add(...)` のように呼ぶ。`OverlayManager` は Component + awt にしか依存しないので（`Window` を知らない）、Window から切り離して扱える。`Window` は `install` 時に `overlays.wire(...)` で dirty-notify / focus-controller を渡し、描画 / イベント dispatch から `window.overlays` を参照する（`window.md`）。

## 型定義
1 つの浮動 UI を表すエントリ。`OverlayManager` が登録順のリストで保持する（top = 最新）。

```zig
pub const OverlayEntry = struct {
    component:  *Component,                 // overlay の root (position は window-local)
    owner:      *anyopaque,                 // dismiss コールバックの owner (Menu / PopupMenu 等)
    on_dismiss: *const fn (*anyopaque) void,// dismiss 時に owner の状態を更新するため
    policy:     OverlayPolicy = .modal_popup,      // 入力モデル。既定はモーダル
};

pub const OverlayPolicy = enum {
    modal_popup, // ヒットテストし、外クリック / ESC で dismiss (menu / combobox)
    passthrough, // 非インタラクティブ。 ヒットテスト / dismiss の対象外 (ghost / tooltip)
};
```

`root` の `position` はウィンドウローカルの絶対座標で、`parent` は `null`。`Component.absoluteOriginInWindow` が root の `position` を含めて足すので、オーバーレイ内の子も正しくヒットテストできる（`component.md`）。

## オーバーレイの登録
```zig
pub fn add(
    self: *OverlayManager,
    component: *Component,
    owner: *anyopaque,
    on_dismiss: *const fn (*anyopaque) void,
) !void;
```

`modal_popup` ポリシーのオーバーレイを登録する。`component.parent` は内部で `null` にされ、dirty 伝搬が Window に接続される。`component.position` は登録前にウィンドウローカル座標へセットしておくこと。

`owner` / `on_dismiss` は dismiss 時のコールバック用。外クリック / ESC で全 overlay を dismiss する際、各 entry の `on_dismiss(owner)` が呼ばれ、owner が `open = false` 等の状態を更新できる。

通常は Menu / PopupMenu / ComboBox の `show` から `w.overlays.add(...)` の形で呼ばれる（`menu.md` / `popup_menu.md` / `combobox.md`）。

## オーバーレイの解除
```zig
pub fn remove(self: *OverlayManager, owner: *anyopaque) void;
```

指定 `owner` のオーバーレイを登録解除する。`on_dismiss` は**呼ばれない**（呼び出し元が owner 自身で、自分で状態管理する前提）。該当が無ければ no-op。

## 全オーバーレイの dismiss
```zig
pub fn dismissAll(self: *OverlayManager) void;
```

登録されている `modal_popup` をすべて top から解除し、各 `on_dismiss(owner)` を呼ぶ。外クリック / ESC のとき Window 内部で呼ばれる。cascade したメニュー（File → Find → submenu）が一発で全部閉じる。`passthrough` エントリ（ドラッグゴースト）は残す。

## passthrough オーバーレイの登録
```zig
pub fn addPassthrough(self: *OverlayManager, component: *Component) !void;
```

`passthrough` ポリシーのオーバーレイ（ドラッグゴースト・ツールチップ等の非インタラクティブ浮遊物）を登録する。`component.parent` は内部で `null` にされる。`owner` / `on_dismiss` は不要（dismiss されない）。`component.position` を更新すればカーソル追従などに使える（再描画は司令塔が促す）。解除は `remove(@ptrCast(component))`（owner はコンポーネントのポインタ自身）。

ヒットテストにも dismiss にもかからないので、下の `modal_popup` / container の操作を妨げない。

## 機能要望
* z 順の明示制御 / 常時最前面の指定
* ゴーストのカスタム描画（現状は既定の汎用矩形。 ドラッグ元の見た目を反映する等は `dnd.md` 機能要望）
* ツールチップの仕組み（`passthrough` を使う将来の利用者）
* 表示 / 非表示のアニメーション（フェードなど）
