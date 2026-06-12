---
unsafe: true
---

# split_pane
2 つのコンポーネント (ペイン) を水平または垂直に並べ、境界のディバイダーをドラッグして配分を変えられるコンテナー。
Swing の `JSplitPane` 相当。

## 型定義
```zig
pub const SplitPane = struct {
    container:        Container,          // 公開 Component は container.component (先頭フィールド必須)
    first:            *Component,         // 左 / 上のペイン (所有)
    second:           *Component,         // 右 / 下のペイン (所有)
    orientation:      Orientation,
    divider_location: ?f32,               // first の主軸サイズ (px)。null = 未確定 (初回レイアウトで決まる)
    divider_size:     f32,                // ディバイダーの太さ (px)。既定 6
    resize_weight:    f32,                // コンテナーのリサイズ差分を first に配る割合 [0, 1]。既定 0
    layout:           SplitLayout,        // 内部 LayoutManager (ScrollPane と同じ手)
    drag:             ?DragState,         // ディバイダードラッグ中だけ non-null (内部状態)
    allocator:        std.mem.Allocator,
};

pub const Orientation = enum {
    horizontal, // first | second を横に並べる (ディバイダーは縦線)
    vertical,   // first / second を縦に積む (ディバイダーは横線)
};
```

### レイアウト規則
主軸 (horizontal なら幅) を `first | ディバイダー | second` に分割する。交差軸は両ペインとも全高 (全幅) に伸ばす。

- `divider_location` が null の間は、初回レイアウト時に `first.effectiveMinSize()` の主軸値を採用して確定する
  (サイドバー的な first が自然幅で出る。50/50 にしたければ `setDividerLocation` で明示する)。
- `divider_location` は常に `[first の最小, 利用可能長 - second の最小]` にクランプされる。
  この範囲が空 (両ペインの最小 + ディバイダーが利用可能長を超える) 場合は first に最小を与え、残りを second に渡す。
- コンテナー自身がリサイズされたときは、主軸の差分 × `resize_weight` を first に配る
  (既定 0 = first は px サイズを維持し、伸縮はすべて second が受ける)。
- ペイン側の grow 係数は SplitPane 内では参照しない (配分はディバイダー位置がすべて)。
  SplitPane 自身が親レイアウトでどう伸びるかは、通常どおり自身の grow / min_size で決まる。
- SplitPane 自身の最小サイズは、主軸 = `first の最小 + divider_size + second の最小`、交差軸 = 両ペインの最小の大きい方。

### ディバイダーの操作と描画
ディバイダー上でマウスボタンを押すとドラッグが始まり、移動中は `divider_location` を逐次更新して再レイアウトする
(連続レイアウト。ドラッグ確定までゴースト線で済ます遅延モードは持たない)。
描画は既定 LAF の paint が `component.theme` を読む (専用のテーマフィールドは追加せず、`separator` 系を使う)。

## 関数定義

### 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    first: *Component,
    second: *Component,
) !*SplitPane;
```

`first` / `second` を内部 `container` の子として取り込み (所有権が移る)、`SplitPane` をヒープに返す。
`divider_location` は null (初回レイアウトで確定)、`divider_size` / `resize_weight` は既定値で始まる。

ファクトリ:
```zig
const sp = try app.splitPane(.horizontal, &left.component, &right.component);
```

#### 失敗時の保証
失敗時は途中で確保した分をすべて解放する。渡した `first` / `second` も解放される (所有権はエラー時も移る)。

#### 事前条件
* `first` / `second` がまだどのコンテナーにも add されていないこと (multi-mount は未対応)。

### 破棄
`vtable.destroy(sp.asComponent(), allocator)` で破棄する。
`first` / `second` (および推移的にその子) をすべて解放する。
通常は親コンテナーの `deinit` 経由で間接的に呼ばれる。

### ディバイダー位置の取得 / 設定
```zig
pub fn getDividerLocation(self: SplitPane) ?f32;
pub fn setDividerLocation(self: *SplitPane, px: f32) void;
```

`first` ペインの主軸サイズを px で扱う。
`set` は「レイアウト規則」のクランプを適用したうえで再レイアウトを要求する。
初回レイアウト前に呼んだ場合は値を保持し、初回レイアウトでクランプして適用する (呼び順の罠なし)。
`get` は初回レイアウト前で未設定なら null を返す。

### ディバイダーの太さの設定
```zig
pub fn setDividerSize(self: *SplitPane, px: f32) void;
```

### リサイズ配分の設定
```zig
pub fn setResizeWeight(self: *SplitPane, weight: f32) void;
```

コンテナーのリサイズ差分を first に配る割合。`[0, 1]` にクランプされる。
0 = second がすべて受ける (サイドバー向け既定)、1 = first がすべて受ける、0.5 = 等分。

---

## 利用例
ファイラー風の 2 ペイン (左: 場所一覧、右: ファイル一覧)。

```zig
const places = try app.list(...);   // 左ペイン
const files  = try app.list(...);   // 右ペイン

const sp = try app.splitPane(.horizontal, places.asComponent(), files.asComponent());
sp.setDividerLocation(180);         // 左を 180px で開始。リサイズ時も左は 180px を維持 (resize_weight 0)
sp.asComponent().setGrowX(1);
sp.asComponent().setGrowY(1);

try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());
```

## 機能要望
* ディバイダー上のリサイズカーソル (awt にカーソル形状 API が無い。glfw 標準カーソル経由で awt-c / awt への追加が先)
* ペインの差し替え (`setFirst` / `setSecond`。ScrollPane の `setView` 相当。実需待ち)
* ワンタッチ展開 (Swing `oneTouchExpandable`。ディバイダー上の小ボタンで片側を畳む)
* ディバイダーのキーボード操作 (フォーカスして矢印キーで移動)
* ドラッグ中はゴースト線だけ動かす遅延レイアウトモード (重いペインでの体感対策。実需待ち)
