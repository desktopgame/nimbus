---
unsafe: true
---

# programs
ビルトイン program の一覧と設計要件。

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
