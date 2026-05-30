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

## 機能要望
* シェーダーの事前コンパイル (現状はランタイムコンパイル、起動時間短縮の余地)。
* 1 つの program で複数の uniform ブロック (`meta.uniforms.len > 1`) を扱う API。現状 `bindUniforms` は最初のブロックのみをバインドする。
* メタデータからシェーダー側の宣言 (HLSL / MSL の `register` / `cbuffer` 等) を自動生成する仕組み。現状はシェーダー側を作者が手書きするので、メタデータと食い違うリスクが残る。
