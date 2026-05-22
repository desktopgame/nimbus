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

## 設計要件
ルートシグネチャの API 形状とバインディングの抽象は、以下を満たすように設計する。
内部の具体的な実装方針 (各バックエンドでどの構文を採用するか等) は、これらの要件から自然に導けるようにする。

* **GUI 用途に十分**: バインディングパターンの種類は少数で足り、汎用 3D シーン向けの複雑な descriptor 抽象は不要。バインディングは「定数バッファ」「テクスチャ」「static sampler (固定)」の 3 種で打ち止め。
* **定数バッファはホットパス**: 定数バッファは draw ごとに更新 / 差し替えされる前提で、間接層を最小化したい。
* **テクスチャの少数バインド**: 1 つの draw で参照するテクスチャは少数 (典型 1 枚) で、descriptor の動的更新は限定的でよい。
* **サンプラーは利用者の関心外**: 静的に固定する設計 (`sampler.md` 参照) のため、ルートシグネチャの API にサンプラー種別は登場しない。
* **複数バックエンドへのマップが平易**: DX12 / Metal / Vulkan などにそのまま流せる粒度に留め、各バックエンドが持つ最も素直な構文 (定数バッファの直接バインド、テクスチャのインデックス指定) に対応できるようにする。複雑な descriptor pool / set / 動的 indexing 等の機能には踏み込まない。

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
