//! Shared menu painting helpers.

const awt = @import("awt");

/// Underline the mnemonic letter (always shown in v1; Alt-reveal deferred).
/// Uses the color currently set on `g` (= the label's text color).
pub fn drawMnemonicUnderline(
    g: *awt.Graphics,
    font: awt.Graphics.TextFont,
    text: []const u8,
    mnemonic_index: ?usize,
    tx: f32,
    ty: f32,
    text_h: f32,
) void {
    const mi = mnemonic_index orelse return;
    if (mi >= text.len) return;
    const prefix_w = font.measureString(text[0..mi]).width;
    const ch_w = font.measureString(text[mi .. mi + 1]).width;
    g.fillRect(.{ .x = tx + prefix_w, .y = ty + text_h - 1, .width = ch_w, .height = 1 });
}
