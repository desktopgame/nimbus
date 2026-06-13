"use strict";

// textlint rule: flag lines whose display width exceeds a limit.
// Width is measured in terminal columns: East Asian Wide / Fullwidth
// characters count as 2, everything else as 1. This targets visual line
// wrapping, which raw character count (sentence-length) does not capture.

const DEFAULT_MAX = 80;

// East Asian Width "Wide" / "Fullwidth" code point ranges. A pragmatic subset
// covering the scripts these docs actually use (CJK, kana, fullwidth forms).
function isWide(cp) {
  return (
    (cp >= 0x1100 && cp <= 0x115f) || // Hangul Jamo
    (cp >= 0x2e80 && cp <= 0x303e) || // CJK radicals .. CJK symbols / punctuation
    (cp >= 0x3041 && cp <= 0x33ff) || // Hiragana, Katakana, CJK compat
    (cp >= 0x3400 && cp <= 0x4dbf) || // CJK Ext A
    (cp >= 0x4e00 && cp <= 0x9fff) || // CJK Unified Ideographs
    (cp >= 0xa000 && cp <= 0xa4cf) || // Yi
    (cp >= 0xac00 && cp <= 0xd7a3) || // Hangul Syllables
    (cp >= 0xf900 && cp <= 0xfaff) || // CJK Compatibility Ideographs
    (cp >= 0xfe30 && cp <= 0xfe4f) || // CJK Compatibility Forms
    (cp >= 0xff00 && cp <= 0xff60) || // Fullwidth Forms
    (cp >= 0xffe0 && cp <= 0xffe6) || // Fullwidth signs
    (cp >= 0x20000 && cp <= 0x3fffd)  // CJK Ext B and beyond
  );
}

// Measure the display width of a line and find the char index at which the
// cumulative width first exceeds `max` (-1 if it never does). The index is in
// UTF-16 code units so it maps back to the source for error reporting.
function measure(line, max) {
  let width = 0;
  let overflowIndex = -1;
  let i = 0;
  for (const ch of line) {
    width += isWide(ch.codePointAt(0)) ? 2 : 1;
    if (overflowIndex === -1 && width > max) {
      overflowIndex = i;
    }
    i += ch.length;
  }
  return { width, overflowIndex };
}

module.exports = function (context, options = {}) {
  const { Syntax, RuleError, report, getSource, locator } = context;
  const max = typeof options.max === "number" ? options.max : DEFAULT_MAX;
  const skipCodeBlocks = options.skipCodeBlocks !== false;

  return {
    [Syntax.Document](node) {
      const text = getSource(node);
      const lines = text.split("\n");
      let offset = 0;
      let inFence = false;

      for (const raw of lines) {
        // Strip a trailing CR so CRLF files do not inflate the width by one.
        const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
        const isFence = /^\s*(```|~~~)/.test(line);

        if (isFence) {
          inFence = !inFence;
        } else if (!(skipCodeBlocks && inFence)) {
          const { width, overflowIndex } = measure(line, max);
          if (overflowIndex !== -1) {
            report(
              node,
              new RuleError(
                `行の表示幅が ${width} 桁で、上限 ${max} 桁を超えています。`,
                { padding: locator.at(offset + overflowIndex) }
              )
            );
          }
        }

        offset += raw.length + 1; // +1 for the "\n" removed by split
      }
    },
  };
};
