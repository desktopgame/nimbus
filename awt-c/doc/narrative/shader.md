---
unsafe: false
---

# shader
シェーダーのエントリ関数命名規約。

## エントリ関数名の規約
シェーダーのエントリ関数名は `stage` ごとに固定し、呼び出し側で指定しない。
* `nmShaderStageVertex` → `vsMain`
* `nmShaderStagePixel` → `psMain`

DX12 では `D3DCompile()` にエントリ関数名を要求されるが、nimbus 内部で上記名に固定して隠蔽する。
