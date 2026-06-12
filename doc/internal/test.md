# test
nimbus のテストの種類と典型的な書き方についてのドキュメント。
`zig build test` で以下すべてが一括で走る。

## テストの種類
| 種別 | 配置 | 用途 |
|---|---|---|
| 埋め込み単体テスト | `awt/src/**/*.zig` / `framework/src/**/*.zig` 内の `test "..."` ブロック | モジュール内のロジック単体検証 |
| awt スナップショットテスト | `awt/tests/snapshot_test.zig` + `awt/tests/scenes.zig` + `awt/tests/fixtures/` | awt 直叩きでの描画結果をゴールデン画像と比較 |
| framework レイアウトテスト | `framework/tests/box_layout_test.zig` / `framework/tests/border_layout_test.zig` / `framework/tests/split_pane_test.zig` | レイアウトマネージャ / レイアウトを内蔵するウィジェットの bounds を数値アサート（GPU 不要） |
| framework スナップショットテスト | `framework/tests/snapshot_test.zig` + `framework/tests/scenes.zig` + `framework/tests/fixtures/` | ウィジェットツリーのレイアウト + 描画結果をゴールデン画像と比較 |
| framework 結合テスト | `framework/tests/focus_test.zig` / `framework/tests/theme_test.zig` | ヘッドレス Application + Robot 経由のキーボード / フォーカス操作、テーマ DI の検証（GPU 必要、無ければ skip） |

## 埋め込み単体テスト
Zig 標準の `test "..."` ブロックをソースファイル内に直接書く。`zig build test` がモジュールの root から到達できる全テストを実行する。

GPU や OS リソースを必要としない純粋な計算のテストはここで書くのが望ましい。

```zig
// 例: awt/src/root.zig
test "backend version reports GLFW 3.4" {
    const ver = backendVersion();
    try std.testing.expect(std.mem.indexOf(u8, ver, "3.4") != null);
}
```

`std.testing.allocator` は `DebugAllocator` なので leak を自動検出する。テスト中に確保したメモリは必ず解放すること。

## スナップショットテスト
レンダリング結果は数値で表現できないため、ゴールデン画像との比較で回帰を検出する。
awt 側と framework 側で**同じ機構**を使い、対象が「awt の primitive 直叩き」か「framework のウィジェットツリー」かだけが違う。

### しくみ
1. `scenes.zig` で `Scene` を一つ定義する。シーンは決定的な描画関数と画像サイズを持つ。
2. `snapshot_test.zig` のランナーがオフスクリーンレンダーターゲットを作って描画する。
3. 結果を RGBA8 として CPU に読み戻し、`fixtures/<scene_name>.png` と比較する。
4. 一致したら成功、異なれば `tmp/snapshot_failures/<scene_name>_{actual,diff}.png` を書き出して失敗する。

### awt 側 (`awt/tests/`)
awt の primitive (`fillRect` / `drawString` / `fillCircle` 等) を直接呼んでシーンを組み立てる。
framework は経由しない。描画バックエンド (DX12 / Metal) の出力をそのまま検証するイメージ。

```zig
// awt/tests/scenes.zig
fn paintMyScene(ctx: PaintContext) anyerror!void {
    ctx.g.setColor(awt.Graphics.Color.rgb(1, 0, 0));
    ctx.g.fillRect(.{ .x = 10, .y = 10, .width = 80, .height = 40 });
}

pub const my_scene = Scene{
    .name = "my_scene",
    .width = 200,
    .height = 100,
    .paint = paintMyScene,
};
```

```zig
// awt/tests/snapshot_test.zig
test "snapshot: my_scene" {
    try runScene(scenes.my_scene);
}
```

追加したシーンは `examples/snapshot` でも `zig build run-snapshot -- tmp/out.png my_scene` のように単体で表示できる。

### framework 側 (`framework/tests/`)
framework の `Container` / `Panel` / `Button` / `Label` / `TextField` などを組み合わせてシーンを組む。
レイアウトを走らせてから描画した結果が fixture と比較される。

