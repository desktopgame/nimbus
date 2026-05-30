---
unsafe: false
---

# font
awt 層の `Font` モジュールの設計要件。

## 設計要件
* awt-c の責務 (単一グリフのラスタライズ / メトリクス) を Zig 側で広げない。アトラスや shaping は別レイヤー。
* C ABI で扱いにくい部分のみを Zig 慣用に直す: 戻り値のエラー型化、メトリクスの struct 化、UTF-8 文字列処理など。`bitmap_pitch` を含むメトリクスはそのまま透過。
* `Font` は値として軽量に複製可能 (1 ポインタ保持)。上位層 (`Graphics.Font` が `*awt.Font` を借用するなど) で値コピーが入っても複製コストが生じない。

## 高水準テキスト機能の置き場所
shaping / フォントフォールバック / 複数行レイアウト / RTL 等の機能を将来追加するときは、`Font` を直接拡張するのではなく awt 内に別モジュール (`TextRenderer` 等) を立てる方針。
そのモジュールが複数 `Font` + `GlyphAtlas` を所有し、利用側には「テキストを描く」高水準 API として見せる。

framework 層には置かない。テキスト描画は widget / Component / Layout などの framework 概念に依存しないため、awt 単独で完結させたほうがレイヤリングが綺麗 (snapshot テストが awt 直叩きでテキストを描く際にも使える)。
