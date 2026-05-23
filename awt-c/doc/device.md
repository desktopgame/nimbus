# device
デバイスに関する設計ノート。

## 型定義
```c
typedef struct nmDevice nmDevice;
```

内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

ここには、全てのウィンドウで共通して参照されるオブジェクトを保持する。
たとえば、以下のようなもの。
* IDXGIFactory6
* ID3D12Device
* ID3D12CommandQueue
* ID3D12Fence
* `nmCommandBuffer` のプール（`command_buffer.md` 参照）
* CBV/SRV/UAV descriptor heap（全テクスチャの SRV を 1 つに集めて格納する）
* Sampler descriptor heap（static sampler 4 種を格納）
* RTV descriptor heap（全レンダーターゲットの RTV を格納する）
* DSV descriptor heap（全 stencil view を格納する）

descriptor heap の存在は API には出さない。
テクスチャやレンダーターゲットのバインドは device が内部で適切な heap 位置に解決する（`texture.md`, `render_target.md` 参照）。
個々のテクスチャやレンダーターゲットが「自分のスロット位置」を持っているのではなく、device が一元管理する不透明なスロット識別子を保持する形になる。

## デバイスの生成
nmDevice* nmCreateDevice(void);

デバイスはウィンドウに依存せず、ウィンドウより先に生成可能であることが保証される。
失敗時は `NULL` を返す。

### 事前条件
* `nmInitAwt()` が事前に呼び出されていること。違反した場合の動作は UB。

## デバイスの破棄
void nmDestroyDevice(nmDevice* self);

デバイスを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。

## GPU 完了待ち
void nmWaitDeviceIdle(nmDevice* self);

デバイス上で投入済みのすべての作業 (コマンドバッファ submit、フェンス signal 等) が完了するまで CPU をブロックする。
シャットダウン直前 (Application.deinit 系) や、リソース再構築 (resize 等) の前に「使用中の GPU リソースが安全に破棄できる状態」を保証するために使う。

### 事前条件
* `self` が non-NULL であること。違反した場合の動作は UB。

### 診断情報
* 通常ケースで明示的なログは出さない。GPU 側のエラーは debug layer (`NM_DX12_DEBUG`) が拾う。
