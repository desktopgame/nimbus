---
unsafe: true
---

# padding_layout
余白プリミティブの設計判断・却下案・テスト方針。
`Insets` / `PaddingLayout` の spec は `framework/doc/padding_layout.md`。

## なぜ wrapper 方式（デコレータ LayoutManager）なのか
nimbus は意図的に「余白」の概念を Component に持たせていない。
従来は空の `Panel` / `Container` スペーサ、`Filler`、`align`、`min`/`max` の組み合わせで余白を代用してきたが、
`app_filer` のドッグフーディングで「左パディングのために幅 6 の空 west リージョンを 4 箇所手組みしている」痛点が表面化した。
a11y / snapshotTree / Driver を建てた今、こうした空スペーサは意味ツリーに幽霊ノードとして残り、走査・スナップショットを汚す。

候補は 2 案あった。

* **field 方式**: `Component` に `inset` フィールドを足し、全 `LayoutManager` が配置時にそれを減算する。
* **wrapper 方式（採用）**: 単一の子を inset ぶんずらして配置するデコレータ `LayoutManager` を 1 つ作る。

nimbus の座標は親相対（`Component.absoluteOriginInWindow` が祖先の `position` を合算する）なので、
wrapper 方式なら子を 1 つずらすだけで既存の各 `LayoutManager` を一切改修せずに済む。
field 方式は per-LayoutManager な VTable 分散設計（各レイアウトが独立に doLayout を実装）と相性が悪く、
全マネージャに inset 減算を行き渡らせる改修が要る。これは Swing の「layout が insets を見なければ無視される」のと同じ穴で、見落としが事故になる。
よって wrapper 方式を採る。Flutter の `Padding` / `Container` モデルに相当する。

## ツリーノードが増えることの許容
wrapper 方式は余白 1 箇所につき中間 `Container` が 1 ノード増える。
これは「あちこちに散ったスペーサ」よりは綺麗で、増えるノードは余白の所在と 1:1 に対応する。
将来は `role` を見て走査時に読み飛ばせる余地を残す（spec の機能要望参照）。
散らばった空スペーサを「読み飛ばす」のは所在が定まらず難しいが、PaddingLayout の中間ノードは規則的なので elide しやすい。

## Insets の形（決定）
4 辺を名前付き `f32`（`left` / `top` / `right` / `bottom`、デフォルト 0）で持つ素直な構造体にした。
理由:

* 辺を名前で持てば順序の取り違えが起きない（Swing の `Insets(top, left, bottom, right)` は順序を覚える必要がある）。
* デフォルト 0 なので「左だけ 6」のような部分指定が `.{ .left = 6 }` で書ける。
* 均等・対称は頻出なので `all` / `symmetric` のコンストラクタを用意し、呼び出し側を短く保つ。

`Insets` は `PaddingLayout` モジュールに置き、`Panel` もこれを参照する（余白の量を表す共通プリミティブだから、レイアウト側に置くのが自然）。

## LayoutManager の所有（決定・既存規約の更新）
`PaddingLayout` は nimbus で初めて「インスタンス確保が要る `LayoutManager`」になる。
従来の `BoxLayout` / `BorderLayout` は状態を持たない const シングルトンで、解放は不要だった。
`container.md` は従来「古い LayoutManager の解放は呼び出し側の責務」と書いていたが、確保するレイアウトが存在しなかったため実質空文だった。

ここで所有モデルを 2 案で比較した。

* **呼び出し側所有**: 利用者が確保し、`Container` 破棄後に自分で解放する。
* **Container 所有（採用）**: `LayoutManager.VTable.deinit` を持つレイアウトは、差された `Container` がその寿命を持つ。
  `Container.deinit` が現行レイアウトを、`setLayout` が差し替え前の（別物かつ `deinit` を持つ）レイアウトを解放する。

採用理由:

* nimbus の所有哲学（コンテナーは子の寿命に責任を持つ。`hint_destroy` も同様に Container が肩代わり）と一致する。
* `VTable.deinit` フックは元々この目的で存在していたが、誰も呼んでおらず dead だった。Container に配線して初めて生きる。
* 呼び出し側所有は「Container を壊したあとにレイアウトを別途解放する」という、保持し忘れやすい後片付けを利用者に強いる。

const シングルトン（`deinit = null`）は決して解放されず、複数 Container で共有してよい（従来どおり）。
確保したレイアウト（`deinit != null`）は差した 1 つの Container が専有する。
同じ確保済みインスタンスを複数 Container に差すと二重解放になる（`hint` の所有と同じ制約）。

この決定により `container.md` の `setLayout` / `destroy` 節と `layout.md` の `deinit` 節を更新した。

## テスト方針
`Application` / GPU 非依存の純ロジックテスト。`Container.create` と `Component.init` の手組みで常時走らせる。

* 配置: 既知の `min_size` を持つ子を 1 個入れ、`Container` に bounds を与えて `doLayout()` を呼ぶ。
  子の bounds が `(left, top, W - left - right, H - top - bottom)` に一致することを確認する。
* computeMinSize / computeMaxSize: 子 min/max に `(horizontalTotal, verticalTotal)` を加えた値になることを確認する。
  子 0 個のとき `insets` ぶんだけになることも確認する。
* 解放: 確保した `PaddingLayout` を差した `Container` を破棄したとき、`deinit` が 1 回呼ばれて二重解放・リークが無いこと
  （`std.testing.allocator` がリークを検出する）。
