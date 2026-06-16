# document-lint

ドキュメントの読みやすさは textlint で機械的に縛っている。コミット時に lefthook の pre-commit ゲートが staged の Markdown へ自動で走るので、基本は自分で流す必要はない。コミットが lint で止まったら、出た指摘を解消してから commit し直す。

## 何がどこに掛かるか

- softbreak（行末スペース／ハードブレーク）: 全 Markdown が対象。base 設定 `.textlintrc.json` と `tools/textlint/rules/`。
- 読みやすさ規則（表示幅・強調数・prh・preset-ja-technical-writing）: モジュール doc（`awt/doc/` `awt-c/doc/` `framework/doc/`）だけが対象。doc 設定 `.textlintrc.doc.json` と `tools/textlint/doc-rules/`。トップレベルの `doc/`（backlog・内部メモ）と doc フォルダ外は重い規則の対象外で、softbreak だけ掛かる。

検知している規則・閾値・設定ファイルの所在は `doc/internal/writing_style_hint.md` を参照。

## 手動で流したいとき（任意）

コミット前に先回りして確認したいときだけ使う。

- 単体: `npm run lint -- <path/to/file.md>`
- 全体（モジュール doc を一括）: `npm run lint_all`

`npm run lint_all` は `*/doc/**/*.md` を見る。コミットゲートの重い規則の対象範囲と一致する。
