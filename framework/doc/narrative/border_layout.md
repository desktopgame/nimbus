---
unsafe: false
---

# border_layout
BorderLayout の配置アルゴリズム・min/max ポリシー・hint 表現・シングルトン理由。

## レイアウトアルゴリズム
container の bounds を `(W, H)` とし、各 region の子を取り出す（存在しないものは無視）。

1. **north 高さ** `nh` = `north.min_size.height`（無ければ 0）
2. **south 高さ** `sh` = `south.min_size.height`（無ければ 0）
3. **west 幅** `ww` = `west.min_size.width`（無ければ 0）
4. **east 幅** `ew` = `east.min_size.width`（無ければ 0）
5. 各 region に以下の bounds をセット:

| region | x | y | width | height |
|---|---|---|---|---|
| north | 0 | 0 | W | nh |
| south | 0 | H - sh | W | sh |
| west | 0 | nh | ww | H - nh - sh |
| east | W - ew | nh | ew | H - nh - sh |
| center | ww | nh | W - ww - ew | H - nh - sh |

N/S は full width。corners は N/S が取る（VSCode / Outlook 慣例）。
center を埋める子が無くてもよい（その場合中央領域は空のまま）。

## min_size / max_size の扱い
* N/S の高さは子の `min_size.height` をそのまま使う。`max_size.height` は無視（バーは min サイズで表示するのが普通）
* E/W の幅も同様に子の `min_size.width` を使う
* N/S の幅は container 幅に強制（子の `max_size.width` を無視して full width に伸ばす）
* E/W の高さも同様に N/S を除いた縦領域いっぱいに伸ばす
* center は残り領域いっぱい

子側で「自分は full width にはなりたくない」と表現する手段は提供しない（要件なら center に Panel + BoxLayout + Filler でラップ）。

## hint の表現
region は `Region` enum で表現するが、hint は `*anyopaque` なので、各 region に対応する static アドレスを用意してそのポインタを hint に格納する。
内部実装：

```zig
var markers = [_]u8{ 0, 0, 0, 0, 0 };
pub fn marker(r: Region) *anyopaque { return &markers[@intFromEnum(r)]; }
```

利用者は `BorderLayout.add(container, .north, child)` を呼ぶだけで marker のことは気にしなくてよい。

## computeMinSize の計算
| 軸 | 計算 |
|---|---|
| width | `max(N.min_w, S.min_w, W.min_w + max(C.min_w, 0) + E.min_w)` |
| height | `N.min_h + max(W.min_h, max(C.min_h, 0), E.min_h) + S.min_h` |

存在しない region は 0 として扱う。

## computeMaxSize の計算
常に `(inf, inf)`。
BorderLayout は center が伸びる前提なので、上限は持たない。

## シングルトンとして提供する理由
BoxLayout と同様、インスタンス固有の状態を持たない。
`pub var` の static インスタンスを 1 つ用意し、`get()` がそのアドレスを返す。
LayoutManager の vtable は `deinit = null`（解放不要）。

## center のみのケース
center だけ指定するのは「container いっぱいに 1 つの子を配置」と同じ。
ただし、それなら BorderLayout を介さず `container.setBounds` の伝搬に任せた方が素直。
BorderLayout の典型用途はあくまで N/S/E/W も合わせて使うケース。
