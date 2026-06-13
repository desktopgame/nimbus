---
unsafe: true
---

# binding
他言語バインディング（Python / Ruby / Lua / Swift / ...）のための設計ガイド。

## 中心の課題
Zig は struct embedding（擬似継承）、動的言語は真の継承を持つ。
この対応付けが必要。

| | Zig | Python |
|---|---|---|
| 派生 | `Frame { window: Window {...} }`（embed） | `class Frame(Window):`（継承） |
| ポインタ | `*Frame` と `*Window` は **別アドレス** | `self` 1 個で全継承メソッドが呼べる |
| 仮想呼び出し | per-instance vtable（`Component.vtable`） | 動的ディスパッチ |
| override | `setVTable` で C 関数ポインタ差替 | サブクラスでメソッド再定義 |

## アップキャストの扱い
`&frame.window` は `&frame` と一致しない（`window` が Frame の先頭フィールドでも、偶然一致するだけで保証ではない）。
C ABI と Python のクラス階層を素直に対応させるには、offset 解決を C ABI レベルで露出する必要がある。

C ABI 側で派生型ごとに `asXxx` を提供する。

```c
nmFrame*     nimbusFrameCreate(nmApp*, const char* title, int w, int h);
nmLabel*     nimbusLabelCreate(nmApp*, const char* text);

// アップキャスト (Zig 側は `&frame.window.container.component` の計算をするだけ)
nmWindow*    nimbusFrameAsWindow(nmFrame*);
nmContainer* nimbusWindowAsContainer(nmWindow*);
nmComponent* nimbusContainerAsComponent(nmContainer*);

// 各操作は「最も具体的な型」を期待する
void nimbusComponentSetBounds(nmComponent*, ...);
int  nimbusContainerAdd(nmContainer*, nmComponent*);
int  nimbusWindowSetTitle(nmWindow*, const char*);
```

Python wrapper は factory 内で 1 度だけ全ハンドルをキャッシュする。

```python
class _Backing:
    __slots__ = ("frame", "window", "container", "component")

class Component:
    def __init__(self, backing): self._b = backing
    def set_bounds(self, r): _lib.nimbusComponentSetBounds(self._b.component, r)

class Container(Component):
    def add(self, child): _lib.nimbusContainerAdd(self._b.container, child._b.component)

class Window(Container):
    def set_title(self, t): _lib.nimbusWindowSetTitle(self._b.window, t)

class Frame(Window):
    @classmethod
    def _from_handle(cls, h):
        b = _Backing()
        b.frame     = h
        b.window    = _lib.nimbusFrameAsWindow(h)
        b.container = _lib.nimbusWindowAsContainer(b.window)
        b.component = _lib.nimbusContainerAsComponent(b.container)
        return cls(b)
```

## メソッド override の扱い（vtable swap への射影）
Python での typical な override は次のように書ける。

```python
class MyLabel(nimbus.Label):
    def paint(self, g):
        g.set_color(red())
        super().paint(g)             # 元実装に委譲
```

これを実装するには、`MyLabel` のインスタンスが生成された瞬間に**トランポリン vtable に差し替える**。
つまり Python の override 機構を Zig の `setVTable` に乗せる。
nimbus 側はすでに `vtable` がインスタンス毎の書き換え可能フィールドなので、機構が揃っている。

### トランポリン vtable（バインディング側で提供）
```c
// バインディングが提供 (nimbus core ではなく Python binding 側のコード)
static void py_paint_tramp(nmComponent* self, nmGraphics* g) {
    PyObject* py_self = nmComponentGetProperty(self, "__pyref__");
    PyGILState_STATE gs = PyGILState_Ensure();
    PyObject* pg = wrap_graphics(g);
    PyObject_CallMethod(py_self, "paint", "O", pg);
    Py_DECREF(pg);
    PyGILState_Release(gs);
}

static const nmVTable py_trampoline_vt = {
    .install      = py_install_tramp,
    .uninstall    = py_uninstall_tramp,
    .paint        = py_paint_tramp,
    .processEvent = py_process_event_tramp,
    .destroy      = py_destroy_tramp,
};
```

