# CODEX.md

このファイルは、このリポジトリにおける Codex 固有の運用メモである。

## 役割

Codex は主に実装、ローカル検証、差分整理に使う。
Claude はドキュメントしか書かない、Codexはコードしか書かない、を徹底することでドキュメントが腐るのを防ぐ。

## 作業前に読むもの

自明でない変更をする前に、以下を確認する。

- 共通のプロジェクト方針として `CLAUDE.md` を読む。
- 関連するソースファイルと近くのドキュメントを読む。
- 既存のレイヤ分離を尊重する。
  - `awt-c`: C/Objective-C platform backend
  - `awt`: Zig wrapper and rendering/input primitives
  - `framework`: public widget/layout/application layer

## doc を仕様として実装を頼まれたとき

doc にはいくつか種別があり、パスと節で見分ける。

- `framework/doc/<name>.md`（narrative 以外）= 実装仕様。これに従って実装する。
- `framework/doc/narrative/<name>.md` = 設計判断の理由。仕様ではない。実装は縛らないが背景として読む。
- 仕様 doc 内の「機能要望」節 = 未来の希望。今回のスコープ外。
- `doc/internal/*_backlog.md` = 検討中 / 棚上げ。確定仕様ではない。

doc と既存実装が食い違う場合は、既存実装を優先するか実装前に短く確認する。
勝手に doc へ寄せて実装し直さない（doc の更新は作者が別途ハンドリングする。
CLAUDE.md「doc と実装の追従関係」とも整合する）。
依頼に「doc は変更しない」とあれば doc は触らない。

実装後は export / factory / example / test の要否を確認する。

## 権限

このリポジトリでは Codex のコマンドルールとして `.codex/rules/default.rules` を使う。
通常のローカル開発は workspace-write 相当の権限で行う想定。

ユーザーから明示的に依頼されていない限り、破壊的なコマンドは実行しない。
たとえば以下を含む。

- `git reset --hard`
- 広範囲の再帰的なファイル削除
- force push

リモート状態に影響する操作や、ローカル作業を書き換える可能性がある操作は事前に確認する。

- `git push`
- `git pull`
- dependency/vendor の更新

## 作業方針

- 変更は依頼された挙動に必要な範囲へ絞る。
- ユーザー由来の無関係な変更を戻さない。
- 新しいパターンを足すより、既存の抽象化とスタイルを優先する。
- doc更新が要る場合は報告する（doc は Claude が書く）
- コードコメントは既存ファイルのスタイルに合わせる。ソース中のコメントは基本的に英語。

## 検証

変更に対して有効な、できるだけ小さい検証を選ぶ。

よく使うコマンド:

```powershell
zig build fmt
zig build test
npm run lint
```

Zig の整形は `zig build test` が `fmt-check` ゲートで検査し、未整形があればテストの前に落ちる
（対象は一次コードのみ。vendor 配下は除外）。整形そのものは `zig build fmt` で一括修正できる。
`zig build fmt-check` で検査だけを単独実行できる。

描画、レイアウト、ウィジェットに関わる変更では、関連する snapshot test や examples の確認も検討する。

作業完了時には以下を簡潔に報告する。

- 変更したファイル
- 実行した検証コマンド
- 実行できなかった確認があればその内容
