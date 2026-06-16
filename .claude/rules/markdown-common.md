---
paths:
  - "*.md"
  - "doc/**/*.md"
  - "awt/doc/**/*.md"
  - "awt-c/doc/**/*.md"
  - "framework/doc/**/*.md"
---

# markdown-common
このリポジトリの Markdown を書くときの共通ルール。
（文体・表記統一・spec/narrative 構造は `*/doc/**` の `api-document-style-guide.md` が持つので、ここでは扱わない。）

## リポジトリルートの表記
ドキュメントにファイルパスを書くときは `{REPO_ROOT}` を基点にして表記する。

`{REPO_ROOT}/README.md`
リポジトリ直下の `README.md` を指す。

`{REPO_ROOT}/src/main.c`
リポジトリ直下の `src` フォルダの下の `main.c` を指す。

## 改行
原則としてソフトブレークに統一し、行末のスペース（またはバックスラッシュ）は挿入しない。
