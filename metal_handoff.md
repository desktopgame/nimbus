# Metal バックエンド実装 ハンドオフ

> **このファイルは一時的なハンドオフ用です**。Mac での実装が終わって動作確認できたら削除してください。Windows 側 Claude セッションから Mac 側 Claude セッションへの引き継ぎ書です。

## ゴール

`examples/hello` を **macOS 上で動かす**こと。現状は Windows / DX12 で動いていて、画面中央に Noto Sans JP の 'A' 文字が描画される。同じ動作を Mac 上で Metal バックエンドで実現する。

## 前提と参照ドキュメント

新セッションは以下を順に読んで全体像を掴んでから着手してください:

1. **`CLAUDE.md`** — プロジェクト全体の規約と方針（C 規約、bool ルール、CCW winding、フォント、文字コード、レイヤー分担 等）
2. **`awt-c/doc/*.md`** — awt-c の primitive 設計 14 ファイル + font.md
3. **`awt-c/src/dx12_*.c`** — Windows 側の参照実装。すべての primitive がここに実装済み
4. **`awt-c/src/internal.h`** — awt-c 公開 API（Mac でも同じ API を実装する）
5. **`awt-c/src/dx12_internal.h`** — Windows 内部だけで共有される struct 本体と helper（Mac は同等の `metal_internal.h` を作る想定）
6. **`build.zig`** + **`build/third_party.zig`** — ビルド構成。Windows / Mac / Linux で分岐済み
7. **`examples/hello/main.zig`** — 動作確認の entry point

## 現状（Windows 側で確認済み）

- Windows + DX12 で hello が動く（'A' が表示される）
- 全 primitive 実装済み: Device / Swapchain / CommandBuffer / RenderTarget / Shader / Buffer / Texture / RootSignature / Pipeline / Font
- リーク検知 (`nm_dxgi_report_live_objects`) と debug layer ログが integration 済み
- `dx12_stub.c` に非 Windows 用の no-op が並んでいる（これらが Mac 側で本物の実装に置き換わる）

## Mac で実装する方針（事前合意済み）

| # | 項目 | 決定 |
|---|---|---|
| 1 | 言語 | **Objective-C (`.m`)**、ARC オフ（`-fno-objc-arc`）。GLFW Cocoa と同じ流儀 |
| 2 | ファイル命名 | `metal_device.m` / `metal_swapchain.m` / `metal_command_buffer.m` / `metal_render_target.m` / `metal_shader.m` / `metal_buffer.m` / `metal_texture.m` / `metal_root_signature.m` / `metal_pipeline.m`（DX12 と対称） |
| 3 | 内部ヘッダ | `awt-c/src/metal_internal.h` を新設。Mac 側の struct 本体 + helper をそこに集約（DX12 と同じ構造） |
| 4 | ステンシルフォーマット | **MTLPixelFormatStencil8** 単独（depth 不要、Apple Silicon ネイティブ） |
| 5 | カラーフォーマット | swapchain = **BGRA8Unorm**、offscreen RT = **RGBA8Unorm** |
| 6 | nmRootSignature の扱い | **空でない struct として保持**。`{ binding[], param_count }` のテーブルを持って、`nmBindConstantBuffer` 等で slot → 実際の shader register に逆引きする（DX12 と対称） |
| 7 | glfw_shim.c の Mac 部分 | 同じファイルに `#ifdef __APPLE__` で並列。`nm_internal_get_nswindow(nmWindow*)` 相当を追加（GLFW の `glfwGetCocoaWindow` で取れる）。CAMetalLayer の attach も内部ヘルパで |
| 8 | hello のシェーダー | `if (builtin.target.os.tag == .macos)` で MSL と HLSL の文字列リテラルを切替。同じ振る舞いの triangle/text quad シェーダーを MSL で手書き |
| 9 | dx12_stub.c | Linux 用に残す。Mac は metal_*.m が backend を提供するので stub は使わない |
| 10 | リーク検知の Metal 等価物 | Metal validation layer (`MTL_DEBUG_LAYER=1` 環境変数 / `MTLCaptureManager`) を debug ビルドで有効化。完璧な ReportLiveObjects 等価物は無いが、validation layer が console に出力する |
| 11 | front face / winding / NDC y | DX12 と同じ規約のまま動く（Metal もデフォルト CCW front、NDC y up、UV y down）。明示設定不要 |
| 12 | フォント | freetype は Mac でも問題なく動く。`nm_font.c` は cross-platform で既に書かれてるのでそのまま使える |

## 概念マッピング

| 抽象 (awt-c) | Windows (DX12) | Mac (Metal) |
|---|---|---|
| nmDevice | ID3D12Device + queue + heap + fence | id<MTLDevice> + id<MTLCommandQueue> |
| nmSwapchain | IDXGISwapChain3 + 2 back buffer | CAMetalLayer attached to NSWindow contentView |
| nmCommandBuffer | ID3D12GraphicsCommandList + allocator + fence value | id<MTLCommandBuffer> + id<MTLRenderCommandEncoder> |
| nmRenderTarget | ID3D12Resource (color + stencil) + RTV/DSV | id<MTLTexture> (color) + id<MTLTexture> (stencil) |
| nmShader | ID3DBlob (DXBC bytecode) | id<MTLLibrary> + id<MTLFunction> |
| nmBuffer | ID3D12Resource (UPLOAD heap、persistent map) | id<MTLBuffer> (sharedMode、persistent contents) |
| nmTexture | ID3D12Resource (DEFAULT) + UPLOAD staging + SRV | id<MTLTexture> with private storage + UPLOAD staging |
| nmRootSignature | ID3D12RootSignature + binding table | binding table struct only（Metal は pipeline state に内包） |
| nmPipeline | ID3D12PipelineState | id<MTLRenderPipelineState> + id<MTLDepthStencilState> + cull/topology meta |
| static samplers (s0..s3) | D3D12_STATIC_SAMPLER_DESC[] | MTLSamplerDescriptor[]、pipeline descriptor に渡す or argument buffer |

