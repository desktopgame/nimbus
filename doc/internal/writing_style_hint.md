# writing_style_hint

ドキュメントの読みやすさのうち、機械的に検知できるものは textlint で縛っている。
ドキュメントを書いたら lint を流す。設計判断の経緯は git 履歴に譲り、ここは運用に絞る。

## 実行

- 単体: `npm run lint -- <path/to/file.md>`
- 全体: `npm run lint_all`

用語統一など機械的に直せるものは `textlint --fix` で置換できる（差分を確認してから）。

## 検知している規則

- 表示幅: 1 行が 160 桁（全角 2 / 半角 1）を超えると警告。折り返し対策。
  実装は `tools/textlint/rules/max-display-width.js`、閾値はその定数。
- 強調の数: 1 行に 1 個まで、見出し配下の本文（セクション）は 2 個まで。強調は `**` / `*`。
  実装は `tools/textlint/rules/max-emphasis-per-line.js`。
- 用語統一: 小文字の英語形を所定のカタカナ・日本語へ寄せる。PascalCase（型名）は対象外。
  辞書は `tools/textlint/prh.yml`、規約は `.claude/rules/api-document-style-guide.md`「表記の統一」。
- 和文技術文: 長文（150 字超）・だ である調と ですます調 の混在・冗長表現など。
  preset-ja-technical-writing。有効無効と閾値は `.textlintrc.json`。

閾値や対象語を変えるときは、上に挙げた各ファイルを直す。

## あえて機械で縛らないもの

意図的に未対応なので、検知されないからといって「気にしなくてよい」ではない。

- アスキーアートのパディング揃え: 現状は許容。人間が編集するとズレるが、低コストとして受け入れる。
- 太字が本当に要る強調か、箇条書きを論点ごとに割るか: 意味判断なので書き手に任せる。
