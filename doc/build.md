# build
nimbus のビルド構成についてのドキュメント。
ビルドスクリプトは `{REPO_ROOT}/build.zig` と `{REPO_ROOT}/build/third_party.zig` に分かれている。

## モジュール構成
nimbus は内部的に複数の Zig モジュールを組み合わせて構築する。

| モジュール | 種別 | 役割 |
|---|---|---|
| `awt-c` | 静的ライブラリ (C/Obj-C) | プラットフォーム固有 API の薄いラッパ。GLFW / FreeType / DX12 / Metal を内部で扱う |
| `awt` | Zig モジュール | `awt-c` を translate-c した上に被せた型安全な Zig 層 |
| `nimbus` (framework) | Zig 公開モジュール | `awt` の上に積む高レイヤ。`Component` / `Container` などウィジェット |
| `libnimbus` | 共有ライブラリ (C ABI) | 他言語バインディング (Python / JS) 用の公開エントリーポイント |

`awt-c` は translate-c に食わせない。`awt-c/src/internal.h` のみを Zig 側に公開し、それ以外の DX12 / Metal ヘッダは `awt-c/src/dx12_internal.h` などに閉じ込めて C ファイル間でのみ共有する。

## 依存ライブラリ
外部の依存はすべて `{REPO_ROOT}/vendor/` に展開済み。パッケージマネージャは使わない。バージョンを固定し、将来サービスが落ちてもビルドが再現できるようにするためである。

### ベンダー化された依存
| ライブラリ | バージョン | パス | 用途 |
|---|---|---|---|
| GLFW | 3.4 | `vendor/glfw-3.4` | ウィンドウシステム、入力 |
| FreeType | 2.14.3 | `vendor/freetype-2.14.3` | TTF フォントラスタライズ |
| zigimg | zig_0.16.0 ブランチ | `vendor/zigimg-zigimg_zig_0.16.0` | PNG / JPEG / GIF / BMP デコード |

GLFW と FreeType は `build/third_party.zig` でソースから静的ライブラリとしてビルドする。zigimg は純 Zig なので Zig モジュールとして直接 import するだけでよい。

### プラットフォーム固有のシステムライブラリ
`awt-c` は OS ごとに別のシステムライブラリにリンクする。

#### Windows
* `d3d12`
* `dxgi`
* `dxguid`
* `d3dcompiler_47`

GLFW 側で `user32` / `gdi32` / `shell32` も要求する。

#### macOS
* `Metal`
* `QuartzCore`
* `AppKit`
* `Foundation`

GLFW 側で `Cocoa` / `IOKit` / `CoreFoundation` も要求する。

#### Linux
レンダリングバックエンドは未実装で、`dx12_stub.c` の no-op が入る。GLFW 自体は X11 バックエンドでビルド可能で、`X11` / `Xrandr` / `Xinerama` / `Xcursor` / `Xi` / `Xext` / `m` / `rt` / `dl` のシステム dev パッケージがホストに必要。

### 依存関係のグラフ
```
libnimbus (.dll/.dylib)
   └── nimbus (framework, Zig)
          └── awt (Zig)
                 ├── awt-c (静的、C/Obj-C)
                 │      ├── GLFW (静的、vendored)
                 │      ├── FreeType (静的、vendored)
                 │      └── プラットフォーム SDK (DX12 / Metal / X11)
                 └── zigimg (Zig、vendored)
```

## ビルドターゲット
標準的なターゲットは `zig build` で全てまとめて生成される。

| コマンド | 生成物 |
|---|---|
| `zig build` | `libnimbus` と公開ヘッダの一式を `zig-out/` 以下にインストール |
| `zig build run-hello` | `examples/hello` を実行 |
| `zig build run-snapshot` | `examples/snapshot` を実行（オフスクリーン描画 → PNG 出力） |
| `zig build test` | 全テストを実行 |
| `zig build update-snapshots` | スナップショットテストの fixture を再生成 |

`-Dtarget=` でのクロスコンパイルが通る構成を維持している。新しい依存を入れる際もこれを壊さないこと。

## examples
利用者がライブラリの典型的な使い方を確認するための実行可能サンプル。`{REPO_ROOT}/examples/<name>/main.zig` を一つ置けば `addExample` が `run-<name>` step を生やす仕組みになっている。

現状で用意されている例は以下。

| 名前 | 内容 |
|---|---|
| `hello` | ウィンドウを開いて毎フレーム描画する標準的なサンプル。フォント、画像、SDF 図形、 framework ウィジェットなど一通りカバー |
| `snapshot` | ウィンドウを開かずにオフスクリーンレンダーターゲットに描画し、結果を PNG ファイルに書き出す。引数で出力パスとシーン名を選べる |

`snapshot` は `awt/tests/scenes.zig` で定義された `Scene` をテストランナーと共有しており、人間が視覚で結果を確認するためのツールでもある。

## tests
`zig build test` で全テストが走る。詳細は `{REPO_ROOT}/doc/test.md` を参照。

ビルド面での要点だけ書いておくと、テストは以下 3 種類のテストアーティファクトを束ねている。

* `awt` モジュールに埋め込まれた `test "..."` ブロック (`awt/src/**/*.zig`)
* `framework` モジュールに埋め込まれた `test "..."` ブロック (`framework/src/**/*.zig`)
* `awt/tests/snapshot_test.zig` 専用のテストモジュール。`awt` / `zigimg` / `scenes` を import する独立モジュールとして組まれる

スナップショットテストランナーは `zig build test` と `zig build update-snapshots` の両方から同じバイナリを起動する。後者は環境変数 `NIMBUS_UPDATE_SNAPSHOTS=1` を設定して走らせるだけ。

## 機能要望
* 利用者向けのパッケージ配布（GitHub release などで `libnimbus` バイナリ + ヘッダの zip を配布）
* Linux 用の Vulkan バックエンド（現状は `dx12_stub.c` の no-op）
* Python / JavaScript バインディングのリポジトリ分割
