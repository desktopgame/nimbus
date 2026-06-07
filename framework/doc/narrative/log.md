---
unsafe: false
---

# log
framework 層の log 機構の位置づけ・awt との独立性・ログレベル運用・カテゴリ命名。

## 依存関係
本モジュールは awt にも awt-c にも依存しない。
内部の静的変数 (`g_cb` / `g_user`) と `std.fmt.bufPrint` + `std.debug.print` のみで完結する。

```
framework の各モジュール ─→ framework.log dispatcher ─→ 利用者が登録した Callback
```

awt 層は別の dispatcher (`awt.log`) を持ち、両者は完全に独立。
レイヤリングは `framework → awt → awt-c` を保つ (framework が awt-c の log API を直接叩くことはない)。

## awt との独立性
2 つの log システムを統合せず分離している理由:

* **個別 subscribe**: 利用者が片方のソースだけを購読できる (例: framework の握りつぶしログは無視したいが、awt-c の dx12 エラーは見たい)
* **依存方向の単純化**: framework は awt の log dispatcher の初期化順序や寿命に依存しない
* **テスト容易性**: framework の log は awt / awt-c のセットアップ無しに単体テスト可能 (本ドキュメント末尾のテスト参照)

両方を統合して受けたい場合のオーバーヘッドは「`setCallback` を 2 回呼ぶ」だけで済む。

## ログレベルの想定用途
awt と同じ運用方針を採る。

* `Level.debug`: 開発時の詳細追跡。本番ではコールバック側でフィルタ可能。
* `Level.info`: 通常の動作情報。
* `Level.warn`: 動作は継続するが注意が必要な事象。
* `Level.err`: 失敗した操作のエラー詳細。

framework 層の握りつぶし箇所 (発生源モジュールは下記「カテゴリ命名」の表に列挙) は、原則として `Level.warn` でログを出してから握りつぶす方針とする。
握りつぶし自体は GUI 慣習として保ったまま、観測手段を確保する。

## カテゴリ命名
発生源モジュールに対応する短い小文字の文字列を使う。
framework 側で現状想定する category:

| 文字列 | 発生源 |
| --- | --- |
| `"window"` | `framework/src/Window.zig` (入力 post / overlay 配線 / DirtyNotify 配線等) |
| `"menu"` | `framework/src/Menu.zig`, `MenuBar.zig`, `PopupMenu.zig` (show / addActionListener) |
| `"component"` | `framework/src/Component.zig` (putProperty / setName) |
| `"button"` / `"slider"` / `"menu_item"` / `"checkbox"` | 各 widget の `addChangeListener` / `addActionListener` 失敗 |
| `"application"` | `framework/src/Application.zig` (icon 初期化等) |

awt の category と名前が衝突した場合 (例: `"window"`) は、それぞれの dispatcher で独立に届くため利用者側で区別したい場合は `user_data` でソースを識別する。
