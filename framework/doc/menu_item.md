# menu_item
クリック可能なメニュー項目（リーフ）。
Swing の `JMenuItem` 相当。
左に icon slot、中央にラベル、右にアクセラレータ表示（将来）の 3 カラム構成。
クリック完了で ActionListener が発火する。

## 型定義
```zig
pub const MenuItem = struct {
    component:  Component,
    text:       []const u8,
    icon:       ?awt.Image,           // null なら icon slot は空白（揃いは保つ）
    model:      *ButtonModel,         // enabled / armed / rollover / action は ButtonModel 流用
    owns_model: bool,
    allocator:  std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };
};
```

## MenuItem の生成
```zig
pub fn create(allocator: std.mem.Allocator, text: []const u8) !*MenuItem;
```

allocator で MenuItem を確保し、内部 `ButtonModel` を生成して所有する（`owns_model = true`）。
`text` を dup して保持し、`component.min_size` を icon slot 幅 + テキスト寸法 + accel slot 幅 + padding から算出する。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## MenuItem の生成（外部 Model）
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    text: []const u8,
) !*MenuItem;
```

利用者が事前に作った `ButtonModel` を借用する（`owns_model = false`）。
同じ Model を複数の MenuItem で共有することで「同期した enabled 状態を持つ複数項目」を作れる（`button.md` の共有 Model 例と同じ）。

## MenuItem の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`MenuItem.vtable.destroy` として登録される。
`uninstall` で model のリスナーを外し、text バッファを解放、`owns_model` が true なら model を deinit + 解放、最後に MenuItem 本体を free する。
`icon` の Image は所有していないので解放しない。

## テキストの取得 / 設定
```zig
pub fn getText(self: MenuItem) []const u8;
pub fn setText(self: *MenuItem, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` を再計算する。

## アイコンの取得 / 設定
```zig
pub fn getIcon(self: MenuItem) ?awt.Image;
pub fn setIcon(self: *MenuItem, icon: ?awt.Image) void;
```

`null` でアイコン無し。
Image の所有権は MenuItem に**移らない**（borrow）。利用者が外で寿命管理する。
アイコン領域の幅は親 Menu / PopupMenu 内で共通幅に揃うので、`null` でもテキスト位置は他項目と揃う。

## Model の取得
```zig
pub fn getModel(self: MenuItem) *ButtonModel;
```

利用者が `addActionListener` を直接呼ぶ場面で使う。

---

## ButtonModel を流用する理由
MenuItem の状態（enabled / armed / rollover）とクリック完了 semantics は Button と完全に同じ。
`button.md`「状態変化と Action の二系統」を参照。
専用の `MenuItemModel` は冗長になるので作らない。

## 描画レイアウト
横並び 3 カラム（左から）：

1. **icon slot**: 固定幅 `icon_slot_width`（≒ 24px）。`icon` が non-null ならそれを描画、null なら空白
2. **label**: テキストを描画。左寄せ、cy は項目中央
3. **accel slot**: 固定幅 `accel_slot_width`（≒ 60px）。v1 は未使用（空白）。将来 `Ctrl+S` 等を右寄せで描画

| 状態 | 背景 | 文字色 |
|---|---|---|
| 通常 | 透明 | 標準 |
| hover (rollover) | アクセント色（淡） | 標準 |
| armed (押下中) | アクセント色（濃） | 反転 |
| disabled | 透明 | グレー |

slot 幅は親 Menu / PopupMenu が `computeMinSize` で全項目をスキャンして決める。
個別の MenuItem は単独描画では「ぴったり最小」で見えても、Menu の中に入ると左寄りに揃って描画される。

## クリック挙動
`Button.processEvent` と同じ：press → armed のまま release → `model.fireAction()`。
ドラッグで外れる → armed=false、戻る → armed=true。

クリックされた MenuItem は **自分で popup を閉じない**。Menu / PopupMenu 側が「子項目が action を発火した」のを ActionListener で検知して popup を hide する。
これにより MenuItem は popup の存在を知らずに済む。

## install / uninstall
`install` で model に「再描画用 ChangeListener」を登録する。
`uninstall` で外す。
親 Menu / PopupMenu が `add` した時に install されるのではなく、`create` 時点で install される（Button と同じ）。

## レイアウト属性
* `min_size`: icon_slot_width + テキスト寸法 + accel_slot_width + padding
* `max_size`: width=inf, height=min_size.height（縦には伸ばさない）
* `grow_x` / `grow_y`: 0（popup 内 BoxLayout vertical で full width に揃う、cross-axis stretch）

---

## 利用例
基本のクリック項目。

```zig
const open = try MenuItem.create(allocator, "Open");
try open.setIcon(open_icon);
try open.getModel().addActionListener(onOpen, &app_ctx);
try file_menu.add(&open.component);
```

disabled の制御。

```zig
const debug = try MenuItem.create(allocator, "Toggle Debug");
debug.getModel().setEnabled(false);
try menu.add(&debug.component);
// 後から有効化
debug.getModel().setEnabled(true);
```

共有 Model で 2 つの MenuItem の enabled 状態を同期。

```zig
const model = try allocator.create(ButtonModel);
model.* = ButtonModel.init(allocator);
defer { model.deinit(); allocator.destroy(model); }

const save_in_file = try MenuItem.createWithModel(allocator, model, "Save");
const save_in_ctx  = try MenuItem.createWithModel(allocator, model, "Save");
try file_menu.add(&save_in_file.component);
try context_menu.add(&save_in_ctx.component);
// model.setEnabled(false) で両方 disabled になる
```

## 機能要望
* アクセラレータの表示（`Ctrl+S` 等を右側 slot に描画）
* ニーモニック（テキスト内に下線、`Alt+x` で発火）
* tooltip
* テキスト + アイコン以外のカスタム描画（vtable.paint オーバライド経由で既に可能だが、専用 API が欲しい）
* HTML レンダリング（Swing が対応している、優先度低）
