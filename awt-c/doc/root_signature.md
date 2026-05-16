# root_signature
ルートシグネチャに関する設計ノート。
シェーダーへの引数渡し配置（constant buffer、texture、sampler の slot 構成）を記述する。

## 型定義
typedef enum nmRootBindingType {
    nmRootBindingTypeConstantBuffer,
    nmRootBindingTypeTexture,
} nmRootBindingType;

typedef struct nmRootBinding {
    nmRootBindingType type;
    nmShaderStage stage;  /* どの stage から見えるか */
    int slot;             /* register 番号 */
} nmRootBinding;

typedef struct nmRootSignature nmRootSignature;

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、binding 構成とそれを実装する API オブジェクトを保持する。
たとえば、以下のようなものです。
* ID3D12RootSignature

複数の pipeline で同じ binding 構成を共有する場合、同じルートシグネチャを使い回せる。
GUI 用途では binding パターンが少数に収まるので、ルートシグネチャは数個で済む想定。

### 同じ slot を複数 stage から見る場合
たとえば VS と PS から同じ constant buffer の slot 0 を参照したい場合、`bindings` 配列に同じ slot で stage 違いの `nmRootBinding` を 2 つ入れる。

### サンプラーは binding に含めない
nimbus は static sampler 方式を採用しており、サンプラーは利用者が個別に bind しない。
nimbus が生成する全ての root signature には、固定の 4 種のサンプラーが自動で組み込まれる。
詳細は `sampler.md` を参照。

### 内部実装方針
`nmRootBindingType` の各種類は、内部で次のようにマップされる。
利用者は意識する必要はない。

| binding 種別 | DX12 実装 | Vulkan 実装 (将来) | Metal 実装 (将来) |
|---|---|---|---|
| ConstantBuffer | Root CBV (heap 経由しない) | Buffer Device Address または Dynamic Uniform Buffer | setBuffer:offset:atIndex: |
| Texture | Descriptor Table (size 1、heap 経由) | descriptor set または bindless | setTexture:atIndex: |
| (Sampler) | Static Sampler (root signature 内蔵) | immutable sampler | static MTLSamplerState |

DX12 では texture の SRV を root に直接置けない（Root SRV は buffer SRV のみ）ため、descriptor heap が必須。
descriptor heap は device が内部管理する（`device.md` 参照）。
他のプラットフォームでは heap 概念自体がないため、より素直な実装になる。

## ルートシグネチャの生成
nmRootSignature* nmCreateRootSignature(nmDevice* device, const nmRootBinding* bindings, int count);

binding 配列からルートシグネチャを生成する。
失敗時は `NULL` を返す。

## ルートシグネチャの破棄
void nmDestroyRootSignature(nmRootSignature* self);

ルートシグネチャを破棄する。
これに依存する pipeline が残っている場合の動作は未定義。
以後引数の `self` が使用可能であるかどうかは保証されない。
