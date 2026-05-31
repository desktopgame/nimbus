# layout-design
レイアウトの設計方針について。
[layout-requirements](doc/layout-requirements.md) から導かれた設計方針です。

## コンポーネントごとに保持する属性

### MinimumSize
これ以下のサイズにはならない。
このサイズを下回ったら見た目が破綻する。

### MaximumSize
これより大きいサイズにはならない。
ハード上限であり、`GrowX` / `GrowY` で余白を食ってもこの値を超えることはない。

### GrowX
ボックスなどにサイズ分配されるとき、どれだけ余白を食うか。
余白を食った結果 `MaximumSize` を超えることはない。

### GrowY
ボックスなどにサイズ分配されるとき、どれだけ余白を食うか。
余白を食った結果 `MaximumSize` を超えることはない。

### SizeQuery（オプショナル）
「ある幅を与えられたときの最小高さ」を答えるための関数を持つ optional 構造体。
折り返しテキスト（`TextArea` wrap モード、将来の wrap `Label` 等）のように **高さが幅の関数になる** widget だけがセットする。
親レイアウトは widget の `size_query` が non-null なら `minHeightForWidth(component, w)` を呼んで「その幅での最小高さ」を pure query で取得できる。`size_query` が null なら従来通り `MinimumSize.height` だけを見ればよい。

呼び出し規約として **pure query**：同じ widget 状態と同じ `w` に対して同じ値を返し、widget の観測可能な状態（`MinimumSize` 等）を書き換えない。内部キャッシュの更新は許される。

幅依存高さの古典問題（Swing の HTML JLabel が抱える 2 パスレイアウト問題、Qt の `heightForWidth` が解いている問題、GTK の `for_size` 引数が解いている問題）を、 親レイアウトが必要に応じて opt-in で問い合わせる形で解消する。
詳細は `framework/doc/component.md`「SizeQuery」、 利用例は `framework/doc/scrollpane.md`「ビューの height-for-width クエリ」を参照。

## レイアウトヒント
コンテナーは子コンポーネントの一覧ではなく、レイアウトヒントの一覧を保持する。
以下は実装イメージ。（疑似言語）

```
struct Container:
- children []LayoutHint
```

```
struct LayoutHint:
- component Component
- hint any
```

`hint` は親コンテナーのレイアウトマネージャ固有のデータを格納する。
たとえば `BorderLayout` であれば `NORTH` / `SOUTH` などの方向を表す enum、`GridBagLayout` のような複雑なものであれば独自の制約構造体を入れる。
フレームワーク自体は中身を解釈しない。
解釈はレイアウトマネージャの責務である。

## レイアウトマネージャのインターフェイス

```zig
pub const LayoutManager = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        /// `container` の現在のサイズと各子のヒントから、各子の bounds を決定して
        /// `child.setBounds(...)` を呼ぶ。直接の子だけを扱う。
        doLayout: *const fn (*LayoutManager, *Container) void,

        /// このレイアウトでコンテナーが取りうる最小サイズ。
        /// 子の MinimumSize 群と自身のアルゴリズムから導く。
        computeMinSize: *const fn (*LayoutManager, *const Container) Size,

        /// このレイアウトでコンテナーが取りうる最大サイズ。
        /// 無制限の場合は両軸に `std.math.inf(f32)` を入れる。
        computeMaxSize: *const fn (*LayoutManager, *const Container) Size,

        /// オプショナル。LayoutManager 自身がメモリを保持するなら解放する。
        deinit: ?*const fn (*LayoutManager, std.mem.Allocator) void = null,
    };
};
```

### doLayout
コンテナーの**直接の子**のみに対して bounds を設定する。
孫以下への再帰はコンテナー側の責務であり、レイアウトマネージャは関知しない。

### computeMinSize / computeMaxSize
コンテナー自身が別のコンテナーにネストされている場合、親側のレイアウトはこのコンテナーの min/max を知る必要がある。
そのためのクエリ。
純粋な計算関数として扱うため `*const Container` で受ける。
内部キャッシュを持ちたい場合は別途 dirty 管理を入れる。

無限の最大サイズは `std.math.inf(f32)` をそのまま入れる。
`f32` で座標を管理する方針と整合する。

### deinit
レイアウトマネージャがアロケート済みの内部状態を持つ場合のみ実装する。
シングルトンの const インスタンスとして提供される標準レイアウトマネージャ（`BoxLayout.horizontal`, `BorderLayout` など）では不要。

## コンテナーとの連携

### MinimumSize / MaximumSize の委譲
コンテナーは leaf widget と同じ `getMinSize()` / `getMaxSize()` のインターフェイスを持つが、内部では layout に問い合わせて返す。
利用者やレイアウトマネージャは leaf かコンテナーかを区別せずに min/max を取得できる。

```zig
pub fn getMinSize(self: *const Container) Size {
    const lm_min = if (self.layout) |lm|
        lm.vtable.computeMinSize(lm, self)
    else
        .{ .width = 0, .height = 0 };
    // コンテナー自身に明示的な下限が設定されていればそれと合成する
    return .{
        .width  = @max(self.component.min_size.width,  lm_min.width),
        .height = @max(self.component.min_size.height, lm_min.height),
    };
}
```

### setBounds は自動で doLayout を呼ぶ
コンテナーは自身の bounds が変更された時点で再レイアウトする。
Swing の手動 `validate` のような呼び出しは不要。

