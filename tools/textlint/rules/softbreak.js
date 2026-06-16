"use strict";

// textlint rule: flag soft / hard line breaks that are invisible in source.
// Two triggers, both of which produce a line break that is easy to introduce
// by accident and hard to see in review:
//   - trailing whitespace at end of line (one or more spaces / tabs).
//   - a trailing backslash, i.e. the Markdown hard line break ("foo\").
// Fenced code blocks are exempt: code examples legitimately end lines with a
// continuation backslash or trailing whitespace, and flagging those would be
// noise. textlint does not pass .textlintrc options to rules loaded via
// --rulesdir (options arrive empty), so behavior lives here.

module.exports = function (context, options = {}) {
  const { Syntax, RuleError, report, getSource, locator } = context;
  const skipCodeBlocks = options.skipCodeBlocks !== false;

  return {
    [Syntax.Document](node) {
      const text = getSource(node);
      const lines = text.split("\n");
      let offset = 0;
      let inFence = false;

      for (const raw of lines) {
        // Strip a trailing CR so CRLF files do not look like trailing space.
        const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
        const isFence = /^\s*(```|~~~)/.test(line);

        if (isFence) {
          inFence = !inFence;
        } else if (!(skipCodeBlocks && inFence)) {
          // Markdown hard break: a backslash as the final character.
          if (/\\$/.test(line)) {
            report(
              node,
              new RuleError(
                "行末のバックスラッシュ（Markdown ハードブレーク）は使わないでください。",
                { padding: locator.at(offset + line.length - 1) }
              )
            );
          } else {
            // Trailing whitespace (spaces / tabs before the line end).
            const trailing = /[ \t]+$/.exec(line);
            if (trailing) {
              report(
                node,
                new RuleError(
                  "行末に空白があります。",
                  { padding: locator.at(offset + trailing.index) }
                )
              );
            }
          }
        }

        offset += raw.length + 1; // +1 for the "\n" removed by split
      }
    },
  };
};
