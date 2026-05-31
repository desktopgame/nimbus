# optimize
レイアウトエンジンの性能に関する観察と将来プラン。
2026-05-24 の棚卸しで挙がった項目をまとめる。

現状の方針は「正しさ優先・最低限のキャッシュ」(`Container.min_cache` / `max_cache` のみ。 部分再レイアウトはまだ) で、UI ツリーが浅い間は問題にならない。
このドキュメントは、ツリーが深くなった／大きくなったときに効いてくる箇所を先に可視化し、
実装に着手するときの設計のたたき台を残すことが目的。

---

## 済: 子コンテナーの二重レイアウト (2026-05-24 修正、 2026-05-31 構造的に解消)

### 症状 (履歴)
`Container.doLayout` は末尾で全子コンテナーへ再帰する (`framework/src/Container.zig`)。
かつての `Container.setBounds` は内部で `doLayout` を即時に走らせていたため、
`BoxLayout` / `BorderLayout` が子コンテナーに対して `Container.setBounds` を呼ぶと、
子コンテナーが「setBounds 経由」と「親の末尾再帰」で 2 回レイアウトされ、
ネストの深さ k に対して 2^k 回のレイアウトに膨らんでいた。

### 初期対応 (2026-05-24)
`LayoutManager` の実装規約として「**子にバウンズを与えるとき必ず `Component.setBounds` を使う**、
`Container.setBounds` は使わない」を導入。 サブツリーへの再帰は `Container.doLayout` が一手に担う、
というのが唯一の所有者、という運用に落とした。

### 構造的解消 (2026-05-31)
`Container.setBounds` から `doLayout` の呼び出しを取り除いた。 これにより:

* `Container.setBounds` と `Component.setBounds` は意味的に等価 (どちらを呼んでも footgun にならない)
* `LayoutManager` 実装の「どちらの `setBounds` を使うか」という規約は **不要** になった
* `doLayout` 起動の唯一の起点は `Window.redraw` が明示的に呼ぶ `root.container.doLayout()` のみ
* 副次効果として、 `Window` に `in_redraw` フラグを足し、 doLayout cascade 中の `setBounds` 経由
  `markLayoutDirty` が無駄な `awt.postEmptyEvent` を呼ばないようにした (= 1 フレーム内の
  wake-up call が大量に発火しないようになった)

`ScrollPane` はこの規約に最初から従っていた (`framework/src/ScrollPane.zig` の viewport 配置コメント参照)。
現在はその縛りがそもそも無いので、 `ScrollPane` のコメントも自由化できる (が、 明示的に
`Component.setBounds` を使っているだけで害はないのでそのまま)。

---

## 済: min/max サイズのキャッシュ (2026-05-24 実装済み)

### 実装
`Container` に `min_cache` / `max_cache` (`?Component.Size`, デフォルト null) を追加し、
`getMinSize` / `getMaxSize` が `computeMinSize` / `computeMaxSize` の結果をメモ化する。
公開シグネチャは不変 — `*const Container` のまま `@constCast` でメモを書く
(メモは不変サブツリーの純関数なので論理的に const、Container 実体は可変なので安全)。
無効化は `Component.markDirty` の root への遡上経路に差し込み、通過するコンテナーの
キャッシュを null にする。これは「変更ノードの祖先 = サブツリー計測が変わり得るコンテナー」と一致する。
葉の min は従来どおり都度読む (キャッシュ対象は Container の computeMinSize のみ) ので葉の stale は起きない。

正しさの前提: min/max を変える変更は必ず `markLayoutDirty` を通る。
現状の全ウィジェット (Label/Button/TextField/Slider/CheckBox/ComboBox) はこれを満たす
(直接代入は init/applyMetrics 内で、公開セッターは後で markLayoutDirty を撃つ)。
新しい葉ウィジェットを足すときもこの規約を守ること。

