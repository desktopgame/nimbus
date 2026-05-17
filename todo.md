# nimbus TODO

開発中の作業項目。設計の根拠・却下案は CLAUDE.md と memory を参照。

## Now（着手中）

### Program 抽象化（awt 層、comptime metadata 駆動）
- [ ] `awt/shaders/Text/text.{hlsl,msl}.{vs,ps}` にシェーダー抽出（hello から inline を移す）
- [ ] `awt/src/programs.zig` に `ProgramFromMeta` comptime helper + Text program
  - meta はZig anonymous struct literal で記述（別ファイル / 独立 codegen 不要）
  - `@embedFile` でシェーダー埋め込み、HLSL / MSL の選択は `builtin.target.os.tag` で
  - 生成される型は `init(device) → bind(cb, uniforms) → deinit()` を持つ
- [ ] hello を programs.Text 経由に書き換え（手動 Shader/RootSig/Pipeline を排除）

レイヤー分担：
- awt-c: 引き続き shader registry を持たない。`nmCompileShader` / `nmCreatePipeline` の primitive のみ
- awt: `programs.zig` で program registry を提供。Renderer は次フェーズ
- framework: awt の高水準 API を使う

## Next

### Renderer 抽象化（awt 層）
- [ ] `awt/src/Renderer.zig`: `drawRect` / `drawCircle` / `drawText` / `drawSprite` の高水準 API
- [ ] 内部で programs.zig を使う
- [ ] 単一 nmBuffer (`.constant = true`) を ConstantsLayout で 256B aligned suballoc
  - **UniformPool は不要**（Root CBV + フレーム末同期で問題が消えるため）

### framework 層の最小実装
- [ ] `Application`（allocator 所有、widget factory）
- [ ] イベントループ（waitEvents + invalidation 駆動、CLAUDE.md 参照）
- [ ] EventQueue / invokeLater
- [ ] `Container` / `Component` 階層
- [ ] 最初の widget（Button あたり）

## Later

- [ ] ビルド時シェーダーコンパイル（DXC / Metal compiler）へ移行
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
- [x] awt-c DX12 primitive 一式（device / swapchain / cb / rt / shader / buffer / texture / root_sig / pipeline / font）
- [x] FreeType 統合（vendored + nm_font.c）
- [x] hello で 1 文字描画（'A'）
- [x] hello で indexed draw 確認（DX12 / Metal 両方）
- [x] DXGI ReportLiveObjects ベースのリーク検知（NM_DX12_DEBUG ビルド時）
- [x] Metal バックエンド（Mac、`metal_*.m` 一式。hello で 'A' が出る）
- [x] bool 規約導入（C コード全体）
