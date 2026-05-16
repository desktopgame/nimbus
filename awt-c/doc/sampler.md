# sampler
サンプラーに関する設計ノート。
nimbus では静的サンプラーのみサポートし、利用者は bind 操作をしない。

## 設計方針
GUI 用途では必要なサンプラーパターンが少数に限られるため、nimbus は **4 種類のサンプラーを root signature に静的に組み込む**。
利用者はシェーダーから register 番号で直接参照する。

`nmCreateSampler` / `nmBindSampler` / `nmSampler` のような API は提供しない。
将来カスタムサンプラー（アニソ、Mirror、Border 等）が必要になった時点で別 API を追加する。

## 用意される 4 種のサンプラー

| register | フィルタ | アドレッシング | 用途 |
|----------|---------|---------------|------|
| `s0` | Linear | Clamp | 通常のスプライト・画像 |
| `s1` | Linear | Wrap | タイル背景 |
| `s2` | Point | Clamp | ピクセルアート・シャープ表示 |
| `s3` | Point | Wrap | 対称性のため（実用は稀） |

nimbus が生成する全ての root signature にこの 4 つが含まれる。
利用者は何も指定せずに上記 register を使える。

## HLSL での参照例

```hlsl
Texture2D    g_tex          : register(t0);
SamplerState g_linearClamp  : register(s0);

float4 psMain(Input input) : SV_TARGET {
    return g_tex.Sample(g_linearClamp, input.uv);
}
```

## 将来拡張の余地
以下が必要になったら API を追加する。それまでは対応しない。
* カスタムフィルタ・アドレッシングの組み合わせ
* Anisotropic フィルタリング
* Mirror / Border アドレッシング
* LOD bias、MIP min/max
* Compare サンプラー（シャドウマップ用）