### 計測 (widget_layoutcost)
| tree | nodes | before | after | 倍率 |
|---|---|---|---|---|
| depth 6 | 1,093 | 755 µs | 107 µs | 7.1× |
| depth 9 | 29,524 | 29,697 µs | 3,199 µs | 9.3× |
| depth 10 | 88,573 | 108,799 µs | 14,665 µs | 7.4× |

深いほど効く (除去した冗長計測が O(depth) だったため)。1 パス内で各ノードの
computeMinSize/MaxSize がちょうど 1 回になり、測定全体が O(n×depth) → O(n) になった。
なお `setBounds` 由来の moved 無効化は毎回 root まで遡上するが、レイアウトは top-down で
「子を読んでから子の bounds を確定」する順序なので、子のキャッシュは読んだ後にしか無効化されず
ヒット率は保たれる (祖先のキャッシュだけが落ちる)。

### 次のボトルネック候補
キャッシュで測定が O(n) になった結果、`setBounds` ごとに走る `markDirty` の root 遡上
(O(depth) × ノード数 = O(n×depth)) が相対的に効いてくるはず。これは次項「部分再レイアウト」の
dirty 管理を入れ替えるときに一緒に解消できる見込み。

### 残課題 / スコープ外
* インクリメンタルな部分測定 (変わった子だけ測り直す) は未対応。次項「部分再レイアウト」と合わせて検討する。
* 短期の妥協案だった「pass1 の結果をスクラッチ配列に蓄えて pass2 で再利用」は、
  キャッシュ本体が入ったので不要になった (pass2 はキャッシュヒットで O(1))。

---

## 未: 部分再レイアウト (dirty subtree)

### 観察
`markLayoutDirty` は常にルートまで歩いて `Window.layout_dirty`(bool) を立てる
(`framework/src/Component.zig`, `framework/src/Window.zig`)。
どこか 1 つが汚れると、次の `redraw` でルートコンテナーから全ツリーを再レイアウトする。

### やりたいこと
汚れたコンテナーをサブツリー単位で記録し、サイズに変化がなければそのサブツリーだけ再レイアウトする。

### 設計の論点
* どこを「再レイアウトの起点」にするか。
  子のサイズ要求が変わらなければ親の配置は不変なので、起点は「サイズ要求が変わった最上位ノード」になる。
  これは前項のサイズキャッシュ無効化が「どこまで伝播したか」と一致する — 2 つはセットで設計する。
* `Window` 側のフラグを単一 bool から「再レイアウト起点リスト」へ拡張するか、
  各 `Container` に dirty フラグを持たせてルートが起点を辿るか、の 2 案がある。
* モーダル/オーバーレイ (`Window.overlays`) やメニューバーは別ルート扱いなので、起点集合に含める設計が要る。

### 制約 / 非機能要件
* 単一 UI スレッド前提 (CLAUDE.md「スレッドモデル」) なので、無効化と再レイアウトの間に並行性の考慮は不要。
* 正しさ優先。部分再レイアウトが全再レイアウトと異なる結果を出してはならない。
  導入時は「全再レイアウト結果との一致」をテストで担保する。

### スコープ外
* 描画の部分更新 (dirty rect 単位の再描画) はレイアウトとは別軸。
  `Window` は現状 `paint_dirty` も bool で画面全体を塗り直しており、これも将来の課題だがこのドキュメントの対象外。

---

## 優先順位の提案
1. ~~短期スクラッチ再利用~~ — サイズキャッシュで吸収済み。不要。
2. ~~サイズキャッシュ + 無効化~~ — **実装済み (2026-05-24)。6〜9× 改善を確認。**
3. **部分再レイアウト** — 残る最大項目。`markDirty` の root 遡上 (O(n×depth)) もここで一緒に解消できる見込み。
   アーキテクチャ判断を伴うので、ベンチで必要性が見えてから着手する。

計測は `examples/widget_layoutcost` を使う (深いネスト・多子のシーンを構築し、強制再レイアウトの所要時間を表示)。
新しい最適化を入れる前後でこのサンプルの per-relayout を比較し、効果を数値で確認すること。
