---
unsafe: false
---

# sampler
サンプラーの設計方針と用意される 4 種類の説明。

## 設計方針
GUI 用途では必要なサンプラーのパターンが少数に限られるため、nimbus は **4 種のサンプラーをルートシグネチャに静的に組み込む**。
利用者はシェーダーからスロット番号 (HLSL の register 番号に対応) で直接参照する。

`nmCreateSampler` / `nmBindSampler` / `nmSampler` のような API は提供しない。
将来カスタムサンプラー (アニソ、Mirror、Border 等) が必要になった時点で別 API を追加する。

## 用意される 4 種のサンプラー
| スロット | フィルタ | アドレッシング | 用途 |
|----------|---------|---------------|------|
| `s0` | Linear | Clamp | 通常のスプライト・画像 |
| `s1` | Linear | Wrap | タイル背景 |
| `s2` | Point | Clamp | ピクセルアート・シャープ表示 |
| `s3` | Point | Wrap | 対称性のため (実用は稀) |

nimbus が生成する全てのルートシグネチャにこの 4 つが含まれる。
利用者は何も指定せずに上記スロットを使える。

## HLSL での参照例
```hlsl
Texture2D    g_tex          : register(t0);
SamplerState g_linearClamp  : register(s0);

float4 psMain(Input input) : SV_TARGET {
    return g_tex.Sample(g_linearClamp, input.uv);
}
```
