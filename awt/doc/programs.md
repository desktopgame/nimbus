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

## 生成された program 型
`ProgramFromMeta(meta)` が返す型は以下のメンバを持つ。
```zig
pub const Uniforms = /* meta.uniforms[0].type または void */;

pub fn init(device: Device) !Self;
pub fn deinit(self: *Self) void;
pub fn bind(self: Self, cb: CommandBuffer) void;
pub fn bindUniforms(self: Self, cb: CommandBuffer, ubuf: UniformBuffer, handle: UniformBuffer.Handle) void;
```

`Uniforms` は CPU 側で uniform 値を組み立てる際の型エイリアス。
`bindUniforms` は metadata で宣言したスロット番号を解決して `cb.bindConstantBuffer` を呼ぶ。
テクスチャのバインドは呼び出し側で `cb.bindTexture` を直接行う。

## ビルトイン program 一覧
| program | 用途 | 頂点レイアウト | uniforms | テクスチャ |
|---|---|---|---|---|
| `Text` | グリフアトラスから 1 文字分のクワッドを描画。`color` で色付け | 2D + UV | `color: float4` | グリフアトラス (R8) |
| `Color` | 単色塗りの 2D クワッド (背景、パネル、罫線等) | 2D | `color: float4` | なし |
| `Image` | RGBA テクスチャの 2D クワッド、`tint` 乗算 | 2D + UV | `tint: float4` | RGBA テクスチャ |
| `RoundedRect` | SDF による角丸矩形 / 円 / それぞれのアウトライン | 2D + UV | `color`, `half_size`, `corner_radius`, `thickness` | なし |

各 program のシェーダーソースは `awt/src/shaders/<Name>/` に HLSL / MSL の 4 ファイル (vs/ps × 2 言語) として配置する。

## 設計要件
* **シェーダーは作者が定義するもの**: アプリ作者 (利用者) がランタイムに program を追加・差し替えする経路は不要。新規 program が必要なら nimbus 側の作者が `programs.zig` に追記する。
* **シェーダー言語の二重管理**: 1 つの program につき HLSL / MSL の両ソースを保持する必要がある。プラットフォームごとに別のソースを選ぶのは内部で行い、利用側 (Graphics 等) はプラットフォームを意識しない。
* **CPU 側と GPU 側のレイアウト一致**: 定数バッファについて、CPU 側構造体のメモリレイアウトと HLSL `cbuffer` / MSL `struct` の宣言が一致する必要がある。
* **バインディングの整合**: ルートシグネチャに渡すスロット番号と、シェーダー側の `register(bN)` / `[[buffer(N)]]` のスロットが一致する必要がある。同様にテクスチャも一致が必要。
* **追加コストの最小化**: 新しい program を追加する手順は「1 つのメタデータ宣言 + シェーダーソースファイルの追加」で済むこと。上記 3 つの同期ポイント (二言語ソース / CPU-GPU レイアウト / バインドスロット) が散在せず、メタデータから一意に決まるようにする。
* **GUI 用途で十分**: GUI に必要な program は少数 (現状 4 種) で打ち止め可能。汎用 3D シーン向けの動的シェーダー生成、利用者定義 program プラグイン機構等は不要。

## 機能要望
* シェーダーの事前コンパイル (現状はランタイムコンパイル、起動時間短縮の余地)。
* 1 つの program で複数の uniform ブロック (`meta.uniforms.len > 1`) を扱う API。現状 `bindUniforms` は最初のブロックのみをバインドする。
* メタデータからシェーダー側の宣言 (HLSL / MSL の `register` / `cbuffer` 等) を自動生成する仕組み。現状はシェーダー側を作者が手書きするので、メタデータと食い違うリスクが残る。
