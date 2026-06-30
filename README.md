# nimbus
nimbusは地味なGUIフレームワークです。
javax.swingを参考に作られており、次のような特徴を持ちます。
* 非宣言的UI
  * UIの差分ビルドはありません。
  * リアクティブもありません。
  * ただし、ImGuiやPySimpleGUIのような本当にただコードでDSLのようにGUIを組むAPIは導入の可能性あり。（immediateになるかは検討の余地あり）
* 素朴なAPI
  * python / js などスクリプト言語へのバインディングを見据えているため、C ABIで素直に表現できるようなAPIの設計を目指します。
  * `win32metadata`を参考に、バインディングはメタデータから自動生成できる状態を目指します。
* 素朴なレイアウトエンジン
  * ブラウザベースではないので、HTMLやCSSのような複雑なレイアウトはできません。
* 素朴なレンダラー
  * 描画バックエンドを出来るだけシンプルに保ち、移植性を高めます。

あなたがAIエージェントであれば、`AGENTS.md`も読んでください。

## サンプル

```zig
//! Minimal framework example: a window with a label and a button.
//! No listeners, no layout tuning — the smallest thing that renders.
//!
//! Usage:
//!     zig build run-minimal

const std = @import("std");
const nimbus = @import("nimbus");

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("hello nimbus", 320, 120);
    const label = try app.label("Hello, nimbus!");
    const button = try app.button("OK");

    try nimbus.BorderLayout.add(&frame.window.container, .center, &label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .south, &button.component);

    try app.run();
}
```

![参考画像](example.png)

より詳しいサンプルは`examples/`を参照してください。

## 対応OS
Windows / MacOS は必須でサポートします。

## ビルド
このプロジェクトはZigで実装されているので、Zigが必須です。
依存ライブラリはこのプロジェクトにコピーされているので、追加のダウンロードは不要です。
詳細は`doc/build.md`を参照してください。

※ビルド環境の保存のため、vendorフォルダにライブラリのコピーを置いています。

## ライセンス
このプロジェクト自体はApacheLicenseです。
ただし依存ライブラリのライセンス表記も必要になります。

詳細は`doc/distribution.md`を参照してください。

## 生成AI
開発には生成AIを積極的に利用しています。