レイアウトテストと対応するシーンを置いておくと、数値アサートが落ちたときに「画像でどう崩れているか」がそのまま分かる（`box_horizontal_pack.png` ↔ `box_layout_test::"horizontal: 3 fixed-size children pack from the left"` のような対応関係）。

```zig
// framework/tests/scenes.zig
fn paintMyLayout(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.horizontal());

    const red = try coloredLeaf(ctx.allocator, 50, 30, awt.Graphics.Color.rgb(0.9, 0.3, 0.3));
    try setup.container.add(&red.container.component);

    setup.paint();
}

pub const my_layout = Scene{
    .name   = "my_layout",
    .width  = 400,
    .height = 80,
    .paint  = paintMyLayout,
};
```

`scenes.zig` 内に `coloredLeaf` / `Setup` のような小さなヘルパーが既にあるので、新規シーンの実装は数行で済む。

### fixture のライフサイクル
* **初回実行**: fixture が存在しないため、ランナーは現在の描画結果をそのまま fixture として書き込み、テストはパスする。人間が目視確認してから commit する。
* **二回目以降**: fixture と比較する。±1 LSB（チャンネルあたり ±1）の差は許容する。GPU ドライバごとに丸めが異なるため。
* **意図的な変更時**: シーンや描画ロジックを変えた直後はすべての fixture が古いので失敗する。`zig build update-snapshots` で awt / framework 両方の fixture を一括再生成し、`git diff awt/tests/fixtures/ framework/tests/fixtures/` で意図通りの変化か確認してから commit する。

### 失敗時の挙動
`tmp/snapshot_failures/<scene_name>_actual.png` と `tmp/snapshot_failures/<scene_name>_diff.png` の 2 枚が書き出される。

* `_actual.png` は今回の描画結果そのまま
* `_diff.png` はチャンネルごとの絶対差を 5 倍に増幅した画像。一致箇所は黒、不一致箇所は明るく光る

ログに `[snapshot] N channel(s) exceed tolerance ±1 (max diff M)` が出る。`M` が大きければ大きな差、`N` が大きければ広範囲の差を示す。

### 一致のとらえ方
ピクセル完全一致ではなく、チャンネルあたり ±1 を許容する。これは：

* 同一 GPU でも実行ごとに同じ結果を返すべきだが、ドライバが更新されると微小な差が出ることがある
* ハードウェア差（NVIDIA / AMD / Apple Silicon）でも数値が完全一致するとは限らない
* それでも 1 LSB の差は意味のあるレンダリング差ではない（目で見て分からない）

許容差を超えた箇所が 1 つでもあれば失敗。

## framework レイアウトテスト
レイアウトは「コンテナのサイズと子の min / max / grow から子の bounds を計算する純粋な関数」なので、GPU 不要の数値アサーションで検証できる。
レイアウトマネージャ 1 種類につき 1 ファイル（`box_layout_test.zig` / `border_layout_test.zig` ...）を置く方針。
レイアウトを内蔵するウィジェット（`SplitPane` 等）も同じスタイルで 1 ファイル置く（`split_pane_test.zig`。合成マウスイベントによるドラッグ操作の検証もここに含む）。

### 書き方
GPU や font を要求しない `Panel` を固定サイズの leaf として使う（`Panel.create` → `setMinSize` / `setMaxSize` で固定）。これにより `awt.init` も font ロードも不要で、テストが軽くて速い。

```zig
// framework/tests/box_layout_test.zig
fn leaf(allocator: std.mem.Allocator, w: f32, h: f32) !*Panel {
    const p = try Panel.create(allocator);
    p.container.component.setMinSize(.{ .width = w, .height = h });
    p.container.component.setMaxSize(.{ .width = w, .height = h });
    return p;
}

fn expectBounds(c: *const Component, x: f32, y: f32, w: f32, h: f32) !void {
    const b = c.getBounds();
    try std.testing.expectApproxEqAbs(x, b.x, 0.001);
    try std.testing.expectApproxEqAbs(y, b.y, 0.001);
    try std.testing.expectApproxEqAbs(w, b.width, 0.001);
    try std.testing.expectApproxEqAbs(h, b.height, 0.001);
}

test "horizontal: 3 fixed-size children pack from the left" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.horizontal());

    const l1 = try leaf(a, 50, 30);
    const l2 = try leaf(a, 80, 40);
    try root.add(&l1.container.component);
    try root.add(&l2.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 100 });

    try expectBounds(&l1.container.component,  0, 0, 50, 30);
    try expectBounds(&l2.container.component, 50, 0, 80, 40);
}
```

