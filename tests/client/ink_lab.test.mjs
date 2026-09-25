import test from "node:test";
import assert from "node:assert/strict";

import {
  colorToCss, keyboardEvent, paintFrame, createFrameModel, applyFrame, flushFrameModel, createAnimationPacer,
} from "../../ink-lab/src/hydronium_ink_lab/client/virtual_terminal.js";

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

// A minimal DOM double faithful enough for `paintFrame`/`flushFrameModel`:
// tracks children, style, and dataset the same way real elements do.
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

function makeContainer() {
  const document = {
    createElement() { return new Node(document); },
    createDocumentFragment() { return new Node(document, true); },
  };
  return new Node(document);
}

const RED_BOLD = { fg: { kind: "rgb", r: 12, g: 34, b: 56 }, bg: null, bold: true, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
const GREEN = { fg: { kind: "rgb", r: 0, g: 200, b: 0 }, bg: null, bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };

test("Ink Lab paints canonical cells directly from style-interned row runs", () => {
  const terminal = makeContainer();
  paintFrame(terminal, {
    version: 2, kind: "full", seq: 1, width: 1, height: 1,
    cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
    styles: { 1: RED_BOLD },
    rows: [[[1, ["λ"]]]],
  });
  assert.equal(terminal.children[0].textContent, "λ");
  assert.equal(terminal.children[0].style.color, "rgb(12 34 56)");
  assert.equal(terminal.children[0].style.fontWeight, "700");
  assert.equal(terminal.children[0].dataset.cursor, "");
  assert.equal(terminal.dataset.columns, "1");
});

test("Ink Lab full frame reproduces every cell, including a wide-glyph's empty continuation cell", () => {
  const model = createFrameModel();
  const terminal = makeContainer();
  // "文" (2 cells wide) + "!" (1 cell), run-length encoded as one style run
  // whose second character is the empty continuation cell.
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 3, height: 1, cursor: null, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["文", "", "!"]]]],
  });
  flushFrameModel(terminal, model);
  assert.equal(terminal.children[0].textContent, "文");
  assert.equal(terminal.children[1].textContent, "");
  assert.equal(terminal.children[2].textContent, "!");
  assert.equal(terminal.children[0].style.color, "rgb(0 200 0)");
});

test("Ink Lab delta application changes only the addressed cells and reproduces a full-frame repaint", () => {
  const model = createFrameModel();
  const terminal = makeContainer();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 4, height: 1, cursor: { x: 0, y: 0 }, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b", "c", "d"]]]],
  });
  flushFrameModel(terminal, model);
  assert.deepEqual(terminal.children.map((cell) => cell.textContent), ["a", "b", "c", "d"]);

  // A delta touching only column 2 must reuse the already-known style (no
  // `styles` payload) and leave every other cell's span untouched.
  const untouchedSpan = terminal.children[3];
  const { activity } = applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: { x: 1, y: 0 }, status: null,
    changes: [[0, 1, 1, ["X"]]],
  });
  assert.equal(activity, true);
  flushFrameModel(terminal, model);
  assert.deepEqual(terminal.children.map((cell) => cell.textContent), ["a", "X", "c", "d"]);
  assert.equal(terminal.children[3], untouchedSpan, "an untouched cell keeps the exact same DOM node");
  assert.equal(terminal.children[0].dataset.cursor, undefined, "cursor dataset is cleared off the cell it left, even though that cell wasn't in `changes`");
  assert.equal(terminal.children[1].dataset.cursor, "");

  // Reconstructing straight from a full frame with the same content must
  // match the delta-built model cell for cell.
  const reference = createFrameModel();
  const referenceTerminal = makeContainer();
  applyFrame(reference, {
    version: 2, kind: "full", seq: 99, width: 4, height: 1, cursor: { x: 1, y: 0 }, status: null,
    styles: { 7: GREEN },
    rows: [[[7, ["a", "X", "c", "d"]]]],
  });
  flushFrameModel(referenceTerminal, reference);
  assert.deepEqual(
    terminal.children.map((cell) => [cell.textContent, cell.style.color]),
    referenceTerminal.children.map((cell) => [cell.textContent, cell.style.color]),
  );
});

test("Ink Lab delta application carries a style change and only ships genuinely new styles", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 2, height: 1, cursor: null, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b"]]]],
  });
  const BLUE = { fg: { kind: "rgb", r: 0, g: 0, b: 255 }, bg: null, bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
  applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: null, status: null,
    styles: { 2: BLUE },
    changes: [[0, 0, 2, ["a"]]],
  });
  assert.deepEqual(model.styles.get(2), BLUE);
  assert.deepEqual(model.styles.get(1), GREEN, "a style not resent must still be resolvable from an earlier frame");
  assert.equal(model.styleIds[0], 2);
  assert.equal(model.styleIds[1], 1);
});

test("Ink Lab treats an idle delta (no changes, no cursor/status change) as no activity", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 2, height: 1, cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b"]]]],
  });
  const { activity } = applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
  });
  assert.equal(activity, false);
});

test("Ink Lab rejects a delta whose base does not match the model's last applied frame", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 1, height: 1, cursor: null, status: null,
    styles: { 1: GREEN }, rows: [[[1, ["a"]]]],
  });
  assert.throws(() => applyFrame(model, {
    version: 2, kind: "delta", seq: 3, base: 2, cursor: null, status: null, changes: [[0, 0, 1, ["b"]]],
  }), (error) => error.desync === true);
});

test("Ink Lab's animation pacer holds a steady cadence while animating and backs off once idle", () => {
  const pacer = createAnimationPacer({ baseDelayMs: 55, idleThreshold: 3, maxDelayMs: 500, idleGrowth: 2 });
  assert.equal(pacer.delay, 55);
  pacer.noteActivity();
  pacer.noteActivity();
  assert.equal(pacer.delay, 55, "activity keeps the base cadence");

  pacer.noteIdle();
  pacer.noteIdle();
  assert.equal(pacer.delay, 55, "backoff only starts after idleThreshold consecutive idle ticks");
  pacer.noteIdle();
  assert.equal(pacer.delay, 110);
  pacer.noteIdle();
  assert.equal(pacer.delay, 220);
  pacer.noteIdle();
  assert.equal(pacer.delay, 440);
  pacer.noteIdle();
  assert.equal(pacer.delay, 500, "backoff is capped at maxDelayMs");

  pacer.noteActivity();
  assert.equal(pacer.delay, 55, "any activity resumes the base cadence immediately");
});
