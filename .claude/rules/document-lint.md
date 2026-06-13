# document-lint

ドキュメントの読みやすさは textlint で機械的に縛っている。
doc を書いたり直したら lint を流し、検出を解消してからコミットに回す。

## 手順

- 単体: `npm run lint -- <path/to/file.md>`
- 全体: `npm run lint_all`

検知している規則・閾値・設定ファイルの所在は `doc/internal/writing_style_hint.md` を参照。

## 対象範囲

`npm run lint_all` は `**/doc/**/*.md` だけを見る。
doc フォルダ外に置いた Markdown は検査されない。
必要なら個別に `npm run lint -- <file>` を流すか、glob を広げる。