レイアウトのバグはほぼこのレベルの数値アサーションで捕まる。失敗メッセージから「どの子のどの座標が想定とどう違うか」が瞬時に分かるため、スナップショットより診断しやすい。

### スナップショットとの対応
意図的に、数値テストと **同じレイアウト** を framework スナップショットシーンとしても置いている。
たとえば上の "horizontal: 3 fixed-size children pack from the left" は `framework/tests/fixtures/box_horizontal_pack.png` を見れば一目でわかる。
数値だけでは「正しい配置とは何か」が分かりにくいので、レビュー時 / 設計時の補助として画像を併用する形。

## `zig build test` の出力（正常時は Build Summary の 1 行だけ）
全テスト pass のときの出力は `Build Summary: N/N steps succeeded; M/M tests passed` の 1 行だけになる。
**それ以外の行が出ていたら読む価値がある**（本物の失敗か、warn 以上のログ）。合否の基準は**ビルド全体の終了コード**で、`0` なら全テスト pass。

背景: Zig 0.16 のビルドランナーは、`--listen=-` で走らせた test.exe が **stderr に何か出力すると**、終了コード 0 でも
その stderr を `failed command: ...test.exe ...` というラベル付きで晒す（失敗ではなく「stderr を出した exe」の表示）。
以前はデバイス初期化の `[INFO]` ログや apigen 負系テストのパースエラーが正常時にもこのバナーを出していたため、
**正常系のテストは stderr に書かない**規約にした:

* **GPU を使うテストのハーネス**は、device 初期化の前に `awt.setLogCallback` で `quietLog`
  （debug / info を捨て、warn / error は従来形式で stderr に通すコールバック）を設定する。
  設置箇所: `awt/tests/snapshot_test.zig` / `framework/tests/snapshot_test.zig` の `ensureAwt`、
  `focus_test.zig` / `theme_test.zig` の `newApp`（+ `initWithTheme` 直呼びテスト）、`Robot.zig` の単体テスト。
  **新しく device を作るテストを書くときも同様にすること**（コールバックはプロセス全体に効くので、
  ハーネスの入口で 1 回設定すればよい）。
* **apigen の負系テスト**（わざと不正な spec を食わせて `error.SpecParse` を確認するテスト）は、
  `fail()` が `builtin.is_test` のときだけ print を抑止する。CLI 実行時のエラー表示は従来どおり。

info 以下だけを捨てるのは意図的: 完全に黙らせると、テストが本当に失敗したときに dx12 のエラーメッセージまで消えるため。
warn / error が出る = `failed command` バナーが復活する、はそれ自体がシグナルとして機能する。

補足: スナップショット harness は awt を意図的に terminate せずリークさせる（`awt/tests/snapshot_test.zig` の冒頭コメント参照）が、それは**メモリリークであって終了コードは 0**。例（`run-widget_*` 等）の起動時 `[INFO]` ログは従来どおり出る — 黙らせたのはテストハーネス側だけで、log システムの既定挙動（コールバック未設定なら stderr）は変えていない。

## 機能要望
* fuzz テストの導入（テキスト周りなど）
* CI でのスナップショットテスト fixture diff の自動表示
* レイアウトのプロパティテスト（min / max / grow を変化させた時の不変条件チェック）
* インタラクションテスト基盤 — 合成イベント (`postEvent`) → 状態 / 描画 のアサート（TextField のキャレット位置遷移、Slider のドラッグ等を回帰テスト化したい）
