# CODEX.md

このファイルは、このリポジトリにおける Codex 固有の運用メモです。

## 役割

Codex は主に実装、ローカル検証、差分整理に使う。ただし、この分担は排他的ではない。
Claude が実装することもあるし、Codex が設計相談やコードレビューを行うこともある。

## 作業前に読むもの

自明でない変更を行う前に、以下を確認する。

- 共通のプロジェクト方針として `CLAUDE.md` を読む。
- 関連するソースファイルと近くのドキュメントを読む。
- 既存のレイヤ分離を尊重する。
  - `awt-c`: C/Objective-C platform backend
  - `awt`: Zig wrapper and rendering/input primitives
  - `framework`: public widget/layout/application layer

## 権限

このリポジトリでは Codex のコマンドルールとして `.codex/rules/default.rules` を使う。
通常のローカル開発は workspace-write 相当の権限で行う想定。

ユーザーから明示的に依頼されていない限り、破壊的なコマンドは実行しない。
たとえば以下を含む。

- `git reset --hard`
- 広範囲の recursive delete
- force push

リモート状態に影響する操作や、ローカル作業を書き換える可能性がある操作は事前に確認する。

- `git push`
- `git pull`
- dependency/vendor の更新

## 作業方針

- 変更は依頼された挙動に必要な範囲へ絞る。
- ユーザー由来の無関係な変更を戻さない。
- 新しいパターンを足すより、既存の抽象化とスタイルを優先する。
- 公開挙動や public API が変わる場合は、必要に応じてドキュメントも更新する。
- コードコメントは既存ファイルのスタイルに合わせる。ソース中のコメントは基本的に英語。

## 検証

変更に対して有効な、できるだけ小さい検証を選ぶ。

よく使うコマンド:

```powershell
zig build test
npm run lint
```

描画、レイアウト、widget に関わる変更では、関連する snapshot test や examples の確認も検討する。

作業完了時には以下を簡潔に報告する。

- 変更したファイル
- 実行した検証コマンド
- 実行できなかった確認があればその内容
