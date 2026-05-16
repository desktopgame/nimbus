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

## デバイスの生成
nmDevice* nmCreateDevice(void);

デバイスはウィンドウに依存せず、ウィンドウより先に生成可能であることが保証される。
ただし、`nmInitAwt()`は先に実行しておくことが推奨される。
失敗時は `NULL` を返す。

## デバイスの破棄
void nmDestroyDevice(nmDevice* self);

デバイスを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。