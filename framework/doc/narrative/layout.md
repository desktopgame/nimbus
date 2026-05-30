---
unsafe: true
---

# layout
LayoutElement / hint の所有モデルと、LayoutManager の構造・Container との連携。

## LayoutElement
Container は子コンポーネントを `*Component` のリストとして直接保持せず、`LayoutElement` のリストとして保持する。

* `component` は子コンポーネント本体
* `hint` は親コンテナーの LayoutManager が解釈するためのデータ。型は LayoutManager 側が決める。フレームワーク自身は中身を解釈しない
* `hint_destroy` は hint が動的にアロケートされている場合の解放関数

## hint の型は LayoutManager に依存する
LayoutManager ごとに hint の型は異なる。

| LayoutManager | hint の型の例 |
|---|---|
| BoxLayout | なし（常に null） |
| BorderLayout | `BorderRegion` enum（NORTH / SOUTH / EAST / WEST / CENTER） |
| GridBagLayout | 独自の `GridBagConstraints` 構造体 |

LayoutManager 実装側は hint を `@ptrCast(@alignCast(...))` で自前の型に戻して読む。
他の LayoutManager 用に書かれた hint を別の LayoutManager に渡すと UB になる。

## hint の所有モデル
opt-in destroy hook 方式。

* `hint_destroy = null`（デフォルト）: caller 所有。スタック変数や const のポインタを渡す。framework は hint に触らない
* `hint_destroy = fn` を渡せば、Container の remove / destroy で自動的に hint の解放を行う

## LayoutManager の構造
コンテナーが子の bounds を計算する責務をカプセル化したオブジェクト。
Component の VTable と同じく per-instance VTable パターンで実装する。
標準レイアウトマネージャは const シングルトンとして提供されることを想定している。

## Container との連携
Container は内部に `layout: ?*LayoutManager` を持ち、以下のように LayoutManager に処理を委譲する。
詳細は `container.md` を参照。

* `container.getMinSize()` → `layout.computeMinSize(container)` を呼ぶ（layout が null なら 0）
* `container.getMaxSize()` → `layout.computeMaxSize(container)` を呼ぶ（layout が null なら inf）
* `container.setBounds(...)` → 自身に bounds を設定したあと、自動的に `doLayout()` を走らせる
* `container.doLayout()` → `layout.doLayout(container)` を呼んだあと、子の Container に対して再帰的に `doLayout` を呼ぶ

LayoutManager 自身は再帰について何もしない。
これは関心の分離のためで、LayoutManager の実装者は直接の子だけを考えればよい。
