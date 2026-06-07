# layout-helpers（計画）
固定サイズ・spacing・余白（inset 相当）の**便利ユーティリティ**を、レイアウトの**上の層**に足す計画。
**未着手。** プリミティブは増やさない方針で、冗長さが実際に効いてきたら足す（先回りでは作らない）。

## 背景と立場
nimbus は意図して `preferredSize` を捨て、`Insets` のようなプリミティブも持たない（`CLAUDE.md` の最小プリミティブ方針）。
その結果、よくある用途がやや冗長になる:

* 固定サイズ: `setMinSize` と `setMaxSize` を同じ値にする（min==max）。
* 余白 / spacing: 空の `Panel` や `app.filler()` を挟む（`widget_textfield` は `vSpacer`/`hSpacer` を自作）。

examples のブラインドレビューはこれを「一級 API が無い穴」と指摘したが、**これは穴ではなく意図した設計**。
少ないプリミティブで合成できている方が良く、プリミティブを増やさずに済んでいる。
冗長さの解消は**上の便利層にユーティリティを足すだけ**でよい。プリミティブ層には触れない。

判断の軸（重要）:

* **新プリミティブ**（Component / 各 LayoutManager が新しく解釈する概念）は足さない。
* **既存プリミティブの糖衣**や**コンテナ合成を組み立てるヘルパ**は、上の層なら足してよい（レイアウト概念は増えない）。

## 候補（足すとしたらこの形）
いずれも上の層（`Application` ファクトリ or 自由関数）に置く。レイアウトマネージャや `Component` のプリミティブは変えない。

* **固定サイズの糖衣**
  ```zig
  // sugar over setMinSize + setMaxSize (min == max). No layout-manager change.
  pub fn setFixedSize(self: *Component, w: f32, h: f32) void;
  ```
  「ピン留め」を 1 行にするだけ。新しいレイアウト概念はゼロ。

* **spacer / strut**
  `app.filler()` の路線を広げ、固定サイズの空コンポーネントを簡単に出す helper。
  例: `app.spacer(size)` や BoxLayout 用の strut/glue 相当。

* **余白（inset 相当）= コンテナ合成のヘルパ**
  `Insets` をプリミティブにはしない。代わりに「子を余白付きコンテナで包む」合成を組み立てる helper を上の層に置く。
  例: `app.padded(child, .{ .top = 8, .left = 8, ... })` が、内部で filler 余白を持つ `Panel` を作って返す。
  利用者から見れば 1 呼び出し、内部は既存のコンテナ合成。

## 却下（プリミティブとしては入れない）
* `Component.setPreferredSize` — 捨てた概念を戻すことになる。
* `Component.insets`（各 LayoutManager が解釈する余白プロパティ）— 全レイアウトマネージャに inset 解釈の義務を負わせ、コンテナ合成より複雑になる。

## 正直なコスト（API でなく性能の話）
余白をコンテナ合成で実現すると、margin 1 個ごとに +1 コンテナ（＋filler 子）になり、深い / 多 margin な UI ではノード数が増える。
ただし nimbus はもともと深いツリー向けに min/max キャッシュ等で手当て済み（`doc/internal/optimize.md`）なので通常 UI では許容範囲。
もし将来効いてきても、それは**性能の最適化の話であって API の話ではない**。

## ステータス
未着手。**冗長さが実際に痛くなってから足す**（`feedback` の lightweight 方針: 先回りで便利 API を量産しない）。
記録の目的は、足すときに「便利層に足す・プリミティブは増やさない」という判断を再び議論し直さないため。
関連: API 安定化のブラインドレビュー指摘 #5、`doc/internal/typed_callbacks.md`（同じく「上の層に薄く足す」系の計画）。