## ビルド設定（build.zig 修正点）

`build.zig` の `.macos =>` ブランチに以下を追加:

- `awt_c_mod.addCSourceFiles({ .files = &.{ "metal_device.m", "metal_swapchain.m", ... }, .flags = &.{"-fno-objc-arc"} })` 
- `awt_c_mod.linkFramework("Metal", .{})`
- `awt_c_mod.linkFramework("QuartzCore", .{})` （CAMetalLayer 用）
- Cocoa / IOKit / Foundation は GLFW build から間接的に link されてるはず（必要なら追加）
- debug ビルド時に `awt_c_mod.addCMacro("NM_METAL_DEBUG", "1")` を define（DX12 側の `NM_DX12_DEBUG` と対称）

Mac の `dx12_stub.c` の compile は不要（Metal が backend を提供するので）。条件分岐の見直しが必要。

## 重要な作法（DX12 実装で踏んだ罠と対策）

これらは Metal でも同じ問題が起きうるので最初から考慮:

1. **GPU が in-flight な状態で resource を destroy しない**: `nmWaitDeviceIdle()` を呼んでから destroy する。例: hello の `device.waitIdle()` を main の最後に置いている。Metal でも `[commandQueue waitUntilCompleted]` 相当を実装すること
2. **デバッグ assert/break は debugger attach 時のみ**: DX12 の `IsDebuggerPresent()` gate と同じ発想。Metal validation で fatal にしすぎると CLI 実行で無音 exit する。`fatalErrors = NO` を default に
3. **Create 関数の失敗時は全部ロールバック**: CLAUDE.md「Create 関数の失敗時セマンティクス」参照。途中で確保したリソースは関数内で release してから NULL を返す
4. **MTLPixelFormat の swapchain BGRA8Unorm**: CAMetalLayer のデフォルトに合わせる。RGBA8Unorm にすると drawable 取得時に warning
5. **CCW winding は Metal デフォルト**: `setFrontFacingWinding:MTLWindingCounterClockwise` 明示しなくてもデフォルト。明示しても害なし
6. **Stencil8 の clear**: MTLRenderPassDescriptor の stencilAttachment.clearStencil + loadAction = MTLLoadActionClear

## 具体的タスクリスト

順番に進めてください:

1. `awt-c/src/metal_internal.h` を新設（dx12_internal.h を参考に Metal 用 struct と helper を定義）
2. `metal_device.m` 実装（MTLDevice + queue 取得、samplers 用意、validation layer setup）
3. `glfw_shim.c` に `#ifdef __APPLE__` ブランチ追加。`nm_internal_get_nswindow(nmWindow*)` と `nm_internal_attach_metal_layer(nmWindow*, layer)` を追加
4. `metal_swapchain.m` 実装（CAMetalLayer 作成、NSWindow contentView に attach、next drawable 取得）
5. `metal_command_buffer.m` 実装（MTLCommandBuffer の acquire/release/begin/end/submit/wait、render encoder の lifecycle）
6. `metal_render_target.m` 実装（color + stencil texture 確保、bind 時に MTLRenderPassDescriptor 構築）
7. `metal_shader.m` 実装（MSL ソース文字列 → MTLLibrary → MTLFunction）
8. `metal_buffer.m` 実装（MTLBuffer with `MTLResourceStorageModeShared`、persistent contents）
9. `metal_texture.m` 実装（DEFAULT 相当 = `MTLStorageModePrivate`、UPLOAD staging buffer 経由でアップロード、R8/RGBA8/BGRA8 対応）
10. `metal_root_signature.m` 実装（binding テーブルだけ）
11. `metal_pipeline.m` 実装（MTLRenderPipelineState + MTLDepthStencilState + topology メタ情報）
12. `build.zig` 修正（上記の Mac 用ソース + framework link、`dx12_stub.c` を Mac から除外）
13. `examples/hello/main.zig` に MSL シェーダー文字列を追加（HLSL と切替）
14. `zig build run-hello` で動作確認、'A' が表示されることを目視確認
15. リーク / validation 警告が出ないか確認

## 動作確認の合格基準

- `zig build` がエラー・警告ゼロで通る
- `zig build run-hello` で window が開き、暗い青背景に白い 'A' が表示される
- window を閉じると EXIT=0 で終了
- Metal validation layer から ERROR / WARNING が出ていない（stderr に出る前提）

## 戻る前にやること

実装完了したら:

1. このファイル `metal_handoff.md` を **削除**（ハンドオフ目的なので役目終了）
2. `CLAUDE.md` の「プラットフォーム」セクションを「Mac 動作確認済み」に更新
3. memory の `project_phase_status.md` を更新（Mac backend 完了の旨）
4. 必要なら `todo.md` の `Later` セクションから「Metal バックエンド」項目を `Done` に移す

それから commit & push して Windows 側で続きの作業に戻ります。

## 注意

- **clangd の LSP 警告は無視可**: GLFW や freetype の include を clangd が見つけられないが、実ビルドは Zig が build.zig 経由で include path を渡しているので通る
- **DX12 側のコードは触らない**: 純粋に Mac 側を追加するだけ。Windows 動作を壊さないこと
- **既存 cross-platform コード（`nm_font.c` / `nm_log.c` / `glfw_shim.c` の cross-platform 部分）は変更しない or 最小限**
