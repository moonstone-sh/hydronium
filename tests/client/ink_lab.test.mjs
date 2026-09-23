import test from "node:test";
import assert from "node:assert/strict";

import { colorToCss, keyboardEvent, paintFrame } from "../../ink-lab/src/hydronium_ink_lab/client/virtual_terminal.js";

test("Ink Lab preserves terminal palette references and absolute colors", () => {
  assert.match(colorToCss({ kind: "palette", index: 9 }), /--hy-terminal-bright-red/);
  assert.equal(colorToCss({ kind: "index", index: 196 }), "rgb(255 0 0)");
  assert.equal(colorToCss({ kind: "rgb", r: 12, g: 34, b: 56 }), "rgb(12 34 56)");
});

test("Ink Lab maps browser keyboard events to Ink key events", () => {
  assert.deepEqual(keyboardEvent({
    key: "ArrowDown", ctrlKey: false, shiftKey: true, metaKey: false,
  }), {
    op: "input",
    input: "",
    key: {
      ctrl: false, shift: true, meta: false, tab: false, return: false,
      escape: false, backspace: false, delete: false, upArrow: false,
      downArrow: true, leftArrow: false, rightArrow: false, pageUp: false,
      pageDown: false, home: false, end: false,
    },
  });
});

test("Ink Lab paints canonical cells directly without an ANSI intermediate", () => {
  class Node {
    constructor(document, fragment = false) {
      this.ownerDocument = document;
      this.fragment = fragment;
      this.children = [];
      this.style = {};
      this.dataset = {};
      this.textContent = "";
    }
    replaceChildren(...children) {
      // Real DOM insertion moves a DocumentFragment's children into the
      // target; keep this tiny test double faithful to that behavior.
      this.children = children.flatMap((child) => child.fragment ? child.children : [child]);
    }
    appendChild(child) {
      if (child.fragment) this.children.push(...child.children);
      else this.children.push(child);
    }
  }
  const document = {
    createElement() { return new Node(document); },
    createDocumentFragment() { return new Node(document, true); },
  };
  const terminal = new Node(document);
  paintFrame(terminal, {
    version: 1,
    width: 1,
    height: 1,
    cursor: { x: 0, y: 0 },
    rows: [[{
      ch: "λ", fg: { kind: "rgb", r: 12, g: 34, b: 56 }, bg: null,
      bold: true, dim: false, italic: false, underline: false,
      strikethrough: false, inverse: false,
    }]],
  });
  assert.equal(terminal.children[0].textContent, "λ");
  assert.equal(terminal.children[0].style.color, "rgb(12 34 56)");
  assert.equal(terminal.children[0].style.fontWeight, "700");
  assert.equal(terminal.children[0].dataset.cursor, "");
  assert.equal(terminal.dataset.columns, "1");
});
