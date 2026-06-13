# AGENTS.md

このファイルは、このリポジトリで作業する AI coding agent 向けの入口です。

## 共通コンテキスト

まず `CLAUDE.md` を主要なプロジェクト方針として読むこと。このリポジトリでは
`CLAUDE.md` を Claude 専用の文脈とは扱わない。プロジェクトの方向性、
レイヤ境界、コーディング規約、ドキュメント方針を含む共通コンテキストとして扱う。

特定の領域で作業する場合は、近くのドキュメントも読むこと。

- `doc/`
- `awt/doc/`
- `awt-c/doc/`
- `framework/doc/`

## エージェント別コンテキスト

- Codex: `CLAUDE.md` に加えて `CODEX.md` を読む。
- Claude: `CLAUDE.md` を読み、Claude 固有の権限と hook は
  `.claude/settings.json` に従う。

エージェントごとの役割分担は慣習であり、排他的な担当境界ではない。
Claude がコードを書くこともあるし、Codex が設計レビューを行うこともある。
常にユーザーの現在の依頼を優先する。
