---
unsafe: true
---

# binding
他言語バインディング（Python / Ruby / Lua / Swift / ...）を将来追加することを見越した設計ノート。
v1 の nimbus 自身はピュア Zig + C ABI で完結する。
ここでは「バインディング側がどう書けば動くか」と「そのために nimbus core が何を提供する必要があるか」を整理する。

このドキュメントは関数リファレンスではなく**設計ガイド**である点に注意。
他の framework doc とは構成が異なる。

具体例は Python を題材にするが、同じパターンが他の動的言語 / 静的言語にも適用できる。

## 利用例
最終的に Python から見た典型コード。
nimbus core の概念（Application、Frame、Label、Component メソッド）が継承の自然な形で見える。

```python
import nimbus

app = nimbus.Application()
frame = app.frame("hello", 800, 600)
label = app.label("こんにちは")

frame.add(label)              # Container 由来
frame.set_title("new title")  # Window 由来
label.set_bounds(0, 0, 200, 32)  # Component 由来

app.run()
```

paint の override 例。

```python
class HighlightLabel(nimbus.Label):
    def paint(self, g):
        g.set_color(nimbus.Color.rgb(1, 1, 0))
        g.fill_rect(0, 0, self.width(), self.height())
        super().paint(g)        # 元の Label.paint に委譲

label = HighlightLabel(app, "important")
frame.add(label)
```

## 機能要望
nimbus core 自身は当面ピュア Zig + C ABI で完結する。
他言語バインディングを実現する段階で以下を整える。

* `Component.getVTable()` を nimbus core に追加（上記「nimbus core に必要な変更」参照、これだけ）
* 派生型ごとの `asXxx` 関数（C ABI）— `nimbusFrameAsWindow` 等。Zig 側は `&self.foo.bar` を返す 1 行関数で済む。C ABI 着手時に派生型ごとに添える
* Python バインディング実装 — 別 repo / 別マイルストーン
* 同パターンでの Lua / Ruby / Swift バインディング
* L&F 機構 — `lookandfeel.md` の方針通り、nimbus core 自身は機構を提供せず、拡張点（`setVTable` / `properties` / `getVTable`）の組み合わせとして外部実装に任せる

