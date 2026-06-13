"use strict";

// textlint rule: limit emphasis (asterisk) spans, to curb the common LLM
// tendency to over-bold. Two limits:
//   - per line: at most 1 emphasis span.
//   - per section: at most 2 emphasis spans in the body that hangs under a
//     heading (from one heading until the next). The heading's own emphasis is
//     not counted toward the section, only toward its own line.
// Counts both Strong (**...**) and Emphasis (*...*). Emphasis inside code is
// not part of the AST, so code spans / blocks are naturally exempt.
//
// textlint does not pass .textlintrc options to rules loaded via --rulesdir
// (options arrive empty), so the limits live here. Edit these constants.
const DEFAULT_MAX_LINE = 1;
const DEFAULT_MAX_SECTION = 2;

module.exports = function (context, options = {}) {
  const { Syntax, RuleError, report } = context;
  const maxLine =
    typeof options.maxLine === "number" ? options.maxLine : DEFAULT_MAX_LINE;
  const maxSection =
    typeof options.maxSection === "number" ? options.maxSection : DEFAULT_MAX_SECTION;

  // Collect emphasis spans under a node without descending into a span
  // (so bold-italic nesting counts once).
  const collect = (node, out) => {
    if (node.type === Syntax.Strong || node.type === Syntax.Emphasis) {
      out.push(node);
      return;
    }
    if (node.children) {
      for (const child of node.children) {
        collect(child, out);
      }
    }
  };

  return {
    [Syntax.Document](node) {
      const byLine = new Map(); // line -> emphasis nodes (per-line check)
      const addByLine = (em) => {
        const line = em.loc.start.line;
        if (!byLine.has(line)) {
          byLine.set(line, []);
        }
        byLine.get(line).push(em);
      };

      // Walk top-level blocks in order; a Header closes the current section.
      let section = []; // body emphasis spans of the current section
      const flushSection = () => {
        if (section.length > maxSection) {
          report(
            section[maxSection],
            new RuleError(
              `見出し配下の本文の強調（アスタリスク）が ${section.length} 個で、上限 ${maxSection} 個を超えています。`
            )
          );
        }
        section = [];
      };

      for (const block of node.children || []) {
        const spans = [];
        collect(block, spans);
        spans.forEach(addByLine);
        if (block.type === Syntax.Header) {
          flushSection(); // close the section that preceded this heading
          // the heading's own emphasis counts for the line check only
        } else {
          for (const span of spans) {
            section.push(span);
          }
        }
      }
      flushSection();

      for (const [, spans] of byLine) {
        if (spans.length > maxLine) {
          report(
            spans[maxLine],
            new RuleError(
              `行の強調（アスタリスク）が ${spans.length} 個で、上限 ${maxLine} 個を超えています。`
            )
          );
        }
      }
    },
  };
};
