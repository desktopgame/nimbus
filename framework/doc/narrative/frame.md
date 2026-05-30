---
unsafe: true
---

# frame
Frame の階層・委譲方針・Window 分離理由・Application との連携。

## 階層と依存関係
```
framework.Window (抽象トップレベル)
  ├─ framework.Frame    ← これ
  └─ framework.Dialog   (オーナー必須、モーダル / モードレス。`dialog.md`)
```

タイトルバー / 最大化最小化 / ウィンドウクローズボタン /（将来）メニューバーを持つ、オーナーを持たない独立したトップレベルウィンドウ。
`framework.Window` を embed し、共通機能はそちらに集約する（`window.md` 参照）。

## 委譲メソッドは生やさない
`add` / `setTitle` / `repaint` 等の委譲メソッドは Frame に生やさない。
Window のメソッドは `frame.window.add(...)` / `frame.window.setTitle(...)` のように親フィールド経由で直接呼ぶ（`component.md`「派生型から Component メソッドへのアクセス」と同じ方針）。

理由は Label / Container と同じで、委譲はボイラープレートになる割に使われない。

* `setTitle` は利用者が毎フレーム呼ぶものではない。出番が少ない
* `add` も大量に呼ぶものではない（典型的には起動時に数個）
* `repaint` は setter 内部で自動的に呼ばれるので、利用者が直接呼ぶ機会は稀

将来「本当に頻出」と判明したものが出てきたら、その時に Frame に委譲を生やす。
デフォルトは **ゼロ**。

## なぜ Window と分けるのか
v1 では Frame ≒ Window と書ける、と思える。
が、Frame と Dialog（`dialog.md`）を並列派生にする設計上、共通部分を Window に置き、Frame 固有部分を Frame に置く分離は必要。

Frame の利用例（`app.frame(...)`）が広く使われる前に統合してしまうと、後で分離する時に利用者 API の変更が発生する。
**最初から分離しておく**のが安全。

将来の Frame 固有機能候補は spec 側の `## 機能要望` を参照。

## Window 抽象を直接生成する API は提供しない
`app.window()` のような API は用意しない。
Frame か Dialog のどちらかを必ず選ぶ設計にする。
Swing の `Window` も直接 new する API は提供されていない（`new Window(owner)` という protected ctor のみ）。

## Application との連携
Application のファクトリ `app.frame(title, w, h)` が Frame を生成し、`windows: ArrayList(WindowEntry)` に `*Window`（= `&frame.window`）を含む entry を登録する。
Frame ポインタではなく Window ポインタを WindowEntry に入れるのは、Application のループが Frame と Dialog を区別せず一律で扱えるようにするため。

詳細は `application.md` 参照。
