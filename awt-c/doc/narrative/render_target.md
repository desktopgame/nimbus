---
unsafe: true
---

# render_target
レンダーターゲットの状態遷移とサイズ変更挙動に関する補足。

## リソース状態の遷移
DX12 におけるリソース状態 (PRESENT / RENDER_TARGET / PIXEL_SHADER_RESOURCE 等) の遷移は内部で自動的に処理される。
利用者は状態遷移を意識する必要はない。

## ウィンドウサイズ変更時の挙動
スワップチェイン由来のレンダーターゲットは `nmResizeSwapchain` が呼ばれた時点で内部的に再作成される。
利用者は何もする必要はないが、`nmGetSwapchainTarget` で取得したポインタはリサイズで無効になるため、キャッシュせずに毎フレーム再取得すること。

オフスクリーンのレンダーターゲットはウィンドウサイズには追従しない。
作成時のサイズで保持され続けるため、ウィンドウサイズに合わせたい場合は利用者が `nmDestroyRenderTarget` + `nmCreateRenderTarget` で作り直す。
