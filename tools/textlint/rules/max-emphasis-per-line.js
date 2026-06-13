"use strict";

// textlint rule: limit emphasis (asterisk) spans per line, to curb the common
// LLM tendency to over-bold. A heading line may hold a few; a normal line at
// most one. Counts both Strong (**...**) and Emphasis (*...*). Emphasis inside
// code is not part of the AST, so code spans / blocks are naturally exempt.
//
// textlint does not pass .textlintrc options to rules loaded via --rulesdir
// (options arrive empty), so the limits live here. Edit these constants.
const DEFAULT_MAX_LINE = 1;
const DEFAULT_MAX_HEADING = 2;

module.exports = function (context, options = {}) {
  const { Syntax, RuleError, report } = context;
  const maxLine =
    typeof options.maxLine === "number" ? options.maxLine : DEFAULT_MAX_LINE;
  const maxHeading =
    typeof options.maxHeading === "number" ? options.maxHeading : DEFAULT_MAX_HEADING;

  return {
    [Syntax.Document](node) {
      // emphasis spans grouped by their start line, and the set of heading lines
      const emphByLine = new Map();
      const headingLines = new Set();

      const visit = (n, inHeading) => {
        if (n.type === Syntax.Strong || n.type === Syntax.Emphasis) {
          const line = n.loc.start.line;
          if (!emphByLine.has(line)) {
            emphByLine.set(line, []);
          }
          emphByLine.get(line).push(n);
          if (inHeading) {
            headingLines.add(line);
          }
          return; // count the whole span once; do not descend into it
        }
        if (n.type === Syntax.Header) {
          headingLines.add(n.loc.start.line);
        }
        const nowHeading = inHeading || n.type === Syntax.Header;
        if (n.children) {
          for (const child of n.children) {
            visit(child, nowHeading);
          }
        }
      };
      visit(node, false);

      for (const [line, nodes] of emphByLine) {
        const isHeading = headingLines.has(line);
        const limit = isHeading ? maxHeading : maxLine;
        if (nodes.length > limit) {
          const where = isHeading ? "見出し" : "行";
          // point at the first span beyond the limit
          report(
            nodes[limit],
            new RuleError(
              `${where}内の強調（アスタリスク）が ${nodes.length} 個で、上限 ${limit} 個を超えています。`
            )
          );
        }
      }
    },
  };
};
