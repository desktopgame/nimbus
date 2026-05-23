# distribution
nimbus を使って作られたアプリ（以下、利用者アプリ）を第三者に配布するとき、
利用者アプリが同梱しなければならないライセンス表記についてまとめる。

nimbus は外部のオープンソースを vendoring してビルドする方針なので、
利用者アプリのバイナリには nimbus 自身に加えて複数のサードパーティ成果物が含まれる。
それぞれのライセンスが要求する条件を、利用者アプリ側でも満たす必要がある。

## 同梱が必要な対象一覧
利用者アプリのバイナリに**実行時に含まれる**サードパーティ成果物。
（ビルド時にしか使わないツール類、例えば SVG → PNG 変換に使う `resvg` などは、
利用者アプリのバイナリには入らないため対象外。）

| 名前 | 用途 | ライセンス | リポジトリ内の場所 |
| --- | --- | --- | --- |
| GLFW 3.4 | ウィンドウシステム / 入力 | zlib/libpng License | `{REPO_ROOT}/vendor/glfw-3.4/LICENSE.md` |
| FreeType 2.14.3 | フォントラスタライズ | FreeType License (FTL) または GPLv2 のデュアル | `{REPO_ROOT}/vendor/freetype-2.14.3/LICENSE.TXT`, `docs/FTL.TXT`, `docs/GPLv2.TXT` |
| zigimg | 画像デコーダ | MIT License | `{REPO_ROOT}/vendor/zigimg-zigimg_zig_0.16.0/LICENSE` |
| Lucide Icons 1.16.0 | ビルトインアイコン (PNG 化済み) | ISC License + 一部 MIT License (Feather 由来) | `{REPO_ROOT}/framework/src/lucide/LICENSE.txt` |
| Noto Sans JP Regular | デフォルトフォント | SIL Open Font License 1.1 (OFL) | `{REPO_ROOT}/framework/src/noto/OFL.txt` |

## ライセンスごとの要件

### GLFW (zlib License)
zlib License は緩い。
配布時の主な要件は以下の通り。

* ソースコードを改変した場合は「これは改変版である」と明示する
* 「自分が書いた」と詐称してはならない
* 配布物の中にあるこのライセンス通知を削除・改変しない

ライセンス文を製品ドキュメントなどに転載すれば十分とみなされる。
クレジット表記そのものは「あれば嬉しい」程度で必須ではないが、
ライセンス本文の同梱は事実上必須と考えてよい。

### FreeType (FTL / GPLv2 デュアル)
FreeType は「FTL」と「GPLv2」のどちらか一方を利用者が選ぶ仕組み。
nimbus は商用も含めた利用を想定しているため、デフォルトとして FTL を選択する前提で進める。
（GPLv2 を選んだ場合は利用者アプリ全体が GPLv2 に縛られるので、
通常は選択しない。）

FTL は BSD ライクなライセンスに広告条項を加えたもの。
配布時に**製品ドキュメント中**で以下を明示する必要がある。

```
Portions of this software are copyright (C) <year> The FreeType
Project (www.freetype.org). All rights reserved.
```

`<year>` は同梱した FreeType のバージョンに対応した年（vendoring している 2.14.3 なら 2024）を入れる。
この一文と、FTL のライセンス本文の同梱が必須。

### zigimg (MIT License)
MIT License は緩い。
要件は1つだけ。

* 利用者アプリの配布物中に、著作権表示と MIT 本文を含める

ライセンス文を製品の About 画面、付属ドキュメント、または `LICENSES/` 等のテキストファイルに転載すればよい。

### Lucide Icons (ISC + MIT)
nimbus は Lucide のアイコンを PNG 化したものを `framework/src/lucide/png/` に同梱しているので、
利用者アプリがアイコンを 1 枚でも使うなら、Lucide のライセンスも同梱対象になる。
（Lucide を一切使わない場合でも、アイコン PNG はバイナリに `@embedFile` される可能性があるため、
実質的には常に同梱が必要と考えるのが安全。）

