---
unsafe: true
---

# color
色の表現と生成。

## 型定義
```zig
pub const Color = struct {
    r: f32, g: f32, b: f32, a: f32,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color;
    pub fn rgb(r: f32, g: f32, b: f32) Color;
    pub fn bytes(r: u8, g: u8, b: u8, a: u8) Color;
};
```

各成分は `0.0` ~ `1.0` の `f32` で保持する。
`a` は不透明度で、`1.0` が完全不透明、`0.0` が完全透明を表す。

色空間は当面 linear / sRGB の区別を持たず、すべて linear として扱う。
利用者がガンマ補正を意識する必要はない。

## f32 成分による色の生成
```zig
pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color;
```

4 成分を `f32` で指定する基本コンストラクタ。

## 不透明色の生成
```zig
pub fn rgb(r: f32, g: f32, b: f32) Color;
```

`a = 1.0` (完全不透明) を補う `rgba` の短縮形。

## バイト値による色の生成
```zig
pub fn bytes(r: u8, g: u8, b: u8, a: u8) Color;
```

`0` ~ `255` の `u8` を `0.0` ~ `1.0` の `f32` に変換するコンストラクタ。
Web 色 (`#RRGGBBAA`) の値をそのまま渡したい場合などに使う。

## 機能要望
* HSL / HSV 系コンストラクタ。
* 16 進文字列パーサ (`fromHex("#RRGGBB")` 等)。
* sRGB / linear の明示的な区別、およびガンマ補正の指定。
