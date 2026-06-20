---
unsafe: true
---

# programs
GUI に必要な少数の描画 program (シェーダー + ルートシグネチャ + パイプライン + バインドヘルパー) をまとめて提供するモジュール。
作者がメタデータを 1 箇所書くだけで、program 1 つに必要な構成要素がすべて揃うようにする。

## 依存関係
`awt-c` の `Shader` / `RootSignature` / `Pipeline` / `CommandBuffer` / `Buffer` を組み合わせて使う。
program は `Graphics` の内部で `Text` / `Color` / `Image` / `RoundedRect` 等として参照される。
利用者 (framework 層、アプリ作者) から program は直接見えない。

## 型定義
```zig
pub const UniformDecl = struct {
    stage: Shader.Stage,
    slot: i32,
    /// CPU 側構造体。シェーダーの cbuffer / struct と同じレイアウト。
    type: type,
};

pub const TextureDecl = struct {
    stage: Shader.Stage,
    slot: i32,
};

pub const ShaderSources = struct {
    hlsl_vs: [:0]const u8,
    hlsl_ps: [:0]const u8,
    msl_vs:  [:0]const u8,
    msl_ps:  [:0]const u8,
};

pub const ProgramMeta = struct {
    vertex_layout:      Pipeline.VertexLayout,
    topology:           Pipeline.Topology  = .triangle_list,
    blend:              Pipeline.BlendMode = .none,
    color_write_enable: bool               = true,
    uniforms:           []const UniformDecl = &.{},
    textures:           []const TextureDecl = &.{},
    shaders:            ShaderSources,
};

pub fn ProgramFromMeta(comptime meta: ProgramMeta) type;
```

`ProgramMeta` には 1 つの program に必要な情報をすべて記述する。
* パイプラインステート (`vertex_layout` / `topology` / `blend` / `color_write_enable`)
* バインドする定数バッファとテクスチャの宣言 (`uniforms` / `textures`)
* HLSL / MSL の両ソース (`shaders`)

`ProgramFromMeta` はメタデータから program 型を comptime で生成する。

## ビルトイン program
現状のビルトイン program は `Text` / `Color` / `Image` / `RoundedRect` / `Gradient` の 5 つ。
いずれも `ProgramFromMeta` でメタデータから生成し、`Graphics` の内部からのみ参照する。
各 program の用途と細かなメタデータは `programs.zig` のソースに併記する。

### Gradient
矩形を縦 linear グラデーションで塗る program。`Graphics.fillGradientRect` が使う。

* `vertex_layout`: `vertex_texcoord_2d` (`Image` / `RoundedRect` と共有する)。
* `blend`: `.alpha`。テクスチャはバインドしない。
* PS uniform (スロット 0): `extern struct { color0: [4]f32, color1: [4]f32 }`。
  `color0` が上端色 (top)、`color1` が下端色 (bottom)。
* shaders: `awt/src/shaders/Gradient/gradient.{hlsl,msl}.{vs,ps}`。
  VS は uv をそのまま PS へ渡す (`RoundedRect` / `Image` と同じ素通し)。
  PS は `lerp(color0, color1, uv.y)` で縦方向に補間する。

## 機能要望
* シェーダーの事前コンパイル (現状はランタイムコンパイル、起動時間短縮の余地)。優先度高。
* 1 つの program で複数の uniform ブロック (`meta.uniforms.len > 1`) を扱う API。現状 `bindUniforms` は最初のブロックのみをバインドする。
* メタデータからシェーダー側の宣言 (HLSL / MSL の `register` / `cbuffer` 等) を自動生成する仕組み。
  現状はシェーダー側を作者が手書きするので、メタデータと食い違うリスクが残る。
