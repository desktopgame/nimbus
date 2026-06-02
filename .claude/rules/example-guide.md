---
paths:
  - "examples/*/*.zig"
---

# example-guide
サンプルコードで守るべきガイドです。

## ドキュメント
テストを追加するときは、examples/readme.md に項目を追加すること。

## 命名規則
framework の機能を使い、ウィジェットを動かすサンプルは widget_* のような名前をつけてください。
例：
* widget_simple
* widget_menu

nimbus の C ABI としてエクスポートされた機能を使うサンプルで、かつC言語で実装されたサンプルは cnimbus_* のような名前をつけてください。
例：
* cnimbus_simple
* cnimbus_menu