```zig
pub fn setBounds(self: *Container, bounds: Rect) void {
    self.component.setBounds(bounds);
    self.doLayout();
}
```

### 再帰はコンテナーが行う
レイアウトマネージャは直接の子のみを扱い、その子が更にコンテナーであった場合の再帰は呼び出し側のコンテナーが担当する。

```zig
pub fn doLayout(self: *Container) void {
    if (self.layout) |lm| lm.vtable.doLayout(lm, self);
    for (self.children.items) |elem| {
        if (elem.component.container) |child_c| child_c.doLayout();
    }
}
```

## 子の分配アルゴリズム
余白の分配は **1-pass clamp** で実装する。

1. すべての子の MinimumSize を合計する
2. コンテナーの利用可能サイズから合計 min を引く（= 余白）
3. 余白を `GrowX` / `GrowY` の重みに従って一括で配分する
4. 配分の結果が MaximumSize を超える子はそこでクランプする
5. クランプの結果生じた余りは隙間として残す（再分配しない）

幅依存高さの子（`SizeQuery` を持つ widget）を縦に並べたい場合、 ステップ 1 の「子の min を集める」段階で `child.size_query.minHeightForWidth(child, allocated_width)` を聞いて高さを取得する形に拡張できる。
ただし `allocated_width` は分配の結果決まるので、 横方向と縦方向の確定順序を整理する必要がある。
組み込みの `BoxLayout` / `BorderLayout` は v1 ではこの拡張を入れておらず（= 折り返し子は `ScrollPane` 経由でしか height-for-width が機能しない）、 将来必要になった時点で追加する余地として残してある。

「クランプ後の再分配」は CSS flexbox 風に実装することもできるが、初版では採用しない。
理由は実装の単純さと挙動の予測しやすさ。
利用者が余白を確実に埋めたい場合は **Filler**（`min = 0, max = inf, grow = 1` の何も描画しない component）を末尾や先頭に置く運用とする。

Filler は次の用途を一つで担う。

* ボックスの末尾余白の吸収
* 左寄せ / 右寄せ / 中央寄せ（Filler を Content の片側または両側に置く）

## レイアウトと描画の更新タイミング
**Invalidation ベース**で扱う。
毎フレーム再レイアウト / 再描画はしない。
イベントが来てかつ dirty フラグが立っているときだけ計算が走る。

Frame は 2 つのフラグを持つ。

```zig
pub const Frame = struct {
    root: *Container,
    layout_dirty: bool = true,
    paint_dirty:  bool = true,
    // ...
};
```

### dirty を立てる側
setter 系のメソッドが対応するフラグを立て、Frame まで伝搬する。

| 操作 | layout_dirty | paint_dirty |
|---|---|---|
| `Label.setText` | ○（文字幅 = min が変わる） | ○ |
| `Component.setMinSize` / `setMaxSize` / `setGrow*` | ○ | ○ |
| `Component.setColor` 等の見た目のみ変化 | × | ○ |
| `Container.add` / `remove` | ○ | ○ |
| Window resize | ○ | ○ |
| マウス hover で見た目変化なし | × | × |

`layout_dirty = true` を立てる場合は同時に `paint_dirty = true` も立てる。
レイアウト変更は描画変更を含意するため。

### イベントループの構造

```zig
while (!frame.shouldClose()) {
    awt.waitEvents();                  // イベントが来るまでブロック
    if (frame.layout_dirty) {
        frame.root.doLayout();
        frame.layout_dirty = false;
    }
    if (frame.paint_dirty) {
        renderFrame(frame);
        frame.paint_dirty = false;
    }
}
```

`pollEvents` ではなく `waitEvents` を使う。
イベントがないアイドル時には CPU 消費は 0 になる。

### dirty の粒度
初版では Frame 単位で 1 個ずつ持つ。
「どの component が dirty か」までは追わない。
描画は全画面再描画になるが、コンテナーが Frame 単一の dirty を立てた瞬間に paint を走らせるという挙動上、毎フレーム発火することはない。

将来 component 粒度の dirty + dirty rect スタイルの部分再描画に切り替えたくなったときも、レイアウトマネージャの interface は変更不要。
invalidation の判定と描画範囲制御は呼び出し側（Frame / Container）の責務であり、レイアウトマネージャから見えない。

## カスタムレイアウトの拡張ポイント
レイアウトマネージャと hint は利用者が独自実装できる。
コアでサポートしない概念（Swing の `preferredSize` 相当など）を必要とする利用者は、wrap container を一段挟んで独自レイアウトを書くことで実現できる。

例: 子を 1 個だけ持つ前提で、hint に `PreferredSize` 構造体を受け取り、利用可能領域に応じて min と preferred の間に clamp するレイアウト。

```zig
const PreferredSize = struct { width: f32, height: f32 };

const PreferredSizeLayout = struct {
    pub fn doLayout(self: *LayoutManager, container: *Container) void {
        // hint に PreferredSize が入っていれば clamp の上限として使用、
        // 入っていなければ min のまま貼り付ける
        ...
    }
    // computeMinSize / computeMaxSize も同様にこのレイアウトの方針で実装する
};
```

hint の所有モデルは `LayoutHint.hint_destroy` で表現する。詳細は `framework/doc/container.md` を参照。

## 機能要望
* 宣言的レイアウト API（手続き型レイアウトをラップした DSL 風 API）
* 部分再描画（component 粒度の dirty / dirty rect）
* MinimumSize / MaximumSize が矛盾するケースの静的または動的検出
