# device
デバイスに関する設計ノート。

## 型定義
typedef struct nmDevice nmDevice;

内部実装に関する知識は外部に漏らさない。
awtの内部で定義された抽象化済みの型については保持しても構わない。

ここには、全てのウィンドウで共通して参照されるオブジェクトを保持する。
たとえば、以下のようなものです。
* IDXGIFactory6
* ID3D12Device
* ID3D12CommandQueue
* ID3D12Fence
* `nmCommandBuffer` のプール（`command_buffer.md` 参照）
* CBV/SRV/UAV descriptor heap（**全 texture の SRV を 1 つに集めて格納する**。利用者には露出しない）
* Sampler descriptor heap（static sampler 4 種を格納。利用者には露出しない）
* RTV descriptor heap（**全 render target の RTV を格納する**。利用者には露出しない）
* DSV descriptor heap（**全 stencil view を格納する**。利用者には露出しない）

descriptor heap の存在は API には出さない。
テクスチャや render target の bind は device が内部で適切な heap 位置に解決する（`texture.md`, `render_target.md` 参照）。
個々の texture や render target が「自分の slot 位置」を持っているのではなく、device が一元管理する不透明な slot 識別子を保持する形になる。

## デバイスの生成
nmDevice* nmCreateDevice(void);

デバイスはウィンドウに依存せず、ウィンドウより先に生成可能であることが保証される。
ただし、`nmInitAwt()`は先に実行しておくことが推奨される。
失敗時は `NULL` を返す。

## デバイスの破棄
void nmDestroyDevice(nmDevice* self);

デバイスを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。