ISC License は MIT に近い緩いライセンスで、要件は以下の通り。

* 配布物中に著作権表示とライセンス本文を含める

加えて、Lucide には Feather プロジェクト由来のアイコン群（`airplay`, `check`, `chevron-down`, ... 一部）が含まれており、
それらは MIT License で別途著作権が付いている。
そのため Lucide の `LICENSE.txt` 全体（ISC 本文 + MIT 本文 + Feather 由来アイコン一覧）をそのまま同梱するのが最も安全。
`{REPO_ROOT}/framework/src/lucide/LICENSE.txt` の内容をそのまま転載してよい。

### Noto Sans JP (SIL OFL 1.1)
nimbus は Noto Sans JP Regular をデフォルトフォントとしてバイナリに `@embedFile` するため、
利用者アプリには事実上常にこのフォントが埋め込まれる。
OFL の主な要件は以下の通り。

* フォント単体での販売は不可（アプリに同梱しての配布は OK）
* 同梱する際は、著作権表示と OFL 本文を一緒に含める
* OFL でライセンスされたフォントは、別ライセンス（例えば GPL のみ）で再配布できない
* 改変版で Reserved Font Name（"Noto"）を主要フォント名として使ってはならない
* 著作権者・作者の名前を、改変版の宣伝・推薦に使ってはならない

利用者アプリは Noto Sans JP を「埋め込んで配布」するケースに該当する。
従って、OFL 本文（`framework/src/noto/OFL.txt`）を利用者アプリの配布物に含めればよい。
フォント名に手を加えて再配布するわけではない限り、Reserved Font Name の制約には引っかからない。

---

## 利用者が実際にやるべきこと
具体的には、利用者アプリの配布物（インストーラ / zip / dmg など）の中に、
以下を満たすテキストファイル群またはドキュメントを含めればよい。

1. `LICENSES/` のようなディレクトリを作り、上記5つのライセンスファイルをそのまま入れる
2. もしくはアプリ内の About 画面に各ライセンスを一覧表示する
3. FreeType の FTL 由来クレジット文（前述の "Portions of this software ..." の一文）を、製品ドキュメントまたは About 画面のどこかに記載する

将来的に nimbus 側で「同梱されているライセンス一覧を実行時に取得する API」を提供することを検討している。
それが実装されれば、利用者アプリは API 経由で取得した文字列を About 画面にそのまま流し込むだけで要件を満たせる。
（CLAUDE.md「ビルトインアセット」参照。）

## 参考: nimbus リポジトリ内のライセンス原文の場所
| 名前 | 原文ファイル |
| --- | --- |
| GLFW | `{REPO_ROOT}/vendor/glfw-3.4/LICENSE.md` |
| FreeType (まとめ) | `{REPO_ROOT}/vendor/freetype-2.14.3/LICENSE.TXT` |
| FreeType (FTL 本文) | `{REPO_ROOT}/vendor/freetype-2.14.3/docs/FTL.TXT` |
| FreeType (GPLv2 本文) | `{REPO_ROOT}/vendor/freetype-2.14.3/docs/GPLv2.TXT` |
| zigimg | `{REPO_ROOT}/vendor/zigimg-zigimg_zig_0.16.0/LICENSE` |
| Lucide Icons | `{REPO_ROOT}/framework/src/lucide/LICENSE.txt` |
| Noto Sans JP (OFL) | `{REPO_ROOT}/framework/src/noto/OFL.txt` |

## スコープ外
* nimbus 自身のライセンス（まだ決定していない。決まり次第このドキュメントに追記する）
* ビルド時のみ使うツールのライセンス（`resvg` 等）— 利用者アプリのバイナリに含まれないため対象外
* 利用者がアプリ内で追加で使うサードパーティ成果物のライセンス — 各利用者の責任で対応
