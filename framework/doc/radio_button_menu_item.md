---
unsafe: true
---

# radio_button_menu_item
排他選択を表すメニュー項目。 Swing の `JRadioButtonMenuItem` 相当。
`CheckBoxMenuItem` とほぼ同じだが、 クリックはトグルではなく常に selected = true にし、
排他性は `ButtonGroup` が担う。 icon スロットには radio インジケータ (選択時に塗り円) を描く。
設計の経緯は [narrative/radio_button_menu_item.md](narrative/radio_button_menu_item.md) を参照。

実装は `CheckBoxMenuItem` (`checkbox_menu_item.md` / `CheckBoxMenuItem.zig`) を雛形にし、
差分 (クリック挙動・インジケータ・ButtonGroup 連携) だけ変える。

## 型定義
```zig
pub const RadioButtonMenuItem = struct {
    component:  Component,
    text:       []const u8,
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    model:      *ToggleButtonModel,   // selected = 選択状態
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

`ToggleButtonModel.selected: bool` を選択状態として使う (`toggle_button_model.md`)。
`MenuItem` の `icon` フィールドは持たない (icon スロットを radio インジケータが占有する)。
排他選択は型の中で完結しない。 利用者が `getModel()` を `ButtonGroup` に add する
(`button_group.md`)。 group が「常に 1 個だけ selected」を保証する。

## 関数定義

### 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButtonMenuItem;
```

`allocator` で本体を確保し、 内部 `ToggleButtonModel` を生成して所有する (`owns_model = true`)。
初期状態は selected = false。 `text` を dup、 `font` / `color` を保持し、
`component.min_size` を icon スロット幅 + テキスト寸法 + accel スロット幅 + padding から算出する。
寸法算出と paint の構造は `CheckBoxMenuItem` に揃える。 vtable をセットして install まで実行する。

#### 失敗時の保証
途中で失敗した場合、 `create` 内で確保したメモリはすべて関数内で解放される。

### 生成 (外部 Model)
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButtonMenuItem;
```

利用者が事前に作った `model` を借用する (`owns_model = false`)。
同じ `model` を共有すれば、 同期した選択状態を持つ複数項目を作れる。
ファクトリ `app.radioButtonMenuItem(text)` は menu 用 font と `theme.text` を注入する。

### 破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`uninstall` で `model` のリスナーを外し、 text バッファを解放、 `owns_model` が true なら
`model` を deinit + 解放、 最後に本体を free する。 `CheckBoxMenuItem.destroy` と同じ。

### テキストの取得 / 設定
```zig
pub fn getText(self: RadioButtonMenuItem) []const u8;
pub fn setText(self: *RadioButtonMenuItem, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` を再計算する。

### 選択状態の取得 / 設定
```zig
pub fn isSelected(self: RadioButtonMenuItem) bool;
pub fn setSelected(self: *RadioButtonMenuItem, v: bool) void;
```

`model.selected` の getter / setter。 `setSelected` は値変化時に ChangeListener を発火する。
ActionListener は発火しない (プログラム由来とユーザクリックを区別するため)。
`true` をセットすると、 group に属していれば group が他を false にする。

### Model の取得
```zig
pub fn getModel(self: RadioButtonMenuItem) *ToggleButtonModel;
```

ActionListener の登録、 enabled の制御、 `ButtonGroup` への add に使う。

### プログラム的な起動
```zig
pub fn doClick(self: *RadioButtonMenuItem) void;
```

選択 (selected = true。 冪等。 group が前の選択を落とす) + `fireAction`
(親 Menu の auto-dismiss リスナーが開いていれば閉じる)。 メニューローカルニーモニックの入口。
`enabled == false` のときは no-op。 **`CheckBoxMenuItem.doClick` との違いはここだけ**で、
トグルせず常に on にする (`RadioButton.doClick` と同じ)。

### 入力ジェスチャ
クリック (release) で `doClick` 相当 = selected = true + `fireAction`。
`CheckBoxMenuItem` の処理から「トグル」を「常に true」に変えるだけ。

### 描画
icon スロットに radio インジケータを描く。 選択時のみ塗り円 (radio dot) を描き、
非選択時は何も描かない (`CheckBoxMenuItem` のチェックマークと同じ「選択時だけ」方針)。
色は `component.theme` から取る (`CheckBoxMenuItem.paint` のチェックマークと同じ扱い)。
円は icon スロットの中央に収める。

### レイアウト属性
`MenuItem` と同じ。

---

## 利用例
表示モードの排他選択 (List / Details)。

```zig
const group = try app.buttonGroup();
defer { group.deinit(); allocator.destroy(group); }

const view_list = try app.radioButtonMenuItem("List");
const view_details = try app.radioButtonMenuItem("Details");
try group.add(view_list.getModel());
try group.add(view_details.getModel());
try view_list.getModel().addActionListener(Ctx, onList, &ctx);
try view_details.getModel().addActionListener(Ctx, onDetails, &ctx);
try view_menu.add(&view_list.component);
try view_menu.add(&view_details.component);

view_list.setSelected(true); // 初期選択
```

## 機能要望
* 非選択時にも空の円を描くスタイル (現状は選択時のみ)
* ニーモニック 対応
