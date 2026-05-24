# scroll_bar
スクロールバーウィジェット。
トラックと、可視量に比例した長さのつまみ (thumb) を持ち、ドラッグやトラッククリックで値を変える。
`Slider` と同じく `BoundedRangeModel` を状態に使う (`value` がスクロール位置、`extent` が可視量、`max - min` が全長)。

主に `ScrollPane` が内部で 2 本 (水平 / 垂直) 抱えて使うが、独立したウィジェットとしても配置できる (`scrollpane.md` 参照)。
メニュー系と違い浮動オーバーレイではないので、`Window` 側の特別扱いは一切不要な普通のリーフウィジェットである。

## 型定義
```zig
pub const ScrollBar = struct {
    component:       Component,
    model:           *BoundedRangeModel,  // value / min / max / extent
    owns_model:      bool,                // create で自前確保したか (createWithModel なら false)
    orientation:     Orientation,
    unit_increment:  i32,                 // 矢印 / ホイール 1 ステップ量 (px)
    block_increment: i32,                 // トラッククリック (ページ) 1 ステップ量 (px)。0 なら extent を使う
    dragging:        bool,                // つまみドラッグ中
    drag_grab:       f32,                 // つかんだ瞬間の「つまみ先頭からカーソルまで」の距離 (px)
    allocator:       std.mem.Allocator,
};

pub const Orientation = enum { horizontal, vertical };
```

`value` は `BoundedRangeModel` の規約どおり `[min, max - extent]` にクランプされる。
スクロール用途では `min = 0`、`max = コンテンツ全長`、`extent = ビューポート可視量`、`value = スクロールオフセット` として使う。

## スクロールバーの生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*ScrollBar;
```

`BoundedRangeModel` を内部で確保した `ScrollBar` をヒープに作る (`owns_model = true`)。
`extent` は 0 で始まる。 後から `model.setExtent` で設定する。

## スクロールバーの生成 (モデル共有)
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
) !*ScrollBar;
```

外部が所有する `BoundedRangeModel` を共有する `ScrollBar` を作る (`owns_model = false`)。
`ScrollPane` がスクロール状態モデルを保持し、それをバーに渡す時に使う。
モデルの寿命は呼び出し側が持つ (バーの `destroy` では解放しない)。

## スクロールバーの破棄
`vtable.destroy(&bar.component, allocator)` で破棄する。
`owns_model` が true のときだけ内部の `BoundedRangeModel` も解放する。
通常はコンテナー (`ScrollPane` 等) の `deinit` 経由で間接的に呼ばれる。

## モデルの取得
```zig
pub fn getModel(self: ScrollBar) *BoundedRangeModel;
```

## 値の取得 / 設定
```zig
pub fn getValue(self: ScrollBar) i32;
pub fn setValue(self: *ScrollBar, v: i32) void;
```

`model.getValue` / `model.setValue` への委譲。
`setValue` は範囲外をクランプし、変化したときだけ `ChangeListener` を発火 + repaint。

## 向きの取得
```zig
pub fn getOrientation(self: ScrollBar) Orientation;
```

## ステップ量の設定
```zig
pub fn setUnitIncrement(self: *ScrollBar, px: i32) void;
pub fn setBlockIncrement(self: *ScrollBar, px: i32) void;
```

`unit_increment` は矢印操作 / ホイール 1 ノッチ、`block_increment` はトラッククリック (ページ) で進む量。
`block_increment` が 0 のときはトラッククリックで `extent` 分 (1 ページ) 進む。

## ChangeListener
```zig
pub fn addChangeListener   (self: *ScrollBar, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeChangeListener(self: *ScrollBar, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
```

`model` の `ChangeListener` への委譲。
`value` / `extent` / 範囲のいずれかが変わると発火する。
`ScrollPane` はこれを購読してビューのスクロールオフセットを更新する。

---

## レイアウト
* 垂直: `min_size = { width = THICKNESS, height = 0 }`、`max_size.width = THICKNESS`、高さは伸びる
* 水平: `min_size = { width = 0, height = THICKNESS }`、`max_size.height = THICKNESS`、幅は伸びる

`THICKNESS` は定数 (初版 14px 程度)。

## 描画
1. トラック (溝) を薄いグレーで塗る
2. つまみを濃いグレーで塗る (`rollover` / `dragging` で少し濃く)

つまみの長さ = `extent / (max - min) * トラック長` (下限 `MIN_THUMB`)。
つまみ位置 = `(value - min) / ((max - min) - extent) * (トラック長 - つまみ長)`。
`(max - min) <= extent` (スクロール不要) のときはつまみがトラックいっぱいになり、ドラッグ不可。

## イベント処理
| 入力 | 動作 |
|---|---|
| つまみ上で left press | ドラッグ開始 (`requestCapture`)、`drag_grab` を記録 |
| ドラッグ中 move | カーソル位置から `value` を算出して `setValue` |
| left release | ドラッグ終了 |
| トラック上 (つまみ外) で left press | クリック側へ `block_increment` (or 1 ページ) 進む |
| ホイール (`.scroll`) | `unit_increment` 分進む |
| move (ドラッグ外) | `rollover` 更新 |

ドラッグは `Slider` と同じ標準のマウスキャプチャ機構 (`ev.requestCapture`) を使う (`window.md`「マウスキャプチャ」参照)。

## ファクトリ
```zig
const bar = try app.scrollBar(.vertical, 0, 0, 100);
```

## 機能要望
* 両端の矢印ボタン (押しっぱなしで連続スクロールする autorepeat タイマー込み)
* キーボード操作 (フォーカス時に矢印 / PageUp/Down / Home/End)
* オーバーレイ式スクロールバー (内容に重ねて表示し、操作時だけ太くなる現代的スタイル)
* つまみの最小長やトラック余白のテーマ化
