# border_layout
5 つの region (north / south / east / west / center) に子を配置する `LayoutManager`。
ツールバー (north)、ステータスバー (south)、サイドバー (west / east)、メインコンテンツ (center) の典型レイアウトを構成するための定番。
Swing の `BorderLayout` を簡素化したもの。
hint で region 指定が必須。

## 型定義
```zig
pub const Region = enum(u8) { north, south, east, west, center };

pub const BorderLayout = struct {
    base: LayoutManager,

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
    };

    // ... メソッド
};
```

利用者は `BorderLayout` 自体を直接インスタンス化せず、シングルトンを返すヘルパで使う（後述）。

## レイアウトの取得
```zig
pub fn get() *LayoutManager;
```

シングルトン `BorderLayout` への `*LayoutManager` を返す。
`Container.setLayout` に渡す。

## 子の追加
```zig
pub fn add(container: *Container, region: Region, child: *Component) !void;
```

`container.addWithHint(child, region_marker, null)` の薄いラッパ。
hint には region 識別用の static pointer が入る（allocator 不要）。

### 事前条件
* `container` の layout が `BorderLayout` であること（そうでない場合 hint は無視される）
* 同じ region に複数回 `add` してはいけない（後勝ち / 無視は未定義、利用者が責任を持つ）

---

## レイアウトアルゴリズム
container の bounds を `(W, H)` とし、各 region の子を取り出す（存在しないものは無視）。

1. **north 高さ** `nh` = `north.min_size.height`（無ければ 0）
2. **south 高さ** `sh` = `south.min_size.height`（無ければ 0）
3. **west 幅** `ww` = `west.min_size.width`（無ければ 0）
4. **east 幅** `ew` = `east.min_size.width`（無ければ 0）
5. 各 region に以下の bounds をセット:

| region | x | y | width | height |
|---|---|---|---|---|
| north | 0 | 0 | W | nh |
| south | 0 | H - sh | W | sh |
| west | 0 | nh | ww | H - nh - sh |
| east | W - ew | nh | ew | H - nh - sh |
| center | ww | nh | W - ww - ew | H - nh - sh |

N/S は full width。corners は N/S が取る（VSCode / Outlook 慣例）。
center を埋める子が無くてもよい（その場合中央領域は空のまま）。

## min_size / max_size の扱い
* N/S の高さは子の `min_size.height` をそのまま使う。`max_size.height` は無視（バーは min サイズで表示するのが普通）
* E/W の幅も同様に子の `min_size.width` を使う
* N/S の幅は container 幅に強制（子の `max_size.width` を無視して full width に伸ばす）
* E/W の高さも同様に N/S を除いた縦領域いっぱいに伸ばす
* center は残り領域いっぱい

子側で「自分は full width にはなりたくない」と表現する手段は提供しない（要件なら center に Panel + BoxLayout + Filler でラップ）。

## hint の表現
region は `Region` enum で表現するが、hint は `*anyopaque` なので、各 region に対応する static アドレスを用意してそのポインタを hint に格納する。
内部実装：

```zig
var markers = [_]u8{ 0, 0, 0, 0, 0 };
pub fn marker(r: Region) *anyopaque { return &markers[@intFromEnum(r)]; }
```

利用者は `BorderLayout.add(container, .north, child)` を呼ぶだけで marker のことは気にしなくてよい。

## computeMinSize の計算
| 軸 | 計算 |
|---|---|
| width | `max(N.min_w, S.min_w, W.min_w + max(C.min_w, 0) + E.min_w)` |
| height | `N.min_h + max(W.min_h, max(C.min_h, 0), E.min_h) + S.min_h` |

存在しない region は 0 として扱う。

## computeMaxSize の計算
常に `(inf, inf)`。
BorderLayout は center が伸びる前提なので、上限は持たない。

## シングルトンとして提供する理由
BoxLayout と同様、インスタンス固有の状態を持たない。
`pub var` の static インスタンスを 1 つ用意し、`get()` がそのアドレスを返す。
LayoutManager の vtable は `deinit = null`（解放不要）。

## center のみのケース
center だけ指定するのは「container いっぱいに 1 つの子を配置」と同じ。
ただし、それなら BorderLayout を介さず `container.setBounds` の伝搬に任せた方が素直。
BorderLayout の典型用途はあくまで N/S/E/W も合わせて使うケース。

---

## 利用例
基本のシェル（toolbar + status bar + sidebar + content）。

```zig
const root = try app.container();
root.setLayout(BorderLayout.get());

const toolbar = try app.panel();
toolbar.container.component.min_size = .{ .width = 0, .height = 32 };
toolbar.setBackground(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));

const status = try app.panel();
status.container.component.min_size = .{ .width = 0, .height = 24 };
status.setBackground(awt.Graphics.Color.rgb(0.4, 0.4, 0.5));

const sidebar = try app.panel();
sidebar.container.component.min_size = .{ .width = 200, .height = 0 };
sidebar.setBackground(awt.Graphics.Color.rgb(0.92, 0.92, 0.94));

const content = try app.panel();
content.setBackground(awt.Graphics.Color.rgb(1, 1, 1));

try BorderLayout.add(root, .north,  &toolbar.container.component);
try BorderLayout.add(root, .south,  &status.container.component);
try BorderLayout.add(root, .west,   &sidebar.container.component);
try BorderLayout.add(root, .center, &content.container.component);

try frame.window.add(&root.component);
```

toolbar 内に複数のボタンを並べる例（toolbar 自体は BoxLayout でラップ）。

```zig
toolbar.container.setLayout(BoxLayout.horizontal());
try toolbar.container.add(&save_btn.component);
try toolbar.container.add(&open_btn.component);
try toolbar.container.add(&app.filler().container.component);  // 右側のスペース
try toolbar.container.add(&settings_btn.component);
```

center を BoxLayout でさらに分割する例（左右ペイン）。

```zig
const split = try app.container();
split.setLayout(BoxLayout.horizontal());

const left  = try app.panel();
left.container.component.min_size = .{ .width = 300, .height = 0 };
const right = try app.panel();
right.container.component.setGrowX(1);

try split.add(&left.container.component);
try split.add(&right.container.component);

try BorderLayout.add(root, .center, &split.component);
```

## 機能要望
* region 間 gap (spacing) のサポート
* corners を W/E に渡すオプション（Photoshop / Figma 系のレイアウト）
* N/S の `align_x` 尊重（full width にせず min 幅で配置可）
* 同一 region への複数 add をエラーにする debug assertion
