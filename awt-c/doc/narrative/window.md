---
unsafe: true
---

# window
DPI スケーリングの取り扱いと、ウィンドウサイズ / フレームバッファサイズの違い。

## 3 つの単位
nimbus はウィンドウに対して **3 種類の量** を区別する。

| 概念 | 単位 | 取得 API | 用途 |
|---|---|---|---|
| ウィンドウサイズ | 論理ポイント | `nmGetWindowSize` | 利用者向け描画座標、レイアウト計算 |
| フレームバッファサイズ | 物理ピクセル | `nmGetFramebufferSize` | スワップチェイン、ビューポート、シザー矩形 |
| コンテンツスケール | 比率 (DPR) | `nmGetWindowContentScale` | 論理 ↔ 物理 変換、フォントの物理サイズ算出 |

関係式: `物理 = 論理 × スケール`。
スケールは plain 1x display で 1.0、Retina 2x で 2.0、Windows 150% で 1.5。

## なぜ 3 つ必要か
DPI 1.0 環境 (古い Windows など) では 3 つが同値に潰れて区別を意識する必要が無い。
HiDPI 環境ではバラバラになり、誤って混ぜると以下のバグを起こす:

- 描画コードが論理ピクセルで書かれているのに viewport を論理サイズに合わせる → ウィンドウの半分しか塗られない
- 描画コードが物理ピクセルで書かれているのに NDC 変換を論理基準にする → 画面の 4 倍領域に描こうとして大半が裏に流れる
- フォントを論理サイズで freetype に渡す → 物理 buffer の中で米粒大に rasterize される

これを防ぐため、awt-c はこの 3 種を別 API で公開し、上位レイヤーで明示的に混ぜる責任を持たせる。

## `GLFW_SCALE_TO_MONITOR` を有効化
`nmCreateWindow` 内で `glfwWindowHint(GLFW_SCALE_TO_MONITOR, GLFW_TRUE)` をセットする。
これにより `glfwCreateWindow(w, h)` に渡した値が「論理ポイント」として扱われ、GLFW が monitor の content scale 倍して物理ピクセルウィンドウを作る。
スケール 200% で `glfwCreateWindow(600, 120)` → 物理 1200x240 のウィンドウ。
フレームバッファもこのサイズで確保される。

この hint が無いと Windows DPI-aware モードでは「800x600 と書いたら物理 800x600」(= Retina で米粒大) になる。
Apple の挙動とは異なるので明示が必要。

## Windows DPI awareness の宣言
`nmInitAwt` の冒頭で `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` を呼ぶ。
これが無いと Windows はプロセスを「DPI-unaware」扱いし、DWM が swapchain を bitmap 拡大してしまう (= ぼやける)。
GLFW 3.4+ は内部で同等の呼び出しを試みるが、manifest との競合等で失敗するケースがあるので明示的に呼ぶ。

## サイズ取得 API の単位の罠
`glfwGetWindowSize` は「screen coordinates」を返す。
- macOS では 論理ポイント (= フレームバッファより小さい)
- Windows DPI-aware では **物理ピクセル** (= フレームバッファと同じ)

つまり Windows では `glfwGetWindowSize` だけでは論理サイズが取れない。
論理サイズが必要な場合は `nmGetFramebufferSize` / `nmGetWindowContentScale` から計算する (上位 awt 層で実施)。
