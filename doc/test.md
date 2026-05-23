# test
nimbus のテストの種類と典型的な書き方についてのドキュメント。
`zig build test` で以下すべてが一括で走る。

## テストの種類
| 種別 | 配置 | 用途 |
|---|---|---|
| 埋め込み単体テスト | `awt/src/**/*.zig` / `framework/src/**/*.zig` 内の `test "..."` ブロック | モジュール内のロジック単体検証 |
| スナップショットテスト | `awt/tests/snapshot_test.zig` と `awt/tests/scenes.zig` | レンダリングの結果画像をゴールデン画像と比較する回帰テスト |
| framework レイアウトテスト（予定） | `framework/tests/layout_test.zig` （未実装） | レイアウトマネージャの数値検証 |
| framework スナップショットテスト（予定） | `awt/tests/scenes.zig` に framework シーンを追加 | ウィジェットの実描画結果の回帰テスト |

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

### しくみ
1. `awt/tests/scenes.zig` で `Scene` を一つ定義する。シーンは決定的な描画関数と画像サイズを持つ。
2. `awt/tests/snapshot_test.zig` のランナーがオフスクリーンレンダーターゲットを作って描画する。
3. 結果を RGBA8 として CPU に読み戻し、`awt/tests/fixtures/<scene_name>.png` と比較する。
4. 一致したら成功、異なれば `tmp/snapshot_failures/<scene_name>_{actual,diff}.png` を書き出して失敗する。

### シーンを追加する
`awt/tests/scenes.zig` に `Scene` を追加し、`all` に登録する。

```zig
fn paintMyScene(g: *awt.Graphics) void {
    g.setColor(awt.Graphics.Color.rgb(1, 0, 0));
    g.fillRect(.{ .x = 10, .y = 10, .width = 80, .height = 40 });
}

pub const my_scene = Scene{
    .name = "my_scene",
    .width = 200,
    .height = 100,
    .paint = paintMyScene,
};

pub const all = [_]Scene{
    basic_shapes,
    my_scene,           // ← 追加
};
```

`snapshot_test.zig` の `test "snapshot: ..."` ブロックを 1 つ追加する。

```zig
test "snapshot: my_scene" {
    try runScene(scenes.my_scene);
}
```

これだけで、人間が目視確認しつつ視覚的な回帰検出のループに乗る。
追加したシーンは `examples/snapshot` でも `zig build run-snapshot -- tmp/out.png my_scene` のように単体で表示できる。

### fixture のライフサイクル
* **初回実行**: fixture が存在しないため、ランナーは現在の描画結果をそのまま fixture として書き込み、テストはパスする。人間が目視確認してから commit する。
* **二回目以降**: fixture と比較する。±1 LSB（チャンネルあたり ±1）の差は許容する。GPU ドライバごとに丸めが異なるため。
* **意図的な変更時**: シーンや描画ロジックを変えた直後はすべての fixture が古いので失敗する。`zig build update-snapshots` で再生成し、`git diff awt/tests/fixtures/` で意図通りの変化か確認してから commit する。

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

## framework レイアウトテスト（予定）
`Frame` / `Application` / レイアウトマネージャが入った後に書く予定。
レイアウトはコンテナのサイズと子の preferred size から子の bounds を計算する純粋な関数のはずなので、GPU 不要の数値アサーションでテストできる。

```zig
// framework/tests/layout_test.zig (予定)
test "BoxLayout vertical: 等分割" {
    var container = Container.init(allocator);
    defer container.deinit();
    container.setLayout(BoxLayout.vertical());

    // 子を 3 つ追加
    const a = try Label.create(allocator, "a", font, color);
    const b = try Label.create(allocator, "b", font, color);
    const c = try Label.create(allocator, "c", font, color);
    try container.add(&a.component);
    try container.add(&b.component);
    try container.add(&c.component);

    container.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 60 });
    container.doLayout();

    try expectEqual(Rect{ .x = 0, .y = 0,  .width = 100, .height = 20 }, a.component.getBounds());
    try expectEqual(Rect{ .x = 0, .y = 20, .width = 100, .height = 20 }, b.component.getBounds());
    try expectEqual(Rect{ .x = 0, .y = 40, .width = 100, .height = 20 }, c.component.getBounds());
}
```

レイアウトのバグはほぼこのレベルの数値アサーションで捕まる。失敗メッセージから「どの子のどの座標が想定とどう違うか」が瞬時に分かるため、スナップショットより診断しやすい。

## framework スナップショットテスト（予定）
レイアウト + 描画 + テキスト計測 + クリッピングが絡む結合バグや、ルックアンドフィールに依存する見た目の回帰は、数値アサーションでは捉えにくい。これは既存の `awt/tests/scenes.zig` に framework シーンを追加する形で対応する予定。

たとえばシーン関数を framework 経由の形に拡張する。

```zig
// awt/tests/scenes.zig (将来の拡張案)
pub const Scene = union(enum) {
    raw: struct {
        name: []const u8,
        width: i32,
        height: i32,
        paint: *const fn (g: *awt.Graphics) void,
    },
    framework: struct {
        name: []const u8,
        width: i32,
        height: i32,
        build: *const fn (allocator) anyerror!*Container,
    },
};
```

ランナーは `framework` シーンの場合、`build` で得た `Container` の bounds を画像サイズに設定してレイアウトを走らせ、そのまま `Component.paintAt(g)` でオフスクリーンに描画する。残りの fixture 比較ロジックは raw シーンと完全に共通でよい。

利点は 2 つ。スナップショットテスト基盤がそのまま使いまわせること、そして framework 経由の見た目が `examples/snapshot` で確認できるようになること。

## 機能要望
* fuzz テストの導入（テキスト周りなど）
* CI でのスナップショットテスト fixture diff の自動表示
* レイアウトのプロパティテスト（preferred size を制約変化させた時の不変条件チェック）
