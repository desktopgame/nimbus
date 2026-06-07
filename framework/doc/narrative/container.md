---
unsafe: false
---

# container
Container の役割・子の所有モデル・描画・イベント・install/uninstall・列挙・想定利用。

## 役割
Container は Component の派生型の一つで、子 Component を所有する。

* 子の追加 / 削除
* 子の再帰描画 (paint)
* 子へのイベント dispatch (processEvent)
* LayoutManager 経由の bounds 計算

framework としては Container を特別扱いしているわけではない。
`Component.container` フィールドが non-null になっているものを Container とみなすルールで識別する。
利用者が「子を持つ独自ウィジェット」を作りたい場合、Container を embed して使うか、同じパターン（children + `component.container = self`）を自前で実装する。

## 子の所有
CLAUDE.md「所有権」セクションのとおり、Container が children を所有し、destroy で再帰的に解放する。
アロケーターは Application から借用したものを使う。

各子は `LayoutElement { component, hint, hint_destroy }` でラップして保持する。
hint と hint_destroy の意味と所有モデルについては `framework/doc/layout.md` を参照。

`remove` と `destroy` は分離している（Swing `Container.remove` も解放はしない）。
子の解放は必ず `elem.component.vtable.destroy` を経由する。
`allocator.destroy(elem.component)` を直接呼ぶと sizeof Component しか free できず、ウィジェット固有のメモリが leak する（`component.md`「メモリ解放」参照）。

## 描画
デフォルトの `vtable.paint` は子を順番に描画する。
各子の `getBounds()` で `Graphics.clip(...)` を作って子の `vtable.paint` に渡す。

Container 自身は背景描画をしない（透明）。
背景を持たせたい場合は `setVTable` で paint を差し替えるか、Container を embed した独自型を作って paint を書く。

## イベント
デフォルトの `vtable.processEvent` は子に dispatch する。
MouseEvent の場合はヒットテスト（マウス座標が含まれる子）で対象を選び、KeyEvent はフォーカス保持子に渡す。
渡す前にウィンドウローカル座標を子のローカル座標に変換する（`awt/doc/event.md`「座標系」参照）。
子が `event.consume()` を呼んだら以降の子への dispatch は行わない。

Event 型の詳細は `awt/doc/event.md` を参照。

## install / uninstall
Container 固有の `install` / `uninstall` は基本 no-op。
ただし children の `install` は add 時にすでに走っている（factory 経由の Component は install 済みで渡される）ので、ここで再度 install を呼ばないこと。

## レイアウト
`layout` が null の場合、子の位置・サイズは利用者が `child.component.setBounds(...)` で手動指定する。
通常は `setLayout` で BoxLayout や BorderLayout を差して使う。

LayoutManager は直接の子の bounds のみを設定し、孫以下への再帰は Container 側が担当する。
詳細は `framework/doc/layout.md` と `{REPO_ROOT}/doc/internal/layout-design.md` を参照。

## 列挙との関係
Container は init で `self.component.container = self` をセットする。
これにより Application などからツリーを再帰的にたどれる。
詳細は `component.md`「コンポーネントの列挙」を参照。

## 利用者が直接使うか
通常、利用者は `app.container()` を直接使わず、`Frame` 経由でウィジェットを add する。
`Frame` は内部で Container を持っており、`frame.add(label)` は実質的に `frame.container.add(&label.component)` への委譲。

`Container` を直接使うのは「子をグルーピングして配置したい」ような中間ノードが必要な場合。
LayoutManager の適用単位としてもこの中間 Container を使うのが自然である。
