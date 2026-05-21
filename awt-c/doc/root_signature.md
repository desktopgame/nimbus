# root_signature
ルートシグネチャに関する設計ノート。
シェーダーへの引数渡し配置 (定数バッファ、テクスチャ、サンプラーのスロット構成) を記述する。

## 型定義
```c
typedef enum nmRootBindingType {
    nmRootBindingTypeConstantBuffer,
    nmRootBindingTypeTexture,
} nmRootBindingType;

typedef struct nmRootBinding {
    nmRootBindingType type;
    nmShaderStage     stage;
    int               slot;
} nmRootBinding;

typedef struct nmRootSignature nmRootSignature;
```

`nmRootBinding` の各メンバの意味は以下。
* `type`: バインディングの種別 (定数バッファかテクスチャか)
* `stage`: どのシェーダーステージから見えるか
* `slot`: スロット番号 (HLSL の register 番号に対応)

`nmRootSignature` の内部実装に関する知識は外部に漏らさない。
ここには、バインディング構成とそれを実装する API オブジェクトを保持する。
たとえば、以下のようなもの。
* ID3D12RootSignature

複数のパイプラインで同じバインディング構成を共有する場合、同じルートシグネチャを使い回せる。
GUI 用途ではバインディングパターンが少数に収まるので、ルートシグネチャは数個で済む想定。

## 同じスロットを複数ステージから見る場合
たとえば VS と PS から同じ定数バッファのスロット 0 を参照したい場合、`bindings` 配列に同じスロットで `stage` 違いの `nmRootBinding` を 2 つ入れる。

## サンプラーはバインディングに含めない
nimbus は static sampler 方式を採用しており、サンプラーは利用者が個別にバインドしない。
nimbus が生成する全てのルートシグネチャには、固定の 4 種のサンプラーが自動で組み込まれる。
詳細は `sampler.md` を参照。

## 内部実装方針
`nmRootBindingType` の各種類は、内部で次のようにマップされる。
利用者は意識する必要はない。

| バインディング種別 | DX12 実装 | Vulkan 実装 (将来) | Metal 実装 (将来) |
|---|---|---|---|
| ConstantBuffer | Root CBV (heap 経由しない) | Buffer Device Address または Dynamic Uniform Buffer | setBuffer:offset:atIndex: |
| Texture | Descriptor Table (size 1、heap 経由) | descriptor set または bindless | setTexture:atIndex: |
| (Sampler) | Static Sampler (root signature 内蔵) | immutable sampler | static MTLSamplerState |

DX12 ではテクスチャの SRV を root に直接置けない (Root SRV は buffer SRV のみ) ため、descriptor heap が必須。
descriptor heap は device が内部管理する (`device.md` 参照)。
他のプラットフォームでは heap 概念自体がないため、より素直な実装になる。

## ルートシグネチャの生成
nmRootSignature* nmCreateRootSignature(nmDevice* device, const nmRootBinding* bindings, int count);

`bindings` 配列 (要素数 `count`) からルートシグネチャを生成する。
失敗時は `NULL` を返す。

### 事前条件
* `count` が 1 以上であること。違反した場合の動作は UB。
* `bindings` 配列内に `(type, stage, slot)` の組が完全に重複するエントリが含まれないこと。違反した場合の動作は UB。

## ルートシグネチャの破棄
void nmDestroyRootSignature(nmRootSignature* self);

ルートシグネチャを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。
* `self` に依存するパイプラインが残っていないこと。違反した場合の動作は UB。
