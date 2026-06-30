# CHANGELOG
変更履歴です。一番上が最新です。

## v0.1.1 - 2026-06-30
* 外部 Zig プロジェクトから `zig fetch` で参照してビルドできるよう、パッケージ tarball に vendor（glfw / freetype / zg 等のベンダーソース）と LICENSE / NOTICE を同梱（`build.zig.zon` の `.paths` 修正）。
* 機能変更なし・公開 API 不変。

## v0.1.0 - 2026-06-30
* 初回リリースです。