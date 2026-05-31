---
unsafe: true
---

# scrollpane
ScrollPane の構成・サイズ決定とビューの契約・イベント処理・寿命管理。

## 構成
`ScrollPane` は自前 vtable を持つ複合コンポーネントで、 3 つの領域を抱える:

```
+-----------------------------+--+
| viewport (center)           |vb|  vb = 垂直 ScrollBar (east gutter)
|   └ view (offset 配置)       |ar|
|                             |  |
+-----------------------------+--+
| hbar (south gutter)         |  |  hbar = 水平 ScrollBar
+-----------------------------+--+
                              corner (小さな filler)
```

* `viewport` / `hbar` / `vbar` は**互いに重ならない矩形**を占める。 これにより `ScrollPane` のイベント配送は領域ごとにきれいに分かれ、 はみ出したビューへの誤クリックは起きない (重なりを避けるために viewport を独立させている)。
* バーは `as_needed` のとき必要な軸だけ表示する。 非表示の軸では gutter を畳んで viewport がその分広がる。
* スクロールの単一の真実は **バーの `BoundedRangeModel`**。 ホイールやプログラム設定はバーの `value` を更新し、 その `ChangeListener` で `viewport` 内のビュー位置 (`view.position = {-h.value, -v.value}`) を更新して repaint する。

メニュー系のようなオーバーレイ / dismiss / 専用 dispatch は一切使わない。 `ScrollBar` も `viewport` も通常のコンポーネントツリーの一部である。

## サイズ決定とビューの契約
レイアウト時、 軸ごとにビューのサイズを次のように決める:

* `view.scrollable` が `null` (既定): その軸は **ビューの自然サイズ** (`effectiveMinSize`) を使う。 自然サイズ > ビューポートならスクロールバーを出す。 自然サイズがビューポート以下ならビューをビューポートいっぱいに広げる (`max(自然, ビューポート)`)。
* `scrollable.tracks_viewport_width = true`: ビューの**幅をビューポート内幅に固定**し、 その軸はスクロールしない。
* `scrollable.tracks_viewport_height = true` も同様 (縦方向)。

### height-for-width の扱い (TextArea 折り返しのための前提)
折り返すビュー (`TextArea` wrap モード等) では、 高さが幅に依存する。
そこで ScrollPane は **「幅を決めてからビューの高さを聞く」** 順序でレイアウトする:

1. ビューの幅を確定する (追従ならビューポート内幅、 でなければ `max(自然幅, ビューポート幅)`)。
2. ビューに `SizeQuery.minHeightForWidth(w)` を呼んで、 その幅での最小高さを取得する。
3. 取得した高さで垂直スクロール範囲を決め、 ビューに `setBounds` で位置とサイズを与える。

このときビュー側に課す契約は **「`size_query` が non-null なら、 `minHeightForWidth(w)` は与えられた幅 `w` でその瞬間に必要な最小高さを返す pure query であること」** (`component.md`「SizeQuery」参照)。
ビュー自身の `min_size` を書き換えてはならず、 同じ `w` を渡せば常に同じ値を返す (内部 cache の更新は許される)。
通常の (折り返さない) ビューはサイズが幅に依存しないので、 `size_query` は null のままでよい。 ScrollPane は `effectiveMinSize` をそのまま使う。

これにより `TextArea` の 2 モードが**公開 API を変えずに**載る:

| `TextArea` モード | 宣言 | 挙動 |
|---|---|---|
| 折り返しなし (overflow) | `scrollable = null` | 最長行の自然幅 → 水平にもスクロール (既定パス) |
| 折り返しあり (wrap) | `scrollable.tracks_viewport_width = true` | 幅をビューポートに固定 → 折り返して高さが伸びる → 垂直のみスクロール |

### スクロールバー表示の相互作用
垂直バーを出すと内幅が減り、 折り返しや横はみ出しが変わって水平バーの要否が変わる、 という相互依存がある。
これは「ポリシーから仮定して数パス回す」形で収束させる (アルゴリズム詳細はソースコメント領分)。

## イベント処理
* `viewport` 上のホイール (`.scroll`) → 縦は `vbar`、 `Shift` 併用で横は `hbar` の `value` を `unit_increment` 分動かす。
* `hbar` / `vbar` 上の操作 → 各 `ScrollBar` が処理 (ドラッグ / トラッククリック、 `scroll_bar.md` 参照)。
* それ以外 → `viewport` 経由でビューに配送 (`Container` の門番 + オフセット位置で自動的に正しく当たる)。

## レイアウト (ScrollPane 自身のサイズ)
`ScrollPane` の `min_size` は**コンテンツの大きさに依存しない** (依存させるとスクロールの意味が無い)。
初版では小さめの既定推奨サイズを返し、 利用者が `setGrowX/Y` やレイアウトで広げて使う想定。
`BorderLayout.center` に置く、 あるいは `setGrowX(1)` + `setGrowY(1)` で領域いっぱいに広げるのが典型。

## ScrollController の設置
`ScrollPane` は生成時に `Component.ScrollController` プロパティを **`viewport` のコンポーネント** に install する (`component.md`「スクロール連携」参照)。
`viewport` はビューの親なので、 ビューが `enclosingScrollController` で親方向にたどると最初にこれが見つかる。
コールバックは `scrollRectToVisible` へ委譲する。
これにより `TextArea` のようなビューが、 `ScrollPane` への直接依存なしにキャレット追従を実現できる。

## 寿命
`ScrollPane` は `view` / `hbar` / `vbar` / 内部 `viewport` をすべて所有し、 `destroy` で再帰的に解放する。
`view` は `viewport` の子として登録されるので、 `viewport.deinit` (= `Container.deinit`) が `view` の `destroy` を呼ぶ。
利用者は `view` を別途解放してはならない (所有権は ScrollPane に移っている)。
