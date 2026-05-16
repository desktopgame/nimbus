# nimbus TODO

開発中の作業項目。設計の根拠・却下案は CLAUDE.md と memory を参照。

## Now（着手予定）

### awt-c に DX12 primitive の薄いラッパー
- [ ] `nmDevice` (ID3D12Device の生成・解放)
- [ ] `nmSwapchain` (swap chain + RTV)
- [ ] 頂点入力レイアウト wrapper（D3D12_INPUT_ELEMENT_DESC 相当）
- [ ] 定数バッファ wrapper（D3D12_CONSTANT_BUFFER_VIEW_DESC 相当）
- [ ] コマンドリスト記録 wrapper（ID3D12GraphicsCommandList 相当）
- [ ] フェンス同期 wrapper（ID3D12Fence 相当）

「薄い」を維持。シェーダーや programs の概念は持ち込まない。

## Next（DX12 primitive が揃ってから）

### シェーダー事前定義パイプライン（awt 内部）
- [ ] `awt/shaders/` 作成: `Meta.meta`, `Default.meta`, 各プログラムの `.meta` + HLSL (`.hlsl.vs` / `.hlsl.ps` 等)
- [ ] `build/shader_gen.zig` 実装（Solid の `Generate.ps1` を Zig に移植、出力は C ではなく Zig）
- [ ] `awt/src/generated/programs.zig` を生成、`.gitignore` で除外、`zig build` の依存に組込み
- [ ] `awt/src/render/Programs.zig`: program registry → pipeline factory
- [ ] `awt/src/render/Renderer.zig`: `drawRect` / `drawCircle` / `drawText` / `drawSprite` の高水準 API
- [ ] 起動時にランタイム `D3DCompile`（ビルド時コンパイルへの移行は後で）

レイヤー分担：
- awt-c: shader registry を持たない。`nmCompileShader` / `nmCreatePipeline` の primitive のみ
- awt: shader registry を持つ。`Renderer` を公開
- framework: `awt.Renderer` を使う側。programs の存在を知らない

## Later

- [ ] Metal バックエンド（Mac）
  - [ ] awt-c に Metal 版 shim 追加
  - [ ] `awt/shaders/*.msl.*` を用意
  - [ ] codegen が MSL も処理するよう拡張
- [ ] FreeType 統合（テキスト描画）
- [ ] framework 層: `Application` / `Container` / `Component` / `widget` 群（CLAUDE.md「その他の決定項目」参照）
- [ ] ビルド時シェーダーコンパイル（DXC）へ移行
- [ ] 宣言的レイアウト API
- [ ] Linux サポート検討（Vulkan 想定だが未定）
- [ ] Python / JS バインディング
- [ ] `vendor/glfw-3.4/` の `glfw.ico` 等を LFS に流すか整理
- [ ] `nmAwtInit` / `nmTerminateAwt` の命名最終確認（`nmInit` だと汎用すぎる懸念あり）

## Done

- [x] 3 モジュール構成 (framework / awt / awt-c) の build.zig 雛形
- [x] GLFW 3.4 をベンダリング + 自前 `build.zig` ビルド
- [x] awt-c ↔ awt ↔ framework の最小ループ（hello でウィンドウが出る）
- [x] コーディング規約 (`nm` prefix, `#pragma once`, `self`, 英語コメント) 適用