### Python wrapper の `__init__` で差し替え
override が定義されていたら、元 vtable を property に保存しつつトランポリンに差し替える。

```python
class Label:
    def __init__(self, ...):
        self._b = _create_label(...)
        if _has_override(type(self), "paint", "processEvent", ...):
            orig_vt = _lib.nimbusComponentGetVTable(self._b.component)
            _lib.nimbusComponentSetProperty(self._b.component, "__super_vt__", orig_vt)
            _lib.nimbusComponentSetProperty(self._b.component, "__pyref__", id(self))
            _lib.nimbusComponentSetVTable(self._b.component, _py_trampoline_vt)

    def paint(self, g):
        # super().paint(g) のデフォルト実装
        super_vt = _lib.nimbusComponentGetProperty(self._b.component, "__super_vt__")
        _lib.invoke_paint(super_vt, self._b.component, g._handle)
```

`super().paint(g)` は「property に保存しておいた元 vtable の paint を直接呼ぶ」で実現できる。
`MyMyLabel(MyLabel)` がさらに paint を override しても再帰的に super() でたどれる。

## ライフサイクル
ここが唯一の罠。
Python wrapper が GC されたあと Zig が paint を呼んで死んだ PyObject にディスパッチ、を避けるため refcount を Zig 側の所有関係に合わせる。

| イベント | 動作 |
|---|---|
| Python wrapper 生成 | 自然な refcount |
| `Container.add(child)` | Python wrapper の refcount を **+1**（Zig 側が所有することの表現） |
| `Container.destroy` → `vtable.destroy` | トランポリンの destroy が PyObject を **-1**、そのあと元 destroy にチェーン |
| Python wrapper の `__del__` | （refcount 0 になった時）Zig 側はもう参照していないので普通に通る |

add / remove で refcount を ±1 するのは標準パターン。
これはバインディング側の責務で nimbus core に変更は不要。

## nimbus core に必要な変更
ほぼ無い。既存の設計が十分。

| 必要なもの | 状態 |
|---|---|
| インスタンス毎の vtable | ✓ `Component.vtable: *const VTable` |
| vtable 差し替え API | ✓ `Component.setVTable` |
| インスタンス毎の side data | ✓ `Component.properties`（PyRef、super_vt を入れる） |
| vtable 解放フック | ✓ `Component.VTable.destroy` |
| 派生型のアップキャスト | △ 派生型ごとに `asXxx`（Zig は `&self.foo.bar` を返す薄い関数） |
| **現在の vtable を読む getter** | ✗ `Component.getVTable()` を追加する必要あり |
| vtable 経由でない直接 invoke 補助 | △ 元 vt の関数ポインタを取り出して直接 call できるので、ヘルパは無くても良い |

つまり nimbus core への追加は **`getVTable` を 1 個生やすだけ**で Python（および他言語）の継承拡張が機能する。
派生型の `asXxx` は C ABI 着手時に派生型ごとに添える（Zig 側は `&self.foo.bar` の 1 行）。

## 副次的な効果
この機構は Python だけでなく以下にも効く。

* **Lua / Ruby / Swift バインディング**: 同じパターンで動く
* **L&F の実装**: 元 vtable を property に保存して、新 vtable から super 呼び出しできる機構が成立する。
  「`setVTable` は full replace」という制約が super_vt convention を使えば緩む
* **テスト**: paint を mock vtable に差し替えて呼び出し回数を検証、等が同じ仕組みで書ける

## 関連 doc
* `component.md` — vtable / setVTable / properties / destroy の詳細
* `lookandfeel.md` — 「nimbus 自身は L&F 機構を提供せず、拡張点だけ露出する」の方針
